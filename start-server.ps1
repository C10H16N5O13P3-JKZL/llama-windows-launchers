# llama-server launcher: Vulkan, standalone CPU, or CUDA 12.4.
# For the NPU use start-npu.ps1 (OpenVINO, different models: LFM3 computes wrongly on the NPU, see README).
# Usage: powershell -ExecutionPolicy Bypass -File .\start-server.ps1 [-Backend iGPU|Vulkan|CPU|CUDA] [-Port 28080]
[CmdletBinding(PositionalBinding = $false)]
param(
    # Model is the only positional parameter, so a GGUF dropped onto a .bat binds here.
    [Parameter(Position = 0)][Alias('m')][string]$Model = "$PSScriptRoot\models\LFM3-1.7B-Q8_0.gguf",
    [Alias('b')][ValidateSet("Auto", "iGPU", "Vulkan", "CPU", "CUDA")]
    [string]$Backend = "iGPU",
    # Use Auto when -Backend is not given (start-gguf.bat); an explicit -Backend still wins.
    [Alias('ab')][switch]$AutoBackend,
    [Alias('p')][int]$Port = 28080,
    [Alias('c')][int]$Ctx = 16384,
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
  -m    -Model      GGUF path (default: models/LFM3-1.7B-Q8_0.gguf); -m optional.
                    Dropping a .gguf onto start-server/start-cpu/start-cuda.bat
                    passes it here and enables -AutoPort.
  -b    -Backend    iGPU/Vulkan (default), CPU (standalone build), CUDA, or Auto.
                    Auto: CUDA if an NVIDIA GPU is present and CUDA is installed,
                    else Vulkan, else CPU; only installed runtimes are chosen.
                    start-gguf.bat uses Auto unless -b is given.
  -p    -Port       Server port (default: 28080).
  -c    -Ctx        Context size (default: 16384).
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
'@
    return
}

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tools\llama-runtime.ps1"
. "$PSScriptRoot\tools\llama-port.ps1"
if ($AutoBackend -and -not $PSBoundParameters.ContainsKey('Backend')) { $Backend = 'Auto' }
if ($Backend -eq 'Auto') {
    $gpus = @(try { Get-CimInstance Win32_VideoController -ErrorAction Stop } catch { @() })
    $hasNvidia = [bool]($gpus | Where-Object { "$($_.AdapterCompatibility) $($_.Name)" -match 'NVIDIA' })
    $candidates = @(if ($hasNvidia) { 'CUDA' }) + @('Vulkan', 'CPU')
    $chosen = $null  # $Backend is ValidateSet-constrained, so it cannot hold $null
    foreach ($candidate in $candidates) {
        $name = switch ($candidate) { 'CPU' { 'cpu' }; 'CUDA' { 'cuda' }; default { 'vulkan' } }
        try { $null = Get-LlamaRuntime $name $Version; $chosen = $candidate; break } catch { }
    }
    if (-not $chosen) {
        $which = if ($Version) { "version $Version of any backend" } else { 'any backend' }
        throw "No runtime installed for $which (tried: $($candidates -join ', ')).`nRun manage-llama.bat and pick one: CUDA for NVIDIA GPUs, Vulkan for other GPUs, or CPU."
    }
    $Backend = $chosen
    $gpuNote =if ($hasNvidia) { 'NVIDIA GPU detected' } else { 'no NVIDIA GPU detected' }
    Write-Host "Auto-selected backend: $Backend ($gpuNote; tried $($candidates -join ' > '))"
}
$runtimeBackend = switch ($Backend) { 'CPU' { 'cpu' }; 'CUDA' { 'cuda' }; default { 'vulkan' } }
$exe = Get-LlamaRuntime $runtimeBackend $Version
$Model = Resolve-Gguf $Model
if ($Port -lt 1 -or $Port -gt 65535 -or $Ctx -lt 1) { throw 'Invalid Port or Ctx.' }
# CPU: --device none keeps every op (incl. prompt processing) off the GPU
$extra = if ($Backend -eq 'CPU') { @('--device', 'none') } else { @('-ngl', '99') }

Write-Host "Runtime: $exe"
if ($AutoPort -and @($ExtraArgs | Where-Object { $_ -match '^(--port|--host)(=|$)' }).Count) {
    throw 'With AutoPort, set the address/port using HostAddr and Port, not ExtraArgs.'
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
    Write-Host "Backend: $Backend  Model: $Model  Ctx: $Ctx  http://${HostAddr}:$candidate"
    $launchArgs = @('-m', $Model, '-c', "$Ctx") + $extra + @('--host', $HostAddr, '--port', "$candidate") + $ExtraArgs
    if ($DryRun) { $launchArgs | ConvertTo-Json; return }
    if (-not $AutoPort) { & $exe @launchArgs; exit $LASTEXITCODE }
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
    if ($code -eq 0 -or -not $bindFailed) { exit $code }
    Write-Host "Binding port $candidate failed; trying the next port..."
}
throw "No usable port in range ${Port}-${lastPort}. Choose another starting port with -p."
