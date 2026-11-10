# Unified llama.cpp launcher: any installed backend (Vulkan, CUDA, CPU, Intel NPU),
# as a server (web UI + OpenAI-compatible API) or as a chat in the terminal.
# Entry points: start-llama.bat (asks for what was not given) and shortcuts\*.bat.
[CmdletBinding(PositionalBinding = $false)]
param(
    # Model is the only positional parameter, so a GGUF dropped onto a .bat binds here.
    [Parameter(Position = 0)][Alias('m')][string]$Model = '',
    [Alias('b')][ValidateSet("Auto", "iGPU", "Vulkan", "CPU", "CUDA", "NPU", "OpenVINO")]
    [string]$Backend = "iGPU",
    [ValidateSet("Server", "Chat")][string]$Mode = "Server",
    # Ask for model, backend and mode when they are not given (start-llama.bat).
    [switch]$Ask,
    # Use Auto when -Backend is not given (start-gguf.bat); an explicit -Backend still wins.
    [Alias('ab')][switch]$AutoBackend,
    # 0 = default: port from launcher.config.json (28080); ctx from the backend or the config (16384).
    [Alias('p')][int]$Port = 0,
    [Alias('c')][int]$Ctx = 0,
    [Alias('addr')][string]$HostAddr = "127.0.0.1",
    [Alias('v')][string]$Version = '',
    [Alias('x')][string[]]$ExtraArgs = @(),
    [Alias('d')][switch]$DryRun,
    [Alias('ap')][switch]$AutoPort,
    [Alias('pt')][ValidateRange(1, 1000)][int]$PortAttempts = 200,
    [Alias('h')][switch]$Help
)
if ($Help) {
    @'
Usage: start-llama.bat ["E:\models\model.gguf"] [options]
Double-click, or drop a .gguf on it: asks for the model, backend and mode
that were not given. Press Enter to accept the first choice.
  -m    -Model      GGUF path; -m optional. Without a model: pick from the
                    models folder or type/drag a path (defaultModel from
                    launcher.config.json is preselected).
  -b    -Backend    Auto, CUDA, Vulkan (= iGPU), CPU, or NPU (= OpenVINO).
                    Auto: CUDA if an NVIDIA GPU is present and CUDA is installed,
                    else Vulkan, else CPU; only installed runtimes are chosen.
        -Mode       Server (default): web UI and OpenAI-compatible API.
                    Chat: talk to the model in this window (llama-cli).
  -p    -Port       Server port (default: 28080, or port in the config file).
  -c    -Ctx        Context size (default: 16384, or ctx in the config file;
                    NPU: 4096).
  -addr -HostAddr   Bind address (default: 127.0.0.1).
  -v    -Version    Installed bNNNNN or legacy; default: selected runtime.
  -x    -ExtraArgs  Native llama arguments; pass an array directly to .ps1.
  -d    -DryRun     Validate paths and print arguments without starting.
  -ap   -AutoPort   Try consecutive ports if unavailable (default in
                    start-llama.bat and for dropped files).
  -pt   -PortAttempts  Maximum ports to try (default: 200, including -p).
  -h    -Help       Show this help.
Examples:
  start-llama.bat "E:\models\model.gguf" -b CUDA -Mode Chat
  start-llama.bat -b CPU -c 8192
  tools\start-llama.ps1 "E:\models\model.gguf" -x @('--temp','0.7')
Without -Ask (shortcuts, direct .ps1 use) nothing is asked except a missing
model; the backend defaults to Vulkan and the mode to Server.
External models are read in place. Relative paths use the working directory.
Per-machine defaults (data folder, models folder, default model, port, ctx):
copy launcher.config.example.json to launcher.config.json and edit it.
'@
    return
}

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\llama-runtime.ps1"
. "$PSScriptRoot\llama-port.ps1"
$config = Get-LlamaConfig
$Ask = $Ask -and (Test-LlamaInteractive)

# 1. Model
if (-not $Model) { $Model = Select-LlamaModel $config -AlwaysAsk:$Ask }
$Model = Resolve-Gguf $Model

# 2. Backend
if ($AutoBackend -and -not $PSBoundParameters.ContainsKey('Backend')) { $Backend = 'Auto' }
$runtimeBackend = ''
if ($Ask -and -not $PSBoundParameters.ContainsKey('Backend')) {
    $runtimeBackend = Select-LlamaBackend $Version
    if (-not $runtimeBackend) { $Backend = 'Auto' }  # nothing installed: handled below
}
if (-not $runtimeBackend) {
    if ($Backend -eq 'Auto') {
        $pick = Find-LlamaBackend $Version
        if (-not $pick.Backend -and -not $Version -and -not $DryRun -and (Test-LlamaInteractive)) {
            # First run from a double-click or drag-and-drop: install something instead of just failing.
            Write-Host 'No llama.cpp runtime is installed yet. Pick one to install (CUDA for NVIDIA GPUs, Vulkan for other GPUs, or CPU):' -ForegroundColor Yellow
            & "$PSScriptRoot\manage-llama.ps1" -Interactive
            $pick = Find-LlamaBackend $Version
        }
        $tried = @($pick.Candidates | ForEach-Object { $LlamaBackends[$_].Name })
        if (-not $pick.Backend) {
            $which = if ($Version) { "version $Version of any backend" } else { 'any backend' }
            throw "No runtime installed for $which (tried: $($tried -join ', ')).`nRun manage-llama.bat and pick one: CUDA for NVIDIA GPUs, Vulkan for other GPUs, or CPU."
        }
        $runtimeBackend = $pick.Backend
        $gpuNote = if ($pick.HasNvidia) { 'NVIDIA GPU detected' } else { 'no NVIDIA GPU detected' }
        Write-Host "Auto-selected backend: $($LlamaBackends[$runtimeBackend].Name) ($gpuNote; tried $($tried -join ' > '))"
    } else {
        $runtimeBackend = ConvertTo-LlamaBackend $Backend
    }
}
$spec = $LlamaBackends[$runtimeBackend]
$exe = Get-LlamaRuntime $runtimeBackend $Version

# 3. Mode
if ($Ask -and -not $PSBoundParameters.ContainsKey('Mode')) {
    $Mode = @('Server', 'Chat')[(Read-LlamaChoice 'Mode:' @(
        'Server - web UI in the browser and OpenAI-compatible API',
        'Chat   - talk to the model in this window'))]
}

if (-not $Port) { $Port = $config.port }
if (-not $Ctx) { $Ctx = if ($spec.DefaultCtx) { $spec.DefaultCtx } else { $config.ctx } }
if ($Port -lt 1 -or $Port -gt 65535 -or $Ctx -lt 1) { throw 'Invalid Port or Ctx.' }

function Set-BackendEnvironment {
    foreach ($name in @($spec.ClearEnv)) { if ($name) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue } }
    if ($spec.Env) { foreach ($name in $spec.Env.Keys) { Set-Item "Env:$name" $spec.Env[$name] } }
}

Write-Host ''
Write-Host "Runtime: $exe"
if ($Mode -eq 'Chat') {
    $cli = Join-Path (Split-Path $exe -Parent) 'llama-cli.exe'
    if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw "This runtime has no llama-cli.exe for chat mode: $cli`nUse -Mode Server, or update the runtime with manage-llama.bat." }
    Write-Host "Backend: $($spec.Name)  Mode: Chat  Model: $Model  Ctx: $Ctx"
    $launchArgs = @('-m', $Model, '-c', "$Ctx") + $spec.LaunchArgs + $ExtraArgs
    if ($DryRun) { $launchArgs | ConvertTo-Json; return }
    if ($spec.Note) { Write-Host $spec.Note }
    Write-Host 'Type your message after the model has loaded. Press Ctrl+C to quit.'
    Set-BackendEnvironment
    # Not piped: llama-cli needs the real console for interactive input.
    & $cli @launchArgs
    exit $LASTEXITCODE
}

if ($AutoPort -and @($ExtraArgs | Where-Object { $_ -match '^(--port|--host)(=|$)' }).Count) {
    throw 'With AutoPort, set the address/port using HostAddr and Port, not ExtraArgs.'
}

# llama-server writes UTF-8; without this, non-ASCII model paths show as mojibake in its log.
$savedEncoding = $null
function Set-Utf8Console {
    if ($script:savedEncoding) { return }
    try { $script:savedEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }
}
function Exit-Launcher([int]$Code) {
    if ($script:savedEncoding) { try { [Console]::OutputEncoding = $script:savedEncoding } catch { } }
    exit $Code
}

$lastPort = if ($AutoPort) { [Math]::Min(65535, $Port + $PortAttempts - 1) } else { $Port }
for ($candidate = $Port; $candidate -le $lastPort; $candidate++) {
    if ($AutoPort) {
        $status = Get-LlamaPortStatus $HostAddr $candidate
        if (-not $status.Available) {
            $reason = if ($status.Reason -eq 'AccessDenied') { 'access denied (possibly a Windows reserved port)' } else { 'address already in use' }
            Write-Host "Port ${candidate}: $reason [socket $($status.Code)]; skipping."
            continue
        }
    }
    Write-Host "Backend: $($spec.Name)  Mode: Server  Model: $Model  Ctx: $Ctx  http://${HostAddr}:$candidate"
    $launchArgs = @('-m', $Model, '-c', "$Ctx") + $spec.LaunchArgs + @($spec.ServerArgs | Where-Object { $_ }) +
        @('--host', $HostAddr, '--port', "$candidate") + $ExtraArgs
    if ($DryRun) { $launchArgs | ConvertTo-Json; return }
    if ($spec.Note) { Write-Host $spec.Note }
    Write-Host "Open the address above in a browser once the server is listening; the API is at /v1. Press Ctrl+C to stop."
    Set-BackendEnvironment
    Set-Utf8Console
    if (-not $AutoPort) { & $exe @launchArgs; Exit-Launcher $LASTEXITCODE }
    # The port can be taken after probing; retry only a reported bind failure.
    $bindFailed = $false
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @launchArgs 2>&1 | ForEach-Object {
            $line = "$_"
            if (Test-LlamaBindError $line) { $bindFailed = $true }
            Write-Host $line
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($code -eq 0 -or -not $bindFailed) { Exit-Launcher $code }
    Write-Host "Binding port $candidate failed; trying the next port..."
}
if ($savedEncoding) { try { [Console]::OutputEncoding = $savedEncoding } catch { } }
throw "No usable port in range ${Port}-${lastPort}. Choose another starting port with -p."
