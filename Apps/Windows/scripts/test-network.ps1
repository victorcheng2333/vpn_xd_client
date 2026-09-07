# Runs the real network script with in-memory cmdlet substitutes. Never changes OS networking.
$ErrorActionPreference='Stop'
$script=Join-Path $PSScriptRoot 'network.ps1'
$oldData=$env:ProgramData
$env:ProgramData=Join-Path ([IO.Path]::GetTempPath()) ('xdvpn-network-test-'+[Guid]::NewGuid())
New-Item $env:ProgramData -ItemType Directory | Out-Null
$global:routes=[Collections.ArrayList]::new();$global:addresses=[Collections.ArrayList]::new();$global:dns=@();$global:failRoute=$false
function Get-NetAdapter { [CmdletBinding()]param([switch]$IncludeHidden,[switch]$Physical) if($Physical){$global:physical}else{$global:physical;$global:tunnel} }
function Get-NetRoute { [CmdletBinding()]param($AddressFamily,$PolicyStore,$DestinationPrefix) $global:routes | Where-Object { -not $DestinationPrefix -or $_.DestinationPrefix -eq $DestinationPrefix } }
function New-NetRoute { [CmdletBinding()]param($DestinationPrefix,$InterfaceIndex,$NextHop,$RouteMetric,$PolicyStore,$Protocol)
    if($global:failRoute -and $InterfaceIndex -eq 9){throw 'Injected route failure'}
    $r=[pscustomobject]@{DestinationPrefix=$DestinationPrefix;InterfaceIndex=$InterfaceIndex;NextHop=$NextHop;RouteMetric=$RouteMetric;InterfaceMetric=0;Protocol=$Protocol};[void]$global:routes.Add($r);$r
}
function Remove-NetRoute { [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject) process{[void]$global:routes.Remove($InputObject)} }
function Get-NetIPAddress { [CmdletBinding()]param($AddressFamily) $global:addresses.ToArray() }
function New-NetIPAddress { [CmdletBinding()]param($InterfaceIndex,$IPAddress,$PrefixLength,$PolicyStore) $r=[pscustomobject]@{InterfaceIndex=$InterfaceIndex;IPAddress=$IPAddress};[void]$global:addresses.Add($r);$r }
function Remove-NetIPAddress { [CmdletBinding(SupportsShouldProcess)]param([Parameter(ValueFromPipeline)]$InputObject) process{[void]$global:addresses.Remove($InputObject)} }
function Get-DnsClientServerAddress { [CmdletBinding()]param($InterfaceIndex,$AddressFamily) [pscustomobject]@{ServerAddresses=@($global:dns)} }
function Set-DnsClientServerAddress { [CmdletBinding()]param($InterfaceIndex,$ServerAddresses,[switch]$ResetServerAddresses) $global:dns=if($ResetServerAddresses){@()}else{@($ServerAddresses)} }
function Set-DnsClient { [CmdletBinding()]param($InterfaceIndex,$ConnectionSpecificSuffix) }
function Set-NetIPInterface { [CmdletBinding()]param($InterfaceIndex,$AddressFamily,$InterfaceMetric,$NlMtuBytes,$PolicyStore) }
function Reset {
    $global:routes.Clear();$global:addresses.Clear();$global:dns=@();$global:failRoute=$false
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
    Write-Output "$passed/8 network tests passed"
}finally{Remove-Item $env:ProgramData -Recurse -Force;$env:ProgramData=$oldData}
