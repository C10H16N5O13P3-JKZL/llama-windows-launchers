# llama-server launcher: Vulkan, standalone CPU, or CUDA. For the NPU use start-npu.ps1.
# Usage: powershell -ExecutionPolicy Bypass -File .\start-server.ps1 [-Backend iGPU|Vulkan|CPU|CUDA] [-Port 28080]
[CmdletBinding(PositionalBinding = $false)]
param(
    # Model is the only positional parameter, so a GGUF dropped onto a .bat binds here.
    [Parameter(Position = 0)][Alias('m')][string]$Model = '',
    [Alias('b')][ValidateSet("Auto", "iGPU", "Vulkan", "CPU", "CUDA")]
    [string]$Backend = "iGPU",
    # Use Auto when -Backend is not given (start-gguf.bat); an explicit -Backend still wins.
    [Alias('ab')][switch]$AutoBackend,
    # 0 = take the value from launcher.config.json (built-in defaults: 28080 / 16384).
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
Usage: start-server.bat [-m] "E:\models\model.gguf" [options]
  -m    -Model      GGUF path; -m optional. Without a model: defaultModel from
                    launcher.config.json, else pick from the models folder or
                    type/drag a path. Dropping a .gguf onto start-server/
                    start-cpu/start-cuda.bat passes it here and enables -AutoPort.
  -b    -Backend    iGPU/Vulkan (default), CPU (standalone build), CUDA, or Auto.
                    Auto: CUDA if an NVIDIA GPU is present and CUDA is installed,
                    else Vulkan, else CPU; only installed runtimes are chosen.
                    start-gguf.bat uses Auto unless -b is given.
  -p    -Port       Server port (default: 28080, or port in the config file).
  -c    -Ctx        Context size (default: 16384, or ctx in the config file).
  -addr -HostAddr   Bind address (default: 127.0.0.1).
  -v    -Version    Installed bNNNNN or legacy; default: selected runtime.
  -x    -ExtraArgs  Native llama arguments; pass an array directly to .ps1.
  -d    -DryRun     Validate paths and print arguments without starting.
  -ap   -AutoPort   Try consecutive ports if unavailable (drop-in default).
  -pt   -PortAttempts  Maximum ports to try (default: 200, including -p).
  -h    -Help       Show this help.
Examples:
  start-server.bat -m "E:\models\model.gguf" -b CPU -c 8192
  start-server.bat -v legacy -d
  .\start-server.ps1 -x @('--temp','0.7')
External models are read in place. Relative paths use the working directory.
Per-machine defaults (data folder, models folder, default model, port, ctx):
copy launcher.config.example.json to launcher.config.json and edit it.
'@
    return
}

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tools\llama-runtime.ps1"
. "$PSScriptRoot\tools\llama-port.ps1"
$config = Get-LlamaConfig
if (-not $Port) { $Port = $config.port }
if (-not $Ctx) { $Ctx = $config.ctx }
if ($Port -lt 1 -or $Port -gt 65535 -or $Ctx -lt 1) { throw 'Invalid Port or Ctx.' }

if ($AutoBackend -and -not $PSBoundParameters.ContainsKey('Backend')) { $Backend = 'Auto' }
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
$backendName = $LlamaBackends[$runtimeBackend].Name
$exe = Get-LlamaRuntime $runtimeBackend $Version
if (-not $Model) { $Model = Select-LlamaModel $config }
$Model = Resolve-Gguf $Model

Write-Host "Runtime: $exe"
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
    Write-Host "Backend: $backendName  Model: $Model  Ctx: $Ctx  http://${HostAddr}:$candidate"
    $launchArgs = @('-m', $Model, '-c', "$Ctx") + $LlamaBackends[$runtimeBackend].LaunchArgs + @('--host', $HostAddr, '--port', "$candidate") + $ExtraArgs
    if ($DryRun) { $launchArgs | ConvertTo-Json; return }
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
