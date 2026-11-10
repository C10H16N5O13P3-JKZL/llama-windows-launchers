# Run with Windows PowerShell 5.1. Offline integration test; no GPU required.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path $PSScriptRoot ('.work-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path "$work\tools", "$work\fixtures\main", "$work\fixtures\deps"
try {
    Copy-Item "$repo\tools\*.ps1" "$work\tools"
    # A tiny real executable exercises --version validation without GPU binaries.
    Add-Type -TypeDefinition 'public class FakeLlama { public static void Main() { System.Console.WriteLine("version: 0.8.0-dev (build 12345, commit fixture)"); } }' -OutputAssembly "$work\fixtures\main\llama-server.exe" -OutputType ConsoleApplication
    Copy-Item "$work\fixtures\main\llama-server.exe" "$work\fixtures\main\llama-cli.exe"
    Set-Content "$work\fixtures\deps\cudart64_12.dll" 'fixture'
    Set-Content "$work\fixtures\deps\cublas64_12.dll" 'fixture'
    Set-Content "$work\fixtures\deps\LICENSE.txt" 'fixture license'
    Compress-Archive "$work\fixtures\main\*" "$work\fixtures\main.zip"
    Compress-Archive "$work\fixtures\deps\*" "$work\fixtures\deps.zip"
    function New-Asset([string]$Name, [string]$Path) {
        [pscustomobject]@{ name = $Name; size = (Get-Item $Path).Length; digest = 'sha256:' + (Get-FileHash $Path).Hash.ToLowerInvariant(); browser_download_url = $Path }
    }
    $release = [pscustomobject]@{ tag_name = 'b12345'; assets = @(
        (New-Asset 'llama-b12345-bin-win-cpu-x64.zip' "$work\fixtures\main.zip"),
        (New-Asset 'llama-b12345-bin-win-cuda-12.4-x64.zip' "$work\fixtures\main.zip"),
        (New-Asset 'cudart-llama-bin-win-cuda-12.4-x64.zip' "$work\fixtures\deps.zip"),
        (New-Asset 'llama-b12345-bin-win-cuda-13.4-x64.zip' "$work\fixtures\main.zip"),
        (New-Asset 'llama-b12345-bin-win-cpu-arm64.zip' "$work\fixtures\main.zip"),
        (New-Asset 'llama-b12345-bin-win-openvino-2025.3-x64.zip' "$work\fixtures\main.zip")
    ) }
    $fixtureRelease = $release  # distinct name: the manager assigns its own $release
    function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) return $fixtureRelease }
    function Invoke-WebRequest { param([switch]$UseBasicParsing, $Uri, $Headers, $OutFile, $TimeoutSec) Copy-Item -LiteralPath $Uri -Destination $OutFile }
    # Shadows the real curl.exe: "-o <file>" then the URL as the last argument.
    $curlCalls = New-Object System.Collections.ArrayList
    function curl.exe {
        $null = $curlCalls.Add($args[-1])
        $out = $args[[array]::IndexOf($args, '-o') + 1]
        Copy-Item -LiteralPath $args[-1] -Destination $out
        $global:LASTEXITCODE = 0
    }
    foreach ($backend in @('cpu', 'cuda')) {
        & "$work\tools\manage-llama.ps1" Update -b $backend -v b12345
        if ((Get-Content "$work\llama-versions\$backend\current.txt") -ne 'b12345') { throw "Selection failed: $backend" }
    }
    if ($curlCalls.Count -ne 3) { throw "Expected 3 curl downloads (cpu, cuda, cudart), got $($curlCalls.Count)" }
    $cudaDir ="$work\llama-versions\cuda\b12345"
    foreach ($file in @('cudart64_12.dll', 'cublas64_12.dll', 'cuda-dependencies\LICENSE.txt')) {
        if (-not (Test-Path "$cudaDir\$file")) { throw "Missing CUDA dependency: $file" }
    }
    $manifest = Get-Content "$cudaDir\install.json" -Raw | ConvertFrom-Json
    if ($manifest.dependencies.Count -ne 1 -or $manifest.asset -notmatch 'cuda-12\.4') { throw 'Incorrect CUDA manifest' }
    [IO.File]::WriteAllBytes("$work\model.gguf", [Text.Encoding]::ASCII.GetBytes('GGUFfixture'))
    foreach ($backend in @('CPU', 'CUDA')) {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b $backend -m "$work\model.gguf" -d 2>&1
        $text = $output -join "`n"
        if ($LASTEXITCODE -ne 0 -or $text -notmatch "llama-versions\\$backend\\b12345") { throw "Runtime routing failed: $text" }
        # Drag-and-drop form used by start-cpu/start-cuda.bat: bare path after -Backend.
        $dropped = & powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -Backend $backend -AutoPort "$work\model.gguf" -d 2>&1
        if ($LASTEXITCODE -ne 0 -or ($dropped -join "`n") -notmatch [regex]::Escape("$work\model.gguf")) { throw "Positional model path failed: $($dropped -join "`n")" }
        if ($backend -eq 'CPU' -and $text -notmatch '--device') { throw 'CPU device flag missing' }
        if ($backend -eq 'CUDA' -and $text -notmatch '-ngl') { throw 'GPU layers missing' }
    }
    # Auto backend (start-gguf.bat): CPU and CUDA are installed, Vulkan is not.
    $hasNvidia = [bool](Get-CimInstance Win32_VideoController | Where-Object { "$($_.AdapterCompatibility) $($_.Name)" -match 'NVIDIA' })
    $expected = if ($hasNvidia) { 'CUDA' } else { 'CPU' }
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -AutoBackend "$work\model.gguf" -d 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $text -notmatch "Auto-selected backend: $expected" -or $text -notmatch "llama-versions\\$($expected.ToLower())\\b12345") { throw "Auto backend failed (expected $expected): $text" }
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -AutoBackend -b CPU "$work\model.gguf" -d 2>&1) -join "`n"
    if ($text -match 'Auto-selected' -or $text -notmatch 'Backend: CPU') { throw "Explicit -b must override AutoBackend: $text" }
    $ErrorActionPreference = 'Continue'  # the child fails on purpose; its stderr must not throw here
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b Auto -v b99999 "$work\model.gguf" -d 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -eq 0 -or $text -notmatch 'No runtime installed') { throw "Auto with missing runtimes must fail clearly: $text" }
    # Real launch path (the fixture prints its version and exits 0), fixed port and AutoPort.
    foreach ($portArgs in @(@('-p', '29321'), @('-p', '29321', '-AutoPort'))) {
        $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b CPU "$work\model.gguf" @portArgs 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $text -notmatch 'build 12345') { throw "Launch failed ($portArgs): $text" }
    }
    # Model picker: lists the models folder without projectors and later shards; accepts a number or a path.
    . "$work\tools\llama-runtime.ps1"
    $null = New-Item -ItemType Directory -Path "$work\pick\sub"
    foreach ($name in @('a.gguf', 'mmproj-a.gguf', 'sub\b-00001-of-00002.gguf', 'sub\b-00002-of-00002.gguf')) { Copy-Item "$work\model.gguf" "$work\pick\$name" }
    function Test-LlamaInteractive { $true }
    $pickAnswers = New-Object 'System.Collections.Generic.Queue[string]'
    function Read-Host { param($Prompt) $pickAnswers.Dequeue() }
    $pickConfig = @{ defaultModel = ''; modelsDir = "$work\pick" }
    $pickAnswers.Enqueue('9'); $pickAnswers.Enqueue('2')
    if ((Select-LlamaModel $pickConfig) -ne "$work\pick\sub\b-00001-of-00002.gguf") { throw 'Model picker: number' }
    $pickAnswers.Enqueue('')
    if ((Select-LlamaModel $pickConfig) -ne "$work\pick\a.gguf") { throw 'Model picker: Enter' }
    $pickAnswers.Enqueue("`"$work\model.gguf`"")
    if ((Select-LlamaModel $pickConfig) -ne "$work\model.gguf") { throw 'Model picker: quoted path' }
    # List without -b covers every backend.
    $listed = @(& "$work\tools\manage-llama.ps1" List)
    if ($listed.Count -ne 2 -or @($listed | Where-Object { $_.Active -and $_.Version -eq 'b12345' }).Count -ne 2) { throw "List must show cpu and cuda: $($listed | Out-String)" }
    # No model and no console: fail with guidance instead of waiting for input.
    $ErrorActionPreference = 'Continue'
    $text = ($null | & powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b CPU -d 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -eq 0 -or $text -notmatch 'No model given') { throw "Missing model must fail clearly: $text" }
    # launcher.config.json: default model (relative to modelsDir), port and ctx; arguments still win.
    Set-Content "$work\launcher.config.json" '{ "modelsDir": ".", "defaultModel": "model.gguf", "port": 29123, "ctx": 2048 }'
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b CPU -d 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $text -notmatch [regex]::Escape("$work\model.gguf") -or $text -notmatch ':29123' -or $text -notmatch 'Ctx: 2048') { throw "Config defaults failed: $text" }
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b CPU -p 29200 -c 1024 -d 2>&1) -join "`n"
    if ($text -notmatch ':29200' -or $text -notmatch 'Ctx: 1024') { throw "Arguments must override config: $text" }
    # Relocated data: move the runtimes away and point the launchers at them, by config and by variable.
    $null = New-Item -ItemType Directory -Path "$work\elsewhere"
    Move-Item "$work\llama-versions" "$work\elsewhere\llama-versions"
    Set-Content "$work\launcher.config.json" '{ "dataDir": "elsewhere" }'
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b CPU "$work\model.gguf" -d 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $text -notmatch 'elsewhere\\llama-versions\\cpu\\b12345') { throw "dataDir relocation failed: $text" }
    Remove-Item "$work\launcher.config.json"
    $env:LLAMA_LAUNCHER_HOME = "$work\elsewhere"
    try {
        $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b CUDA "$work\model.gguf" -d 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $text -notmatch 'elsewhere\\llama-versions\\cuda\\b12345') { throw "LLAMA_LAUNCHER_HOME relocation failed: $text" }
        if (@(& "$work\tools\manage-llama.ps1" List -b cuda).Count -ne 1) { throw 'List must follow LLAMA_LAUNCHER_HOME' }
    } finally { Remove-Item Env:LLAMA_LAUNCHER_HOME }
    Move-Item "$work\elsewhere\llama-versions" "$work\llama-versions"
    # A typo in the config must be reported, not ignored.
    Set-Content "$work\launcher.config.json" '{ "modelDir": "x" }'
    $rejected = $false
    try { & "$work\tools\manage-llama.ps1" List } catch { $rejected = $_.Exception.Message -match 'Unknown setting' }
    Remove-Item "$work\launcher.config.json"
    if (-not $rejected) { throw 'Unknown config setting was accepted' }
    # Chat mode: llama-cli from the same runtime, no server arguments.
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b CPU -Mode Chat "$work\model.gguf" -d 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $text -notmatch 'Mode: Chat' -or $text -match '--port' -or $text -notmatch '--device') { throw "Chat dry run failed: $text" }
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b CPU -Mode Chat "$work\model.gguf" 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $text -notmatch 'build 12345') { throw "Chat launch failed: $text" }
    # Backend menu: Auto first, then installed backends in registry order (cuda, cpu); invalid input is asked again.
    $pickAnswers.Enqueue('x'); $pickAnswers.Enqueue('3')
    if ((Select-LlamaBackend) -ne 'cpu') { throw 'Backend menu: number' }
    $pickAnswers.Enqueue('')
    if ((Select-LlamaBackend) -notin @('cuda', 'cpu')) { throw 'Backend menu: Enter must pick Auto' }
    # Configured default model is preselected when asking.
    $pickAnswers.Enqueue('')
    if ((Select-LlamaModel @{ defaultModel = "$work\model.gguf"; modelsDir = "$work\pick" } -AlwaysAsk) -ne "$work\model.gguf") { throw 'Model picker: default' }
    # Intel NPU (OpenVINO) through the unified launcher and through start-npu.
    & "$work\tools\manage-llama.ps1" Update -b openvino -v b12345
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b NPU "$work\model.gguf" -d 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $text -notmatch 'llama-versions\\openvino\\b12345' -or $text -notmatch 'Ctx: 4096' -or $text -notmatch '"-np"') { throw "NPU routing failed: $text" }
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-llama.ps1" -b NPU -Mode Chat "$work\model.gguf" -d 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $text -match '"-np"') { throw "NPU chat must not get server arguments: $text" }
    $text = (& powershell -NoProfile -ExecutionPolicy Bypass -File "$work\tools\start-npu.ps1" -m "$work\model.gguf" -d 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $text -notmatch ':28081' -or $text -notmatch 'Backend: OpenVINO') { throw "start-npu routing failed: $text" }
    & "$work\tools\start-npu.ps1" -m "$work\model.gguf"   # real launch in-process: must set the NPU environment
    if ($env:GGML_OPENVINO_DEVICE -ne 'NPU') { throw 'NPU environment not set' }
    Remove-Item Env:GGML_OPENVINO_DEVICE
    Remove-Item "$work\llama-versions\openvino" -Recurse -Force
    # A corrupt dependency must not publish a new installation or alter selection.
    $release.tag_name = 'b12346'
    foreach ($asset in $release.assets) { $asset.name = $asset.name.Replace('b12345', 'b12346') }
    $release.assets[2].digest = 'sha256:' + ('0' * 64)
    $rejected = $false
    try { & "$work\tools\manage-llama.ps1" Update -b cuda -v b12346 }
    catch { if ($_.Exception.Message -notmatch 'SHA256 mismatch') { throw }; $rejected = $true }
    if (-not $rejected -or (Test-Path "$work\llama-versions\cuda\b12346") -or (Get-Content "$work\llama-versions\cuda\current.txt") -ne 'b12345') { throw 'Failed update changed installation/selection' }
    # Interactive menu: choose 3 (cpu, latest), then 0 to exit; it must re-select the installed build.
    $release.tag_name = 'b12345'
    foreach ($asset in $release.assets) { $asset.name = $asset.name.Replace('b12346', 'b12345') }
    Remove-Item "$work\llama-versions\cpu\current.txt"
    $menuAnswers = New-Object 'System.Collections.Generic.Queue[string]'
    $menuAnswers.Enqueue('3'); $menuAnswers.Enqueue('0')
    function Read-Host { param($Prompt) $menuAnswers.Dequeue() }
    & "$work\tools\manage-llama.ps1" -Interactive
    if ((Get-Content "$work\llama-versions\cpu\current.txt") -ne 'b12345') { throw 'Interactive install did not select latest cpu' }
    Write-Host 'PASS: CPU/CUDA asset selection, dependency deployment, manifests, launcher routing, chat mode, NPU routing, menus, config and data relocation, SHA256 failure preserves current version, interactive menu.'
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    if ((Split-Path $resolved -Parent) -ne [IO.Path]::GetFullPath($PSScriptRoot) -or (Split-Path $resolved -Leaf) -notlike '.work-*') { throw 'Invalid test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
