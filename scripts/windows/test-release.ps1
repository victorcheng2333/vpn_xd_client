$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture=Join-Path $repo ('.build/windows-release-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item "$fixture/scripts","$fixture/scripts/windows","$fixture/Resources","$fixture/Apps/Windows/XDVPN.App","$fixture/docs/releases","$fixture/dist/windows-release-0.1.4" -ItemType Directory -Force | Out-Null
Copy-Item "$repo/scripts/release-windows.ps1" "$fixture/scripts/release-windows.ps1"
Copy-Item "$repo/scripts/windows/version.ps1" "$fixture/scripts/windows/version.ps1"
'<plist><dict><key>CFBundleShortVersionString</key><string>0.1.4</string><key>CFBundleVersion</key><string>34</string></dict></plist>' | Set-Content "$fixture/Resources/Info.plist"
'<Project><PropertyGroup><Version>0.1.4</Version></PropertyGroup></Project>' | Set-Content "$fixture/Apps/Windows/XDVPN.App/XDVPN.App.csproj"
'notes' | Set-Content "$fixture/docs/releases/windows-v0.1.4.md"
$root="$fixture/dist/windows-release-0.1.4"
$assets=@('XDVPN-Setup-windows-x64-0.1.4.exe','XDVPN-windows-x64-0.1.4.zip','XDVPN-windows-x64-0.1.4.sha256' | ForEach-Object {
    'fixture' | Set-Content "$root/$_"
    @{name=$_;sha256=(Get-FileHash "$root/$_").Hash.ToLowerInvariant();size=(Get-Item "$root/$_").Length}
})
@{tag='windows-v0.1.4';revision='revision';assets=$assets} | ConvertTo-Json -Depth 5 | Set-Content "$root/release.json"
function git {
    $global:LASTEXITCODE=0
    if($args[0] -eq 'status'){if($global:windowsReleaseTestScenario -eq 'dirty'){' M file'};return}
    if($global:windowsReleaseTestScenario -eq 'wrong-head' -and $args[1] -eq 'HEAD'){'other';return}
    'revision'
}
function gh {
    $global:LASTEXITCODE=0
    $global:windowsReleaseTestCalls.Add(($args -join ' '))
    if($args[0] -eq 'api'){
        if($args -contains '--paginate'){
            if($global:windowsReleaseTestScenario -eq 'published'){'[[{"id":100,"tag_name":"v0.1.4","draft":false},{"id":123,"tag_name":"windows-v0.1.4","draft":false},{"id":99,"tag_name":"v0.1.3","draft":false}]]'}
            elseif($global:windowsReleaseTestScenario -eq 'draft' -or @($global:windowsReleaseTestCalls | Where-Object { $_ -like 'release create*' }).Count){'[[{"id":100,"tag_name":"v0.1.4","draft":false},{"id":123,"tag_name":"windows-v0.1.4","draft":true},{"id":99,"tag_name":"v0.1.3","draft":false}]]'}
            else{'[[{"id":100,"tag_name":"v0.1.4","draft":false},{"id":99,"tag_name":"v0.1.3","draft":false}]]'}
            return
        }
        if($args[-1] -like '*/releases/tags/*'){throw 'Draft lookup must use release ID'}
        $remote=@($assets | ForEach-Object { @{name=$_.name;size=$_.size;digest="sha256:$($_.sha256)"} })
        if($global:windowsReleaseTestScenario -eq 'unexpected'){$remote+=@{name='other';size=1;digest='other'}}
        @{draft=$true;assets=$remote} | ConvertTo-Json -Depth 5
    }
}
$passed=0
try {
    foreach($case in @('success','draft','published','dirty','wrong-head','unexpected','stable-publish','wrong-tag','tampered')){
        $global:windowsReleaseTestScenario=$case
        $global:windowsReleaseTestCalls=New-Object 'System.Collections.Generic.List[string]'
        if($case -eq 'tampered'){'changed' | Set-Content "$root/$($assets[0].name)"}
        $failure=$null
        $tag=if($case -eq 'stable-publish'){'v0.1.4'}elseif($case -eq 'wrong-tag'){'v0.1.3'}else{'windows-v0.1.4'}
        try { & "$fixture/scripts/release-windows.ps1" publish -Tag $tag | Out-Null } catch {$failure=$_}
        $success=$case -in @('success','draft')
        if($success -and $failure){throw "$case failed: $failure"}
        if(-not $success -and -not $failure){throw "$case incorrectly succeeded"}
        $published=@($global:windowsReleaseTestCalls | Where-Object {$_ -like 'release edit*'}).Count
        if($published -ne [int]$success){throw "$case published unexpectedly"}
        if($case -in @('published','dirty','wrong-head','tampered','stable-publish','wrong-tag') -and @($global:windowsReleaseTestCalls | Where-Object {$_ -like 'release upload*'}).Count){throw "$case uploaded unexpectedly"}
        if($case -eq 'draft' -and @($global:windowsReleaseTestCalls | Where-Object {$_ -like 'release create*'}).Count){throw 'Existing draft recreated'}
        $passed++;Write-Output "PASS Windows release: $case"
    }
} finally { Set-Location $repo }
Write-Output "$passed Windows release checks passed (mock GitHub; no publication)."
