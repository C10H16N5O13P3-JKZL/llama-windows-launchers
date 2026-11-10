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
Aliases download from Hugging Face into the models folder on first use;
set HF_ENDPOINT to use a mirror. Folders follow launcher.config.json.
NPU support and output quality depend on the model and runtime.
'@
    return
}

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tools\llama-runtime.ps1"
if ($Port -lt 1 -or $Port -gt 65535 -or $Ctx -lt 1) { throw 'Invalid Port or Ctx.' }
$config = Get-LlamaConfig
$modelsDir = $config.modelsDir
# HF_ENDPOINT is the Hugging Face convention for mirrors; huggingface_hub (GenAI path) honors it too.
$hfEndpoint = if ($env:HF_ENDPOINT) { $env:HF_ENDPOINT.TrimEnd('/') } else { 'https://huggingface.co' }
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
    $launchArgs = @('-m', $path, '-c', "$Ctx") + $LlamaBackends.openvino.LaunchArgs + @('--host', $HostAddr, '--port', "$Port") + $ExtraArgs
    Write-Host "Runtime: $exe"
    if ($DryRun) { $launchArgs | ConvertTo-Json; return }
    $env:GGML_OPENVINO_DEVICE = "NPU"
    # GGML_OPENVINO_CACHE_DIR breaks NPU compilation ("WeightlessCacheAttribute"), keep it unset
    Remove-Item Env:GGML_OPENVINO_CACHE_DIR -ErrorAction SilentlyContinue
    Write-Host "NPU llama-server: $path  ctx $Ctx  http://${HostAddr}:$Port  (first start compiles for the NPU, ~30 s)"
    & $exe @launchArgs
    exit $LASTEXITCODE
}

function Start-GenaiNpu([string]$dir) {
    if ($Version -or $ExtraArgs.Count) { throw 'Version and ExtraArgs only apply to GGUF/llama.cpp, not GenAI.' }
    if ($DryRun) { Write-Host "GenAI NPU model: $dir"; return }
    $venv = Join-Path $config.dataDir 'ov-venv'
    $py = Join-Path $venv 'Scripts\python.exe'
    $ready = Join-Path $venv '.launcher-ready'  # written only after a complete dependency install
    if (-not (Test-Path -LiteralPath $ready) -and (Test-Path -LiteralPath $py)) {
        # Environment created by an earlier launcher version: accept it if it already works.
        & $py -c "import openvino_genai, huggingface_hub" 2>$null
        if ($LASTEXITCODE -eq 0) { Set-Content -LiteralPath $ready -Value 'ok' }
    }
    if (-not (Test-Path -LiteralPath $ready)) {
        if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            throw 'Python was not found on PATH. The GenAI path needs Python; GGUF models (start-npu.bat -m file.gguf) do not.'
        }
        Write-Host "Creating $venv with OpenVINO GenAI (nightly, needed for NPU LLM support)..."
        python -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw "Could not create the Python environment: $venv" }
        & $py -m pip install -q -U pip
        & $py -m pip install -q -U --pre openvino-genai openvino-tokenizers openvino huggingface_hub `
            --extra-index-url https://storage.openvinotoolkit.org/simple/wheels/nightly
        if ($LASTEXITCODE -ne 0) { throw 'Installing OpenVINO GenAI failed; see the pip output above. Run again to retry.' }
        Set-Content -LiteralPath $ready -Value 'ok'
    }
    if ($dir -match '^OpenVINO/') {
        $repo = $dir; $dir = Join-Path $modelsDir ($repo -split "/")[1]
        if (-not (Test-Path -LiteralPath "$dir\openvino_model.xml")) {
            Write-Host "Downloading $repo ..."
            & $py -c "import huggingface_hub as h, sys; h.snapshot_download(sys.argv[1], local_dir=sys.argv[2])" $repo $dir
            if (-not (Test-Path -LiteralPath "$dir\openvino_model.xml")) { Write-Error "Download failed: $repo"; exit 1 }
        }
    }
    Write-Host "NPU OpenVINO GenAI server: $dir  http://${HostAddr}:$Port/v1  (first start compiles for the NPU, ~30-90 s)"
    & $py "$PSScriptRoot\tools\ov_server.py" --model $dir --device NPU --host $HostAddr --port $Port `
        --max-prompt $MaxPrompt --max-response $MaxResponse
    exit $LASTEXITCODE
}

if ($gguf.ContainsKey($key)) {
    $path = Join-Path $modelsDir $gguf[$key].file
    if (-not (Test-Path -LiteralPath $path)) {
        if ($DryRun) { throw "Model not downloaded: $path" }
        Write-Host "Downloading $($gguf[$key].repo)/$($gguf[$key].file) ..."
        $null = New-Item -ItemType Directory -Force -Path $modelsDir
        $partial = "$path.$([guid]::NewGuid().ToString()).part"
        try {
            curl.exe -L --fail -o $partial "$hfEndpoint/$($gguf[$key].repo)/resolve/main/$($gguf[$key].file)"
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
} elseif (Test-Path -LiteralPath "$Model\openvino_model.xml") {
    Start-GenaiNpu (Resolve-Path -LiteralPath $Model).Path
} else {
    Write-Error "Unknown model '$Model'. Use one of: $(($gguf.Keys + $ir.Keys) -join ', '), a .gguf file, or an OpenVINO IR folder."
    exit 1
}
