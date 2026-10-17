[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference='Stop'
$tool=Join-Path $PSScriptRoot 'Backup-ClaudeHistorySafe.ps1'
$area=Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('b-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($area)
$global:BackupTestRunning=$false;$global:BackupTestCalls=0;$global:BackupTestStartAt=0
function Get-Process {
    param($Name,$ErrorAction)
    if($Name -eq 'Claude'){
        $global:BackupTestCalls++
        if($global:BackupTestRunning -or ($global:BackupTestStartAt -gt 0 -and $global:BackupTestCalls -ge $global:BackupTestStartAt)){[pscustomobject]@{Path='C:\fixture\Claude.exe'}}
    }
}
$results=New-Object System.Collections.Generic.List[object]
function Check($v,$message){if(-not $v){throw $message}}
function Refuses([scriptblock]$body){$threw=$false;try{& $body|Out-Null}catch{$threw=$true};Check $threw 'Expected refusal missing'}
function Case([string]$name,[scriptblock]$body){try{& $body;$results.Add([pscustomobject]@{Name=$name;Passed=$true;Detail=''})}catch{$results.Add([pscustomobject]@{Name=$name;Passed=$false;Detail=$_.Exception.Message})}}
function Fixture {
    $base=Join-Path $area ([guid]::NewGuid().ToString('N').Substring(0,8))
    $sessions=Join-Path $base 'Claude\claude-code-sessions';$projects=Join-Path $base '.claude\projects'
    $path=Join-Path $sessions ([guid]::NewGuid().ToString('D')+'\'+[guid]::NewGuid().ToString('D'))
    [void][IO.Directory]::CreateDirectory($path);[void][IO.Directory]::CreateDirectory((Join-Path $projects 'p\subagents'))
    [IO.File]::WriteAllText((Join-Path $path 'local_test.json'),'{"cliSessionId":"fixture"}')
    [IO.File]::WriteAllText((Join-Path $path 'scheduled-tasks.json'),'TASKS MUST NOT BE COPIED OR TOUCHED')
    [IO.File]::WriteAllText((Join-Path $projects 'p\main.jsonl'),'{"type":"fixture","text":"conversation"}')
    [IO.File]::WriteAllText((Join-Path $projects 'p\subagents\agent.jsonl'),'{"type":"fixture","text":"subagent"}')
    $asset=Join-Path $projects 'p\attachment.bin';[IO.File]::WriteAllBytes($asset,[byte[]]@(0,255,3,4,0))
    $hidden=Join-Path $projects 'p\.hidden';[IO.File]::WriteAllText($hidden,'hidden attachment');[IO.File]::SetAttributes($hidden,[IO.FileAttributes]::Hidden)
    [pscustomobject]@{Base=$base;Sessions=$sessions;Projects=$projects;Backup=(Join-Path $base 'backup')}
}
function Capture($f){$global:BackupTestCalls=0;& $tool -Mode Create -SessionRoot $f.Sessions -TranscriptRoot $f.Projects -BackupRoot $f.Backup}
function OriginalState($f){$state=@{};foreach($p in @(Get-ChildItem $f.Sessions,$f.Projects -Recurse -File -Force)){$state[$p.FullName]=@{Hash=(Get-FileHash $p.FullName).Hash;Ticks=$p.LastWriteTimeUtc.Ticks}};return $state}
function Preserved($state){foreach($p in $state.Keys){Check ([IO.File]::Exists($p)) 'Original missing';Check ((Get-FileHash $p).Hash -ceq $state[$p].Hash) 'Original content changed';Check ([IO.File]::GetLastWriteTimeUtc($p).Ticks -eq $state[$p].Ticks) 'Original date changed'}}
try{
 Case 'Preview has zero writes and includes nested transcripts and hidden assets' {
    $f=Fixture;$before=OriginalState $f;$r=& $tool -Mode Preview -SessionRoot $f.Sessions -TranscriptRoot $f.Projects
    Check ($r.Files -eq 5 -and $r.Writes -eq 0 -and -not [IO.Directory]::Exists($f.Backup)) 'Preview inventory mismatch';Preserved $before
 }
 Case 'Complete snapshot verifies every byte while originals and scheduled tasks remain untouched' {
    $f=Fixture;$before=OriginalState $f;$r=Capture $f;Check ($r.Verified -and $r.Files -eq 5) 'Snapshot incomplete';Preserved $before
    Check (@(Get-ChildItem $r.SnapshotPath -Recurse -Filter 'scheduled-tasks.json').Count -eq 0) 'Tasks included'
    $v=& $tool -Mode Verify -SnapshotPath $r.SnapshotPath;Check $v.Verified 'Independent verification failed'
 }
 Case 'RestoreCopy reconstructs transcripts, subagents, assets and metadata into a new folder' {
    $f=Fixture;$before=OriginalState $f;$r=Capture $f;$dest=Join-Path $f.Base 'restored'
    $v=& $tool -Mode RestoreCopy -SnapshotPath $r.SnapshotPath -RestoreDestination $dest
    Check ($v.Verified -and $v.Files -eq 5 -and -not $v.OriginalProfileModified) 'Restore failed';Preserved $before
    $manifest=Get-Content (Join-Path $r.SnapshotPath 'manifest.json') -Raw|ConvertFrom-Json
    foreach($entry in $manifest.Files){Check ((Get-FileHash (Join-Path $dest $entry.RelativePath)).Hash.ToLowerInvariant() -ceq $entry.SHA256) 'Recovered bytes differ'}
 }
 Case 'RestoreCopy refuses an existing profile or destination' {
    $f=Fixture;$r=Capture $f;$before=OriginalState $f
    Refuses {& $tool -Mode RestoreCopy -SnapshotPath $r.SnapshotPath -RestoreDestination $f.Projects};Preserved $before
 }
 Case 'Corrupted backup is rejected and never restored' {
    $f=Fixture;$r=Capture $f;$p=Get-ChildItem (Join-Path $r.SnapshotPath 'data\projects') -Recurse -File|Select-Object -First 1
    [IO.File]::WriteAllText($p.FullName,'CORRUPTED FIXTURE')
    Refuses {& $tool -Mode Verify -SnapshotPath $r.SnapshotPath};Refuses {& $tool -Mode RestoreCopy -SnapshotPath $r.SnapshotPath -RestoreDestination (Join-Path $f.Base 'restored')}
    Check (-not [IO.Directory]::Exists((Join-Path $f.Base 'restored'))) 'Restore wrote before validation'
 }
 Case 'Missing backup file is rejected' {
    $f=Fixture;$r=Capture $f;$p=Get-ChildItem (Join-Path $r.SnapshotPath 'data\projects') -Recurse -File|Select-Object -First 1
    [IO.File]::Delete($p.FullName);Refuses {& $tool -Mode Verify -SnapshotPath $r.SnapshotPath}
 }
 Case 'Incomplete snapshot with no COMPLETE marker is rejected' {
    $f=Fixture;$r=Capture $f;[IO.File]::Delete((Join-Path $r.SnapshotPath 'COMPLETE.json'));Refuses {& $tool -Mode Verify -SnapshotPath $r.SnapshotPath}
 }
 Case 'Tampered manifest is rejected' {
    $f=Fixture;$r=Capture $f;[IO.File]::AppendAllText((Join-Path $r.SnapshotPath 'manifest.json'),' ');Refuses {& $tool -Mode Verify -SnapshotPath $r.SnapshotPath}
 }
 Case 'Path-traversal manifest is refused even with a recomputed marker hash' {
    $f=Fixture;$r=Capture $f;$m=Join-Path $r.SnapshotPath 'manifest.json'
    $doc=Get-Content $m -Raw|ConvertFrom-Json;$doc.Files[0].RelativePath='data/projects/../../escape';[IO.File]::WriteAllText($m,($doc|ConvertTo-Json -Depth 6))
    $marker=@{Status='Complete';ManifestSHA256=(Get-FileHash $m).Hash.ToLowerInvariant()};[IO.File]::WriteAllText((Join-Path $r.SnapshotPath 'COMPLETE.json'),($marker|ConvertTo-Json))
    Refuses {& $tool -Mode Verify -SnapshotPath $r.SnapshotPath}
 }
 Case 'App running prevents any definitive backup' {
    $f=Fixture;$before=OriginalState $f;$global:BackupTestRunning=$true
    try{Refuses {Capture $f};Check (-not [IO.Directory]::Exists($f.Backup)) 'Backup began with app open'}finally{$global:BackupTestRunning=$false};Preserved $before
 }
 Case 'App reopening during backup leaves an explicitly incomplete snapshot' {
    $f=Fixture;$before=OriginalState $f;$global:BackupTestStartAt=3
    try{Refuses {Capture $f}}finally{$global:BackupTestStartAt=0}
    $s=@(Get-ChildItem $f.Backup -Directory);Check ($s.Count -eq 1) 'No interrupted snapshot';Check (-not [IO.File]::Exists((Join-Path $s[0].FullName 'COMPLETE.json'))) 'Interrupted snapshot marked complete';Preserved $before
 }
 Case 'Large transcript (12 MiB) is streamed and restored without the metadata size limit' {
    $f=Fixture;$large=Join-Path $f.Projects 'p\large.jsonl';$data=New-Object byte[] (12*1024*1024);(New-Object Random 17).NextBytes($data);[IO.File]::WriteAllBytes($large,$data)
    $r=Capture $f;Check ($r.Files -eq 6) 'Large transcript missing'
    $dest=Join-Path $f.Base 'restored';$null=& $tool -Mode RestoreCopy -SnapshotPath $r.SnapshotPath -RestoreDestination $dest
    Check ((Get-FileHash $large).Hash -ceq (Get-FileHash (Join-Path $dest 'data\projects\p\large.jsonl')).Hash) 'Large recovery mismatch'
 }
 Case 'Links in source trees are refused' {
    $f=Fixture;$outside=Join-Path $f.Base 'outside';[void][IO.Directory]::CreateDirectory($outside)
    $null=New-Item -ItemType Junction -Path (Join-Path $f.Projects 'p\link') -Target $outside
    Refuses {Capture $f}
 }
 Case 'Deletion markers and archive index are backed up without including scheduled tasks' {
    $f=Fixture;$scope=Get-ChildItem $f.Sessions -Directory|Get-ChildItem -Directory|Select-Object -First 1
    [IO.File]::WriteAllText((Join-Path $scope.FullName ('deleted_'+[guid]::NewGuid().ToString('D'))),'1234567890123')
    [IO.File]::WriteAllText((Join-Path $scope.FullName 'archived-sessions.idx'),'archive fixture')
    $r=Capture $f;Check ($r.Files -eq 7) 'Recovery state missing'
    Check (@(Get-ChildItem $r.SnapshotPath -Recurse -Filter 'scheduled-tasks.json').Count -eq 0) 'Tasks included'
 }
}finally{$global:BackupTestRunning=$false;$global:BackupTestStartAt=0}
$failed=@($results|Where-Object {-not $_.Passed})
[pscustomobject]@{Runtime=$PSVersionTable.PSVersion.ToString();Cases=$results.Count;Passed=$results.Count-$failed.Count;Failed=$failed.Count;Tests=@($results.ToArray());FixtureRoot=$area}|ConvertTo-Json -Depth 6
if($failed.Count -gt 0){exit 1}
