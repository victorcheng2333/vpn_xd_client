<#
.SYNOPSIS
Collect XD VPN session evidence without changing network configuration.
.DESCRIPTION
Without -TargetUri this script reads local state only. It does not connect,
disconnect, install, change routes/DNS, or change any security driver.
A target URI opts into bounded DNS and source/interface-bound TCP/TLS/HTTP HEAD
checks for that host only. Redirects and authentication are never followed.
-ProbeMtu additionally opts into IPv4 ICMP checks to that same target.
The report contains private network addresses; review it before sharing.
.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\diagnose-live.ps1
.EXAMPLE
.\diagnose-live.ps1 -Session <session-guid> -TargetUri https://your-intranet-host/ -ProbeMtu | Out-File .\xdvpn-report.json -Encoding utf8
#>
[CmdletBinding()]
param(
    [Guid]$Session = [Guid]::Empty,
    [Uri]$TargetUri,
    [ValidateRange(1,30)][int]$SampleSeconds = 3,
    [ValidateRange(1,10)][int]$TimeoutSeconds = 4,
    [switch]$ProbeMtu
)
$ErrorActionPreference = 'Stop'
if ($TargetUri -and (-not $TargetUri.IsAbsoluteUri -or $TargetUri.Scheme -notin @('http','https') -or $TargetUri.UserInfo)) { throw 'TargetUri must be an absolute HTTP(S) URI without credentials.' }
if ($ProbeMtu -and -not $TargetUri) { throw '-ProbeMtu requires an explicit -TargetUri.' }
$issues = [Collections.Generic.List[string]]::new()
function Read-Evidence([string]$Label, [scriptblock]$Read) {
    try { & $Read } catch { $issues.Add($Label + ': ' + $_.Exception.Message) }
}
function Initialize-XDVPNDiagnosticProbe {
    # Resolve beside this script, never through CWD or dynamically compiled
    # CodeDOM references (the installed app also ships a .NET 10 System.dll).
    $helperPath=Join-Path $PSScriptRoot 'XDVPN.RouteAudit.dll'
    $helper=Get-Item -LiteralPath $helperPath -ErrorAction Stop
    if($helper.PSIsContainer -or ($helper.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid packaged diagnostic helper.'}
    $assembly=[Reflection.Assembly]::LoadFrom($helper.FullName)
    if(-not [string]::Equals($assembly.Location,$helper.FullName,[StringComparison]::OrdinalIgnoreCase)){throw 'Diagnostic helper resolved outside the script directory.'}
    return $assembly.GetType('XDVPN.DiagnosticTargetProbe',$true)
}
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Read-Statistics($Adapter) {
    # Select by the verified, unique adapter name; descriptions are not unique.
    Get-NetAdapterStatistics -Name $Adapter.Name -ErrorAction Stop |
        Select-Object Name,ReceivedBytes,SentBytes,ReceivedUnicastPackets,SentUnicastPackets,ReceivedDiscardedPackets,OutboundDiscardedPackets,ReceivedPacketErrors,OutboundPacketErrors
}
function Read-BestRoute([string]$Address, [string]$LocalAddress = '', [int]$Index = 0) {
    $arguments = @{ RemoteIPAddress = $Address; ErrorAction = 'Stop' }
    if ($LocalAddress) { $arguments.LocalIPAddress = $LocalAddress }
    if ($Index) { $arguments.InterfaceIndex = [uint32]$Index }
    @(Find-NetRoute @arguments | Select-Object IPAddress,InterfaceIndex,InterfaceAlias,DestinationPrefix,NextHop,RouteMetric,InterfaceMetric)
}
$report = [ordered]@{
    SchemaVersion = 1
    TimeUtc = [DateTime]::UtcNow.ToString('o')
    Administrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Notes = @(
        'Default collection is local/read-only. Access denied is reported as unknown, never as an absent route or policy.',
        'Adapter counters include all traffic and do not prove this particular target worked. Idle tunnels need not receive traffic.',
        'Configured and SSL connected prove setup/control-channel state only. Successful TCP/TLS/HTTP checks describe this target and this moment only.',
        'A running filter driver is not evidence that it dropped traffic. This report cannot establish WFP policy or server-side isolation as the cause.',
        'ICMP failure alone cannot establish a tunnel failure or an MTU black hole. Compare with a successful small probe and the target TCP/TLS result.',
        'Service activity logs contain structured events, not a complete raw OpenConnect transcript.'
    )
    Service = Read-Evidence 'service' { Get-Service XDVPN -ErrorAction Stop | Select-Object Name,Status,StartType }
    SessionCandidates = @()
    Session = $null
    Adapter = $null
    Addresses = @()
    IpInterfaces = @()
    RelevantRoutes = @()
    DnsServers = @(Read-Evidence 'DNS servers' { Get-DnsClientServerAddress -ErrorAction Stop | Where-Object { $_.ServerAddresses.Count } | Select-Object InterfaceAlias,InterfaceIndex,AddressFamily,ServerAddresses })
    EffectiveNrpt = @(Read-Evidence 'effective NRPT' { Get-DnsClientNrptPolicy -Effective -ErrorAction Stop | Select-Object Namespace,NameServers,DirectAccessEnabled,DnsSecValidationRequired })
    OtherUpAdapters = @()
    Bindings = @()
    Counters = $null
    ActivityEvents = @()
    NetworkLogs = @()
    TargetProbe = $null
    Errors = $issues
}
$sessionRoot = Join-Path $env:ProgramData 'XDVPN\sessions'
$candidates = @(Read-Evidence 'session directory' { Get-ChildItem -LiteralPath $sessionRoot -Directory -ErrorAction Stop | Where-Object { $id=[Guid]::Empty; [Guid]::TryParseExact($_.Name,'D',[ref]$id) } })
$report.SessionCandidates = @($candidates | Select-Object Name,LastWriteTimeUtc)
if ($Session -eq [Guid]::Empty) {
    if ($candidates.Count -eq 1) { $Session = [Guid]$candidates[0].Name }
    elseif ($candidates.Count -gt 1) { $issues.Add('Multiple sessions exist. Use -Session with the intended GUID; no session or probe was selected.') }
}
$state = $null; $adapter = $null
if ($Session -ne [Guid]::Empty) {
    Read-Evidence 'selected session' {
        $directory = Join-Path $sessionRoot $Session.ToString('D')
        $owner = Read-Json (Join-Path $directory 'owner.json')
        $expectedAdapter = 'XDVPN-' + $Session.ToString('N').Substring(0,12)
        if ($owner.session -ne $Session.ToString('D') -or $owner.adapter -ne $expectedAdapter) { throw 'Session ownership does not match the requested GUID.' }
        $script:state = Read-Json (Join-Path $directory 'network.json')
        $configuredPath = Join-Path $directory 'configured'
        $configured = (Test-Path -LiteralPath $configuredPath -ErrorAction Stop) -and ((Get-Content -LiteralPath $configuredPath -Raw).Trim() -eq $Session.ToString('D'))
        $report.Session = [ordered]@{ Id=$Session.ToString('D'); AdapterName=$expectedAdapter; Configured=$configured; Network=$state }
        $matches = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.ifIndex -eq $state.InterfaceIndex -and $_.Name -eq $expectedAdapter -and $_.InterfaceGuid.ToString() -eq $state.InterfaceGuid })
        if ($matches.Count -ne 1) { throw 'No unique adapter matches the session index, GUID and name. Counters and target probes were skipped.' }
        $script:adapter = $matches[0]
        $report.Adapter = $adapter | Select-Object ifIndex,Name,Status,InterfaceDescription,InterfaceGuid
    }
}
$report.OtherUpAdapters = @(Read-Evidence 'other adapters' { Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and (-not $adapter -or $_.ifIndex -ne $adapter.ifIndex) } | Select-Object ifIndex,Name,InterfaceDescription })
$report.RelevantRoutes = @(Read-Evidence 'routes' {
    Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop | Where-Object {
        ($adapter -and $_.InterfaceIndex -eq $adapter.ifIndex) -or
        $_.DestinationPrefix -in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1','::/0') -or
        ($state -and $_.DestinationPrefix -in @($state.Routes | ForEach-Object Prefix))
    } | Select-Object AddressFamily,InterfaceIndex,DestinationPrefix,NextHop,RouteMetric,InterfaceMetric,Protocol
})
if ($adapter) {
    $report.Addresses = @(Read-Evidence 'addresses' { Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | Select-Object IPAddress,AddressFamily,PrefixLength,AddressState,SkipAsSource })
    $report.IpInterfaces = @(Read-Evidence 'IP interfaces' { Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | Select-Object AddressFamily,InterfaceMetric,NlMtu,ConnectionState })
    $report.Bindings = @(Read-Evidence 'adapter bindings' { Get-NetAdapterBinding -Name $adapter.Name -ErrorAction Stop | Select-Object DisplayName,ComponentID,Enabled })
}
$before = $null; $started = [DateTime]::UtcNow
if ($adapter) { $before = Read-Evidence 'initial counters' { Read-Statistics $adapter } }
if ($TargetUri) {
    $target = [UriBuilder]::new($TargetUri); $target.Fragment = ''
    $report.TargetProbe = [ordered]@{ Host=$target.Host; Port=$target.Port; Scheme=$target.Scheme; DnsResults=@(); DnsServerRoutes=@(); SystemRoutes=@(); TunnelRoutes=@(); Tests=@(); Mtu=@(); Notes=@('Only IPv4 is tested through XD VPN. IPv6 answers are recorded because other application traffic could use IPv6 outside this IPv4 tunnel.', 'DNS answers use Windows resolver routing; successful resolution alone is not proof of tunnel reachability.', 'TCP connects pin both the source IP and IP_UNICAST_IF to the verified XD adapter. HTTPS validates the normal certificate chain and hostname. HTTP HEAD sends no credentials/cookies and follows no redirects.') }
    if (-not $adapter -or -not $report.Session.Configured -or $state.Address -notin @($report.Addresses | ForEach-Object IPAddress)) {
        $issues.Add('Target probe skipped: a configured session and matching tunnel source address are required.')
    } else {
        $helperReady=$false
        try { [void](Initialize-XDVPNDiagnosticProbe); $helperReady=$true }
        catch { $issues.Add('Target probe skipped: packaged diagnostic helper unavailable: '+$_.Exception.Message) }
        if($helperReady) {
        $parsedAddress = $null
        if ([Net.IPAddress]::TryParse($target.Host,[ref]$parsedAddress)) {
            $answers = @([pscustomobject]@{ Name=$target.Host; Type=if($parsedAddress.AddressFamily -eq 'InterNetwork'){'A'}else{'AAAA'}; IPAddress=$parsedAddress.ToString(); Resolver='literal' })
        } else {
            $answers = @(Read-Evidence 'system target DNS' { Resolve-DnsName -Name $target.Host -Type A_AAAA -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object IPAddress | Select-Object Name,Type,IPAddress,@{n='Resolver';e={'system'}} })
            foreach ($server in @($state.Dns | Select-Object -First 4)) {
                $report.TargetProbe.DnsServerRoutes += @(Read-Evidence ('DNS server route '+$server) { Read-BestRoute $server })
                $answers += @(Read-Evidence ('target DNS via '+$server) { Resolve-DnsName -Name $target.Host -Server $server -Type A_AAAA -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object IPAddress | Select-Object Name,Type,IPAddress,@{n='Resolver';e={$server}} })
            }
        }
        $report.TargetProbe.DnsResults = $answers
        $destinations = @($answers | Where-Object { $_.Type -eq 'A' -or $_.Type -eq 1 } | Select-Object -ExpandProperty IPAddress -Unique | Select-Object -First 4)
        if (-not $destinations.Count) { $issues.Add('No IPv4 target address is available; TCP/TLS/HTTP and MTU probes skipped.') }
        foreach ($destination in $destinations) {
            $report.TargetProbe.SystemRoutes += @(Read-Evidence ('system route '+$destination) { Read-BestRoute $destination })
            $report.TargetProbe.TunnelRoutes += @(Read-Evidence ('tunnel route '+$destination) { Read-BestRoute $destination $state.Address $adapter.ifIndex })
            $report.TargetProbe.Tests += [XDVPN.DiagnosticTargetProbe]::Run($destination,$state.Address,$adapter.ifIndex,$target.Uri,$TimeoutSeconds*1000)
            if ($ProbeMtu) {
                $mtu = @($report.IpInterfaces | Where-Object AddressFamily -eq 'IPv4' | Select-Object -First 1 -ExpandProperty NlMtu)
                $largePayload = if ($mtu.Count -and [int]$mtu[0] -ge 576) { [Math]::Min(1400,[int]$mtu[0]-28) } else { 1200 }
                foreach ($payload in @(32,$largePayload | Select-Object -Unique)) {
                    # -S binds the source; unlike TCP, ping does not enforce IP_UNICAST_IF.
                    $output = @(& "$env:SystemRoot\System32\PING.EXE" -4 -S $state.Address -n 1 -w ($TimeoutSeconds*1000) -f -l $payload $destination 2>&1)
                    $report.TargetProbe.Mtu += [pscustomobject]@{ RemoteAddress=$destination; SourceAddress=$state.Address; PayloadBytes=$payload; PacketBytes=$payload+28; ExitCode=$LASTEXITCODE; Output=($output -join "`n"); Note='ICMP may be filtered; source binding alone does not prove the egress interface. A successful large probe bounds MTU; a timeout does not locate a cause.' }
                }
            }
        }
        }
    }
}
if ($adapter -and $before) {
    $remaining = $SampleSeconds - ([DateTime]::UtcNow-$started).TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($remaining*1000)) }
    $after = Read-Evidence 'final counters' {
        $current = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.ifIndex -eq $adapter.ifIndex -and $_.InterfaceGuid -eq $adapter.InterfaceGuid -and $_.Name -eq $adapter.Name })
        if ($current.Count -ne 1) { throw 'Adapter disappeared or changed identity during sampling.' }
        Read-Statistics $adapter
    }
    if ($after) {
        $deltaRx=[decimal]$after.ReceivedBytes-[decimal]$before.ReceivedBytes; $deltaTx=[decimal]$after.SentBytes-[decimal]$before.SentBytes
        $reset=$deltaRx -lt 0 -or $deltaTx -lt 0
        $report.Counters = [ordered]@{ ElapsedSeconds=[Math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,2); Before=$before; After=$after; ResetDetected=$reset; ReceivedBytesDelta=if($reset){$null}else{$deltaRx}; SentBytesDelta=if($reset){$null}else{$deltaTx} }
    }
}
$report.ActivityEvents = @(Read-Evidence 'structured service activity log' {
    $logPath = Join-Path $env:ProgramData 'XDVPN\logs\activity.jsonl'
    Get-Content -LiteralPath $logPath -Tail 120 -ErrorAction Stop | ForEach-Object {
        try { $entry=$_ | ConvertFrom-Json; if ($Session -eq [Guid]::Empty -or $entry.Attempt -eq $Session.ToString('D')) { $entry | Select-Object Time,Event,Message,Attempt,DurationMs } }
        catch { $issues.Add('One service activity record could not be parsed.') }
    }
})
# Network hook logs deliberately survive session cleanup. Read only the chosen
# session, or at most three recent attempts when no session directory remains.
$report.NetworkLogs = @(Read-Evidence 'structured network logs' {
    $logDirectory = Join-Path $env:ProgramData 'XDVPN\logs'
    if ((Get-Item -LiteralPath $logDirectory -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Network log directory is a reparse point; logs are unknown.' }
    $files = if ($Session -ne [Guid]::Empty) {
        @(Get-Item -LiteralPath (Join-Path $logDirectory ('network-'+$Session.ToString('D')+'.jsonl')) -ErrorAction Stop)
    } elseif ($candidates.Count -eq 0) {
        @(Get-ChildItem -LiteralPath $logDirectory -Filter 'network-*.jsonl' -File -ErrorAction Stop | Where-Object {
            $logId=[Guid]::Empty
            $_.Name -match '^network-(.{36})\.jsonl$' -and [Guid]::TryParseExact($Matches[1],'D',[ref]$logId)
        } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3)
    } else { @() }
    foreach ($file in $files) {
        $logId=[Guid]::ParseExact($file.BaseName.Substring(8),'D').ToString('D')
        $log = [ordered]@{ FileName=$file.Name; Session=$logId; LastWriteTimeUtc=$file.LastWriteTimeUtc; ReadStatus='ok'; Records=@() }
        try {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint -or $file.Length -gt 262144) { throw 'Network log is a reparse point or exceeds the bounded size limit.' }
            $recordNumber=0
            foreach ($line in @(Get-Content -LiteralPath $file.FullName -Tail 60 -ErrorAction Stop)) {
                $recordNumber++
                try {
                    if ($line.Length -gt 32768) { throw 'Record too large' }
                    $entry=$line | ConvertFrom-Json -ErrorAction Stop
                    if ($entry.session -ne $logId -or $entry.code -notmatch '^[a-z][a-z0-9.-]{0,80}$' -or $entry.outcome -notin @('ok','failed')) { throw 'Invalid record schema or session' }
                    $log.Records += [pscustomobject]@{ ReadStatus='ok'; Time=$entry.time; Session=$entry.session; Phase=$entry.phase; Outcome=$entry.outcome; Code=$entry.code; Detail=$entry.detail }
                } catch {
                    $log.ReadStatus='partial'
                    $log.Records += [pscustomobject]@{ ReadStatus='unknown'; Record=$recordNumber; Reason='Invalid JSON, schema, session or record size; raw content omitted.' }
                    $issues.Add('A network log record is unknown in '+$file.Name+'.')
                }
            }
        } catch { $log.ReadStatus='unknown'; $issues.Add('Network log '+$file.Name+': '+$_.Exception.Message) }
        [pscustomobject]$log
    }
})
$report | ConvertTo-Json -Depth 14
