param([ValidateSet('Hook','Cleanup')][string]$Mode, [Guid]$Session)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Join-Path $env:ProgramData ('XDVPN\sessions\' + $Session.ToString('D'))
$ownerPath = Join-Path $root 'owner.json'
$statePath = Join-Path $root 'network.json'
$readyPath = Join-Path $root 'configured'
$lockPath = Join-Path $root 'lock'
if (-not (Test-Path -LiteralPath $ownerPath)) { if ($Mode -eq 'Cleanup') { exit 0 }; throw 'Missing session owner' }
$lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    if ($owner.session -ne $Session.ToString('D') -or $owner.adapter -ne ('XDVPN-' + $Session.ToString('N').Substring(0,12))) { throw 'Invalid owner' }
    $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else {
        [pscustomobject]@{ InterfaceGuid = ''; InterfaceIndex = 0; Address = ''; Dns = @(); Routes = @(); Gateway = ''; Excludes = @() }
    }
    function Save-State {
        $temp = $statePath + '.new'
        [IO.File]::WriteAllText($temp, ($state | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $statePath) { [IO.File]::Replace($temp, $statePath, ($statePath + '.bak')) } else { [IO.File]::Move($temp, $statePath) }
    }
    function IPv4([string]$value) {
        $ip = $null
        if ($value -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($value,[ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { throw 'Invalid IPv4 value' }
        return $ip.ToString()
    }
    function Count([string]$name) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not $value) { return 0 }
        if ($value -notmatch '^\d{1,3}$' -or [int]$value -gt 256) { throw 'Too many routes' }
        return [int]$value
    }
    function Prefix([string]$name, [int]$i) {
        $address = IPv4 ([Environment]::GetEnvironmentVariable($name + '_' + $i + '_ADDR'))
        $mask = [Environment]::GetEnvironmentVariable($name + '_' + $i + '_MASKLEN')
        if ($mask -notmatch '^\d{1,2}$' -or [int]$mask -gt 32) { throw 'Invalid prefix' }
        return $address + '/' + [int]$mask
    }
    function Adapter([int]$index, [string]$guid) {
        $nic = Get-NetAdapter -IncludeHidden | Where-Object { $_.ifIndex -eq $index } | Select-Object -First 1
        if ($nic -and $nic.InterfaceGuid.ToString() -ne $guid) { throw 'Interface identity changed' }
        return $nic
    }
    function Matching-Route($r) {
        return @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
            $_.InterfaceIndex -eq $r.Index -and $_.DestinationPrefix -eq $r.Prefix -and $_.NextHop -eq $r.NextHop -and $_.RouteMetric -eq $r.Metric -and $_.Protocol -eq 'NetMgmt'
        })
    }
    function Remove-OwnedRoute($r) {
        $nic = Adapter $r.Index $r.Guid
        if ($nic) {
            @(Matching-Route $r) | Remove-NetRoute -Confirm:$false -ErrorAction Stop
            if (@(Matching-Route $r).Count) { throw 'Route cleanup verification failed' }
        }
    }
    function Add-OwnedRoute([string]$prefix, [int]$index, [string]$next, [bool]$external) {
        $nic = Get-NetAdapter -IncludeHidden | Where-Object { $_.ifIndex -eq $index } | Select-Object -First 1
        if (-not $nic) { throw 'Route interface disappeared' }
        $metric = if ($external) { 42757 } else { 3 }
        $r = [pscustomobject]@{ Prefix=$prefix; Index=$index; Guid=$nic.InterfaceGuid.ToString(); NextHop=$next; Metric=$metric; External=$external }
        $existing = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore | Where-Object { $_.DestinationPrefix -eq $prefix -and $_.InterfaceIndex -eq $index -and $_.NextHop -eq $next })
        if ($existing.Count) { return }
        $state.Routes = @($state.Routes) + $r; Save-State
        New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $index -NextHop $next -RouteMetric $metric -PolicyStore ActiveStore -Protocol NetMgmt | Out-Null
        if (-not @(Matching-Route $r).Count) { throw 'Route creation verification failed' }
    }
    function Refresh-Bypass {
        $physical = @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty ifIndex)
        $defaults = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore | Where-Object { $_.InterfaceIndex -in $physical -and $_.NextHop -ne '0.0.0.0' } | Sort-Object { $_.RouteMetric + $_.InterfaceMetric })
        if (-not $defaults.Count) { throw 'Physical gateway unavailable' }
        $gateway = $defaults[0]
        foreach ($r in @($state.Routes | Where-Object External)) { Remove-OwnedRoute $r }
        $state.Routes = @($state.Routes | Where-Object { -not $_.External }); Save-State
        Add-OwnedRoute ($state.Gateway + '/32') $gateway.InterfaceIndex $gateway.NextHop $true
        foreach ($prefix in @($state.Excludes)) { Add-OwnedRoute $prefix $gateway.InterfaceIndex $gateway.NextHop $true }
    }
    function Cleanup {
        foreach ($r in @($state.Routes)) { Remove-OwnedRoute $r }
        if ($state.InterfaceGuid) {
            $nic = Adapter $state.InterfaceIndex $state.InterfaceGuid
            if ($nic) {
                if ($nic.Name -ne $owner.adapter) { throw 'Adapter name changed' }
                $dns = @((Get-DnsClientServerAddress -InterfaceIndex $state.InterfaceIndex -AddressFamily IPv4).ServerAddresses)
                if ($dns.Count -and (($dns | Sort-Object) -join ',') -ne (($state.Dns | Sort-Object) -join ',')) { throw 'DNS ownership changed' }
                Set-DnsClientServerAddress -InterfaceIndex $state.InterfaceIndex -ResetServerAddresses
                Set-DnsClient -InterfaceIndex $state.InterfaceIndex -ConnectionSpecificSuffix ''
                Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceIndex -eq $state.InterfaceIndex | Where-Object IPAddress -eq $state.Address | Remove-NetIPAddress -Confirm:$false
                if (@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceIndex -eq $state.InterfaceIndex | Where-Object IPAddress -eq $state.Address).Count) { throw 'Address cleanup verification failed' }
                if (@((Get-DnsClientServerAddress -InterfaceIndex $state.InterfaceIndex -AddressFamily IPv4).ServerAddresses).Count) { throw 'DNS cleanup verification failed' }
            }
        }
    }
    $reason = [Environment]::GetEnvironmentVariable('reason')
    Remove-Item -LiteralPath $readyPath -ErrorAction SilentlyContinue
    if ($Mode -eq 'Cleanup' -or $reason -eq 'disconnect') {
        Cleanup
        Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
    } elseif ($reason -eq 'connect') {
        if ($state.InterfaceGuid) { throw 'Duplicate initial configuration' }
        $index = [Environment]::GetEnvironmentVariable('TUNIDX')
        if ($index -notmatch '^\d{1,10}$') { throw 'Invalid tunnel index' }
        $nic = Get-NetAdapter -IncludeHidden | Where-Object { $_.ifIndex -eq [int]$index } | Select-Object -First 1
        if (-not $nic -or $nic.Name -ne $owner.adapter) { throw 'Tunnel identity mismatch' }
        $state.InterfaceIndex = [int]$index; $state.InterfaceGuid = $nic.InterfaceGuid.ToString()
        $state.Address = IPv4 $env:INTERNAL_IP4_ADDRESS
        $state.Gateway = IPv4 $env:VPNGATEWAY
        $dnsValue = [Environment]::GetEnvironmentVariable('INTERNAL_IP4_DNS')
        $state.Dns = @(); if ($dnsValue) { $state.Dns = @($dnsValue.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { IPv4 $_ }) }
        if ($state.Dns.Count -gt 16) { throw 'Too many DNS servers' }
        $includes = @(); for ($i=0; $i -lt (Count 'CISCO_SPLIT_INC'); $i++) { $includes += Prefix 'CISCO_SPLIT_INC' $i }
        $state.Excludes = @(); for ($i=0; $i -lt (Count 'CISCO_SPLIT_EXC'); $i++) { $state.Excludes += Prefix 'CISCO_SPLIT_EXC' $i }
        if (@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceIndex -eq $state.InterfaceIndex | Where-Object { $_.IPAddress -notlike '169.254.*' }).Count) { throw 'Tunnel already configured' }
        Save-State
        Refresh-Bypass
        New-NetIPAddress -InterfaceIndex $state.InterfaceIndex -IPAddress $state.Address -PrefixLength 32 -PolicyStore ActiveStore | Out-Null
        $mtuValue = [Environment]::GetEnvironmentVariable('INTERNAL_IP4_MTU')
        $mtu = 1400
        if ($mtuValue) { if ($mtuValue -notmatch '^\d{3,4}$' -or [int]$mtuValue -lt 576 -or [int]$mtuValue -gt 9000) { throw 'Invalid MTU' }; $mtu = [int]$mtuValue }
        Set-NetIPInterface -InterfaceIndex $state.InterfaceIndex -AddressFamily IPv4 -InterfaceMetric 3 -NlMtuBytes $mtu -PolicyStore ActiveStore
        if ($state.Dns.Count) { Set-DnsClientServerAddress -InterfaceIndex $state.InterfaceIndex -ServerAddresses $state.Dns }
        $domain = [Environment]::GetEnvironmentVariable('CISCO_DEF_DOMAIN')
        if ($domain) {
            if ($domain.Length -gt 253 -or $domain -notmatch '^[A-Za-z0-9.-]+$') { throw 'Invalid DNS suffix' }
            Set-DnsClient -InterfaceIndex $state.InterfaceIndex -ConnectionSpecificSuffix $domain
        }
        if (-not $includes.Count) { $includes = @('0.0.0.0/1', '128.0.0.0/1') }
        foreach ($prefix in $includes) { Add-OwnedRoute $prefix $state.InterfaceIndex '0.0.0.0' $false }
        if (-not @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceIndex -eq $state.InterfaceIndex | Where-Object IPAddress -eq $state.Address).Count) { throw 'Address verification failed' }
        $actualDns = @((Get-DnsClientServerAddress -InterfaceIndex $state.InterfaceIndex -AddressFamily IPv4).ServerAddresses)
        if (($actualDns -join ',') -ne ($state.Dns -join ',')) { throw 'DNS verification failed' }
    } elseif ($reason -eq 'attempt-reconnect' -or $reason -eq 'reconnect') {
        if ($state.InterfaceGuid) { Refresh-Bypass }
    } elseif ($reason -ne 'pre-init') { throw 'Unexpected network hook' }
    if ($Mode -eq 'Hook' -and $reason -in @('connect','reconnect') -and $state.InterfaceGuid) { [IO.File]::WriteAllText($readyPath, $Session.ToString('D')) }
} finally { $lock.Dispose() }
if ($Mode -eq 'Cleanup') { Remove-Item -LiteralPath $root -Recurse -Force }
