param(
    [string]$Payload = (Join-Path $PSScriptRoot '../../dist/XDVPN-windows-x64-preview.zip'),
    [string]$Output = (Join-Path $PSScriptRoot '../../dist/XDVPN-Setup-windows-x64-preview.exe')
)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$payloadPath = (Resolve-Path -LiteralPath $Payload).Path
$outputPath = [IO.Path]::GetFullPath($Output)
$iconPath = (Resolve-Path (Join-Path $PSScriptRoot '../../Apps/Windows/XDVPN.App/Assets/XDVPN.ico')).Path
New-Item -ItemType Directory -Path (Split-Path $outputPath) -Force | Out-Null
$metadata=& "$PSScriptRoot/version.ps1"
$generated=Join-Path $PSScriptRoot '../../.build/windows-setup-version'
New-Item -ItemType Directory -Path $generated -Force | Out-Null
$assembly=Join-Path $generated 'Version.cs'
('[assembly: System.Reflection.AssemblyVersion("'+$metadata.FileVersion+'")]') | Set-Content $assembly -Encoding utf8
[xml]$manifest=Get-Content (Join-Path $PSScriptRoot 'setup.manifest')
$manifest.assembly.assemblyIdentity.version=$metadata.FileVersion
$manifestPath=Join-Path $generated 'setup.manifest'
$manifest.Save($manifestPath)
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /codepage:65001 "/out:$outputPath" ('/win32manifest:' + $manifestPath) "/win32icon:$iconPath" "/resource:$payloadPath,XDVPN.Payload.zip" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll (Join-Path $PSScriptRoot 'Setup.cs') $assembly
if ($LASTEXITCODE) { throw "Installer compilation failed: $LASTEXITCODE" }
Get-Item -LiteralPath $outputPath | Select-Object FullName, Length
