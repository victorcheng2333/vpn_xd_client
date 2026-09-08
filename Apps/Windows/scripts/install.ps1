param([string]$OwnerSid,[switch]$NoLaunch)
$ErrorActionPreference='Stop'
$result=Join-Path $PSScriptRoot 'install-error.txt'
$log=Join-Path $PSScriptRoot 'install.log'
try {
    if(-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw 'Run this x64 installer in 64-bit PowerShell on Windows x64.'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $admin=([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(-not $OwnerSid){$OwnerSid=$identity.User.Value}
    [void](New-Object Security.Principal.SecurityIdentifier $OwnerSid)
    if(-not $admin){throw 'Run the XD VPN Setup EXE to install. ZIP scripts require an explicitly opened administrator PowerShell; this script never elevates user-writable files.'}
    $mutex=New-Object Threading.Mutex($false,'Global\XDVPN.Install')
    $locked=$false
    try {
        try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
        if(-not $locked){throw 'Another XD VPN installation is running. Wait for it to finish and retry.'}
        Start-Transcript -LiteralPath $log -Force | Out-Null
        try {
            . (Join-Path $PSScriptRoot 'install-core.ps1')
            Invoke-XDVPNInstall -OwnerSid $OwnerSid -Source $PSScriptRoot -dest (Join-Path $env:ProgramFiles 'XD VPN') -data (Join-Path $env:ProgramData 'XDVPN')
        } finally {Stop-Transcript | Out-Null}
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
    exit 0
} catch {
    $details=$_.Exception.Message+"`r`n"+$_.InvocationInfo.PositionMessage+"`r`n"+$_.ScriptStackTrace
    try {$details | Set-Content -LiteralPath $result -Encoding UTF8} catch {}
    [Console]::Error.WriteLine($details)
    exit 1
}
