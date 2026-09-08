# Pure argument/ACL-descriptor tests and temp-directory extraction only; no UAC/service/network.
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$output=Join-Path $repo '.build/windows-setup-tests'
New-Item -Path $output -ItemType Directory -Force|Out-Null
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$testExe=Join-Path $output 'SetupTests.exe'
& $compiler /nologo /target:exe /main:SetupTests /platform:x64 /codepage:65001 "/out:$testExe" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll (Join-Path $PSScriptRoot 'Setup.cs') (Join-Path $PSScriptRoot 'SetupTests.cs')
if($LASTEXITCODE){throw 'Setup test compilation failed'}
& $testExe
if($LASTEXITCODE){throw 'Setup isolated tests failed'}
