$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture=Join-Path $repo ('.build/windows-release-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item "$fixture/scripts","$fixture/Apps/Windows/XDVPN.App","$fixture/docs/releases","$fixture/dist/windows-release-0.1.4" -ItemType Directory -Force | Out-Null
Copy-Item "$repo/scripts/release-windows.ps1" "$fixture/scripts/release-windows.ps1"
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
            if($global:windowsReleaseTestScenario -eq 'published'){'[[{"tag_name":"windows-v0.1.4","draft":false}]]'}
            elseif($global:windowsReleaseTestScenario -eq 'draft'){'[[{"tag_name":"windows-v0.1.4","draft":true}]]'}
            else{'[[]]'}
            return
        }
        $remote=@($assets | ForEach-Object { @{name=$_.name;size=$_.size;digest="sha256:$($_.sha256)"} })
        if($global:windowsReleaseTestScenario -eq 'unexpected'){$remote+=@{name='other';size=1;digest='other'}}
        @{draft=$true;assets=$remote} | ConvertTo-Json -Depth 5
    }
}
$passed=0
try {
    foreach($case in @('success','draft','published','dirty','wrong-head','unexpected','tampered')){
        $global:windowsReleaseTestScenario=$case
        $global:windowsReleaseTestCalls=New-Object 'System.Collections.Generic.List[string]'
        if($case -eq 'tampered'){'changed' | Set-Content "$root/$($assets[0].name)"}
        $failure=$null
        try { & "$fixture/scripts/release-windows.ps1" publish -Tag windows-v0.1.4 | Out-Null } catch {$failure=$_}
        $success=$case -in @('success','draft')
        if($success -and $failure){throw "$case failed: $failure"}
        if(-not $success -and -not $failure){throw "$case incorrectly succeeded"}
        $published=@($global:windowsReleaseTestCalls | Where-Object {$_ -like 'release edit*'}).Count
        if($published -ne [int]$success){throw "$case published unexpectedly"}
        if($case -in @('published','dirty','wrong-head','tampered') -and @($global:windowsReleaseTestCalls | Where-Object {$_ -like 'release upload*'}).Count){throw "$case uploaded unexpectedly"}
        if($case -eq 'draft' -and @($global:windowsReleaseTestCalls | Where-Object {$_ -like 'release create*'}).Count){throw 'Existing draft recreated'}
        $passed++;Write-Output "PASS Windows release: $case"
    }
} finally { Set-Location $repo }
Write-Output "$passed Windows release checks passed (mock GitHub; no publication)."
