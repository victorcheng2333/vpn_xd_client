$ErrorActionPreference='Stop'
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin){$child=Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"')) -Wait -PassThru;exit $child.ExitCode}
if(Get-Process XDVPN.App -ErrorAction SilentlyContinue){throw 'Exit XD VPN from its tray menu first.'}
$dest=Join-Path $env:ProgramFiles 'XD VPN';$data=Join-Path $env:ProgramData 'XDVPN'
$svc=Get-Service XDVPN -ErrorAction SilentlyContinue
if($svc){Stop-Service XDVPN;(Get-Service XDVPN).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(85))}
if(Test-Path "$data/sessions"){if(@(Get-ChildItem "$data/sessions" -Directory).Count){throw 'Network cleanup remains incomplete. Restart the service and disconnect before uninstalling.'}}
if($svc){& sc.exe delete XDVPN | Out-Null;if($LASTEXITCODE){throw 'Cannot remove service'}}
Remove-Item (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'XD VPN.lnk') -ErrorAction SilentlyContinue
# Personal profiles / credentials remain with their owner; use the app's Forget Password before uninstalling if needed.
Remove-Item $dest -Recurse -Force
Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'XD VPN removed. Personal settings and credentials were retained.'
