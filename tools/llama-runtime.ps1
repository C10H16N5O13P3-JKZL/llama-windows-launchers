# Shared configuration, backend registry, runtime resolution and model selection.
# Keep every .ps1 ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts in the system code page.

# One entry per runtime; adding or retargeting a backend (e.g. another CUDA version) is a change here only.
# Asset/Dependency match official llama.cpp release archive names. Order is the menu and List order.
# LaunchArgs apply to server and chat, ServerArgs to llama-server only. Optional: DefaultCtx, Env,
# ClearEnv (environment for the launched process) and Note (shown before starting).
$LlamaBackends = [ordered]@{
    vulkan   = @{
        Name = 'Vulkan'; Label = 'Vulkan GPU (AMD / Intel / NVIDIA)'
        Asset = '^llama-b[0-9]+-bin-win-vulkan-x64\.zip$'
        LaunchArgs = @('-ngl', '99')
    }
    cuda     = @{
        Name = 'CUDA'; Label = 'NVIDIA CUDA 12.4 (large download)'
        Asset = '^llama-b[0-9]+-bin-win-cuda-12\.4-x64\.zip$'
        # Runtime DLLs shipped as a second archive of the same release.
        Dependency = '^cudart-llama(?:-b[0-9]+)?-bin-win-cuda-12\.4-x64\.zip$'
        DependencyDlls = @('cudart*.dll', 'cublas*.dll')
        LaunchArgs = @('-ngl', '99')
    }
    cpu      = @{
        Name = 'CPU'; Label = 'CPU only'
        Asset = '^llama-b[0-9]+-bin-win-cpu-x64\.zip$'
        # --device none keeps every op (incl. prompt processing) off the GPU.
        LaunchArgs = @('--device', 'none')
    }
    openvino = @{
        Name = 'OpenVINO'; Label = 'Intel OpenVINO (NPU)'
        Asset = '^llama-b[0-9]+-bin-win-openvino(?:-[0-9.]+)?-x64\.zip$'
        LaunchArgs = @()
        # The NPU backend does not support parallel sequences.
        ServerArgs = @('-np', '1')
        # The NPU attends over the whole context every token: keep it small unless -c is given.
        DefaultCtx = 4096
        Env = @{ GGML_OPENVINO_DEVICE = 'NPU' }
        # GGML_OPENVINO_CACHE_DIR breaks NPU compilation ("WeightlessCacheAttribute"); keep it unset.
        ClearEnv = @('GGML_OPENVINO_CACHE_DIR')
        Note = 'Intel NPU: the first start compiles the model for the NPU (about 30 s).'
    }
}

function Resolve-LlamaPath([string]$Path, [string]$Base) {
    $Path = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $Base $Path }
    return [IO.Path]::GetFullPath($Path)
}

# Per-machine settings live outside version control: launcher.config.json next to the scripts,
# overridden by LLAMA_LAUNCHER_HOME for the data directory. Without either, everything stays
# inside the script folder, so the folder can be copied or moved as a unit.
function Get-LlamaConfig {
    $root = Split-Path $PSScriptRoot -Parent
    $file = Join-Path $root 'launcher.config.json'
    $config = @{ dataDir = ''; modelsDir = ''; defaultModel = ''; port = 28080; ctx = 16384 }
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        try { $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { throw "Cannot read ${file}: $($_.Exception.Message)`nWrite paths in JSON with / or \\ as the separator." }
        foreach ($property in $json.PSObject.Properties) {
            if (-not $config.ContainsKey($property.Name)) {
                throw "Unknown setting '$($property.Name)' in $file. Known settings: $(($config.Keys | Sort-Object) -join ', ')"
            }
            if ("$($property.Value)" -ne '') { $config[$property.Name] = $property.Value }
        }
    }
    if ($env:LLAMA_LAUNCHER_HOME) { $config.dataDir = $env:LLAMA_LAUNCHER_HOME }
    $config.dataDir = if ($config.dataDir) { Resolve-LlamaPath $config.dataDir $root } else { $root }
    $config.modelsDir = if ($config.modelsDir) { Resolve-LlamaPath $config.modelsDir $root } else { Join-Path $config.dataDir 'models' }
    if ($config.defaultModel) { $config.defaultModel = Resolve-LlamaPath $config.defaultModel $config.modelsDir }
    foreach ($key in @('port', 'ctx')) {
        $number = 0
        if (-not [int]::TryParse("$($config[$key])", [ref]$number) -or $number -lt 1 -or ($key -eq 'port' -and $number -gt 65535)) {
            throw "Invalid '$key' in ${file}: $($config[$key])"
        }
        $config[$key] = $number
    }
    $config.file = $file
    return $config
}

# Launcher spellings (iGPU, Vulkan, CPU, CUDA, NPU, OpenVINO) -> registry key.
function ConvertTo-LlamaBackend([string]$Name) {
    $key = switch ($Name) { 'iGPU' { 'vulkan' } 'NPU' { 'openvino' } default { $Name.ToLowerInvariant() } }
    if (-not $LlamaBackends.Contains($key)) { throw "Unknown backend: $Name" }
    return $key
}

function Get-LlamaBackendDir([string]$Backend) {
    return (Join-Path (Get-LlamaConfig).dataDir "llama-versions\$Backend")
}

# The selected version of a backend. "legacy" always means the original, unmanaged installation.
function Get-LlamaCurrent([string]$Backend) {
    $pointer = Join-Path (Get-LlamaBackendDir $Backend) 'current.txt'
    if (Test-Path -LiteralPath $pointer -PathType Leaf) { return (Get-Content -LiteralPath $pointer -Raw).Trim() }
    return 'legacy'
}

function Get-LlamaRuntimeDir([string]$Backend, [string]$Version) {
    if ($Version -eq 'legacy') { return (Join-Path (Get-LlamaConfig).dataDir "llama-$Backend") }
    if ($Version -notmatch '^b[0-9]+$') { throw "Invalid version: $Version" }
    return (Join-Path (Get-LlamaBackendDir $Backend) $Version)
}

function Get-LlamaRuntime([string]$Backend, [string]$Version = '') {
    if (-not $Version) { $Version = Get-LlamaCurrent $Backend }
    $exe = Join-Path (Get-LlamaRuntimeDir $Backend $Version) 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $hint = if ($Version -eq 'legacy') { "manage-llama.bat Update -b $Backend" } else { "manage-llama.bat Install -b $Backend -v $Version" }
        throw "Runtime not installed: $exe`nInstall it first: $hint"
    }
    return $exe
}

# Complete local installations only; a directory without llama-server.exe is not listed.
function Get-LlamaInstalledVersions([string]$Backend) {
    $tags = @()
    if (Test-Path -LiteralPath (Join-Path (Get-LlamaRuntimeDir $Backend 'legacy') 'llama-server.exe') -PathType Leaf) { $tags += 'legacy' }
    $base = Get-LlamaBackendDir $Backend
    if (Test-Path -LiteralPath $base -PathType Container) {
        $tags += @(Get-ChildItem -LiteralPath $base -Directory |
            Where-Object { $_.Name -match '^b[0-9]+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'llama-server.exe') -PathType Leaf) } |
            Select-Object -ExpandProperty Name)
    }
    return $tags
}

# Auto backend: CUDA when an NVIDIA GPU is present, then Vulkan, then CPU; installed runtimes only.
function Find-LlamaBackend([string]$Version = '') {
    $gpus = @(try { Get-CimInstance Win32_VideoController -ErrorAction Stop } catch { @() })
    $hasNvidia = [bool]($gpus | Where-Object { "$($_.AdapterCompatibility) $($_.Name)" -match 'NVIDIA' })
    $candidates = @(if ($hasNvidia) { 'cuda' }) + @('vulkan', 'cpu')
    $chosen = ''
    foreach ($candidate in $candidates) {
        try { $null = Get-LlamaRuntime $candidate $Version; $chosen = $candidate; break } catch { }
    }
    return [pscustomobject]@{ Backend = $chosen; HasNvidia = $hasNvidia; Candidates = $candidates }
}

# Prompts are only shown when a person can answer them (not under CI, pipes or redirected input).
function Test-LlamaInteractive { return (-not [Console]::IsInputRedirected) }

# Numbered menu; returns the zero-based index. Enter picks the first entry.
function Read-LlamaChoice([string]$Title, [string[]]$Labels) {
    Write-Host ''
    Write-Host $Title
    for ($i = 0; $i -lt $Labels.Count; $i++) { Write-Host ('  {0}) {1}' -f ($i + 1), $Labels[$i]) }
    while ($true) {
        $answer = Read-Host 'Number (Enter = 1)'
        if ($null -eq $answer) { return 0 }  # stdin closed
        $answer = $answer.Trim()
        if ($answer -eq '') { return 0 }
        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $Labels.Count) { return ($index - 1) }
        Write-Host "Invalid choice: $answer" -ForegroundColor Yellow
    }
}

# Interactive backend choice among installed runtimes. Returns a registry key, or '' when none is
# installed. A single installed backend is used without asking.
function Select-LlamaBackend([string]$Version = '') {
    $installed = @($LlamaBackends.Keys | Where-Object { try { $null = Get-LlamaRuntime $_ $Version; $true } catch { $false } })
    if ($installed.Count -le 1) { return [string]($installed | Select-Object -First 1) }
    $keys = @(); $labels = @()
    $auto = (Find-LlamaBackend $Version).Backend
    if ($auto) { $keys += $auto; $labels += "Auto     - $($LlamaBackends[$auto].Name) on this machine" }
    foreach ($key in $installed) {
        $tag = if ($Version) { $Version } else { Get-LlamaCurrent $key }
        $keys += $key
        $labels += ('{0,-8} - {1} [{2}]' -f $LlamaBackends[$key].Name, $LlamaBackends[$key].Label, $tag)
    }
    return $keys[(Read-LlamaChoice 'Backend:' $labels)]
}

function Resolve-Gguf([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Extension -ne '.gguf') { throw "Expected a GGUF file: $Path" }
    $stream = [IO.File]::OpenRead($item.FullName)
    try {
        $magic = New-Object byte[] 4
        if ($stream.Read($magic, 0, 4) -ne 4 -or [Text.Encoding]::ASCII.GetString($magic) -ne 'GGUF') {
            throw "Invalid GGUF header: $Path"
        }
    } finally { $stream.Dispose() }
    return $item.FullName
}

# Used when no model was passed: the configured default, else ask (numbered list of the models
# folder, or a pasted/dragged path). Never blocks on a prompt when stdin is not a console.
function Select-LlamaModel($Config, [switch]$AlwaysAsk) {
    $default = $Config.defaultModel
    if ($default -and -not $AlwaysAsk) { return $default }
    $found = @()
    if (Test-Path -LiteralPath $Config.modelsDir -PathType Container) {
        # Skip vision projectors and all but the first shard of a split model.
        $found = @(Get-ChildItem -LiteralPath $Config.modelsDir -Filter *.gguf -File -Recurse -Depth 2 |
            Where-Object { $_.Name -notmatch '^mmproj' -and ($_.Name -notmatch '-[0-9]{5}-of-[0-9]{5}\.gguf$' -or $_.Name -match '-00001-of-') } |
            Sort-Object FullName)
    }
    if (-not (Test-LlamaInteractive)) {
        throw "No model given. Pass a GGUF path, e.g. start-gguf.bat `"E:\models\model.gguf`", or set defaultModel in launcher.config.json."
    }
    Write-Host ''
    if ($found.Count) {
        Write-Host "Models in $($Config.modelsDir):"
        for ($i = 0; $i -lt $found.Count; $i++) {
            $relative = $found[$i].FullName.Substring($Config.modelsDir.TrimEnd('\').Length + 1)
            Write-Host ('  {0,2}) {1}  ({2:N1} GB)' -f ($i + 1), $relative, ($found[$i].Length / 1GB))
        }
        if (-not $default) { $default = $found[0].FullName }
        $prompt = "Number, or a full GGUF path (Enter = $(Split-Path $default -Leaf))"
    } elseif ($default) {
        $prompt = "GGUF full path (Enter = $(Split-Path $default -Leaf))"
    } else {
        Write-Host "No GGUF files in $($Config.modelsDir)."
        $prompt = 'GGUF full path (you can drag the file into this window)'
    }
    while ($true) {
        $answer = Read-Host $prompt
        if ($null -eq $answer) { throw 'No model given.' }  # stdin closed
        $answer = $answer.Trim().Trim('"').Trim()
        if ($answer -eq '') { if ($default) { return $default }; continue }
        $index = 0
        if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $found.Count) { return $found[$index - 1].FullName }
        if (Test-Path -LiteralPath $answer -PathType Leaf) { return $answer }
        Write-Host "Not found: $answer" -ForegroundColor Yellow
    }
}
