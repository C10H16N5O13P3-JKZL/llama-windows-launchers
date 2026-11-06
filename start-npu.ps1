# Start an OpenAI-compatible chat server on the Intel NPU.
# Only models verified to compute correctly on this NPU are offered; the model is downloaded on first use.
#   lfm2.5   (default) -> llama-server from llama-openvino (llama.cpp OpenVINO backend), GGUF, has a web UI
#   qwen3-8b           -> OpenVINO GenAI + tools\ov_server.py (2x faster than llama-server for this model on NPU)
# Usage:  powershell -ExecutionPolicy Bypass -File .\start-npu.ps1 [-Model lfm2.5|qwen3-8b|<file.gguf>|<IR dir>] [-Port 28081]
param(
    [Alias('m')][string]$Model = "lfm2.5",
    [Alias('p')][int]$Port = 28081,              # 28081 so it can run next to the iGPU server on 28080
    [Alias('addr')][string]$HostAddr = "127.0.0.1",
    [Alias('c')][int]$Ctx = 4096,               # llama-server: NPU attends over the whole ctx every token, keep it small
    [Alias('mp')][int]$MaxPrompt = 4096,         # OpenVINO GenAI: static NPU limits
    [Alias('mr')][int]$MaxResponse = 4096,
    [Alias('v')][string]$Version = '',
    [Alias('x')][string[]]$ExtraArgs = @(),
    [Alias('d')][switch]$DryRun,
    [Alias('h')][switch]$Help
)
if ($Help) {
    @'
Usage: start-npu.bat [-m MODEL] [options]
  -m    -Model        lfm2.5 (default), qwen3-8b, GGUF path or IR folder.
  -p    -Port         Server port (default: 28081).
  -addr -HostAddr     Bind address (default: 127.0.0.1).
  -c    -Ctx          GGUF context size (default: 4096).
  -mp   -MaxPrompt    GenAI prompt limit (default: 4096).
  -mr   -MaxResponse  GenAI response limit (default: 4096).
  -v    -Version      Installed bNNNNN or legacy; GGUF only.
  -x    -ExtraArgs    Native llama args; GGUF only, array via .ps1.
  -d    -DryRun       Preview without starting or downloading models.
  -h    -Help         Show this help.
Examples:
  start-npu.bat -m "E:\models\model.gguf" -v legacy -c 4096
  start-npu.bat -m qwen3-8b -mp 4096 -mr 2048
  .\start-npu.ps1 -x @('--swa-full')
Default version: selected OpenVINO runtime. qwen3-8b uses GenAI instead.
NPU support and output quality depend on the model and runtime.
'@
    return
}

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tools\llama-runtime.ps1"
if ($Port -lt 1 -or $Port -gt 65535 -or $Ctx -lt 1) { throw 'Invalid Port or Ctx.' }
# short name -> GGUF (llama-server) or OpenVINO IR repo (ov_server.py); both passed quality checks on NPU
$gguf = @{
    "lfm2.5" = @{ repo = "LiquidAI/LFM2.5-1.2B-Instruct-GGUF"; file = "LFM2.5-1.2B-Instruct-Q4_K_M.gguf" }  # ~49 tok/s
}
$ir = @{
    "qwen3-8b" = "OpenVINO/Qwen3-8B-int4-cw-ov"   # 4.4 GB, ~16 tok/s on NPU, thinks
}
$key = $Model.ToLower()

function Start-LlamaNpu([string]$path) {
    $path = Resolve-Gguf $path
    $exe = Get-LlamaRuntime 'openvino' $Version
    $launchArgs = @('-m', $path, '-c', "$Ctx", '-np', '1', '--host', $HostAddr, '--port', "$Port") + $ExtraArgs
    Write-Host "Runtime: $exe"
    if ($DryRun) { $launchArgs | ConvertTo-Json; return }
    $env:GGML_OPENVINO_DEVICE = "NPU"
    # GGML_OPENVINO_CACHE_DIR breaks NPU compilation ("WeightlessCacheAttribute"), keep it unset
    Remove-Item Env:GGML_OPENVINO_CACHE_DIR -ErrorAction SilentlyContinue
    Write-Host "NPU llama-server: $path  ctx $Ctx  http://${HostAddr}:$Port  (first start compiles for the NPU, ~30 s)"
    # -np 1: the NPU backend does not support parallel sequences
    & $exe @launchArgs
    exit $LASTEXITCODE
}

function Start-GenaiNpu([string]$dir) {
    if ($Version -or $ExtraArgs.Count) { throw 'Version and ExtraArgs only apply to GGUF/llama.cpp, not GenAI.' }
    if ($DryRun) { Write-Host "GenAI NPU model: $dir"; return }
    $py = "$PSScriptRoot\ov-venv\Scripts\python.exe"
    if (-not (Test-Path $py)) {
        Write-Host "Creating ov-venv with OpenVINO GenAI (nightly, needed for NPU LLM support)..."
        python -m venv "$PSScriptRoot\ov-venv"
        & $py -m pip install -q -U pip
        & $py -m pip install -q -U --pre openvino-genai openvino-tokenizers openvino huggingface_hub `
            --extra-index-url https://storage.openvinotoolkit.org/simple/wheels/nightly
    }
    if ($dir -match '^OpenVINO/') {
        $repo = $dir; $dir = "$PSScriptRoot\models\" + ($repo -split "/")[1]
        if (-not (Test-Path "$dir\openvino_model.xml")) {
            Write-Host "Downloading $repo ..."
            & $py -c "import huggingface_hub as h, sys; h.snapshot_download(sys.argv[1], local_dir=sys.argv[2])" $repo $dir
            if (-not (Test-Path "$dir\openvino_model.xml")) { Write-Error "Download failed: $repo"; exit 1 }
        }
    }
    Write-Host "NPU OpenVINO GenAI server: $dir  http://${HostAddr}:$Port/v1  (first start compiles for the NPU, ~30-90 s)"
    & $py "$PSScriptRoot\tools\ov_server.py" --model $dir --device NPU --host $HostAddr --port $Port `
        --max-prompt $MaxPrompt --max-response $MaxResponse
}

if ($gguf.ContainsKey($key)) {
    $path = "$PSScriptRoot\models\" + $gguf[$key].file
    if (-not (Test-Path $path)) {
        if ($DryRun) { throw "Model not downloaded: $path" }
        Write-Host "Downloading $($gguf[$key].repo)/$($gguf[$key].file) ..."
        $null = New-Item -ItemType Directory -Force -Path "$PSScriptRoot\models"
        $partial = "$path.$([guid]::NewGuid().ToString()).part"
        try {
            curl.exe -L --fail -o $partial "https://huggingface.co/$($gguf[$key].repo)/resolve/main/$($gguf[$key].file)"
            if ($LASTEXITCODE -ne 0) { throw 'Model download failed.' }
            Move-Item -LiteralPath $partial -Destination $path
        } finally {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        }
    }
    Start-LlamaNpu $path
} elseif ($ir.ContainsKey($key)) {
    Start-GenaiNpu $ir[$key]
} elseif ($Model -like "*.gguf") {
    Start-LlamaNpu $Model
} elseif (Test-Path "$Model\openvino_model.xml") {
    Start-GenaiNpu (Resolve-Path $Model).Path
} else {
    Write-Error "Unknown model '$Model'. Use one of: $(($gguf.Keys + $ir.Keys) -join ', '), a .gguf file, or an OpenVINO IR folder."
    exit 1
}
