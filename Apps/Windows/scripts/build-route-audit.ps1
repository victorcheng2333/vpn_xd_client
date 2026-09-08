param([string]$Output='')
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
if(-not $Output){$Output=Join-Path $repo '.build/windows-route-audit/XDVPN.RouteAudit.dll'}
$Output=[IO.Path]::GetFullPath($Output)
if(-not $Output.StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Route audit output must stay inside this workspace'}
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$framework=Split-Path $compiler
$sources=@((Join-Path $repo 'Apps/Windows/native/RouteAudit.cs'),(Join-Path $repo 'Apps/Windows/native/DiagnosticTargetProbe.cs'))
New-Item -ItemType Directory -Path (Split-Path $Output) -Force | Out-Null
& $compiler /nologo /noconfig /nostdlib+ /target:library /platform:anycpu /optimize+ /codepage:65001 "/reference:$framework/mscorlib.dll" "/reference:$framework/System.dll" "/reference:$framework/System.Core.dll" "/out:$Output" @sources
if($LASTEXITCODE){throw "Route audit compilation failed: $LASTEXITCODE"}
Write-Host "Built route audit: $Output"
