param(
    [Parameter(Mandatory=$true)][ValidateSet('prepare','publish')][string]$Action,
    [Parameter(Mandatory=$true)][string]$Tag,
    [string]$Repository = 'victorcheng2333/vpn_xd_client'
)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repo
function Git-Value([string[]]$Arguments) {
    $result = & git @Arguments
    if($LASTEXITCODE){throw "git failed: $Arguments"}
    return ($result -join "`n").Trim()
}
function Gh-Value([string[]]$Arguments) {
    $result = & gh @Arguments
    if($LASTEXITCODE){throw "GitHub command failed: $($Arguments[0])"}
    return ($result -join "`n").Trim()
}
$metadata=& "$PSScriptRoot/windows/version.ps1"
$version=$metadata.Version
if($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or $Tag -cne "windows-v$version"){throw 'Windows tag must match Resources/Info.plist (windows-vMAJOR.MINOR.PATCH).'}
if($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'){throw 'Invalid GitHub repository'}
if(Git-Value @('status','--porcelain','--untracked-files=normal')){throw 'Release requires a clean working tree.'}
$revision=Git-Value @('rev-parse','HEAD')
if($revision -ne (Git-Value @('rev-parse',"$Tag^{commit}"))){throw 'Release tag must point to HEAD.'}
$root=Join-Path $repo "dist/windows-release-$version"
$names=@("XDVPN-Setup-windows-x64-$version.exe","XDVPN-windows-x64-$version.zip")
$checksum="XDVPN-windows-x64-$version.sha256"
$record=Join-Path $root 'release.json'
if($Action -eq 'prepare') {
    & "$repo/Apps/Windows/scripts/build.ps1" -OutputRoot $root
    Copy-Item "$root/XDVPN-Setup-windows-x64-preview.exe" (Join-Path $root $names[0])
    Copy-Item "$root/XDVPN-windows-x64-preview.zip" (Join-Path $root $names[1])
    foreach($binary in @((Join-Path $root $names[0]),"$root/windows-x64/XDVPN.App.exe","$root/windows-x64/XDVPN.Service.exe")){
        if((Get-Item $binary).VersionInfo.FileVersion -ne $metadata.FileVersion){throw "Embedded version mismatch: $binary"}
    }
    $lines=@($names | ForEach-Object { "{0}  {1}" -f (Get-FileHash (Join-Path $root $_) -Algorithm SHA256).Hash.ToLowerInvariant(),$_ })
    [IO.File]::WriteAllText((Join-Path $root $checksum),($lines -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
    $assets=@($names + $checksum | ForEach-Object { @{name=$_; sha256=(Get-FileHash (Join-Path $root $_) -Algorithm SHA256).Hash.ToLowerInvariant(); size=(Get-Item (Join-Path $root $_)).Length} })
    @{tag=$Tag;revision=$revision;assets=$assets} | ConvertTo-Json -Depth 5 | Set-Content $record -Encoding utf8
    Write-Output "Prepared $Tag at $revision in $root"
    return
}
$data=Get-Content $record -Raw | ConvertFrom-Json
if($data.tag -cne $Tag -or $data.revision -ne $revision){throw 'Prepared files belong to another source revision.'}
$expected=@($names + $checksum)
if(@($data.assets).Count -ne $expected.Count -or @(Compare-Object $expected @($data.assets.name)).Count){throw 'Unexpected prepared asset set.'}
foreach($asset in $data.assets){
    $path=Join-Path $root $asset.name
    if((Get-Item $path).Length -ne $asset.size -or (Get-FileHash $path -Algorithm SHA256).Hash -ne $asset.sha256){throw "Prepared asset changed: $($asset.name)"}
}
$pages=Gh-Value @('api','--paginate','--slurp',"repos/$Repository/releases?per_page=100") | ConvertFrom-Json
$existing=@($pages | ForEach-Object { $_ } | Where-Object tag_name -eq $Tag)
if($existing.Count -gt 1 -or ($existing.Count -eq 1 -and -not $existing[0].draft)){throw 'Published Windows versions cannot be overwritten; use a new version.'}
$notes=Join-Path $repo "docs/releases/$Tag.md"
if(-not (Test-Path $notes)){throw "Missing release notes: $notes"}
if(-not $existing.Count){
    Gh-Value @('release','create',$Tag,'--repo',$Repository,'--verify-tag','--draft','--prerelease','--title',"XD VPN Windows $version",'--notes-file',$notes) | Out-Null
}
$drafts=Gh-Value @('api','--paginate','--slurp',"repos/$Repository/releases?per_page=100") | ConvertFrom-Json
$draft=@($drafts | ForEach-Object { $_ } | Where-Object tag_name -eq $Tag)
if($draft.Count -ne 1 -or -not $draft[0].draft -or -not $draft[0].id){throw 'Expected one draft release with an ID.'}
$releaseId=$draft[0].id
$paths=@($expected | ForEach-Object { Join-Path $root $_ })
Gh-Value (@('release','upload',$Tag,'--repo',$Repository,'--clobber')+$paths) | Out-Null
$verified=$false
for($attempt=0;$attempt -lt 12;$attempt++){
    $remote=Gh-Value @('api',"repos/$Repository/releases/$releaseId") | ConvertFrom-Json
    if(-not $remote.draft){throw 'Release was published during upload.'}
    if(@(Compare-Object $expected @($remote.assets.name)).Count){throw 'Unexpected draft assets; refusing publication.'}
    $verified=$true
    foreach($asset in $data.assets){
        $uploaded=@($remote.assets | Where-Object name -eq $asset.name)
        if($uploaded.Count -ne 1 -or $uploaded[0].size -ne $asset.size -or $uploaded[0].digest -ne "sha256:$($asset.sha256)"){$verified=$false}
    }
    if($verified){break}
    Start-Sleep -Seconds 5
}
if(-not $verified){throw 'GitHub asset hashes did not verify; release remains draft.'}
Gh-Value @('release','edit',$Tag,'--repo',$Repository,'--draft=false','--prerelease','--latest=false','--notes-file',$notes) | Out-Null
Gh-Value @('release','view',$Tag,'--repo',$Repository,'--json','url','--jq','.url')