# Shared runtime resolution. "legacy" always means the original installation.
function Get-LlamaRuntime([string]$Backend, [string]$Version = '') {
    $root = Split-Path $PSScriptRoot -Parent
    if (-not $Version) {
        $pointer = Join-Path $root "llama-versions\$Backend\current.txt"
        $Version = if (Test-Path -LiteralPath $pointer) { (Get-Content -LiteralPath $pointer -Raw).Trim() } else { 'legacy' }
    }
    if ($Version -ne 'legacy' -and $Version -notmatch '^b[0-9]+$') { throw "Invalid version: $Version" }
    $dir = if ($Version -eq 'legacy') { Join-Path $root "llama-$Backend" } else { Join-Path $root "llama-versions\$Backend\$Version" }
    $exe = Join-Path $dir 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $hint = if ($Version -eq 'legacy') { "manage-llama.bat Update -b $Backend" } else { "manage-llama.bat Install -b $Backend -v $Version" }
        throw "Runtime not installed: $exe`nInstall it first: $hint"
    }
    return $exe
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
