# Windows PowerShell 5.1+. Download official builds side by side; never overwrite legacy.
[CmdletBinding()]
param(
    [Alias('a')][ValidateSet('Help','List','Check','Install','Update','Use','Remove')][string]$Action = 'List',
    [Alias('b')][ValidateSet('vulkan','openvino')][string]$Backend = 'vulkan',
    [Alias('v')][string]$Version = 'latest',
    [Alias('d')][switch]$DryRun,
    [Alias('h')][switch]$Help
)
if ($Help -or $Action -eq 'Help') {
    @'
Usage: manage-llama.bat [Action] [-b vulkan|openvino] [-v VERSION] [-d]
       manage-llama.bat Help   (or -Help / -h)
Actions:
  List     List local versions (default; offline).
  Check    Check official release and SHA256 (online, no download).
  Install  Download and verify a version without selecting it.
  Update   Download, verify and select a version.
  Use      Select an installed bNNNNN version or legacy.
  Remove   Delete a non-selected managed bNNNNN version (offline).
Options:
  -a  -Action   Action name; may also be the first positional argument.
  -b  -Backend  vulkan (default) or openvino; managed independently.
  -v  -Version  latest (default) or bNNNNN; Use also accepts legacy.
  -d  -DryRun   Preview Remove only; no deletion.
  -h  -Help     Show help without accessing network or installations.
Examples:
  manage-llama.bat Check -b openvino
  manage-llama.bat Install -v b11970
  manage-llama.bat Use -v legacy
  manage-llama.bat Remove -b vulkan -v b11970 -d
Remove requires an explicit version. Selected/running versions and legacy
are protected. Switch versions and stop the old process before deletion.
Use .ps1 with the same arguments in PowerShell for execution without pause.
'@
    return
}
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tools\llama-runtime.ps1"
$base = Join-Path $PSScriptRoot "llama-versions\$Backend"
$pointer = Join-Path $base 'current.txt'
$current = if (Test-Path -LiteralPath $pointer) { (Get-Content -LiteralPath $pointer -Raw).Trim() } else { 'legacy' }
if ($DryRun -and $Action -ne 'Remove') { throw 'DryRun is only supported for Remove.' }

function Set-Current([string]$Tag) {
    $null = Get-LlamaRuntime $Backend $Tag
    $null = New-Item -ItemType Directory -Force -Path $base
    $temp = Join-Path $base ([guid]::NewGuid().ToString() + '.tmp')
    [IO.File]::WriteAllText($temp, $Tag)
    if (Test-Path -LiteralPath $pointer) {
        $backup = "$temp.previous"
        [IO.File]::Replace($temp, $pointer, $backup)
        Remove-Item -LiteralPath $backup -Force
    }
    else { [IO.File]::Move($temp, $pointer) }
    Write-Host "Selected $Backend / $Tag. Restart the server to apply."
}
function Get-Assets($Release) {
    $pattern = if ($Backend -eq 'vulkan') { '^llama-b[0-9]+-bin-win-vulkan-x64\.zip$' } else { '^llama-b[0-9]+-bin-win-openvino(?:-[0-9.]+)?-x64\.zip$' }
    @($Release.assets | Where-Object { $_.name -match $pattern })
}

if ($Action -eq 'List') {
    $tags = @()
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot "llama-$Backend\llama-server.exe") -PathType Leaf) { $tags += 'legacy' }
    if (Test-Path -LiteralPath $base) { $tags += @(Get-ChildItem -LiteralPath $base -Directory | Where-Object Name -Match '^b[0-9]+$' | Select-Object -ExpandProperty Name) }
    foreach ($tag in $tags) {
        $exe = Get-LlamaRuntime $Backend $tag
        [pscustomobject]@{ Backend = $Backend; Version = $tag; Active = ($tag -eq $current); Executable = $exe }
    }
    if ($tags.Count -eq 0) { Write-Host "No local $Backend versions. Run: manage-llama.bat Update -b $Backend" }
    return
}
if ($Action -eq 'Use') { Set-Current $Version; return }
if ($Action -eq 'Remove') {
    if ($Version -notmatch '^b[0-9]+$') { throw 'Remove requires an explicit bNNNNN version; legacy cannot be removed.' }
    if ($Version -eq $current) { throw "Cannot remove selected version $Version. Use another version or legacy first." }
    $managedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'llama-versions'))
    $target = [IO.Path]::GetFullPath((Join-Path $base $Version))
    $expectedParent = [IO.Path]::GetFullPath($base).TrimEnd('\') + '\'
    if (-not $target.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $target -Leaf) -ne $Version) { throw 'Deletion target is outside the managed backend directory.' }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw "Version not installed: $Backend / $Version" }
    # Refuse junctions/symlinks in the managed path or tree, so recursive deletion stays local.
    foreach ($path in @($managedRoot, $base, $target)) {
        if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to remove through a reparse point: $path"
        }
    }
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($target)
    while ($pending.Count -gt 0) {
        foreach ($entry in Get-ChildItem -LiteralPath $pending.Dequeue() -Force) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point in version directory: $($entry.FullName)" }
            if ($entry.PSIsContainer) { $pending.Enqueue($entry.FullName) }
        }
    }
    $prefix = $target.TrimEnd('\') + '\'
    foreach ($process in Get-Process) {
        $processPath = $process.Path
        if ($processPath -and $processPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Version is running (PID $($process.Id)). Stop it before removing."
        }
    }
    if ($DryRun) { Write-Host "Would remove: $target"; return }
    Remove-Item -LiteralPath $target -Recurse -Force
    Write-Host "Removed $Backend / $Version"
    return
}
if ($Version -ne 'latest' -and $Version -notmatch '^b[0-9]+$') { throw 'Version must be latest or bNNNNN.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ 'User-Agent' = 'local-llama-manager'; Accept = 'application/vnd.github+json' }
$api = 'https://api.github.com/repos/ggml-org/llama.cpp/releases'
if ($Version -eq 'latest') {
    # /latest can point to a semantic release containing no binaries.
    $release = $null
    foreach ($page in 1..5) {
        $releases = Invoke-RestMethod -Uri "${api}?per_page=30&page=$page" -Headers $headers -TimeoutSec 60
        $release = $releases | Where-Object { -not $_.draft -and $_.tag_name -match '^b[0-9]+$' -and @(Get-Assets $_).Count -eq 1 } | Select-Object -First 1
        if ($release) { break }
    }
    if (-not $release) { throw "No recent Windows x64 $Backend release found." }
} else {
    $release = Invoke-RestMethod -Uri "$api/tags/$Version" -Headers $headers -TimeoutSec 60
}
$assets = @(Get-Assets $release)
if ($assets.Count -ne 1) { throw 'Release must contain exactly one matching Windows x64 archive.' }
$asset = $assets[0]
$tag = [string]$release.tag_name
if ($tag -notmatch '^b[0-9]+$') { throw 'Unexpected release tag.' }
Write-Host "Selected release: $tag / $($asset.name) (current: $current)"
if ($Action -eq 'Check') { $asset | Select-Object name,size,digest,browser_download_url | Format-List; return }
$destination = Join-Path $base $tag
if (-not (Test-Path -LiteralPath $destination)) {
    $null = New-Item -ItemType Directory -Force -Path $base
    $stage = Join-Path $base ('.staging-' + [guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory -Path $stage
    $zip = Join-Path $stage 'package.zip'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -Headers $headers -OutFile $zip -TimeoutSec 1800
        if ((Get-Item -LiteralPath $zip).Length -ne $asset.size) { throw 'Download size mismatch.' }
        $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($asset.digest -match '^sha256:([a-fA-F0-9]{64})$') {
            if ($sha -ne $Matches[1]) { throw 'SHA256 mismatch.' }
        } else { throw 'Release has no SHA256 digest; refusing an unverified installation.' }
        $unpack = Join-Path $stage 'unpacked'
        Expand-Archive -LiteralPath $zip -DestinationPath $unpack
        $servers = @(Get-ChildItem -LiteralPath $unpack -Recurse -File -Filter llama-server.exe)
        if ($servers.Count -ne 1) { throw 'Archive must contain one llama-server.exe.' }
        $runtime = $servers[0].DirectoryName
        # Windows PowerShell treats native stderr as errors; llama prints version there.
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $versionText = (& $servers[0].FullName --version 2>&1 | Out-String); $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $savedPreference }
        if ($code -ne 0 -or $versionText -notmatch ('(?m)(?:build\s+|version:\s*)' + $tag.Substring(1) + '\b')) {
            throw "Runtime version check failed: $versionText"
        }
        @{ tag = $tag; backend = $Backend; asset = $asset.name; sha256 = $sha; source = $asset.browser_download_url; installedUtc = [DateTime]::UtcNow.ToString('o'); versionOutput = $versionText } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtime 'install.json') -Encoding UTF8
        # Both paths are constructed inside the workspace; destination is a validated bNNNNN tag.
        Move-Item -LiteralPath $runtime -Destination $destination
        Write-Host "Installed: $destination"
    } finally {
        $resolvedStage = [IO.Path]::GetFullPath($stage)
        $expectedParent = [IO.Path]::GetFullPath($base).TrimEnd('\') + '\'
        if ($resolvedStage.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedStage -Leaf) -like '.staging-*') {
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force
        }
    }
} else { $null = Get-LlamaRuntime $Backend $tag; Write-Host "Already installed: $tag" }
if ($Action -eq 'Update') { Set-Current $tag }
