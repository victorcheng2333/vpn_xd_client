# Exact allowlists replace the complete DACL, including explicit ACEs on children.
function New-XDVPNAccessDescriptor([bool]$Directory,[bool]$PublicRead) {
    $acl = if($Directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inheritance = if($Directory){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
    foreach($sid in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
    }
    if($PublicRead){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),[Security.AccessControl.FileSystemRights]::ReadAndExecute,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))}
    return $acl
}
function Write-XDVPNAccessDescriptor([string]$Path,[Security.AccessControl.FileSystemSecurity]$Security) {
    if($Security -is [Security.AccessControl.DirectorySecurity]){[IO.Directory]::SetAccessControl($Path,$Security)}else{[IO.File]::SetAccessControl($Path,$Security)}
    $actual=Get-Acl -LiteralPath $Path -ErrorAction Stop
    # Windows may retain the auto-inherited bookkeeping flag even with a
    # protected DACL. Ignore that flag only; all owners and ACE bytes must match.
    $sections=[Security.AccessControl.AccessControlSections]'Access,Owner'
    if(-not $actual.AreAccessRulesProtected -or $actual.GetSecurityDescriptorSddlForm($sections).Replace('D:PAI(','D:P(') -ne $Security.GetSecurityDescriptorSddlForm($sections).Replace('D:PAI(','D:P(')){throw 'Trusted permissions did not persist exactly'}
}
function Set-XDVPNPermissions([string]$Path,[bool]$PublicRead) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Installation contains a reparse point'}
    Write-XDVPNAccessDescriptor $item.FullName (New-XDVPNAccessDescriptor $item.PSIsContainer $PublicRead)
    if($item.PSIsContainer){foreach($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)){Set-XDVPNPermissions $child.FullName $PublicRead}}
}
function Read-XDVPNManifest([string]$Path) {
    $manifest=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if($manifest -isnot [Management.Automation.PSCustomObject]){throw 'Invalid manifest object'}
    $files=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($property in $manifest.PSObject.Properties) {
        $name=$property.Name.Replace('/','\')
        $parts=$name.Split('\')
        if([IO.Path]::IsPathRooted($name) -or $name.Contains(':') -or $name.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or
            @($parts|Where-Object { -not $_ -or $_ -in @('.','..') -or $_ -ne $_.TrimEnd([char[]]' .') }).Count -or
            $name -eq 'manifest.json' -or $parts[0] -like '.install-backup-*'){throw 'Invalid manifest path'}
        if($property.Value -isnot [string] -or $property.Value -notmatch '^[0-9a-fA-F]{64}$' -or $files.ContainsKey($name)){throw 'Invalid manifest hash or duplicate path'}
        $files.Add($name,$property.Value)
    }
    return ,$files
}
# Kept separate so installation/upgrade failure paths can run against isolated test directories.
function Invoke-XDVPNInstall {
param([string]$OwnerSid,[string]$Source,[string]$dest,[string]$data)
$ErrorActionPreference='Stop'
$Source=[IO.Path]::GetFullPath($Source).TrimEnd('\');$dest=[IO.Path]::GetFullPath($dest).TrimEnd('\');$data=[IO.Path]::GetFullPath($data).TrimEnd('\')
if($Source -eq $dest){throw 'Extract a fresh installation bundle before upgrading.'}
foreach($path in @($Source,$dest,$data)){
    if(Test-Path -LiteralPath $path){if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Installation path is a reparse point'}
        if(@(Get-ChildItem -LiteralPath $path -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count){throw 'Installation contains a reparse point'}}
}
if(Test-Path "$data/owner.sid"){if((Get-Content "$data/owner.sid" -Raw).Trim() -ne $OwnerSid){throw 'This installation belongs to another Windows account. Uninstall before changing its owner.'}}
if(-not(Test-Path "$Source/runtime/openconnect.exe") -or -not(Test-Path "$Source/runtime/wintun.dll")){throw 'The bundle has no native engine.'}
if((Get-AuthenticodeSignature "$Source/runtime/wintun.dll").Status -ne 'Valid'){throw 'Invalid Wintun signature'}
$manifest=Read-XDVPNManifest "$Source/manifest.json"
$files=@($manifest.Keys)
foreach($required in @('XDVPN.App.exe','XDVPN.Service.exe','XDVPN.RouteAudit.dll','runtime/openconnect.exe','runtime/wintun.dll')) {
    if(-not $manifest.ContainsKey($required.Replace('/','\'))){throw "Bundle manifest is missing: $required"}
    if(-not [IO.File]::Exists((Join-Path $Source $required))){throw "Bundle file is missing: $required"}
}
foreach($name in $files){
    $file=[IO.Path]::GetFullPath((Join-Path $Source $name))
    if(-not $file.StartsWith($Source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid manifest path'}
    if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $manifest[$name]){throw "Bundle hash mismatch: $name"}
}
# Retire only old manifest entries whose current bytes still match that manifest.
# Unknown files and modified retired files are never silently deleted.
$retired=@()
if(Test-Path -LiteralPath "$dest/manifest.json") {
    $previous=Read-XDVPNManifest "$dest/manifest.json"
    foreach($name in $previous.Keys) {
        if($manifest.ContainsKey($name)){continue}
        $target=Join-Path $dest $name
        if(Test-Path -LiteralPath $target) {
            if((Get-Item -LiteralPath $target).PSIsContainer -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $previous[$name]){throw "Retired managed file was modified: $name. Preserve it before upgrading."}
            $retired+= $name
        }
    }
}
if(Get-Process XDVPN.App -ErrorAction SilentlyContinue){throw 'Exit XD VPN from its tray menu before installing. The service has not been stopped.'}
$svc=Get-Service XDVPN -ErrorAction SilentlyContinue
$wasRunning=$svc -and $svc.Status -eq 'Running'
$backup=$null;$changed=[Collections.Generic.List[string]]::new();$createdService=$false
try {
if($svc){Stop-Service XDVPN; (Get-Service XDVPN).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(85))}
if(Test-Path "$data/sessions"){if(@(Get-ChildItem "$data/sessions" -Directory).Count){throw 'Previous network cleanup is incomplete. Restart the installed service and disconnect before upgrading.'}}
if(Get-Process XDVPN.App -ErrorAction SilentlyContinue){throw 'Exit XD VPN from its tray menu before installing.'}
New-Item $dest -ItemType Directory -Force | Out-Null
New-Item $data -ItemType Directory -Force | Out-Null
try{Set-XDVPNPermissions $dest $true}catch{throw "Cannot secure installation directory: $($_.Exception.Message)"}
try{Set-XDVPNPermissions $data $false}catch{throw "Cannot secure service data: $($_.Exception.Message)"}
$backup=Join-Path $dest ('.install-backup-'+[Guid]::NewGuid().ToString('N'))
New-Item $backup -ItemType Directory | Out-Null
foreach($name in @($files)+@($retired)+@('manifest.json')) {
    $target=Join-Path $dest $name
    if(Test-Path -LiteralPath $target) {
        $saved=Join-Path $backup $name
        New-Item (Split-Path $saved) -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $target -Destination $saved -Force
    }
}
foreach($name in $retired) {
    $changed.Add($name)
    Remove-Item -LiteralPath (Join-Path $dest $name) -Force
}
foreach($name in @($files)+@('manifest.json')) {
    $target=Join-Path $dest $name
    New-Item (Split-Path $target) -ItemType Directory -Force | Out-Null
    $changed.Add($name)
    Copy-Item -LiteralPath (Join-Path $Source $name) -Destination $target -Force
}
# Exclusive access rejects an untrusted pre-existing open handle to the authority file.
$ownerBytes=[Text.Encoding]::ASCII.GetBytes($OwnerSid+[Environment]::NewLine)
$ownerFile=[IO.File]::Open((Join-Path $data 'owner.sid'),[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$ownerFile.Write($ownerBytes,0,$ownerBytes.Length);$ownerFile.Flush($true)}finally{$ownerFile.Dispose()}
# Copied/new objects receive the same exact trusted ACL before the service starts.
Set-XDVPNPermissions $dest $true
Set-XDVPNPermissions $data $false
foreach($path in @($dest,$data)) {
    & icacls.exe $path /setowner '*S-1-5-18' /T | Out-Null
    if($LASTEXITCODE){throw 'Cannot secure ownership of installed files'}
}
if(-not $svc){New-Service -Name XDVPN -BinaryPathName ('"'+$dest+'\XDVPN.Service.exe"') -DisplayName 'XD VPN Connection Service' -StartupType Automatic | Out-Null;$createdService=$true}
& sc.exe failure XDVPN reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
if($LASTEXITCODE){throw 'Cannot configure service recovery'}
Start-Service XDVPN
(Get-Service XDVPN).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
Start-Sleep -Seconds 2
if((Get-Service XDVPN).Status -ne 'Running'){throw 'Service did not stay running'}
} catch {
    $failure=$_
    try {
        if($changed.Count) {
            if(Get-Service XDVPN -ErrorAction SilentlyContinue){Stop-Service XDVPN;(Get-Service XDVPN).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(85))}
            foreach($name in $changed) {
                $saved=Join-Path $backup $name;$target=Join-Path $dest $name
                if(Test-Path -LiteralPath $saved){Copy-Item -LiteralPath $saved -Destination $target -Force}
                elseif(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Force}
            }
            # Retired files are recreated during rollback; restore their trusted
            # ACL/owner before a restored service can execute the old runtime.
            Set-XDVPNPermissions $dest $true
            Set-XDVPNPermissions $data $false
            foreach($path in @($dest,$data)) {
                & icacls.exe $path /setowner '*S-1-5-18' /T | Out-Null
                if($LASTEXITCODE){throw 'Cannot secure ownership of restored files'}
            }
        }
        if($createdService){& sc.exe delete XDVPN | Out-Null;if($LASTEXITCODE){throw 'Cannot remove failed new service'}}
        if($wasRunning){Start-Service XDVPN;(Get-Service XDVPN).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))}
    } catch {throw "$($failure.Exception.Message) | Recovery failed: $($_.Exception.Message). Backup: $backup"}
    throw $failure
}
if($backup) {
    $backupPath=[IO.Path]::GetFullPath($backup)
    if((Split-Path $backupPath) -ne [IO.Path]::GetFullPath($dest) -or (Split-Path $backupPath -Leaf) -notmatch '^\.install-backup-[0-9a-f]{32}$'){throw 'Invalid backup path'}
    try {Remove-Item -LiteralPath $backupPath -Recurse -Force} catch {Write-Warning "Installed, but backup cleanup failed: $backupPath"}
}
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'XD VPN.lnk'))
$shortcut.TargetPath="$dest/XDVPN.App.exe";$shortcut.WorkingDirectory=$dest
$shortcut.IconLocation="$dest/XDVPN.App.exe,0";$shortcut.Save()
Write-Host 'XD VPN installed. Open it from the Start menu.'
}
