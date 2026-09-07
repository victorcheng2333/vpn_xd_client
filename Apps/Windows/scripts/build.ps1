param([string]$Configuration='Release', [switch]$SkipEngine)
$ErrorActionPreference='Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
function Run-Dotnet([string[]]$Arguments) { & dotnet @Arguments; if ($LASTEXITCODE) { throw "dotnet failed: $LASTEXITCODE" } }
Run-Dotnet @('run','--project',"$repo/Apps/Windows/XDVPN.Tests",'-c',$Configuration)
& "$PSScriptRoot/test-network.ps1"
$dist=Join-Path $repo 'dist/windows-x64'
if(Test-Path $dist){Remove-Item $dist -Recurse -Force}
New-Item $dist -ItemType Directory | Out-Null
Run-Dotnet @('publish',"$repo/Apps/Windows/XDVPN.Service",'-c',$Configuration,'-r','win-x64','--self-contained','true','-o',$dist)
Run-Dotnet @('publish',"$repo/Apps/Windows/XDVPN.App",'-c',$Configuration,'-r','win-x64','--self-contained','true','-o',$dist)
Copy-Item "$PSScriptRoot/network.ps1" $dist
Copy-Item "$PSScriptRoot/install.ps1" $dist
Copy-Item "$PSScriptRoot/uninstall.ps1" $dist
Copy-Item "$PSScriptRoot/Install.cmd" $dist
Copy-Item "$PSScriptRoot/Uninstall.cmd" $dist
Copy-Item "$repo/Apps/Windows/README.md" $dist
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
if(-not $SkipEngine){Compress-Archive "$dist/*" (Join-Path $repo 'dist/XDVPN-windows-x64-preview.zip') -Force}
Write-Host "Built: $dist"
