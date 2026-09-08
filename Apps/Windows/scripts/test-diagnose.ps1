# Offline tests: all networking cmdlets are substitutes; active probes are forbidden.
param(
    [string]$HelperAssembly=(Join-Path $PSScriptRoot '..\..\..\.build\windows-route-audit\XDVPN.RouteAudit.dll'),
    [string]$FacadeAssembly='',
    [switch]$IsolatedWorker,
    [string]$FixtureRoot=''
)
$ErrorActionPreference='Stop'
$sourceDiagnostic=Join-Path $PSScriptRoot 'diagnose-live.ps1'
if(-not(Test-Path -LiteralPath $HelperAssembly -PathType Leaf)){throw 'Build XDVPN.RouteAudit.dll with build-route-audit.ps1 before diagnostic tests.'}
$HelperAssembly=(Resolve-Path -LiteralPath $HelperAssembly).ProviderPath
if(-not $FacadeAssembly) {
    $runtimeRoots=@()
    $dotnetCommand=Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    if($dotnetCommand){$runtimeRoots+=Join-Path (Split-Path $dotnetCommand.Source) 'shared\Microsoft.NETCore.App'}
    $runtimeRoots+=Join-Path $PSScriptRoot '..\..\..\.build\windows-package\dotnet\shared\Microsoft.NETCore.App'
    foreach($runtime in $runtimeRoots){
        $candidate=Get-ChildItem -Path (Join-Path $runtime '*\System.dll') -File -ErrorAction SilentlyContinue|Where-Object {$_.VersionInfo.ProductVersion -match '^10\.'}|Sort-Object FullName -Descending|Select-Object -First 1
        if($candidate){$FacadeAssembly=$candidate.FullName;break}
    }
}
if(-not $FacadeAssembly -or -not(Test-Path -LiteralPath $FacadeAssembly -PathType Leaf)){throw 'Pass the packaged .NET 10 System.dll using -FacadeAssembly.'}
$FacadeAssembly=(Resolve-Path -LiteralPath $FacadeAssembly).ProviderPath
if((Get-Item -LiteralPath $FacadeAssembly).VersionInfo.ProductVersion -notmatch '^10\.'){throw 'Diagnostic cold-load test requires the real .NET 10 System.dll facade.'}
if(-not $IsolatedWorker){
    # Framework LoadFrom pins the helper DLL until process exit. The parent owns
    # cleanup after a fresh Windows PowerShell 5.1 worker exits completely.
    $testRoot=Join-Path ([IO.Path]::GetTempPath()) ('xdvpn-diagnostic-test-'+[Guid]::NewGuid().ToString('N'))
    $process=$null
    try{
        New-Item -Path $testRoot -ItemType Directory|Out-Null
        Copy-Item -LiteralPath $FacadeAssembly -Destination (Join-Path $testRoot 'System.dll')
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory=$testRoot
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -HelperAssembly "'+$HelperAssembly+'" -FacadeAssembly "'+$FacadeAssembly+'" -IsolatedWorker -FixtureRoot "'+$testRoot+'"'
        $process=[Diagnostics.Process]::Start($start)
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(30000)){$process.Kill();$process.WaitForExit();throw 'Isolated diagnostic tests exceeded 30 seconds'}
        $output=$stdout.GetAwaiter().GetResult();$errors=$stderr.GetAwaiter().GetResult()
        if($output){Write-Output $output.TrimEnd()};if($errors){Write-Output $errors.TrimEnd()}
        if($process.ExitCode -ne 0){throw ('Isolated diagnostic tests failed: '+$process.ExitCode)}
    }finally{
        if($process){$process.Dispose()}
        $resolved=[IO.Path]::GetFullPath($testRoot)
        if((Split-Path $resolved) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and (Split-Path $resolved -Leaf) -match '^xdvpn-diagnostic-test-[0-9a-f]{32}$'){Remove-Item -LiteralPath $resolved -Recurse -Force}
    }
    return
}
if(-not $FixtureRoot -or [IO.Path]::GetFullPath($FixtureRoot) -ne [Environment]::CurrentDirectory){throw 'Diagnostic worker requires its isolated process working directory.'}
if(-not(Test-Path -LiteralPath (Join-Path $FixtureRoot 'System.dll') -PathType Leaf)){throw 'Cold environment lacks packaged System.dll.'}
$previousData=$env:ProgramData
$fixture=$FixtureRoot
$env:ProgramData=$fixture
$bundle=Join-Path $fixture 'bundle'
New-Item -Path $bundle -ItemType Directory|Out-Null
$diagnostic=Join-Path $bundle 'diagnose-live.ps1'
Copy-Item -LiteralPath $sourceDiagnostic -Destination $diagnostic
Copy-Item -LiteralPath $HelperAssembly -Destination (Join-Path $bundle 'XDVPN.RouteAudit.dll')
function Add-Type {throw 'Runtime CodeDOM compilation is forbidden in diagnostic tests.'}
$global:DiagnosticProbeCalled=$false
$global:DiagnosticStatsCount=0
$global:DiagnosticAdapter=[pscustomobject]@{Name='';ifIndex=91;InterfaceGuid=[Guid]::NewGuid();Status='Up';InterfaceDescription='Test Wintun'}
function Get-Service { [CmdletBinding()]param($Name) [pscustomobject]@{Name='XDVPN';Status='Running';StartType='Automatic'} }
function Get-NetAdapter { [CmdletBinding()]param([switch]$IncludeHidden) $global:DiagnosticAdapter }
function Get-NetAdapterStatistics { [CmdletBinding()]param($Name) $global:DiagnosticStatsCount++; [pscustomobject]@{Name=$Name;ReceivedBytes=100*$global:DiagnosticStatsCount;SentBytes=200*$global:DiagnosticStatsCount} }
function Get-NetIPAddress { [CmdletBinding()]param($InterfaceIndex) [pscustomobject]@{IPAddress='10.0.0.2';AddressFamily='IPv4';PrefixLength=32;AddressState='Preferred'} }
function Get-NetIPInterface { [CmdletBinding()]param($InterfaceIndex) [pscustomobject]@{AddressFamily='IPv4';InterfaceMetric=3;NlMtu=1400;ConnectionState='Connected'} }
function Get-NetRoute { [CmdletBinding()]param($PolicyStore) [pscustomobject]@{AddressFamily='IPv4';InterfaceIndex=91;DestinationPrefix='0.0.0.0/1';NextHop='0.0.0.0';RouteMetric=3;InterfaceMetric=3;Protocol='NetMgmt'} }
function Get-DnsClientServerAddress { [CmdletBinding()]param() [pscustomobject]@{InterfaceAlias=$global:DiagnosticAdapter.Name;InterfaceIndex=91;AddressFamily='IPv4';ServerAddresses=@('10.0.0.53')} }
function Get-DnsClientNrptPolicy { [CmdletBinding()]param([switch]$Effective) throw 'NRPT access denied in fixture' }
function Get-NetAdapterBinding { [CmdletBinding()]param($Name) [pscustomobject]@{DisplayName='IPv4';ComponentID='ms_tcpip';Enabled=$true} }
function Start-Sleep { param($Milliseconds) }
function Resolve-DnsName { $global:DiagnosticProbeCalled=$true;throw 'Unexpected active DNS query' }
function Find-NetRoute { $global:DiagnosticProbeCalled=$true;throw 'Unexpected target route query' }
function Assert($Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function New-Fixture([Guid]$Id) {
    $directory=Join-Path $fixture ('XDVPN\sessions\'+$Id.ToString('D'))
    New-Item -Path $directory -ItemType Directory -Force | Out-Null
    $name='XDVPN-'+$Id.ToString('N').Substring(0,12)
    @{session=$Id.ToString('D');adapter=$name}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $directory 'owner.json')
    @{InterfaceGuid=$global:DiagnosticAdapter.InterfaceGuid.ToString();InterfaceIndex=91;Address='10.0.0.2';Dns=@('10.0.0.53');Routes=@();Gateway='192.0.2.1'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $directory 'network.json')
    $Id.ToString('D')|Set-Content -LiteralPath (Join-Path $directory 'configured')
    return $name
}
$passed=0
try {
    $id=[Guid]::NewGuid();$global:DiagnosticAdapter.Name=New-Fixture $id
    $logDirectory=Join-Path $fixture 'XDVPN\logs';New-Item $logDirectory -ItemType Directory -Force|Out-Null
    @{Time='2026-01-01T00:00:00Z';Event='attempt.started';Message='Fixture';Attempt=$id.ToString('D')}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $logDirectory 'activity.jsonl')
    $networkLog=Join-Path $logDirectory ('network-'+$id.ToString('D')+'.jsonl')
    @{time='2026-01-01T00:00:00Z';session=$id.ToString('D');phase='verify';outcome='ok';code='network.verified';detail=@{address='10.0.0.2';mtu=1400;dns=@('10.0.0.53')}}|ConvertTo-Json -Depth 4 -Compress|Set-Content -LiteralPath $networkLog
    Add-Content -LiteralPath $networkLog -Value 'not valid JSON'
    @{time='2026-01-01T00:00:00Z';session=[Guid]::NewGuid().ToString('D');phase='verify';outcome='ok';code='network.verified';detail=$null}|ConvertTo-Json -Compress|Add-Content -LiteralPath $networkLog
    $report=& $diagnostic -SampleSeconds 1 | ConvertFrom-Json
    Assert ($report.Session.Id -eq $id.ToString('D') -and $report.Session.Configured) 'One session was not selected'
    Assert ($report.Counters.ReceivedBytesDelta -eq 100 -and $report.Counters.SentBytesDelta -eq 200) 'Counter window wrong'
    Assert ($null -eq $report.TargetProbe -and -not $global:DiagnosticProbeCalled) 'Default collection performed an active probe'
    Assert ($report.Errors -match 'NRPT access denied') 'Policy access failure was hidden'
    Assert ($report.ActivityEvents.Count -eq 1) 'Structured activity was not collected'
    $passed++;Write-Output 'PASS default local-only evidence, counters and explicit policy errors'
    Assert ($report.NetworkLogs.Count -eq 1 -and $report.NetworkLogs[0].Session -eq $id.ToString('D')) 'Selected network log missing'
    Assert ($report.NetworkLogs[0].ReadStatus -eq 'partial' -and @($report.NetworkLogs[0].Records|Where-Object ReadStatus -eq 'unknown').Count -eq 2) 'Malformed/mismatched records were not marked unknown'
    Assert ($report.NetworkLogs[0].Records[0].Detail.mtu -eq 1400) 'Structured diagnostic details were lost'
    $passed++;Write-Output 'PASS selected network log and unknown malformed records'
    $second=[Guid]::NewGuid();[void](New-Fixture $second)

    $report=& $diagnostic -SampleSeconds 1 | ConvertFrom-Json
    Assert ($null -eq $report.Session -and $report.SessionCandidates.Count -eq 2) 'Ambiguous sessions were selected silently'
    $passed++;Write-Output 'PASS multiple sessions require explicit selection'
    $report=& $diagnostic -Session $id -SampleSeconds 1 | ConvertFrom-Json
    Assert ($report.Session.Id -eq $id.ToString('D') -and $report.Adapter.Name -eq $global:DiagnosticAdapter.Name) 'Explicit session selection failed'
    $passed++;Write-Output 'PASS explicit session selection'
    $missingBundle=Join-Path $fixture 'without-helper';New-Item -Path $missingBundle -ItemType Directory|Out-Null
    $missingDiagnostic=Join-Path $missingBundle 'diagnose-live.ps1';Copy-Item -LiteralPath $sourceDiagnostic -Destination $missingDiagnostic
    $report=& $missingDiagnostic -Session $id -SampleSeconds 1|ConvertFrom-Json
    Assert ($null -eq $report.TargetProbe -and -not $global:DiagnosticProbeCalled) 'Default report required the helper or made a target probe'
    $passed++;Write-Output 'PASS default local-only report works without diagnostic helper'
    $report=& $missingDiagnostic -Session $id -TargetUri https://example.invalid/ -SampleSeconds 1|ConvertFrom-Json
    Assert (($report.Errors -match 'packaged diagnostic helper unavailable') -and -not $global:DiagnosticProbeCalled -and $report.TargetProbe.Tests.Count -eq 0) 'Missing helper did not fail before active DNS or target checks'
    $passed++;Write-Output 'PASS missing packaged helper skips target before DNS and preserves report'
    $global:DiagnosticAdapter.InterfaceGuid=[Guid]::NewGuid();$global:DiagnosticStatsCount=0
    $report=& $diagnostic -Session $id -TargetUri https://example.invalid/ -SampleSeconds 1 | ConvertFrom-Json
    Assert ($null -eq $report.Adapter -and $global:DiagnosticStatsCount -eq 0 -and -not $global:DiagnosticProbeCalled) 'Changed adapter identity was probed'
    $passed++;Write-Output 'PASS adapter identity mismatch skips counters and target probe'
    $sessionsPath=[IO.Path]::GetFullPath((Join-Path $fixture 'XDVPN\sessions'))
    if(-not $sessionsPath.StartsWith([IO.Path]::GetFullPath($fixture)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path'}
    Remove-Item -LiteralPath $sessionsPath -Recurse -Force
    for($i=0;$i -lt 4;$i++) {
        $oldId=[Guid]::NewGuid();$oldLog=Join-Path $logDirectory ('network-'+$oldId.ToString('D')+'.jsonl')
        $records=1..70|ForEach-Object {@{time='2026-01-01T00:00:00Z';session=$oldId.ToString('D');phase='verify';outcome='failed';code='route.missing';detail=$null}|ConvertTo-Json -Compress}
        $records|Set-Content -LiteralPath $oldLog
        (Get-Item -LiteralPath $oldLog).LastWriteTimeUtc=[DateTime]::UtcNow.AddMinutes($i+1)
    }
    $report=& $diagnostic -SampleSeconds 1 | ConvertFrom-Json
    Assert ($null -eq $report.Session -and $report.NetworkLogs.Count -eq 3) 'No-session report did not select at most three recent logs'
    Assert (@($report.NetworkLogs|Where-Object {$_.Records.Count -ne 60}).Count -eq 0) 'Retained log record limit was not applied'
    Assert (-not $global:DiagnosticProbeCalled) 'Post-cleanup diagnostics performed an active probe'
    $passed++;Write-Output 'PASS cleaned sessions retain bounded last-three network attempts'
    $report=& $diagnostic -Session $id -SampleSeconds 1 | ConvertFrom-Json
    Assert ($null -eq $report.Session -and $report.NetworkLogs.Count -eq 1 -and $report.NetworkLogs[0].Session -eq $id.ToString('D')) 'Explicit cleaned session did not retain its own evidence'
    $passed++;Write-Output 'PASS explicit cleaned session reads only its retained network log'
    foreach($bad in @('ftp://example.invalid/','https://user:pass@example.invalid/')) {
        $rejected=$false;try{& $diagnostic -TargetUri $bad | Out-Null}catch{$rejected=$true}
        Assert $rejected 'Unsafe target URI was accepted'
    }
    $rejected=$false;try{& $diagnostic -ProbeMtu | Out-Null}catch{$rejected=$true}
    Assert $rejected 'MTU probe without target accepted'
    $passed++;Write-Output 'PASS target validation and explicit MTU opt-in'
    # Run the real packaged loader for the first time in this process. The
    # working directory contains the same .NET 10 System.dll facade as the app.
    Assert (-not ('XDVPN.DiagnosticTargetProbe' -as [type])) 'Cold worker already loaded diagnostic type'
    Assert ((Get-Item -LiteralPath (Join-Path ([Environment]::CurrentDirectory) 'System.dll')).VersionInfo.ProductVersion -match '^10\.') 'Actual .NET 10 facade CWD missing'
    . $diagnostic -SampleSeconds 1 | Out-Null
    $probeType=Initialize-XDVPNDiagnosticProbe
    Assert ($probeType.FullName -eq 'XDVPN.DiagnosticTargetProbe' -and $probeType.Assembly.Location -eq (Join-Path $bundle 'XDVPN.RouteAudit.dll')) 'Probe loaded from the wrong package path'
    Assert (@($probeType.Assembly.GetReferencedAssemblies()|Where-Object {$_.Name -in @('System','mscorlib') -and $_.Version.Major -ne 4}).Count -eq 0) 'Probe was not compiled against Framework 4 references'
    $passed++;Write-Output 'PASS cold fixed-path Framework 4 helper load with actual .NET 10 facade CWD'
    # Invalid input returns before constructing any socket. Calling the compiled
    # method also forces JIT resolution of its Framework IPAddress/TLS types.
    $invalid=[XDVPN.DiagnosticTargetProbe]::Run('192.0.2.1','invalid-source',91,[Uri]'https://diagnostic.invalid/',1)
    Assert ($invalid.Error -eq 'Invalid IPv4 source address' -and -not $invalid.TcpConnected -and -not $global:DiagnosticProbeCalled) 'Cold compiled probe validation failed or touched networking'
    $passed++;Write-Output 'PASS cold probe JIT validates input without creating a socket or network request'
    Write-Output "$passed/$passed passed"
} finally {
    $env:ProgramData=$previousData
    # The parent removes pinned DLL fixtures after this worker exits.
    Remove-Variable DiagnosticProbeCalled,DiagnosticStatsCount,DiagnosticAdapter -Scope Global -ErrorAction SilentlyContinue
}
