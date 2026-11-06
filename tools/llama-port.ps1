# Probe the requested bind address, not just a list of active TCP connections.
function Get-LlamaPortStatus([string]$Address, [int]$Port) {
    $addresses = @([Net.Dns]::GetHostAddresses($Address))
    if ($addresses.Count -eq 0) { throw "Cannot resolve bind address: $Address" }
    foreach ($ip in $addresses) {
        $listener = New-Object Net.Sockets.TcpListener($ip, $Port)
        try {
            $listener.Server.ExclusiveAddressUse = $true
            $listener.Start()
        } catch [Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -in @('AddressAlreadyInUse', 'AccessDenied')) {
                return [pscustomobject]@{ Available = $false; Reason = [string]$_.Exception.SocketErrorCode; Code = $_.Exception.NativeErrorCode }
            }
            throw
        } finally { $listener.Stop() }
    }
    return [pscustomobject]@{ Available = $true; Reason = 'Available'; Code = 0 }
}

function Test-LlamaPort([string]$Address, [int]$Port) {
    return (Get-LlamaPortStatus $Address $Port).Available
}

function Test-LlamaBindError([string]$Line) {
    return $Line -match "(?i)(address already in use|WSAEADDRINUSE|failed to bind|could not bind|couldn't bind|unable to bind|bind\(\).*failed|bind failed)"
}
