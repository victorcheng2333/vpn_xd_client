param([ValidateSet('Hook','Cleanup','Verify')][string]$Mode, [Guid]$Session)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Join-Path $env:ProgramData ('XDVPN\sessions\' + $Session.ToString('D'))
$ownerPath = Join-Path $root 'owner.json'
$statePath = Join-Path $root 'network.json'
$readyPath = Join-Path $root 'configured'
$lockPath = Join-Path $root 'lock'
$reason = if ($Mode -eq 'Hook') { [Environment]::GetEnvironmentVariable('reason') } else { $Mode.ToLowerInvariant() }
$phase = if ($reason -in @('connect','disconnect','attempt-reconnect','reconnect','pre-init','verify','cleanup')) { $reason } else { 'invalid' }
$failureCode = 'hook.failed'
function Diagnostic([string]$outcome, [string]$code, $detail) {
    # Only callers' numeric network fields and fixed codes enter this log. Never log
    # arbitrary exception text, the environment, server URLs, domains or credentials.
    try {
        $logs = Join-Path $env:ProgramData 'XDVPN\logs'
        if (-not (Test-Path -LiteralPath $logs)) { New-Item -Path $logs -ItemType Directory -Force | Out-Null }
        if ((Get-Item -LiteralPath $logs).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        $file = Join-Path $logs ('network-' + $Session.ToString('D') + '.jsonl')
        if (Test-Path -LiteralPath $file) {
            $item = Get-Item -LiteralPath $file
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
            if ($item.Length -gt 98304) { [IO.File]::WriteAllText($file, '') }
        }
        $entry = [ordered]@{ time=[DateTime]::UtcNow.ToString('o'); session=$Session.ToString('D'); phase=$phase; outcome=$outcome; code=$code; detail=$detail }
        [IO.File]::AppendAllText($file, (($entry | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding $false))
        @(Get-ChildItem -LiteralPath $logs -Filter 'network-*.jsonl' -File |
            Where-Object { $_.Name -match '^network-[0-9a-f-]{36}\.jsonl$' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 32) | Remove-Item -Force
    } catch { } # Diagnostic storage must never bypass cleanup.
}
function Reject([string]$code) { $script:failureCode=$code; throw ('XDVPN_NETWORK_ERROR:' + $code) }
if (-not (Test-Path -LiteralPath $ownerPath)) {
    if ($Mode -eq 'Cleanup') {
        # A crash between creating the session directory and publishing owner.json
        # must not leave an immortal "successful cleanup" tombstone. Only a truly
        # empty directory (or its unused zero-byte lock) is provably pre-configuration.
        if (-not (Test-Path -LiteralPath $root)) { exit 0 }
        $orphanLock=$null
        try {
            $dataRoot=[IO.Path]::GetFullPath((Join-Path $env:ProgramData 'XDVPN'))
            $sessionsRoot=[IO.Path]::GetFullPath((Join-Path $dataRoot 'sessions'))
            $orphanRoot=[IO.Path]::GetFullPath($root)
            if ($orphanRoot -ne (Join-Path $sessionsRoot $Session.ToString('D'))) { Reject 'session.path' }
            foreach ($path in @($dataRoot,$sessionsRoot,$orphanRoot)) {
                $item=Get-Item -LiteralPath $path -Force
                if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Reject 'session.path' }
            }
            $entries=@(Get-ChildItem -LiteralPath $orphanRoot -Force)
            if ($entries.Count) {
                if ($entries.Count -ne 1 -or $entries[0].Name -ne 'lock' -or $entries[0].PSIsContainer -or
                    ($entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -or $entries[0].Length -ne 0) { Reject 'session.unowned-content' }
                try { $orphanLock=[IO.File]::Open($lockPath,'Open','ReadWrite','None') }
                catch [IO.IOException] { Reject 'session.busy' }
                # Re-enumerate while owning the lock; never discard owner, network,
                # configured, PID, partial journal or any other unrecognised record.
                $entries=@(Get-ChildItem -LiteralPath $orphanRoot -Force)
                if ($entries.Count -ne 1 -or $entries[0].Name -ne 'lock' -or $orphanLock.Length -ne 0) { Reject 'session.unowned-content' }
                $orphanLock.Dispose(); $orphanLock=$null
                [IO.File]::Delete($lockPath)
            }
            # Nonrecursive deletion fails safely if a concurrent initializer writes
            # any file after the checks. Never recursively erase an unowned session.
            [IO.Directory]::Delete($orphanRoot,$false)
            Diagnostic 'ok' 'session.empty-cleaned' $null
            exit 0
        } catch {
            if ($failureCode -eq 'hook.failed') { $failureCode='session.empty-cleanup' }
            Diagnostic 'failed' $failureCode @{ errorType=$_.Exception.GetType().FullName; hresult=$_.Exception.HResult }
            throw ('XDVPN_NETWORK_ERROR:' + $failureCode)
        } finally { if ($orphanLock) { $orphanLock.Dispose() } }
    }
    Diagnostic 'failed' 'session.missing' $null
    throw 'XDVPN_NETWORK_ERROR:session.missing'
}
$lock=$null
for ($lockAttempt=0; $lockAttempt -le 50; $lockAttempt++) {
    try { $lock=[IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None'); break }
    catch [IO.IOException] {
        if (($_.Exception.HResult -band 65535) -notin @(32,33)) { throw 'XDVPN_NETWORK_ERROR:session.lock' }
        if ($lockAttempt -lt 50) { Start-Sleep -Milliseconds 100 }
    }
}
if (-not $lock) {
    Diagnostic 'busy' 'session.busy' $null
    # A health check must not revoke readiness owned by the active hook.
    if ($Mode -eq 'Verify') { exit 75 }
    throw 'XDVPN_NETWORK_ERROR:session.busy'
}
try {
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    if ($owner.session -ne $Session.ToString('D') -or $owner.adapter -ne ('XDVPN-' + $Session.ToString('N').Substring(0,12))) { Reject 'session.identity' }
    $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else {
        [pscustomobject]@{ InterfaceGuid=''; InterfaceIndex=0; Address=''; Dns=@(); Routes=@(); Gateway=''; Excludes=@() }
    }
    # Old journals remain cleanable, but cannot claim a verified new configuration.
    foreach ($pair in @(@('SchemaVersion',0),@('Includes',@()),@('DnsRoutes',@()),@('Mtu',0),@('Domain',''),@('FullTunnel',$false),@('BypassIndex',0),@('BypassNextHop',''),@('BypassGuid',''))) {
        if (-not $state.PSObject.Properties[$pair[0]]) { $state | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
    }
    function Save-State {
        $temp = $statePath + '.new'
        [IO.File]::WriteAllText($temp, ($state | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $statePath) { [IO.File]::Replace($temp, $statePath, ($statePath + '.bak')) } else { [IO.File]::Move($temp, $statePath) }
    }
    function IPv4([string]$value) {
        $ip = $null
        if ($value -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($value,[ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { Reject 'input.ipv4' }
        return $ip.ToString()
    }
    function IPNumber([string]$value) {
        $b=[Net.IPAddress]::Parse($value).GetAddressBytes()
        return [uint64]$b[0]*16777216+[uint64]$b[1]*65536+[uint64]$b[2]*256+[uint64]$b[3]
    }
    function Contains([string]$prefix,[string]$ip) {
        $parts=$prefix.Split('/'); $size=[Math]::Pow(2,32-[int]$parts[1])
        return [Math]::Floor((IPNumber $parts[0])/$size) -eq [Math]::Floor((IPNumber $ip)/$size)
    }
    function In-Prefixes($prefixes,[string]$ip) {
        foreach ($prefix in $prefixes) { if (Contains $prefix $ip) { return $true } }; return $false
    }
    function Count([string]$name) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not $value) { return 0 }
        if ($value -notmatch '^\d{1,3}$' -or [int]$value -gt 256) { Reject 'input.route-count' }
        return [int]$value
    }
    function Prefix([string]$name, [int]$i) {
        $address = IPv4 ([Environment]::GetEnvironmentVariable($name + '_' + $i + '_ADDR'))
        $mask = [Environment]::GetEnvironmentVariable($name + '_' + $i + '_MASKLEN')
        if ($mask -notmatch '^\d{1,2}$' -or [int]$mask -gt 32) { Reject 'input.prefix' }
        $size=[Math]::Pow(2,32-[int]$mask)
        if ((IPNumber $address) % $size -ne 0) { Reject 'input.network-address' }
        return $address + '/' + [int]$mask
    }
    function Adapter([int]$index, [string]$guid) {
        $nic = Get-NetAdapter -IncludeHidden | Where-Object { $_.ifIndex -eq $index } | Select-Object -First 1
        if ($nic -and $nic.InterfaceGuid.ToString() -ne $guid) { Reject 'interface.identity' }
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
            if (@(Matching-Route $r).Count) { Reject 'route.cleanup' }
        }
    }
    function Add-OwnedRoute([string]$prefix, [int]$index, [string]$next, [bool]$external) {
        $nic = Get-NetAdapter -IncludeHidden | Where-Object { $_.ifIndex -eq $index } | Select-Object -First 1
        if (-not $nic) { Reject 'route.interface-missing' }
        $metric = if ($external) { 42757 } else { 3 }
        $r = [pscustomobject]@{ Prefix=$prefix; Index=$index; Guid=$nic.InterfaceGuid.ToString(); NextHop=$next; Metric=$metric; External=$external }
        $existing = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore | Where-Object { $_.DestinationPrefix -eq $prefix -and $_.InterfaceIndex -eq $index -and $_.NextHop -eq $next })
        if ($existing.Count) { return } # Borrow, never adopt an existing route.
        if (-not @($state.Routes | Where-Object { $_.Prefix -eq $prefix -and $_.Index -eq $index -and $_.NextHop -eq $next }).Count) {
            $state.Routes = @($state.Routes) + $r; Save-State
        }
        $script:failureCode='route.creation'
        New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $index -NextHop $next -RouteMetric $metric -PolicyStore ActiveStore -Protocol NetMgmt | Out-Null
        if (-not @(Matching-Route $r).Count) { Reject 'route.creation' }
    }
    function Refresh-Bypass {
        $physicalNics = @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')
        $physical = @($physicalNics | Select-Object -ExpandProperty ifIndex)
        $defaults = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore | Where-Object { $_.InterfaceIndex -in $physical -and $_.NextHop -ne '0.0.0.0' } | Sort-Object { $_.RouteMetric + $_.InterfaceMetric })
        if (-not $defaults.Count) { Reject 'physical.gateway-missing' }
        $gateway = $defaults[0]
        foreach ($r in @($state.Routes | Where-Object External)) { Remove-OwnedRoute $r }
        $state.Routes = @($state.Routes | Where-Object { -not $_.External })
        $state.BypassIndex=[int]$gateway.InterfaceIndex; $state.BypassNextHop=IPv4 $gateway.NextHop
        $state.BypassGuid=($physicalNics | Where-Object ifIndex -eq $state.BypassIndex | Select-Object -First 1).InterfaceGuid.ToString(); Save-State
        Add-OwnedRoute ($state.Gateway + '/32') $gateway.InterfaceIndex $gateway.NextHop $true
        foreach ($prefix in @($state.Excludes)) { Add-OwnedRoute $prefix $gateway.InterfaceIndex $gateway.NextHop $true }
    }
    function Wait-Address([bool]$wait) {
        for ($attempt=0; $attempt -lt $(if($wait){30}else{1}); $attempt++) {
            $addresses=@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceIndex -eq $state.InterfaceIndex -and $_.IPAddress -eq $state.Address })
            if ($addresses.Count -eq 1 -and $addresses[0].AddressState -eq 'Preferred') { return }
            if ($addresses.Count -ne 1 -or $addresses[0].AddressState -ne 'Tentative') { Reject 'address.unusable' }
            if ($wait) { Start-Sleep -Milliseconds 100 }
        }
        Reject 'address.tentative-timeout'
    }
    function Check-KernelRoute([string]$ip,[int]$expectedIndex,[string]$expectedHop) {
        # Find-NetRoute reads the kernel route/source selection; it sends no packets.
        $selection=@(Find-NetRoute -RemoteIPAddress $ip -ErrorAction Stop)
        $route=@($selection | Where-Object { $_.PSObject.Properties['DestinationPrefix'] })
        $source=@($selection | Where-Object { $_.PSObject.Properties['IPAddress'] })
        if ($route.Count -ne 1 -or $route[0].InterfaceIndex -ne $expectedIndex -or $route[0].NextHop -ne $expectedHop -or
            ($expectedIndex -eq $state.InterfaceIndex -and ($source.Count -ne 1 -or $source[0].IPAddress -ne $state.Address))) {
            Diagnostic 'failed' 'route.selection' @{ destination=$ip; expectedIndex=$expectedIndex; actual=@($route | Select-Object DestinationPrefix,InterfaceIndex,NextHop,RouteMetric) }
            Reject 'route.selection'
        }
    }
    function Verify-Network([bool]$wait) {
        $script:failureCode='network.verify'
        if ($state.SchemaVersion -ne 2) { Reject 'journal.version' }
        $adapters=@(Get-NetAdapter -IncludeHidden)
        $nic=@($adapters | Where-Object ifIndex -eq $state.InterfaceIndex)
        if ($nic.Count -ne 1 -or $nic[0].InterfaceGuid.ToString() -ne $state.InterfaceGuid -or $nic[0].Name -ne $owner.adapter -or $nic[0].Status -ne 'Up') { Reject 'interface.unavailable' }
        $physicalNics=@(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')
        $bypassNic=@($physicalNics | Where-Object ifIndex -eq $state.BypassIndex)
        if ($bypassNic.Count -ne 1 -or $bypassNic[0].InterfaceGuid.ToString() -ne $state.BypassGuid) { Reject 'physical.identity' }
        Wait-Address $wait
        $ipInterfaces=@(Get-NetIPInterface -AddressFamily IPv4)
        $ipInterface=@($ipInterfaces | Where-Object InterfaceIndex -eq $state.InterfaceIndex)
        if ($ipInterface.Count -ne 1 -or $ipInterface[0].ConnectionState -ne 'Connected' -or $ipInterface[0].NlMtu -ne $state.Mtu -or $ipInterface[0].InterfaceMetric -ne 3) { Reject 'interface.configuration' }
        $actualDns=@((Get-DnsClientServerAddress -InterfaceIndex $state.InterfaceIndex -AddressFamily IPv4).ServerAddresses)
        if (($actualDns -join ',') -ne ($state.Dns -join ',')) { Reject 'dns.configuration' }
        if ((Get-DnsClient -InterfaceIndex $state.InterfaceIndex).ConnectionSpecificSuffix -ne $state.Domain) { Reject 'dns.suffix' }
        $connected=@($ipInterfaces | Where-Object ConnectionState -eq 'Connected' | Select-Object -ExpandProperty InterfaceIndex)
        $table=@(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore | Where-Object InterfaceIndex -in $connected)
        foreach ($r in $state.Routes) {
            if (-not @($adapters | Where-Object { $_.ifIndex -eq $r.Index -and $_.InterfaceGuid.ToString() -eq $r.Guid }).Count) { Reject 'route.interface-identity' }
            if (-not @($table | Where-Object { $_.InterfaceIndex -eq $r.Index -and $_.DestinationPrefix -eq $r.Prefix -and $_.NextHop -eq $r.NextHop -and $_.RouteMetric -eq $r.Metric -and $_.Protocol -eq 'NetMgmt' }).Count) { Reject 'route.owned-missing' }
        }
        foreach ($prefix in @($state.Includes)+@($state.DnsRoutes)) {
            if (-not @($table | Where-Object { $_.DestinationPrefix -eq $prefix -and $_.InterfaceIndex -eq $state.InterfaceIndex -and $_.NextHop -eq '0.0.0.0' }).Count) { Reject 'route.tunnel-missing' }
        }
        # Check the whole IPv4 policy, including more-specific foreign routes. The
        # pure interval sweep is local arithmetic, not hundreds of network probes.
        if (-not ('XDVPN.RouteAudit' -as [type])) {
            $script:failureCode='route.audit-load'
            [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot 'XDVPN.RouteAudit.dll')) | Out-Null
            if (-not ('XDVPN.RouteAudit' -as [type])) { Reject 'route.audit-load' }
            $script:failureCode='network.verify'
        }
        $metrics=@{}; foreach($i in $ipInterfaces){ $metrics[[int]$i.InterfaceIndex]=[int]$i.InterfaceMetric }
        $rows=@($table | ForEach-Object {
            $metric=if($metrics.ContainsKey([int]$_.InterfaceIndex)){$metrics[[int]$_.InterfaceIndex]}else{[int]$_.InterfaceMetric}
            $_.DestinationPrefix+'|'+$_.InterfaceIndex+'|'+$_.NextHop+'|'+([int]$_.RouteMetric+$metric)+'|'+$_.Protocol
        })
        $conflict=[XDVPN.RouteAudit]::Check([string[]]$rows,[string[]]$state.Includes,[string[]]$state.Excludes,[string[]]$state.Dns,$state.Gateway,$state.InterfaceIndex,$state.BypassIndex,$state.BypassNextHop,$state.FullTunnel,[int[]]@($physicalNics | Select-Object -ExpandProperty ifIndex))
        if ($conflict.Count) { Diagnostic 'failed' 'route.policy-conflict' @{ destination=$conflict[0]; actualIndex=$conflict[1]; actualNextHop=$conflict[2] }; Reject 'route.policy-conflict' }
        Check-KernelRoute $state.Gateway $state.BypassIndex $state.BypassNextHop
        foreach ($dns in $state.Dns) {
            if (In-Prefixes $state.Excludes $dns) { Check-KernelRoute $dns $state.BypassIndex $state.BypassNextHop }
            else { Check-KernelRoute $dns $state.InterfaceIndex '0.0.0.0' }
        }
        Diagnostic 'ok' 'network.verified' @{ address=$state.Address; interface=$state.InterfaceIndex; mtu=$state.Mtu; gateway=$state.Gateway; bypassIndex=$state.BypassIndex; bypassNextHop=$state.BypassNextHop; dns=@($state.Dns); includes=@($state.Includes); excludes=@($state.Excludes); dnsRoutes=@($state.DnsRoutes) }
    }
    function Cleanup {
        $script:failureCode='network.cleanup'
        foreach ($r in @($state.Routes)) { Remove-OwnedRoute $r }
        if ($state.InterfaceGuid) {
            $nic = Adapter $state.InterfaceIndex $state.InterfaceGuid
            if ($nic) {
                if ($nic.Name -ne $owner.adapter) { Reject 'interface.name-changed' }
                $dns = @((Get-DnsClientServerAddress -InterfaceIndex $state.InterfaceIndex -AddressFamily IPv4).ServerAddresses)
                if ($dns.Count -and (($dns | Sort-Object) -join ',') -ne (($state.Dns | Sort-Object) -join ',')) { Reject 'dns.ownership' }
                Set-DnsClientServerAddress -InterfaceIndex $state.InterfaceIndex -ResetServerAddresses
                Set-DnsClient -InterfaceIndex $state.InterfaceIndex -ConnectionSpecificSuffix ''
                Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceIndex -eq $state.InterfaceIndex | Where-Object IPAddress -eq $state.Address | Remove-NetIPAddress -Confirm:$false
                if (@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceIndex -eq $state.InterfaceIndex | Where-Object IPAddress -eq $state.Address).Count) { Reject 'address.cleanup' }
                if (@((Get-DnsClientServerAddress -InterfaceIndex $state.InterfaceIndex -AddressFamily IPv4).ServerAddresses).Count) { Reject 'dns.cleanup' }
            }
        }
    }
    if ($Mode -ne 'Verify') { Remove-Item -LiteralPath $readyPath -ErrorAction SilentlyContinue }
    if ($Mode -eq 'Cleanup' -or $reason -eq 'disconnect') {
        Cleanup
        Remove-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
        Diagnostic 'ok' 'network.cleaned' $null
    } elseif ($Mode -eq 'Verify') {
        Verify-Network $false
    } elseif ($reason -eq 'connect') {
        if ($state.InterfaceGuid) { Reject 'session.duplicate-connect' }
        $index = [Environment]::GetEnvironmentVariable('TUNIDX')
        if ($index -notmatch '^\d{1,10}$') { Reject 'input.tunnel-index' }
        $nic = Get-NetAdapter -IncludeHidden | Where-Object { $_.ifIndex -eq [int]$index } | Select-Object -First 1
        if (-not $nic -or $nic.Name -ne $owner.adapter) { Reject 'interface.identity' }
        $state.InterfaceIndex = [int]$index; $state.InterfaceGuid = $nic.InterfaceGuid.ToString()
        $state.Address = IPv4 $env:INTERNAL_IP4_ADDRESS
        $state.Gateway = IPv4 $env:VPNGATEWAY
        $dnsValue = [Environment]::GetEnvironmentVariable('INTERNAL_IP4_DNS')
        $state.Dns = @(); if ($dnsValue) { $state.Dns = @($dnsValue.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { IPv4 $_ } | Select-Object -Unique) }
        if ($state.Dns.Count -gt 16) { Reject 'input.dns-count' }
        $includes = @(); for ($i=0; $i -lt (Count 'CISCO_SPLIT_INC'); $i++) { $includes += Prefix 'CISCO_SPLIT_INC' $i }
        $state.FullTunnel = -not $includes.Count -or '0.0.0.0/0' -in $includes
        if ($state.FullTunnel) { $includes = @($includes | Where-Object { $_ -ne '0.0.0.0/0' }) + @('0.0.0.0/1','128.0.0.0/1') }
        $state.Includes=@($includes | Select-Object -Unique)
        $state.Excludes = @(); for ($i=0; $i -lt (Count 'CISCO_SPLIT_EXC'); $i++) { $state.Excludes += Prefix 'CISCO_SPLIT_EXC' $i }
        $state.Excludes=@($state.Excludes | Select-Object -Unique)
        $state.DnsRoutes=@($state.Dns | Where-Object { -not (In-Prefixes $state.Excludes $_) -and -not (In-Prefixes $state.Includes $_) } | ForEach-Object { $_+'/32' })
        $mtuValue = [Environment]::GetEnvironmentVariable('INTERNAL_IP4_MTU'); $state.Mtu = 1400
        if ($mtuValue) { if ($mtuValue -notmatch '^\d{3,4}$' -or [int]$mtuValue -lt 576 -or [int]$mtuValue -gt 9000) { Reject 'input.mtu' }; $state.Mtu = [int]$mtuValue }
        $state.Domain = [Environment]::GetEnvironmentVariable('CISCO_DEF_DOMAIN')
        if (-not $state.Domain) { $state.Domain='' }
        if ($state.Domain -and ($state.Domain.Length -gt 253 -or $state.Domain -notmatch '^[A-Za-z0-9.-]+$')) { Reject 'input.dns-suffix' }
        if (@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceIndex -eq $state.InterfaceIndex | Where-Object { $_.IPAddress -notlike '169.254.*' }).Count) { Reject 'address.already-configured' }
        $state.SchemaVersion=2; Save-State
        Refresh-Bypass
        New-NetIPAddress -InterfaceIndex $state.InterfaceIndex -IPAddress $state.Address -PrefixLength 32 -PolicyStore ActiveStore | Out-Null
        Set-NetIPInterface -InterfaceIndex $state.InterfaceIndex -AddressFamily IPv4 -InterfaceMetric 3 -NlMtuBytes $state.Mtu -PolicyStore ActiveStore
        if ($state.Dns.Count) { Set-DnsClientServerAddress -InterfaceIndex $state.InterfaceIndex -ServerAddresses $state.Dns }
        if ($state.Domain) { Set-DnsClient -InterfaceIndex $state.InterfaceIndex -ConnectionSpecificSuffix $state.Domain }
        foreach ($prefix in @($state.Includes)+@($state.DnsRoutes)) { Add-OwnedRoute $prefix $state.InterfaceIndex '0.0.0.0' $false }
        Verify-Network $true
    } elseif ($reason -eq 'attempt-reconnect' -or $reason -eq 'reconnect') {
        if (-not $state.InterfaceGuid -or $state.SchemaVersion -ne 2) { Reject 'journal.version' }
        $nic=Adapter $state.InterfaceIndex $state.InterfaceGuid
        if (-not $nic -or $nic.Name -ne $owner.adapter) { Reject 'interface.identity' }
        Refresh-Bypass
        Check-KernelRoute $state.Gateway $state.BypassIndex $state.BypassNextHop
        Diagnostic 'ok' 'bypass.refreshed' @{ gateway=$state.Gateway; interface=$state.BypassIndex; nextHop=$state.BypassNextHop }
        if ($reason -eq 'reconnect') {
            foreach ($prefix in @($state.Includes)+@($state.DnsRoutes)) { Add-OwnedRoute $prefix $state.InterfaceIndex '0.0.0.0' $false }
            Verify-Network $true
        }
    } elseif ($reason -ne 'pre-init') { Reject 'hook.phase' }
    if ($Mode -eq 'Hook' -and $reason -in @('connect','reconnect') -and $state.InterfaceGuid) { [IO.File]::WriteAllText($readyPath, $Session.ToString('D')) }
} catch {
    Remove-Item -LiteralPath $readyPath -ErrorAction SilentlyContinue
    Diagnostic 'failed' $failureCode @{ errorType=$_.Exception.GetType().FullName; hresult=$_.Exception.HResult; line=$_.InvocationInfo.ScriptLineNumber }
    throw ('XDVPN_NETWORK_ERROR:' + $failureCode)
} finally { $lock.Dispose() }
if ($Mode -eq 'Cleanup') { Remove-Item -LiteralPath $root -Recurse -Force }
