$ErrorActionPreference='Stop'
[xml]$info=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../Resources/Info.plist') -Raw
$version=$info.SelectSingleNode("/plist/dict/key[.='CFBundleShortVersionString']/following-sibling::string[1]").InnerText
$build=$info.SelectSingleNode("/plist/dict/key[.='CFBundleVersion']/following-sibling::string[1]").InnerText
if($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or $build -notmatch '^[1-9][0-9]*$'){throw 'Invalid shared version metadata'}
if(@($version.Split('.') + $build | Where-Object { [long]$_ -gt 65534 }).Count){throw 'Version exceeds Windows version limits'}
[pscustomobject]@{Version=$version;Build=$build;FileVersion="$version.$build"}
