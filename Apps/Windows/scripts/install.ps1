param([string]$OwnerSid)
$ErrorActionPreference='Stop'
if(-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw 'Run this x64 installer in 64-bit PowerShell on Windows x64.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$admin=([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $OwnerSid){$OwnerSid=$identity.User.Value}
[void](New-Object Security.Principal.SecurityIdentifier $OwnerSid)
if(-not $admin){
    $elevatedArguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-OwnerSid',$OwnerSid)
    $child=Start-Process powershell.exe -Verb RunAs -ArgumentList $elevatedArguments -Wait -PassThru
    if($child.ExitCode){throw "Installation failed: $($child.ExitCode)"}
    Start-Process (Join-Path $env:ProgramFiles 'XD VPN/XDVPN.App.exe')
    exit 0
}
$dest=Join-Path $env:ProgramFiles 'XD VPN'
$data=Join-Path $env:ProgramData 'XDVPN'
if($PSScriptRoot -eq $dest){throw 'Extract a fresh installation bundle before upgrading.'}
foreach($path in @($dest,$data)){
    if(Test-Path $path){if((Get-Item $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Installation path is a reparse point'}
        if(@(Get-ChildItem $path -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count){throw 'Installation contains a reparse point'}}
}
if(Test-Path "$data/owner.sid"){if((Get-Content "$data/owner.sid" -Raw).Trim() -ne $OwnerSid){throw 'This installation belongs to another Windows account. Uninstall before changing its owner.'}}
if(-not(Test-Path "$PSScriptRoot/runtime/openconnect.exe") -or -not(Test-Path "$PSScriptRoot/runtime/wintun.dll")){throw 'The bundle has no native engine.'}
if((Get-AuthenticodeSignature "$PSScriptRoot/runtime/wintun.dll").Status -ne 'Valid'){throw 'Invalid Wintun signature'}
$manifest=Get-Content "$PSScriptRoot/manifest.json" -Raw | ConvertFrom-Json
foreach($property in $manifest.PSObject.Properties){
    $file=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $property.Name))
    if(-not $file.StartsWith($PSScriptRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid manifest path'}
    if((Get-FileHash $file -Algorithm SHA256).Hash -ne $property.Value){throw "Bundle hash mismatch: $($property.Name)"}
}
$svc=Get-Service XDVPN -ErrorAction SilentlyContinue
if($svc){Stop-Service XDVPN; (Get-Service XDVPN).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(85))}
if(Test-Path "$data/sessions"){if(@(Get-ChildItem "$data/sessions" -Directory).Count){throw 'Previous network cleanup is incomplete. Restart the installed service and disconnect before upgrading.'}}
if(Get-Process XDVPN.App -ErrorAction SilentlyContinue){throw 'Exit XD VPN from its tray menu before installing.'}
New-Item $dest -ItemType Directory -Force | Out-Null
New-Item $data -ItemType Directory -Force | Out-Null
& icacls.exe $dest /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if($LASTEXITCODE){throw 'Cannot secure installation directory'}
& icacls.exe $data /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if($LASTEXITCODE){throw 'Cannot secure service data'}
Get-ChildItem $PSScriptRoot -Force | ForEach-Object { Copy-Item $_.FullName $dest -Recurse -Force }
$OwnerSid | Set-Content "$data/owner.sid" -Encoding ascii
foreach($path in @($dest,$data)) {
    & icacls.exe $path /setowner '*S-1-5-18' /T | Out-Null
    if($LASTEXITCODE){throw 'Cannot secure ownership of installed files'}
}
if(-not $svc){New-Service -Name XDVPN -BinaryPathName ('"'+$dest+'\XDVPN.Service.exe"') -DisplayName 'XD VPN Connection Service' -StartupType Automatic | Out-Null}
& sc.exe failure XDVPN reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
if($LASTEXITCODE){throw 'Cannot configure service recovery'}
Start-Service XDVPN
(Get-Service XDVPN).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
Start-Sleep -Seconds 2
if((Get-Service XDVPN).Status -ne 'Running'){throw 'Service did not stay running'}
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'XD VPN.lnk'))
$shortcut.TargetPath="$dest/XDVPN.App.exe";$shortcut.WorkingDirectory=$dest;$shortcut.Save()
Write-Host 'XD VPN installed. Open it from the Start menu.'
