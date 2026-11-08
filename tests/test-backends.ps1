# Run with Windows PowerShell 5.1. Offline integration test; no GPU required.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path $PSScriptRoot ('.work-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path "$work\tools", "$work\fixtures\main", "$work\fixtures\deps"
try {
    Copy-Item "$repo\manage-llama.ps1", "$repo\start-server.ps1" $work
    Copy-Item "$repo\tools\*.ps1" "$work\tools"
    # A tiny real executable exercises --version validation without GPU binaries.
    Add-Type -TypeDefinition 'public class FakeLlama { public static void Main() { System.Console.WriteLine("version: 0.8.0-dev (build 12345, commit fixture)"); } }' -OutputAssembly "$work\fixtures\main\llama-server.exe" -OutputType ConsoleApplication
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
        (New-Asset 'llama-b12345-bin-win-cpu-arm64.zip' "$work\fixtures\main.zip")
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
        & "$work\manage-llama.ps1" Update -b $backend -v b12345
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
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File "$work\start-server.ps1" -b $backend -m "$work\model.gguf" -d 2>&1
        $text = $output -join "`n"
        if ($LASTEXITCODE -ne 0 -or $text -notmatch "llama-versions\\$backend\\b12345") { throw "Runtime routing failed: $text" }
        if ($backend -eq 'CPU' -and $text -notmatch '--device') { throw 'CPU device flag missing' }
        if ($backend -eq 'CUDA' -and $text -notmatch '-ngl') { throw 'GPU layers missing' }
    }
    # A corrupt dependency must not publish a new installation or alter selection.
    $release.tag_name = 'b12346'
    foreach ($asset in $release.assets) { $asset.name = $asset.name.Replace('b12345', 'b12346') }
    $release.assets[2].digest = 'sha256:' + ('0' * 64)
    $rejected = $false
    try { & "$work\manage-llama.ps1" Update -b cuda -v b12346 }
    catch { if ($_.Exception.Message -notmatch 'SHA256 mismatch') { throw }; $rejected = $true }
    if (-not $rejected -or (Test-Path "$work\llama-versions\cuda\b12346") -or (Get-Content "$work\llama-versions\cuda\current.txt") -ne 'b12345') { throw 'Failed update changed installation/selection' }
    # Interactive menu: choose 3 (cpu, latest), then 0 to exit; it must re-select the installed build.
    $release.tag_name = 'b12345'
    foreach ($asset in $release.assets) { $asset.name = $asset.name.Replace('b12346', 'b12345') }
    Remove-Item "$work\llama-versions\cpu\current.txt"
    $menuAnswers = New-Object 'System.Collections.Generic.Queue[string]'
    $menuAnswers.Enqueue('3'); $menuAnswers.Enqueue('0')
    function Read-Host { param($Prompt) $menuAnswers.Dequeue() }
    & "$work\manage-llama.ps1" -Interactive
    if ((Get-Content "$work\llama-versions\cpu\current.txt") -ne 'b12345') { throw 'Interactive install did not select latest cpu' }
    Write-Host 'PASS: CPU/CUDA asset selection, dependency deployment, manifests, launcher routing, SHA256 failure preserves current version, interactive menu.'
} finally {
    $resolved = [IO.Path]::GetFullPath($work)
    if ((Split-Path $resolved -Parent) -ne [IO.Path]::GetFullPath($PSScriptRoot) -or (Split-Path $resolved -Leaf) -notlike '.work-*') { throw 'Invalid test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
