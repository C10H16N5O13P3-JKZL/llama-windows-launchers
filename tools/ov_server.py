"""Minimal OpenAI-compatible chat server on OpenVINO GenAI (NPU/GPU/CPU).

Endpoints: GET /health, GET /v1/models, POST /v1/chat/completions (stream or not).
One request at a time (the NPU pipeline is single-sequence).

usage: python ov_server.py --model DIR [--device NPU] [--port 8080] [--host 127.0.0.1]
                           [--max-prompt 4096] [--max-response 4096] [--vlm]
"""
import argparse, json, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import openvino_genai as ov_genai

ap = argparse.ArgumentParser()
ap.add_argument("--model", required=True)
ap.add_argument("--device", default="NPU")
ap.add_argument("--host", default="127.0.0.1")
ap.add_argument("--port", type=int, default=8080)
ap.add_argument("--max-prompt", type=int, default=4096, help="NPU: max prompt tokens")
ap.add_argument("--max-response", type=int, default=4096, help="NPU: guaranteed response tokens")
ap.add_argument("--vlm", action="store_true", help="model is a VLM (e.g. Qwen3.5); text chat only")
args = ap.parse_args()

model_name = Path(args.model).name
cfg = {"MAX_PROMPT_LEN": args.max_prompt, "MIN_RESPONSE_LEN": args.max_response} if args.device == "NPU" else {}
print(f"Loading {model_name} on {args.device} {cfg} ...", flush=True)
t0 = time.time()
pipe = (ov_genai.VLMPipeline if args.vlm else ov_genai.LLMPipeline)(args.model, args.device, **cfg)
print(f"Loaded in {time.time() - t0:.0f}s", flush=True)
lock = threading.Lock()


def make_config(req):
    gc = pipe.get_generation_config()
    gc.max_new_tokens = int(req.get("max_tokens") or req.get("max_completion_tokens") or args.max_response)
    temp = float(req.get("temperature", 0.7))
    gc.do_sample = temp > 0
    if gc.do_sample:
        gc.temperature = temp
        gc.top_p = float(req.get("top_p", 1.0))
        gc.top_k = int(req.get("top_k", 50))
    gc.repetition_penalty = float(req.get("repetition_penalty", 1.0))
    if req.get("stop"):
        gc.stop_strings = set([req["stop"]] if isinstance(req["stop"], str) else req["stop"])
    return gc


def text_of(content):
    if isinstance(content, list):  # OpenAI content parts
        return "".join(p.get("text", "") for p in content if isinstance(p, dict))
    return content or ""


def run(messages, gc, on_token=None):
    msgs = [{"role": m["role"], "content": text_of(m.get("content"))} for m in messages]
    streamer = (lambda s: (on_token(s), ov_genai.StreamingStatus.RUNNING)[1]) if on_token else None
    if args.vlm:
        hist = ov_genai.ChatHistory()
        for m in msgs:
            hist.append(m)
        r = pipe.generate(hist, generation_config=gc, streamer=streamer)
    else:
        prompt = pipe.get_tokenizer().apply_chat_template(msgs, add_generation_prompt=True)
        r = pipe.generate([prompt], gc, streamer=streamer)
    pm = r.perf_metrics
    return r.texts[0], pm.get_num_input_tokens(), pm.get_num_generated_tokens(), pm.get_throughput().mean


def split_reasoning(text):
    if "</think>" in text:
        reasoning, content = text.split("</think>", 1)
        return reasoning.replace("<think>", "").strip(), content.strip()
    return None, text


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"status": "ok", "device": args.device, "model": model_name})
        elif self.path == "/v1/models":
            self._json(200, {"object": "list", "data": [{"id": model_name, "object": "model", "owned_by": "openvino"}]})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path not in ("/v1/chat/completions", "/chat/completions"):
            return self._json(404, {"error": {"message": "not found"}})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            gc = make_config(req)
        except Exception as e:
            return self._json(400, {"error": {"message": f"bad request: {e}"}})
        cid, created = "chatcmpl-" + uuid.uuid4().hex[:24], int(time.time())
        with lock:
            if req.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Connection", "close")
                self.end_headers()

                def send(delta, finish=None):
                    chunk = {"id": cid, "object": "chat.completion.chunk", "created": created, "model": model_name,
                             "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                    self.wfile.write(f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode("utf-8"))
                    self.wfile.flush()

                send({"role": "assistant"})
                try:
                    _, _, n_out, _ = run(req["messages"], gc, on_token=lambda s: send({"content": s}))
                    send({}, "length" if n_out >= gc.max_new_tokens else "stop")
                    self.wfile.write(b"data: [DONE]\n\n")
                except (BrokenPipeError, ConnectionResetError):
                    pass
                self.close_connection = True
                return
            text, n_in, n_out, tps = run(req["messages"], gc)
        reasoning, content = split_reasoning(text)
        msg = {"role": "assistant", "content": content}
        if reasoning is not None:
            msg["reasoning_content"] = reasoning
        self._json(200, {
            "id": cid, "object": "chat.completion", "created": created, "model": model_name,
            "choices": [{"index": 0, "message": msg,
                         "finish_reason": "length" if n_out >= gc.max_new_tokens else "stop"}],
            "usage": {"prompt_tokens": n_in, "completion_tokens": n_out, "total_tokens": n_in + n_out},
            "timings": {"predicted_per_second": tps},
        })

    def log_message(self, fmt, *a):
        print(f"{self.address_string()} {fmt % a}", flush=True)


print(f"listening on http://{args.host}:{args.port}  (OpenAI API at /v1)", flush=True)
ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
