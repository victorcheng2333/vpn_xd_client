$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$build = Join-Path $repo '.build/windows-icon'
New-Item $build -ItemType Directory -Force | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $compiler /nologo /target:exe /optimize+ /reference:System.Drawing.dll "/out:$build/IconGenerator.exe" (Join-Path $PSScriptRoot 'IconGenerator.cs')
if ($LASTEXITCODE) { throw 'Icon generator compilation failed' }
& "$build/IconGenerator.exe" (Join-Path $repo 'Apps/Windows/XDVPN.App/Assets')
if ($LASTEXITCODE) { throw 'Icon generation failed' }
