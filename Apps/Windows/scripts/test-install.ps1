# Executes the production installer against temporary files and fake OS services.
# No elevation, real service, registry, or networking changes.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/install-core.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('XDVPN-install-test-'+[Guid]::NewGuid().ToString('N'))
New-Item $root -ItemType Directory | Out-Null
$script:passed=0
function Assert($condition,$message){if(-not $condition){throw $message};$script:passed++;Write-Host "PASS $message"}
function Get-Process {param($Name,$ErrorAction) if($script:app){[pscustomobject]@{Name=$Name}}}
function Get-Service {param($Name,$ErrorAction) if($script:exists){$script:svc}}
function Stop-Service {param($Name) $script:stops++;if($script:stopFailure){throw 'Injected stop failure'};$script:svc.Status='Stopped'}
function Start-Service {param($Name) $script:starts++;if($script:startFailure){$script:startFailure=$false;throw 'Injected start failure'};$script:svc.Status='Running'}
function New-Service {param($Name,$BinaryPathName,$DisplayName,$StartupType) $script:exists=$true;$script:created++}
function Get-AuthenticodeSignature {param($FilePath) [pscustomobject]@{Status=$script:signature}}
# Exercise production ACL construction and traversal on real temporary files.
# The persistence seam only substitutes the owner and adds the current test SID
# so a non-admin test process can inspect and delete its fixtures afterwards.
function Write-XDVPNAccessDescriptor([string]$Path,[Security.AccessControl.FileSystemSecurity]$Security) {
    if($script:aclFailure){throw 'Injected secure installation ACL failure'}
    $rules=@($Security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    if(-not $Security.AreAccessRulesProtected -or $Security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544'){throw 'Production descriptor did not protect ownership/inheritance'}
    if(@($rules|Where-Object {$_.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544','S-1-5-32-545') -or $_.AccessControlType -ne 'Allow' -or $_.IsInherited}).Count){throw 'Production descriptor allowed an unexpected principal'}
    $isData=$Path.StartsWith($script:data,[StringComparison]::OrdinalIgnoreCase)
    if(($isData -and $rules.Count -ne 2) -or (-not $isData -and $rules.Count -ne 3)){throw 'Wrong number of production ACL entries'}
    foreach($rule in $rules) {
        $expected=if($rule.IdentityReference.Value -eq 'S-1-5-32-545'){[Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize}else{[Security.AccessControl.FileSystemRights]::FullControl}
        if($rule.FileSystemRights -ne $expected){throw 'Wrong production permission mask'}
    }
    $current=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $Security.SetOwner($current)
    $inheritance=if((Get-Item -LiteralPath $Path).PSIsContainer){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
    $Security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($current,[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
    try { if($Security -is [Security.AccessControl.DirectorySecurity]){[IO.Directory]::SetAccessControl($Path,$Security)}else{[IO.File]::SetAccessControl($Path,$Security)} } catch { throw ('Test ACL write '+$Path+': '+$_.Exception.Message+' at '+$_.ScriptStackTrace) }
    $written=Get-Acl -LiteralPath $Path
    $sections=[Security.AccessControl.AccessControlSections]'Access,Owner'
    if($written.GetSecurityDescriptorSddlForm($sections).Replace('D:PAI(','D:P(') -ne $Security.GetSecurityDescriptorSddlForm($sections).Replace('D:PAI(','D:P(')){throw ('ACL roundtrip mismatch: '+$written.GetSecurityDescriptorSddlForm($sections)+' vs '+$Security.GetSecurityDescriptorSddlForm($sections))}
    if(@($written.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.IdentityReference.Value -eq 'S-1-1-0'}).Count){throw 'Everyone survived real filesystem ACL update'}
    $script:aclWrites++
}
function icacls.exe {$global:LASTEXITCODE=0;if($script:aclFailure){$global:LASTEXITCODE=1}}
function sc.exe {if($args[0] -eq 'delete'){$script:exists=$false};$global:LASTEXITCODE=0}
function Start-Sleep {param($Seconds)}
function New-Object {param($ComObject) if($ComObject -ne 'WScript.Shell'){throw 'Unexpected COM activation'}; $obj=[pscustomobject]@{}; $obj | Add-Member ScriptMethod CreateShortcut {param($path) $s=[pscustomobject]@{TargetPath='';WorkingDirectory='';IconLocation=''};$s | Add-Member ScriptMethod Save {};$s};$obj}
function Reset([bool]$existing=$true){
  $script:case=Join-Path $root ([Guid]::NewGuid().ToString('N'))
  $script:source=Join-Path $case 'payload';$script:dest=Join-Path $case 'installed';$script:data=Join-Path $case 'data'
  New-Item "$source/runtime",$dest,$data -ItemType Directory -Force | Out-Null
  $manifest=@{}
  foreach($name in @('XDVPN.App.exe','XDVPN.Service.exe','XDVPN.RouteAudit.dll','runtime/openconnect.exe','runtime/wintun.dll')){
    Set-Content (Join-Path $source $name) 'new version';$manifest[$name]=(Get-FileHash (Join-Path $source $name)).Hash
  }
  $manifest | ConvertTo-Json | Set-Content "$source/manifest.json"
  Set-Content "$source/install.log" 'never install logs'
  if($existing){Set-Content "$dest/XDVPN.App.exe" 'old version';Set-Content "$data/owner.sid" 'S-1-5-21-123'}
  $script:aclWrites=0;$script:app=$false;$script:exists=$existing;$script:created=0;$script:stops=0;$script:starts=0
  $script:stopFailure=$false;$script:startFailure=$false;$script:aclFailure=$false;$script:signature='Valid'
  $script:svc=[pscustomobject]@{Status='Running'};$script:svc | Add-Member ScriptMethod WaitForStatus {param($status,$timeout) if($this.Status -ne $status){throw 'Unexpected service state'}}
}
function Run {Invoke-XDVPNInstall -OwnerSid 'S-1-5-21-123' -Source $source -dest $dest -data $data}
function Fails($pattern){$message='';try{Run}catch{$message=$_.Exception.Message};Assert ($message -like "*$pattern*") "Failure surfaced: $pattern"}
try {
 Reset;$script:app=$true;Fails 'tray menu';Assert ($stops -eq 0) 'Running app rejected before stopping service'
 Reset;Set-Content "$data/owner.sid" 'S-1-5-21-456';Fails 'another Windows account';Assert ($stops -eq 0) 'Wrong owner leaves service untouched'
 Reset;Set-Content "$source/XDVPN.App.exe" 'corrupt';Fails 'hash mismatch';Assert ($stops -eq 0) 'Corrupted payload leaves service untouched'
 Reset;$script:signature='NotSigned';Fails 'Wintun signature'
 Reset;Remove-Item "$source/runtime/openconnect.exe";Fails 'no native engine'
 Reset;$m=Get-Content "$source/manifest.json" -Raw | ConvertFrom-Json;$m.PSObject.Properties.Remove('XDVPN.Service.exe');$m | ConvertTo-Json | Set-Content "$source/manifest.json";Fails 'manifest is missing'
 Reset;$m=Get-Content "$source/manifest.json" -Raw | ConvertFrom-Json;$m.PSObject.Properties.Remove('XDVPN.RouteAudit.dll');$m | ConvertTo-Json | Set-Content "$source/manifest.json";Fails 'Bundle manifest is missing: XDVPN.RouteAudit.dll'
 Assert ($stops -eq 0) 'Missing route-audit manifest entry rejected before stopping service'
 Reset;Remove-Item -LiteralPath "$source/XDVPN.RouteAudit.dll";Fails 'Bundle file is missing: XDVPN.RouteAudit.dll'
 Assert ($stops -eq 0) 'Missing route-audit DLL rejected before stopping service'
 Reset;Set-Content -LiteralPath "$source/XDVPN.RouteAudit.dll" 'corrupt helper';Fails 'Bundle hash mismatch: XDVPN.RouteAudit.dll'
 Assert ($stops -eq 0) 'Corrupted route-audit DLL rejected before stopping service'
 Reset;$m=Get-Content "$source/manifest.json" -Raw | ConvertFrom-Json;$m | Add-Member NoteProperty '../escape.exe' 'bad';$m | ConvertTo-Json | Set-Content "$source/manifest.json";Fails 'Invalid manifest path'
 Reset;$script:stopFailure=$true;Fails 'stop failure';Assert ($svc.Status -eq 'Running') 'Stop failure preserves running service'
 Reset;New-Item "$data/sessions/pending" -ItemType Directory -Force | Out-Null;Fails 'cleanup is incomplete';Assert ($svc.Status -eq 'Running') 'Pending network cleanup restores original service'
 Reset;$script:aclFailure=$true;Fails 'secure installation';Assert ($svc.Status -eq 'Running') 'ACL failure restores original service'
 Reset;$script:startFailure=$true;Fails 'start failure';Assert ((Get-Content "$dest/XDVPN.App.exe" -Raw).Trim() -eq 'old version') 'Failed upgrade restores old executable';Assert ($svc.Status -eq 'Running') 'Failed upgrade restarts restored service';Assert (-not(Test-Path "$dest/runtime/openconnect.exe")) 'Rollback removes newly installed files';Assert (-not(Test-Path "$dest/XDVPN.RouteAudit.dll")) 'Rollback removes newly installed route-audit helper'
 Reset;$handle=[IO.File]::Open("$dest/XDVPN.App.exe",'Open','ReadWrite','None');$failed=$false
 try {try{Run}catch{$failed=$true}} finally {$handle.Dispose()}
 Assert $failed 'Real exclusive file lock rejects upgrade';Assert ((Get-Content "$dest/XDVPN.App.exe" -Raw).Trim() -eq 'old version') 'Locked upgrade preserves old file';Assert ($svc.Status -eq 'Running') 'Locked upgrade restores service'
 Reset;$script:svc.Status='Stopped';$script:aclFailure=$true;Fails 'secure installation';Assert ($starts -eq 0) 'Failure does not start an originally stopped service'
 Reset;Run;Assert ((Get-Content "$dest/XDVPN.App.exe" -Raw).Trim() -eq 'new version') 'Upgrade replaces existing executable';Assert (-not(Test-Path "$dest/install.log")) 'Diagnostics excluded from installed files';Assert ((Get-Content "$dest/XDVPN.RouteAudit.dll" -Raw).Trim() -eq 'new version') 'Upgrade installs route-audit helper';Assert ($svc.Status -eq 'Running' -and $created -eq 0) 'Upgrade reuses existing service';Assert (@(Get-ChildItem $dest -Directory -Filter '.install-backup-*').Count -eq 0) 'Successful upgrade cleans its backup'
 Reset $false;Run;Assert ($created -eq 1 -and $svc.Status -eq 'Running') 'Fresh install creates and starts service'
 Reset $false;$script:startFailure=$true;Fails 'start failure';Assert (-not $exists) 'Failed fresh install removes new service'
 Reset
 $child=Join-Path $data 'untrusted';New-Item $child -ItemType Directory|Out-Null;Set-Content (Join-Path $child 'foreign.txt') 'retain this data'
 foreach($item in @($data,$child,(Join-Path $child 'foreign.txt'))) {
   $acl=Get-Acl -LiteralPath $item
   $inheritance=if((Get-Item -LiteralPath $item).PSIsContainer){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
   $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
   Set-Acl -LiteralPath $item -AclObject $acl
 }
 Run
 Assert ($aclWrites -gt 5) 'Real ACL construction and recursive persistence exercised'
 foreach($item in @($data,$child,(Join-Path $child 'foreign.txt'))) {
   $acl=Get-Acl -LiteralPath $item
   Assert ($acl.AreAccessRulesProtected -and @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.IdentityReference.Value -eq 'S-1-1-0'}).Count -eq 0) 'Explicit Everyone permissions removed from pre-existing data objects'
 }
 Assert ((Get-Content (Join-Path $child 'foreign.txt') -Raw).Trim() -eq 'retain this data') 'Permission repair preserves unknown user data'
 function Add-OldManifest {
   New-Item "$dest/runtime" -ItemType Directory -Force|Out-Null
   Set-Content "$dest/runtime/retired.dll" 'old managed runtime'
   Set-Content "$dest/unmanaged.txt" 'keep unknown files'
   @{ 'XDVPN.App.exe'=(Get-FileHash "$dest/XDVPN.App.exe").Hash; 'runtime/retired.dll'=(Get-FileHash "$dest/runtime/retired.dll").Hash }|ConvertTo-Json|Set-Content "$dest/manifest.json"
 }
 Reset;Add-OldManifest;Run
 Assert (-not(Test-Path "$dest/runtime/retired.dll")) 'Upgrade removes verified retired managed runtime'
 Assert ((Get-Content "$dest/unmanaged.txt" -Raw).Trim() -eq 'keep unknown files') 'Upgrade preserves untracked files'
 Reset;Add-OldManifest;$oldManifest=Get-Content "$dest/manifest.json" -Raw;$script:startFailure=$true;Fails 'start failure'
 Assert ((Get-Content "$dest/runtime/retired.dll" -Raw).Trim() -eq 'old managed runtime') 'Rollback restores retired managed runtime'
 Assert ((Get-Content "$dest/manifest.json" -Raw) -eq $oldManifest) 'Rollback restores prior manifest provenance'
 Reset;Add-OldManifest;Set-Content "$dest/runtime/retired.dll" 'local modification';Fails 'Retired managed file was modified'
 Assert ($stops -eq 0 -and (Get-Content "$dest/runtime/retired.dll" -Raw).Trim() -eq 'local modification') 'Modified retired files block before service stop and remain untouched'
 Reset;Add-OldManifest;$old=@{'../unmanaged.txt'=('0'*64)};$old|ConvertTo-Json|Set-Content "$dest/manifest.json";Fails 'Invalid manifest path'
 Assert ($stops -eq 0) 'Untrusted previous manifest path rejected before stopping service'
 Write-Host "Installer regression checks passed: $passed"
} finally {
 $resolved=[IO.Path]::GetFullPath($root)
 if((Split-Path $resolved) -eq [IO.Path]::GetTempPath().TrimEnd('\') -and (Split-Path $resolved -Leaf) -match '^XDVPN-install-test-[0-9a-f]{32}$'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
