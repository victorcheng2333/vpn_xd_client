# Runs the real network script with in-memory cmdlet substitutes. Never changes OS networking.
param(
    [string]$RouteAuditAssembly=(Join-Path $PSScriptRoot '..\..\..\.build\windows-route-audit\XDVPN.RouteAudit.dll'),
    [switch]$ColdLoadOnly,
    [string]$FacadeAssembly='',
    [switch]$IsolatedWorker,
    [string]$FixtureRoot=''
)
$ErrorActionPreference='Stop'
$sourceScript=Join-Path $PSScriptRoot 'network.ps1'
if (-not (Test-Path -LiteralPath $RouteAuditAssembly -PathType Leaf)) { throw 'Build XDVPN.RouteAudit.dll with build-route-audit.ps1 before running network tests.' }
$RouteAuditAssembly=(Resolve-Path -LiteralPath $RouteAuditAssembly).ProviderPath
if (-not $FacadeAssembly) {
    $runtimeRoots=@()
    $dotnetCommand=Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dotnetCommand) { $runtimeRoots+=Join-Path (Split-Path $dotnetCommand.Source) 'shared\Microsoft.NETCore.App' }
    $runtimeRoots+=Join-Path $PSScriptRoot '..\..\..\.build\windows-package\dotnet\shared\Microsoft.NETCore.App'
    foreach ($runtime in $runtimeRoots) {
        $candidate=Get-ChildItem -Path (Join-Path $runtime '*\System.dll') -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($candidate) { $FacadeAssembly=$candidate.FullName; break }
    }
}
if (-not $FacadeAssembly -or -not (Test-Path -LiteralPath $FacadeAssembly -PathType Leaf)) { throw 'Pass the packaged .NET runtime System.dll using -FacadeAssembly.' }
$FacadeAssembly=(Resolve-Path -LiteralPath $FacadeAssembly).ProviderPath
if (-not $IsolatedWorker) {
    # Framework LoadFrom holds the DLL open until process exit. The parent owns
    # the fixture and removes it only after the worker has completely exited.
    $testRoot=Join-Path ([IO.Path]::GetTempPath()) ('xdvpn-network-test-'+[Guid]::NewGuid())
    $process=$null
    try {
        New-Item -Path $testRoot -ItemType Directory | Out-Null
        Copy-Item -LiteralPath $FacadeAssembly -Destination (Join-Path $testRoot 'System.dll')
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.WorkingDirectory=$testRoot
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        $start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -RouteAuditAssembly "'+$RouteAuditAssembly+'" -FacadeAssembly "'+$FacadeAssembly+'" -IsolatedWorker -FixtureRoot "'+$testRoot+'"'
        if ($ColdLoadOnly) { $start.Arguments+=' -ColdLoadOnly' }
        $process=[Diagnostics.Process]::Start($start)
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw 'Isolated network tests exceeded 30 seconds' }
        $output=$stdout.GetAwaiter().GetResult(); $errors=$stderr.GetAwaiter().GetResult()
        if ($output) { Write-Output $output.TrimEnd() }
        if ($errors) { Write-Output $errors.TrimEnd() }
        if ($process.ExitCode -ne 0) { throw ('Isolated network tests failed: '+$process.ExitCode) }
    } finally {
        if ($process) { $process.Dispose() }
        $target=[IO.Path]::GetFullPath($testRoot)
        if ((Split-Path $target) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and (Split-Path $target -Leaf) -match '^xdvpn-network-test-[0-9a-f-]{36}$') { Remove-Item -LiteralPath $target -Recurse -Force }
    }
    return
}
if (-not $FixtureRoot -or [IO.Path]::GetFullPath($FixtureRoot) -ne [Environment]::CurrentDirectory) { throw 'Network worker requires its isolated process working directory' }
if (-not (Test-Path -LiteralPath (Join-Path ([Environment]::CurrentDirectory) 'System.dll') -PathType Leaf)) { throw 'Cold environment lacks the packaged .NET System.dll' }
$oldTemp=$env:TEMP; $oldTmp=$env:TMP
$environmentPattern='^(reason|TUNIDX|INTERNAL_IP4_[A-Z0-9_]+|CISCO_(DEF_DOMAIN|SPLIT_[A-Z0-9_]+))$'; $originalEnvironment=@{}; Get-ChildItem Env: | Where-Object Name -match $environmentPattern | ForEach-Object { $originalEnvironment[$_.Name]=$_.Value }; $oldData=$env:ProgramData
$env:ProgramData=$FixtureRoot
$fixture=Join-Path $env:ProgramData 'bundle'
New-Item $fixture -ItemType Directory | Out-Null
$script=Join-Path $fixture 'network.ps1'
Copy-Item -LiteralPath $sourceScript -Destination $script
Copy-Item -LiteralPath $RouteAuditAssembly -Destination (Join-Path $fixture 'XDVPN.RouteAudit.dll')
$global:routes=[Collections.ArrayList]::new();$global:addresses=[Collections.ArrayList]::new();$global:dns=@();$global:failRoute=$false
function Get-NetAdapter { [CmdletBinding()]param([switch]$IncludeHidden,[switch]$Physical) if($Physical){$global:physical;if($global:otherPhysical){$global:otherPhysical}}else{$global:physical;if($global:otherPhysical){$global:otherPhysical};$global:tunnel} }
function Get-NetRoute { [CmdletBinding()]param($AddressFamily,$PolicyStore,$DestinationPrefix) $global:routes | Where-Object { -not $DestinationPrefix -or $_.DestinationPrefix -eq $DestinationPrefix } }
function New-NetRoute { [CmdletBinding()]param($DestinationPrefix,$InterfaceIndex,$NextHop,$RouteMetric,$PolicyStore,$Protocol)
    if($global:failRoute -and $InterfaceIndex -eq 9){throw 'Injected route failure'}
    $r=[pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=$InterfaceIndex;NextHop=$NextHop;RouteMetric=$RouteMetric;InterfaceMetric=0;Protocol=$Protocol};[void]$global:routes.Add($r);$r
}
function Remove-NetRoute { [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject) process{[void]$global:routes.Remove($InputObject)} }
function Get-NetIPAddress { [CmdletBinding()]param($AddressFamily) $global:addresses.ToArray() }
function New-NetIPAddress { [CmdletBinding()]param($InterfaceIndex,$IPAddress,$PrefixLength,$PolicyStore) $r=[pscustomobject]@{InterfaceIndex=$InterfaceIndex;IPAddress=$IPAddress;AddressState=$global:addressState};[void]$global:addresses.Add($r);$r }
function Remove-NetIPAddress { [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject) process{[void]$global:addresses.Remove($InputObject)} }
function Get-DnsClientServerAddress { [CmdletBinding()]param($InterfaceIndex,$AddressFamily) [pscustomobject]@{ServerAddresses=@($global:dns)} }
function Set-DnsClientServerAddress { [CmdletBinding()]param($InterfaceIndex,$ServerAddresses,[switch]$ResetServerAddresses) if($ResetServerAddresses){$global:dns=@()}else{$global:dns=@($ServerAddresses)} }
function Set-DnsClient { [CmdletBinding()]param($InterfaceIndex,$ConnectionSpecificSuffix) $global:domain=$ConnectionSpecificSuffix }
function Set-NetIPInterface { [CmdletBinding()]param($InterfaceIndex,$AddressFamily,$InterfaceMetric,$NlMtuBytes,$PolicyStore) $global:mtu=$NlMtuBytes; $global:interfaceMetric=$InterfaceMetric }
function Get-DnsClient { [CmdletBinding()]param($InterfaceIndex) [pscustomobject]@{ConnectionSpecificSuffix=$global:domain} }
function Get-NetIPInterface { [CmdletBinding()]param($AddressFamily)
    foreach($idx in @(3,9,20,31)) { [pscustomobject]@{InterfaceIndex=$idx;NlMtu=$(if($idx -eq 9){$global:mtu}else{1500});InterfaceMetric=$(if($idx -eq 9){$global:interfaceMetric}else{1});ConnectionState=$(if($idx -in $global:disconnected){'Disconnected'}else{'Connected'})} }
}
function Start-Sleep { param($Milliseconds) $global:dadWait++; if($global:heldLock -and $global:lockReleaseAfter -gt 0 -and $global:dadWait -ge $global:lockReleaseAfter){$global:heldLock.Dispose();$global:heldLock=$null}; if($global:dadReadyAfter -gt 0 -and $global:dadWait -ge $global:dadReadyAfter){foreach($a in $global:addresses){$a.AddressState='Preferred'}} }
function IPNumber([string]$s){$b=[Net.IPAddress]::Parse($s).GetAddressBytes();return [uint64]$b[0]*16777216+[uint64]$b[1]*65536+[uint64]$b[2]*256+[uint64]$b[3]}
function Selected([string]$ip) {
    $n=IPNumber $ip
    @($global:routes | Where-Object InterfaceIndex -notin $global:disconnected | Where-Object { $p=$_.DestinationPrefix.Split('/'); $size=[Math]::Pow(2,32-[int]$p[1]); [Math]::Floor($n/$size) -eq [Math]::Floor((IPNumber $p[0])/$size) } |
        Sort-Object @{Expression={[int]$_.DestinationPrefix.Split('/')[1]};Descending=$true},@{Expression={$_.RouteMetric+$(if($_.InterfaceIndex -eq 9){$global:interfaceMetric}else{1})}})[0]
}
function Find-NetRoute { [CmdletBinding()]param($RemoteIPAddress)
    $r=Selected $RemoteIPAddress
    if($global:kernelWrong){$r=$global:routes[0]}
    [pscustomobject]@{InterfaceIndex=$r.InterfaceIndex;IPAddress=$(if($r.InterfaceIndex -eq 9){$env:INTERNAL_IP4_ADDRESS}else{'192.0.2.2'})}
    $r
}
function Ready { Test-Path (Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D')+'\configured')) }
function Rejects([scriptblock]$action,[string]$code) {
    $caught=$false
    try { & $action } catch { if($_.Exception.Message -notmatch [regex]::Escape($code)){throw}; $caught=$true }
    Assert ($caught -and -not (Ready)) ('Expected failure with no ready marker: '+$code)
}
function Reset {
    $global:routes.Clear();$global:addresses.Clear();$global:dns=@();$global:failRoute=$false; $global:domain=''; $global:mtu=1400; $global:interfaceMetric=3; $global:addressState='Preferred'; $global:dadWait=0; $global:dadReadyAfter=0; $global:kernelWrong=$false; $global:disconnected=@(); $global:otherPhysical=$null; $global:heldLock=$null; $global:lockReleaseAfter=0; $env:CISCO_DEF_DOMAIN=''; $env:INTERNAL_IP4_MTU=''
    $global:session=[Guid]::NewGuid()
    $global:physical=[pscustomobject]@{ifIndex=3;Name='Wi-Fi';InterfaceGuid=[Guid]::NewGuid();Status='Up'}
    $global:tunnel=[pscustomobject]@{ifIndex=9;Name=('XDVPN-'+$session.ToString('N').Substring(0,12));InterfaceGuid=[Guid]::NewGuid();Status='Up'}
    $folder=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D'));New-Item $folder -ItemType Directory -Force | Out-Null
    @{session=$session.ToString('D');adapter=$tunnel.Name}|ConvertTo-Json|Set-Content (Join-Path $folder 'owner.json')
    [void](New-NetRoute '0.0.0.0/0' 3 '192.0.2.1' 10 ActiveStore Dhcp)
    $env:reason='connect';$env:TUNIDX='9';$env:INTERNAL_IP4_ADDRESS='10.0.0.2';$env:VPNGATEWAY='203.0.113.1';$env:INTERNAL_IP4_DNS='10.0.0.53';$env:CISCO_SPLIT_INC='1';$env:CISCO_SPLIT_INC_0_ADDR='10.0.0.0';$env:CISCO_SPLIT_INC_0_MASKLEN='8';$env:CISCO_SPLIT_EXC='0'
}
function Assert($value,[string]$message){if(-not $value){throw $message}}
$passed=0
try{
    if ($ColdLoadOnly) {
        Assert ($PSVersionTable.PSVersion.Major -eq 5) 'Cold-load regression requires Windows PowerShell 5.1'
        Assert (-not ('XDVPN.RouteAudit' -as [type])) 'Cold-load regression started with an already loaded audit type'
        # A file cannot hold compiler temporary files. Only this child process sees
        # these environment values; no OS ACL or machine environment is changed.
        $env:TEMP=Join-Path $env:ProgramData 'compiler-temp-is-a-file'; $env:TMP=$env:TEMP
        [IO.File]::WriteAllText($env:TEMP,'no temporary compiler directory')
        function Add-Type { throw 'Runtime compilation must not be invoked' }
        $dll=Join-Path $fixture 'XDVPN.RouteAudit.dll'
        [IO.File]::Delete($dll)
        Reset
        Rejects { & $script -Mode Hook -Session $session } 'route.audit-load'
        $loadFailure=Get-Content -LiteralPath (Join-Path $env:ProgramData ('XDVPN\logs\network-'+$session.ToString('D')+'.jsonl')) -Tail 1 | ConvertFrom-Json
        Assert ($loadFailure.code -eq 'route.audit-load' -and $loadFailure.detail.errorType -and $loadFailure.detail.hresult -ne 0 -and $loadFailure.detail.line -gt 0) 'Audit load failure did not retain its fixed code and safe exception details'
        & $script -Mode Cleanup -Session $session
        Assert (-not ('XDVPN.RouteAudit' -as [type])) 'Missing DLL triggered a compiler fallback'
        Write-Output 'PASS cold missing audit DLL fails with route.audit-load and no ready marker'
        $invalidFixture=Join-Path $env:ProgramData 'bundle-invalid'
        New-Item $invalidFixture -ItemType Directory | Out-Null
        $script=Join-Path $invalidFixture 'network.ps1'
        Copy-Item -LiteralPath $sourceScript -Destination $script
        $dll=Join-Path $invalidFixture 'XDVPN.RouteAudit.dll'
        [IO.File]::WriteAllText($dll,'not a managed assembly')
        Reset
        Rejects { & $script -Mode Hook -Session $session } 'route.audit-load'
        $loadFailure=Get-Content -LiteralPath (Join-Path $env:ProgramData ('XDVPN\logs\network-'+$session.ToString('D')+'.jsonl')) -Tail 1 | ConvertFrom-Json
        Assert ($loadFailure.code -eq 'route.audit-load' -and $loadFailure.detail.errorType -and $loadFailure.detail.hresult -ne 0 -and $loadFailure.detail.line -gt 0) 'Audit load failure did not retain its fixed code and safe exception details'
        & $script -Mode Cleanup -Session $session
        Assert (-not ('XDVPN.RouteAudit' -as [type])) 'Invalid DLL triggered a compiler fallback'
        Write-Output 'PASS cold invalid audit DLL fails with route.audit-load and no ready marker'
        # .NET Framework caches assembly-load failures by path. The working bundle
        # needs its own cold path after testing an intentionally invalid image.
        $validFixture=Join-Path $env:ProgramData 'bundle-valid'
        New-Item $validFixture -ItemType Directory | Out-Null
        $script=Join-Path $validFixture 'network.ps1'
        Copy-Item -LiteralPath $sourceScript -Destination $script
        $dll=Join-Path $validFixture 'XDVPN.RouteAudit.dll'
        Copy-Item -LiteralPath $RouteAuditAssembly -Destination $dll
        Reset
        & $script -Mode Hook -Session $session
        Assert ((Ready) -and ('XDVPN.RouteAudit' -as [type])) 'Cold DLL load failed or did not validate network policy'
        & $script -Mode Cleanup -Session $session
        Assert ($routes.Count -eq 1 -and $addresses.Count -eq 0) 'Cold-load regression left mocked network state'
        Write-Output 'PASS cold PowerShell 5.1 hook loads packaged DLL with packaged .NET facade CWD, compiler temp unavailable and Add-Type blocked'
        return
    }
    $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -RouteAuditAssembly $RouteAuditAssembly -FacadeAssembly $FacadeAssembly -ColdLoadOnly
    Assert ($LASTEXITCODE -eq 0) 'Cold PowerShell 5.1 DLL-loading regression failed'
    $passed+=3
    Reset;& $script -Mode Hook -Session $session
    Assert ($routes.Count -eq 3 -and $addresses.Count -eq 1 -and $dns.Count -eq 1) 'Initial configuration missing'
    & $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 1 -and $addresses.Count -eq 0 -and $dns.Count -eq 0) 'Cleanup changed physical default or left VPN state'
    $passed++;Write-Output 'PASS connect / cleanup preserves physical default'
    Reset;[void](New-NetRoute '203.0.113.1/32' 3 '192.0.2.1' 9 ActiveStore NetMgmt)
    & $script -Mode Hook -Session $session;& $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 2) 'Pre-existing route was removed'
    $passed++;Write-Output 'PASS existing routes are never claimed'
    Reset;& $script -Mode Hook -Session $session
    $routes[0].NextHop='192.0.2.254';$env:reason='attempt-reconnect'; & $script -Mode Hook -Session $session
    $bypass=@($routes|Where-Object DestinationPrefix -eq '203.0.113.1/32')
    Assert ($bypass.Count -eq 1 -and $bypass[0].NextHop -eq '192.0.2.254') 'Stale gateway after switch'
    & $script -Mode Cleanup -Session $session;$passed++;Write-Output 'PASS reconnect replaces owned server gateway route'
    Reset;& $script -Mode Hook -Session $session;$tunnel.InterfaceGuid=[Guid]::NewGuid();$rejected=$false
    try{& $script -Mode Cleanup -Session $session}catch{$rejected=$true}
    Assert ($rejected -and $addresses.Count -eq 1) 'Reused interface was modified'
    $passed++;Write-Output 'PASS reused interface identity blocks cleanup'
    Reset;& $script -Mode Hook -Session $session;$global:dns=@('10.9.9.9');$rejected=$false
    try{& $script -Mode Cleanup -Session $session}catch{$rejected=$true}
    Assert ($rejected -and $dns[0] -eq '10.9.9.9') 'Foreign DNS was overwritten'
    $passed++;Write-Output 'PASS changed DNS ownership blocks cleanup'
    Reset;$global:failRoute=$true;$rejected=$false
    try{& $script -Mode Hook -Session $session}catch{$rejected=$true}
    Assert $rejected 'Injected route failure should fail';$global:failRoute=$false;& $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 1 -and $addresses.Count -eq 0 -and $dns.Count -eq 0) 'Partial configuration not recovered'
    $passed++;Write-Output 'PASS durable intent recovers partial configuration'
    Reset;$env:INTERNAL_IP4_DNS='10.0.0.53; calc.exe';$rejected=$false
    try{& $script -Mode Hook -Session $session}catch{$rejected=$true}
    Assert ($rejected -and $routes.Count -eq 1 -and $addresses.Count -eq 0) 'Invalid server field mutated network'
    & $script -Mode Cleanup -Session $session;$passed++;Write-Output 'PASS server fields validated before mutation'
    Reset;$env:reason='pre-init';& $script -Mode Hook -Session $session;& $script -Mode Cleanup -Session $session;& $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 1) 'Empty cleanup changed network';$passed++;Write-Output 'PASS repeated cleanup is idempotent'

    Reset; $env:CISCO_SPLIT_INC_0_ADDR='0.0.0.0'; $env:CISCO_SPLIT_INC_0_MASKLEN='0'
    [void](New-NetRoute '0.0.0.0/1' 20 '10.237.0.1' 34 ActiveStore NetMgmt)
    [void](New-NetRoute '128.0.0.0/1' 20 '10.237.0.1' 34 ActiveStore NetMgmt)
    [void](New-NetRoute '192.0.2.0/24' 3 '0.0.0.0' 256 ActiveStore Local)
    & $script -Mode Hook -Session $session
    Assert ((Ready) -and (Selected '39.106.15.98').InterfaceIndex -eq 9 -and (Selected '192.0.2.25').InterfaceIndex -eq 3) 'Explicit full tunnel did not use /1 pair or broke local LAN'
    & $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 4) 'Cleanup removed another VPN routes'
    $passed++; Write-Output 'PASS explicit /0 becomes /1 pair, preserves physical LAN and foreign routes'

    Reset; [void](New-NetRoute '10.20.0.0/16' 20 '10.237.0.1' 34 ActiveStore NetMgmt)
    Rejects { & $script -Mode Hook -Session $session } 'route.policy-conflict'
    & $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 2) 'Conflicting foreign route was removed'
    $passed++; Write-Output 'PASS more-specific competing VPN route prevents false ready'

    Reset; $env:CISCO_SPLIT_INC_0_ADDR='203.0.113.1'; $env:CISCO_SPLIT_INC_0_MASKLEN='32'
    Rejects { & $script -Mode Hook -Session $session } 'route.policy-conflict'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS server host route loop is rejected'

    Reset; $env:CISCO_SPLIT_EXC='1'; $env:CISCO_SPLIT_EXC_0_ADDR='10.20.0.0'; $env:CISCO_SPLIT_EXC_0_MASKLEN='16'
    & $script -Mode Hook -Session $session
    Assert ((Ready) -and (Selected '10.20.1.1').InterfaceIndex -eq 3) 'Explicit exclusion was not respected'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS more-specific exclusion stays physical'

    Reset; $env:CISCO_SPLIT_EXC='1'; $env:CISCO_SPLIT_EXC_0_ADDR='10.0.0.0'; $env:CISCO_SPLIT_EXC_0_MASKLEN='8'
    Rejects { & $script -Mode Hook -Session $session } 'route.policy-conflict'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS equal-prefix exclusion conflict refuses ready instead of ignoring exclusion'

    Reset; $env:INTERNAL_IP4_DNS='172.24.4.79'
    & $script -Mode Hook -Session $session
    Assert ((Ready) -and (Selected '172.24.4.79').InterfaceIndex -eq 9 -and @($routes | Where-Object DestinationPrefix -eq '172.24.4.79/32').Count -eq 1) 'VPN DNS outside split lacks tunnel route'
    & $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 1) 'DNS host route was not cleaned'
    $passed++; Write-Output 'PASS DNS outside includes gets an owned tunnel /32 route'

    Reset; $env:INTERNAL_IP4_DNS='172.24.4.79'; $env:CISCO_SPLIT_EXC='1'; $env:CISCO_SPLIT_EXC_0_ADDR='172.24.0.0'; $env:CISCO_SPLIT_EXC_0_MASKLEN='16'
    & $script -Mode Hook -Session $session
    Assert ((Ready) -and (Selected '172.24.4.79').InterfaceIndex -eq 3 -and @($routes | Where-Object DestinationPrefix -eq '172.24.4.79/32').Count -eq 0) 'DNS host route overrode explicit exclusion'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS DNS explicit exclusion wins over automatic DNS host route'

    Reset; [void](New-NetRoute '10.0.0.53/32' 20 '10.237.0.1' 2 ActiveStore NetMgmt)
    Rejects { & $script -Mode Hook -Session $session } 'route.policy-conflict'
    & $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 2) 'Foreign DNS route removed'
    $passed++; Write-Output 'PASS DNS traffic captured by another interface refuses ready'

    Reset; & $script -Mode Hook -Session $session
    $lost=@($routes | Where-Object { $_.InterfaceIndex -eq 9 })[0]; [void]$routes.Remove($lost)
    $env:reason='reconnect'; & $script -Mode Hook -Session $session
    Assert ((Ready) -and (Selected '10.1.2.3').InterfaceIndex -eq 9) 'Reconnect failed to restore missing owned tunnel route'
    & $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 1) 'Reconnect duplicated route journal'
    $passed++; Write-Output 'PASS reconnect restores missing owned route and cleanup remains exact'

    Reset; & $script -Mode Hook -Session $session; $global:dns=@('10.9.9.9'); $env:reason='reconnect'
    Rejects { & $script -Mode Hook -Session $session } 'dns.configuration'
    Assert ($dns[0] -eq '10.9.9.9') 'Reconnect silently overwrote foreign DNS'
    $passed++; Write-Output 'PASS reconnect rejects changed DNS without overwriting it'

    Reset; $global:addressState='Duplicate'
    Rejects { & $script -Mode Hook -Session $session } 'address.unusable'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS duplicate address cannot report ready'

    Reset; $global:addressState='Tentative'; $global:dadReadyAfter=3
    & $script -Mode Hook -Session $session
    Assert ((Ready) -and $global:dadWait -eq 3) 'Address was published before preferred'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS tentative address waits until preferred'

    Reset; $global:addressState='Tentative'
    Rejects { & $script -Mode Hook -Session $session } 'address.tentative-timeout'
    Assert ($global:dadWait -eq 30) 'Address wait is not bounded'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS address wait times out instead of publishing unusable address'

    Reset; & $script -Mode Hook -Session $session
    $beforeRoutes=$routes | ConvertTo-Json -Compress; $beforeAddresses=$addresses | ConvertTo-Json -Compress
    & $script -Mode Verify -Session $session
    Assert ((Ready) -and ($routes | ConvertTo-Json -Compress) -eq $beforeRoutes -and ($addresses | ConvertTo-Json -Compress) -eq $beforeAddresses -and $dns[0] -eq '10.0.0.53') 'Verify changed live network configuration'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS healthy Verify only reads network configuration'

    Reset; & $script -Mode Hook -Session $session
    [void]$routes.Remove(@($routes | Where-Object InterfaceIndex -eq 9)[0])
    Rejects { & $script -Mode Verify -Session $session } 'route.owned-missing'
    Assert (@($routes | Where-Object InterfaceIndex -eq 9).Count -eq 0) 'Verify unexpectedly recreated a route'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS Verify revokes readiness for missing route without repairing network'

    Reset; & $script -Mode Hook -Session $session; $global:mtu=1200
    Rejects { & $script -Mode Verify -Session $session } 'interface.configuration'
    Assert ($global:mtu -eq 1200) 'Verify changed MTU'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS Verify detects MTU drift without mutation'

    Reset; & $script -Mode Hook -Session $session; $global:kernelWrong=$true
    Rejects { & $script -Mode Verify -Session $session } 'route.selection'
    & $script -Mode Cleanup -Session $session; $passed++; Write-Output 'PASS kernel-selected route must agree with route-table policy'

    Reset; & $script -Mode Hook -Session $session; $tunnel.InterfaceGuid=[Guid]::NewGuid(); $env:reason='reconnect'
    $before=$routes | ConvertTo-Json -Compress
    Rejects { & $script -Mode Hook -Session $session } 'interface.identity'
    Assert (($routes | ConvertTo-Json -Compress) -eq $before) 'Reconnect modified reused interface before identity validation'
    $passed++; Write-Output 'PASS reconnect validates interface identity before any route mutation'

    Reset; $env:CISCO_DEF_DOMAIN='corp.example'; & $script -Mode Hook -Session $session
    Assert ($global:domain -eq 'corp.example') 'DNS suffix was not set'
    $global:domain='changed.example'; Rejects { & $script -Mode Verify -Session $session } 'dns.suffix'
    $passed++; Write-Output 'PASS DNS suffix drift is reported separately from namespace policy'

    Reset; & $script -Mode Hook -Session $session
    $journal=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D')+'\network.json')
    $oldJournal=Get-Content $journal -Raw | ConvertFrom-Json; $oldJournal.SchemaVersion=0; $oldJournal | ConvertTo-Json -Depth 8 | Set-Content $journal
    Rejects { & $script -Mode Verify -Session $session } 'journal.version'
    & $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 1 -and $addresses.Count -eq 0) 'Legacy journal no longer cleanable'
    $passed++; Write-Output 'PASS old journal is cleanable but cannot report current verification'

    Reset; $env:INTERNAL_IP4_MTU='invalid-secret-mtu'
    Rejects { & $script -Mode Hook -Session $session } 'input.mtu'
    Assert ($routes.Count -eq 1 -and $addresses.Count -eq 0) 'MTU validation happened after mutation'
    $log=Join-Path $env:ProgramData ('XDVPN\logs\network-'+$session.ToString('D')+'.jsonl')
    $content=Get-Content $log -Raw
    Assert ($content -notmatch 'invalid-secret-mtu' -and $content -match 'input.mtu') 'Network log included raw rejected input'
    & $script -Mode Cleanup -Session $session
    Assert (Test-Path $log) 'Cleanup deleted diagnostic evidence'
    $passed++; Write-Output 'PASS bounded diagnostic log retains safe failures after cleanup'

    Reset; $env:CISCO_SPLIT_INC='256'
    for($i=0;$i -lt 256;$i++) {
        [Environment]::SetEnvironmentVariable(('CISCO_SPLIT_INC_'+$i+'_ADDR'),('10.'+$i+'.0.0'))
        [Environment]::SetEnvironmentVariable(('CISCO_SPLIT_INC_'+$i+'_MASKLEN'),'16')
    }
    $watch=[Diagnostics.Stopwatch]::StartNew(); & $script -Mode Hook -Session $session; $watch.Stop()
    Assert ((Ready) -and $watch.Elapsed.TotalSeconds -lt 25) 'Maximum supported route table exceeded hook budget'
    & $script -Mode Cleanup -Session $session
    $passed++; Write-Output ('PASS 256-route policy verifies within hook budget ('+[Math]::Round($watch.Elapsed.TotalSeconds,2)+'s)')


    Reset; [void](New-NetRoute '10.20.0.0/16' 20 '10.237.0.1' 0 ActiveStore NetMgmt); $global:disconnected=@(20)
    & $script -Mode Hook -Session $session
    Assert ((Ready) -and (Selected '10.20.1.2').InterfaceIndex -eq 9) 'Disconnected interface route caused false conflict'
    & $script -Mode Cleanup -Session $session
    Assert ($routes.Count -eq 2) 'Disconnected foreign route was removed'
    $passed++; Write-Output 'PASS disconnected spare VPN route does not cause false conflict'

    Reset; $env:CISCO_SPLIT_INC='0'
    $global:otherPhysical=[pscustomobject]@{ifIndex=31;Name='Ethernet';InterfaceGuid=[Guid]::NewGuid();Status='Up'}
    [void](New-NetRoute '192.168.88.0/24' 31 '0.0.0.0' 256 ActiveStore Local)
    & $script -Mode Hook -Session $session
    Assert ((Ready) -and (Selected '192.168.88.5').InterfaceIndex -eq 31) 'Full tunnel rejected another directly attached physical LAN'
    & $script -Mode Cleanup -Session $session
    $passed++; Write-Output 'PASS full tunnel preserves directly attached LANs on multiple physical adapters'

    Reset; & $script -Mode Hook -Session $session; $physical.InterfaceGuid=[Guid]::NewGuid()
    Rejects { & $script -Mode Verify -Session $session } 'physical.identity'
    $passed++; Write-Output 'PASS reused physical interface index cannot satisfy bypass verification'

    Reset; & $script -Mode Hook -Session $session
    $lockFile=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D')+'\lock')
    $global:heldLock=[IO.File]::Open($lockFile,'OpenOrCreate','ReadWrite','None'); $global:lockReleaseAfter=3
    & $script -Mode Verify -Session $session
    Assert ((Ready) -and $global:dadWait -eq 3 -and -not $global:heldLock) 'Verify did not wait for the real session file lock'
    & $script -Mode Cleanup -Session $session
    $passed++; Write-Output 'PASS Verify retries real FileStream sharing lock until hook releases it'

    Reset; & $script -Mode Hook -Session $session
    $lockFile=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D')+'\lock')
    $global:heldLock=[IO.File]::Open($lockFile,'OpenOrCreate','ReadWrite','None')
    $before=$routes | ConvertTo-Json -Compress
    & $script -Mode Verify -Session $session
    Assert ($LASTEXITCODE -eq 75 -and (Ready) -and $global:dadWait -eq 50 -and ($routes | ConvertTo-Json -Compress) -eq $before) 'Busy Verify changed readiness or lacked distinct bounded exit status'
    $global:heldLock.Dispose(); $global:heldLock=$null
    & $script -Mode Cleanup -Session $session
    $passed++; Write-Output 'PASS busy Verify returns 75, preserves readiness and does not mutate routes'

    Reset; & $script -Mode Hook -Session $session
    $logDirectory=Join-Path $env:ProgramData 'XDVPN\logs'
    for($i=0;$i -lt 40;$i++) { $entry=Join-Path $logDirectory ('network-'+[Guid]::NewGuid().ToString('D')+'.jsonl'); [IO.File]::WriteAllText($entry,'{}'); (Get-Item $entry).LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-1) }
    $log=Join-Path $logDirectory ('network-'+$session.ToString('D')+'.jsonl')
    [IO.File]::WriteAllText($log,('x'*100000))
    & $script -Mode Verify -Session $session
    Assert (@(Get-ChildItem $logDirectory -Filter 'network-*.jsonl').Count -le 32 -and (Get-Item $log).Length -lt 131072) 'Diagnostic retention is not bounded'
    & $script -Mode Cleanup -Session $session
    $passed++; Write-Output 'PASS network diagnostics bound per-file size and retained session count'


    Reset
    $orphan=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D'))
    Remove-Item -LiteralPath (Join-Path $orphan 'owner.json')
    & $script -Mode Cleanup -Session $session; & $script -Mode Cleanup -Session $session
    Assert (-not (Test-Path -LiteralPath $orphan) -and $routes.Count -eq 1 -and $addresses.Count -eq 0) 'Empty pre-owner session survived cleanup or changed network'
    $passed++; Write-Output 'PASS ownerless empty session is removed and repeated cleanup is idempotent'

    Reset
    $orphan=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D'))
    Remove-Item -LiteralPath (Join-Path $orphan 'owner.json')
    [IO.File]::WriteAllText((Join-Path $orphan 'lock'),'')
    & $script -Mode Cleanup -Session $session
    Assert (-not (Test-Path -LiteralPath $orphan) -and $routes.Count -eq 1) 'Unused empty lock prevented safe orphan removal'
    $passed++; Write-Output 'PASS ownerless session with only an unused zero-byte lock is removed'

    foreach($record in @('network.json','configured','network.json.new','owner.pid','unknown.txt')) {
        Reset
        $orphan=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D'))
        Remove-Item -LiteralPath (Join-Path $orphan 'owner.json')
        $recordPath=Join-Path $orphan $record
        [IO.File]::WriteAllText($recordPath,'unowned-network-record')
        $rejected=$false
        try { & $script -Mode Cleanup -Session $session } catch { if($_.Exception.Message -notmatch 'session.unowned-content'){throw}; $rejected=$true }
        Assert ($rejected -and (Test-Path -LiteralPath $orphan) -and [IO.File]::ReadAllText($recordPath) -eq 'unowned-network-record' -and $routes.Count -eq 1 -and $addresses.Count -eq 0) ('Unknown ownerless record was ignored or removed: '+$record)
        $passed++; Write-Output ('PASS ownerless '+$record+' is preserved with explicit cleanup failure')
    }

    Reset
    $orphan=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D'))
    Remove-Item -LiteralPath (Join-Path $orphan 'owner.json')
    $lockFile=Join-Path $orphan 'lock'; [IO.File]::WriteAllText($lockFile,'')
    $global:heldLock=[IO.File]::Open($lockFile,'Open','ReadWrite','None')
    Rejects { & $script -Mode Cleanup -Session $session } 'session.busy'
    Assert ((Test-Path -LiteralPath $lockFile) -and $routes.Count -eq 1) 'Locked orphan was removed'
    $global:heldLock.Dispose(); $global:heldLock=$null
    & $script -Mode Cleanup -Session $session
    Assert (-not (Test-Path -LiteralPath $orphan)) 'Unlocked empty orphan did not recover'
    $passed++; Write-Output 'PASS ownerless lock in use is preserved and removable after release'

    Reset
    $orphan=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D'))
    Remove-Item -LiteralPath (Join-Path $orphan 'owner.json')
    [IO.File]::WriteAllText((Join-Path $orphan 'lock'),'unknown')
    Rejects { & $script -Mode Cleanup -Session $session } 'session.unowned-content'
    Assert ([IO.File]::ReadAllText((Join-Path $orphan 'lock')) -eq 'unknown') 'Nonempty lock metadata was discarded'
    $passed++; Write-Output 'PASS nonempty unowned lock is treated as unknown state'

    Reset
    $orphan=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D'))
    Remove-Item -LiteralPath (Join-Path $orphan 'owner.json')
    New-Item -Path (Join-Path $orphan 'lock') -ItemType Directory | Out-Null
    Rejects { & $script -Mode Cleanup -Session $session } 'session.unowned-content'
    Assert (Test-Path -LiteralPath (Join-Path $orphan 'lock') -PathType Container) 'Unowned lock directory was recursively removed'
    $passed++; Write-Output 'PASS unowned subdirectory is never recursively removed'

    Reset
    $orphan=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D'))
    Remove-Item -LiteralPath (Join-Path $orphan 'owner.json')
    Rejects { & $script -Mode Hook -Session $session } 'session.missing'
    Rejects { & $script -Mode Verify -Session $session } 'session.missing'
    Assert ((Test-Path -LiteralPath $orphan) -and $routes.Count -eq 1) 'Hook or Verify removed ownerless directory'
    & $script -Mode Cleanup -Session $session
    $passed++; Write-Output 'PASS empty orphan deletion is exclusive to Cleanup mode'

    Reset
    $global:arrivalRoot=Join-Path $env:ProgramData ('XDVPN\sessions\'+$session.ToString('D'))
    $global:arrivalOwner=[IO.File]::ReadAllText((Join-Path $global:arrivalRoot 'owner.json'))
    Remove-Item -LiteralPath (Join-Path $global:arrivalRoot 'owner.json')
    $global:arriveAfterListing=$true
    function Get-ChildItem {
        [CmdletBinding()]param([Parameter(Position=0)]$Path,$LiteralPath,$Filter,[switch]$Force,[switch]$File)
        $items=@(Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters)
        if($global:arriveAfterListing -and $LiteralPath -eq $global:arrivalRoot) {
            $global:arriveAfterListing=$false
            [IO.File]::WriteAllText((Join-Path $global:arrivalRoot 'owner.json'),$global:arrivalOwner)
        }
        $items
    }
    try { Rejects { & $script -Mode Cleanup -Session $session } 'session.empty-cleanup' }
    finally { Remove-Item Function:\Get-ChildItem }
    Assert ((Test-Path -LiteralPath (Join-Path $global:arrivalRoot 'owner.json')) -and $routes.Count -eq 1) 'Concurrent owner publication was erased'
    & $script -Mode Cleanup -Session $session
    $passed++; Write-Output 'PASS concurrent owner publication prevents nonrecursive orphan deletion'

    Write-Output "$passed network tests passed"
}finally{ $env:TEMP=$oldTemp; $env:TMP=$oldTmp; if($ColdLoadOnly){Remove-Item Function:\Add-Type -ErrorAction SilentlyContinue}; if($global:heldLock){$global:heldLock.Dispose()}; $env:ProgramData=$oldData; @(Get-ChildItem Env: | Where-Object Name -match $environmentPattern) | ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name,$null) }; foreach($entry in $originalEnvironment.GetEnumerator()){ [Environment]::SetEnvironmentVariable($entry.Key,$entry.Value) } }
