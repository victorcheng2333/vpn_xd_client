param([string]$Configuration='Release', [switch]$SkipEngine, [string]$OutputRoot='')
$ErrorActionPreference='Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
if(-not $OutputRoot){$OutputRoot=Join-Path $repo 'dist'}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(-not $OutputRoot.StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Output must stay inside this workspace'}
$routeAudit=Join-Path $repo '.build/windows-route-audit/XDVPN.RouteAudit.dll'
& "$PSScriptRoot/build-route-audit.ps1" -Output $routeAudit
function Run-Dotnet([string[]]$Arguments) { & dotnet @Arguments; if ($LASTEXITCODE) { throw "dotnet failed: $LASTEXITCODE" } }
Run-Dotnet @('run','--project',"$repo/Apps/Windows/XDVPN.Tests",'-c',$Configuration)
Run-Dotnet @('run','--project',"$repo/Apps/Windows/XDVPN.Service.Tests",'-c',$Configuration)
& "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot/test-network.ps1" -RouteAuditAssembly $routeAudit
if($LASTEXITCODE){throw 'Network regression tests failed'}
& "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot/test-diagnose.ps1" -HelperAssembly $routeAudit
if($LASTEXITCODE){throw 'Diagnostic regression tests failed'}
& "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot/test-install.ps1"
if($LASTEXITCODE){throw 'Installer regression tests failed'}
& "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$repo/scripts/windows/test-setup.ps1"
if($LASTEXITCODE){throw 'Setup regression tests failed'}
Run-Dotnet @('run','--project',"$repo/Apps/Windows/XDVPN.UI.Tests",'-c',$Configuration,'--',"$repo/.build/windows-ui-review")
$dist=Join-Path $OutputRoot 'windows-x64'
if(-not [IO.Path]::GetFullPath($dist).StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid output directory'}
if(Test-Path $dist){Remove-Item $dist -Recurse -Force}
New-Item $dist -ItemType Directory | Out-Null
Run-Dotnet @('publish',"$repo/Apps/Windows/XDVPN.Service",'-c',$Configuration,'-r','win-x64','--self-contained','true','-o',$dist)
Run-Dotnet @('publish',"$repo/Apps/Windows/XDVPN.App",'-c',$Configuration,'-r','win-x64','--self-contained','true','-o',$dist)
Copy-Item "$PSScriptRoot/network.ps1" $dist
Copy-Item -LiteralPath $routeAudit -Destination $dist
Copy-Item "$PSScriptRoot/diagnose-live.ps1" $dist
Copy-Item "$PSScriptRoot/install.ps1" $dist
Copy-Item "$PSScriptRoot/install-core.ps1" $dist
Copy-Item "$PSScriptRoot/uninstall.ps1" $dist
Copy-Item "$PSScriptRoot/Install.cmd" $dist
Copy-Item "$PSScriptRoot/Uninstall.cmd" $dist
Copy-Item "$repo/Apps/Windows/README.md" $dist
Copy-Item "$repo/Apps/Windows/VERIFICATION.md" $dist
Copy-Item "$repo/Apps/Windows/AUDIT-REVIEW.md" $dist
$runtime=Join-Path $repo '.build/windows-engine/runtime'
if(-not $SkipEngine) {
    if(-not(Test-Path "$runtime/openconnect.exe") -or -not(Test-Path "$runtime/wintun.dll")){throw 'Build the native engine with build-engine.sh first.'}
    Copy-Item $runtime "$dist/runtime" -Recurse
    Copy-Item "$repo/.build/windows-engine/licenses" "$dist/licenses" -Recurse
    if((Get-AuthenticodeSignature "$dist/runtime/wintun.dll").Status -ne 'Valid'){throw 'Wintun signature validation failed'}
    & "$dist/runtime/openconnect.exe" --version
    if($LASTEXITCODE){throw 'Native engine failed its version smoke check'}
    Run-Dotnet @('run','--project',"$repo/Apps/Windows/XDVPN.Platform.Tests",'-c',$Configuration,'--','--engine',"$dist/runtime/openconnect.exe")
}
$manifest=@{}
Get-ChildItem $dist -File -Recurse | ForEach-Object { $manifest[$_.FullName.Substring($dist.Length+1)]=(Get-FileHash $_.FullName -Algorithm SHA256).Hash }
$manifest | ConvertTo-Json -Depth 3 | Set-Content "$dist/manifest.json" -Encoding utf8
if(-not $SkipEngine){
    $zip=Join-Path $OutputRoot 'XDVPN-windows-x64-preview.zip'
    Compress-Archive "$dist/*" $zip -Force
    & "$repo/scripts/windows/package-exe.ps1" -Payload $zip -Output (Join-Path $OutputRoot 'XDVPN-Setup-windows-x64-preview.exe')
}
Write-Host "Built: $dist"
