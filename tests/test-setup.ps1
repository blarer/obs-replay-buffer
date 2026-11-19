# Tests for setup.ps1's config editing. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-setup.ps1
# Works on copies in a temp folder. Never touches the real OBS config, the
# registry, or Task Scheduler.
$ErrorActionPreference = 'Stop'
$tmp = Join-Path $env:TEMP ("obs-setup-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$env:OBS_SETUP_TEST = '1'
. (Join-Path $PSScriptRoot '..\setup.ps1')
Remove-Item Env:\OBS_SETUP_TEST

$script:pass = 0; $script:fail = 0
function Check($name, $got, $expect) {
    if ("$got" -eq "$expect") { $script:pass++; "PASS  $name" }
    else { $script:fail++; "FAIL  $name  expected=[$expect] got=[$got]" }
}

'--- INI editing ---'
$ini = Join-Path $tmp 'basic.ini'
@"
[General]
Name=Untitled

[Output]
Mode=Simple

[SimpleOutput]
FilePath=C:\Users\x\Videos
RecRB=false
RecRBTime=20

[Hotkeys]
OBSBasic.StartRecording={"bindings":[]}
"@ | Set-Content $ini -Encoding UTF8

Set-IniValue $ini 'SimpleOutput' 'RecRB' 'true'
Check 'existing key updated'                      (Get-IniValue $ini 'SimpleOutput' 'RecRB') 'true'
Check 'sibling key untouched'                     (Get-IniValue $ini 'SimpleOutput' 'RecRBTime') '20'
Check 'other section untouched'                   (Get-IniValue $ini 'Output' 'Mode') 'Simple'
Set-IniValue $ini 'AdvOut' 'RecRB' 'true'
Check 'missing section is created'                (Get-IniValue $ini 'AdvOut' 'RecRB') 'true'
Set-IniValue $ini 'Hotkeys' 'ReplayBuffer' '{"ReplayBuffer.Save":[{"alt":true,"key":"OBS_KEY_Z"}]}'
Check 'key appended to existing section'          ((Get-IniValue $ini 'Hotkeys' 'ReplayBuffer') -match 'OBS_KEY_Z') $true
Check 'existing hotkey line kept'                 ((Get-IniValue $ini 'Hotkeys' 'OBSBasic.StartRecording') -ne $null) $true
Check 'missing key -> null'                       (Get-IniValue $ini 'Nope' 'Nope') ''
Check 'RecRB only set once (no duplicates)'       @(Select-String -Path $ini -Pattern '^RecRB=' ).Count 2   # one per section
Check 'file has no BOM'                           ([IO.File]::ReadAllBytes($ini)[0] -ne 0xEF) $true

'--- scene collection JSON ---'
$scene = Join-Path $tmp 'Untitled.json'
'{"name":"Untitled","sources":[],"modules":{"scripts-tool":[{"path":"C:/old/place/obs-replay-flush.lua","settings":{}},{"path":"C:/other/thing.lua","settings":{}}],"output-timer":{"x":1}},"version":2}' | Set-Content $scene
Check 'old path counts as not registered'         (Test-LuaRegistered $scene) $false
Register-Lua $scene
$j = Get-Content $scene -Raw | ConvertFrom-Json
Check 'registered after Register-Lua'             (Test-LuaRegistered $scene) $true
Check 'stale copy of our script removed'          @($j.modules.'scripts-tool' | Where-Object { $_.path -match 'old/place' }).Count 0
Check 'unrelated script kept'                     @($j.modules.'scripts-tool' | Where-Object { $_.path -match 'thing\.lua' }).Count 1
Check 'exactly one entry for our script'          @($j.modules.'scripts-tool' | Where-Object { $_.path -match 'obs-replay-flush' }).Count 1
Check 'uses forward slashes like OBS'             (($j.modules.'scripts-tool' | Where-Object { $_.path -match 'obs-replay-flush' }).path -notmatch '\\') $true
Check 'other module data preserved'               $j.modules.'output-timer'.x 1
Check 'top-level fields preserved'                $j.version 2
Check 'backup written'                            (Test-Path "$scene.pre-setup.bak") $true
Register-Lua $scene
$j = Get-Content $scene -Raw | ConvertFrom-Json
Check 'idempotent: still one entry'               @($j.modules.'scripts-tool' | Where-Object { $_.path -match 'obs-replay-flush' }).Count 1
Unregister-Lua $scene
$j = Get-Content $scene -Raw | ConvertFrom-Json
Check 'unregister removes it'                     (Test-LuaRegistered $scene) $false
Check 'unregister keeps other scripts'            @($j.modules.'scripts-tool').Count 1

$bare = Join-Path $tmp 'bare.json'
'{"name":"Fresh","sources":[]}' | Set-Content $bare
Register-Lua $bare
Check 'fresh collection without modules works'    (Test-LuaRegistered $bare) $true

'--- scene collection discovery ---'
$ObsCfg = Join-Path $tmp 'obs-studio'
New-Item -ItemType Directory (Join-Path $ObsCfg 'basic\scenes') | Out-Null
'{"a":1}' | Set-Content (Join-Path $ObsCfg 'basic\scenes\Only.json')
Check 'single collection, no ini -> picked'       (Split-Path (Get-ObsSceneCollectionFile) -Leaf) 'Only.json'
"[Basic]`nSceneCollection=Main`nSceneCollectionFile=Main.json`n" | Set-Content (Join-Path $ObsCfg 'user.ini')
Check 'user.ini names the collection'             (Split-Path (Get-ObsSceneCollectionFile) -Leaf) 'Main.json'
"[Basic]`nSceneCollectionFile=Legacy`n" | Set-Content (Join-Path $ObsCfg 'user.ini')
Check 'extension added when missing'              (Split-Path (Get-ObsSceneCollectionFile) -Leaf) 'Legacy.json'

'--- task template ---'
$xml = (Get-Content $Template -Raw) -replace '\{\{SID\}\}', 'S-1-5-21-1-2-3-1001' -replace '\{\{USER\}\}', 'PC\me' `
        -replace '\{\{GATE\}\}', 'C:\x\obs-watchdog-gate.vbs' -replace '\{\{START\}\}', '2026-01-01T00:00:00'
$xml = $xml -replace '(?s)<!--.*?-->\s*', ''
Check 'template has no placeholders left'         ($xml -notmatch '\{\{') $true
$doc = New-Object Xml.XmlDocument; $doc.LoadXml($xml)
$ns = New-Object Xml.XmlNamespaceManager $doc.NameTable; $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
Check 'template is valid XML with 1-min repeat'   $doc.SelectSingleNode('//t:Repetition/t:Interval', $ns).InnerText 'PT1M'
Check 'template runs the gate'                    $doc.SelectSingleNode('//t:Exec/t:Arguments', $ns).InnerText '"C:\x\obs-watchdog-gate.vbs"'
Check 'template uses interactive token (no pw)'   $doc.SelectSingleNode('//t:LogonType', $ns).InnerText 'InteractiveToken'

Remove-Item $tmp -Recurse -Force
"`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
