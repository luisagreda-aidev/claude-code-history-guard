param([Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference='Stop'
$base=Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('w-'+[guid]::NewGuid().ToString('N').Substring(0,8));[void][IO.Directory]::CreateDirectory($base)
$root=Join-Path $base 'Claude\sessions';$tr=Join-Path $base '.claude\projects';$scopes=@();$paths=@();$state=Join-Path $base 'state';$backup=Join-Path $base 'backup';$config=Join-Path $base 'config.json';$flag=Join-Path $base 'app-open'
for($i=0;$i-lt3;$i++){$s=[guid]::NewGuid().ToString('D')+'/'+[guid]::NewGuid().ToString('D');$scopes+=$s;$paths+=Join-Path $root $s.Replace('/','\');[void][IO.Directory]::CreateDirectory($paths[-1])}
[void][IO.Directory]::CreateDirectory((Join-Path $tr 'p'));[IO.File]::WriteAllText($flag,'')
$hashes=@{};foreach($name in @('Sync-ClaudeSessionsSafe.ps1','Sync-ClaudeSessionsAutomatic.ps1','Archive-ClaudeHistoryIncremental.ps1','ClaudeHistoryAutomatic.ps1')){$hashes[$name]=(Get-FileHash (Join-Path $PSScriptRoot $name)).Hash}
@{Format='ClaudeOfflineAutomation-v1';SessionRoot=$root;TranscriptRoot=$tr;BackupRoot=$backup;StateRoot=$state;Scopes=$scopes;BaselineFileNames=@();ScriptSHA256=$hashes;AppUserModelId='Claude_fixture!Claude'}|ConvertTo-Json -Depth 7|Set-Content $config -Encoding utf8
$harness=Join-Path $base 'harness.ps1'
@'
param($Tool,$Config,$Flag)
$ErrorActionPreference='Stop'
function Get-Process {param($Name,$ErrorAction);if($Name-eq'Claude'-and[IO.File]::Exists($Flag)){[pscustomobject]@{Path='C:\fixture\Claude.exe'}}}
&$Tool -Mode Watch -ConfigPath $Config
'@|Set-Content $harness -Encoding utf8
$exe=if(Test-Path (Join-Path $PSHOME 'pwsh.exe')){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
$tool=Join-Path $PSScriptRoot 'ClaudeHistoryAutomatic.ps1';$worker=$null;$second=$null;$checks=New-Object System.Collections.Generic.List[string]
function Check($v,$m){if(-not$v){throw $m};$checks.Add($m)}
function Chat([int]$account){$id=[guid]::NewGuid().ToString('D');$name='local_'+$id+'.json';[IO.File]::WriteAllText((Join-Path $paths[$account] $name),(@{cliSessionId=$id;sessionId=('local_'+$id);cwd=$base;title='fixture'}|ConvertTo-Json -Compress));[IO.File]::WriteAllText((Join-Path $tr ('p\'+$id+'.jsonl')),'fixture transcript');return $name}
function WaitEvent([string]$wanted,[int]$count){
 $deadline=[DateTime]::UtcNow.AddSeconds(40)
 do{$events=@(Get-ChildItem $state -Filter 'event-*.json' -File -ErrorAction SilentlyContinue|ForEach-Object{Get-Content $_.FullName -Raw|ConvertFrom-Json}|Where-Object {$_.State-eq$wanted});if($events.Count-ge$count){return $events[-1]};Start-Sleep -Milliseconds 300}while([DateTime]::UtcNow-lt$deadline)
 throw ('Timed out waiting for '+$wanted)
}
try{
 $name=Chat 0;$source=Join-Path $paths[0] $name;$hash=(Get-FileHash $source).Hash;$ticks=[IO.File]::GetLastWriteTimeUtc($source).Ticks
 $args='-NoProfile -ExecutionPolicy Bypass -File "'+$harness+'" -Tool "'+$tool+'" -Config "'+$config+'" -Flag "'+$flag+'"'
 $worker=Start-Process $exe -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $base 'worker.err')
 $null=WaitEvent 'Started' 1;Check (-not(Test-Path $backup)) 'Open app prevented all archive and copy writes'
 $second=Start-Process $exe -ArgumentList $args -WindowStyle Hidden -PassThru
 Check ($second.WaitForExit(8000)) 'Second watcher exited instead of duplicating the worker'
 [IO.File]::Delete($flag);$first=WaitEvent 'Complete' 1
 Check ($first.Detail.Added-eq2-and(Test-Path (Join-Path $paths[2] $name))) 'Real watcher detected exit and copied after verified backup'
 Check ((Get-FileHash $source).Hash-ceq$hash-and[IO.File]::GetLastWriteTimeUtc($source).Ticks-eq$ticks) 'Original bytes and modification date preserved'
 [IO.File]::WriteAllText((Join-Path $state 'PAUSE'),'');$null=WaitEvent 'Paused' 1
 # An entire app use/exit occurs while paused: the worker must catch it on resume.
 [IO.File]::WriteAllText($flag,'');$newName=Chat 1;[IO.File]::Delete($flag)
 Start-Sleep -Seconds 4
 Check (-not(Test-Path (Join-Path $paths[0] $newName))) 'Pause blocked synchronization after the next app exit'
 [IO.File]::Delete((Join-Path $state 'PAUSE'));$last=WaitEvent 'Complete' 2
 Check ($last.Detail.Added-eq2-and(Test-Path (Join-Path $paths[0] $newName))) 'Resume completed the pending conversation copy'
 $restore=Join-Path $base 'restore';$recovered=&(Join-Path $PSScriptRoot 'Archive-ClaudeHistoryIncremental.ps1') -Mode RestoreCopy -SnapshotPath $last.Detail.Snapshot -RestoreDestination $restore
 Check $recovered.Verified 'Watcher backup reconstructed into a separate folder'
 $audit=& node (Join-Path $PSScriptRoot 'Verify-IncrementalHistoryIndependent.cjs') $last.Detail.Snapshot $restore
 Check ($LASTEXITCODE-eq0-and($audit|ConvertFrom-Json).RecoveryVerified) 'Independent Node SHA-256 audit verified restored history'
 [pscustomobject]@{Runtime=$PSVersionTable.PSVersion.ToString();Passed=$checks.Count;Failed=0;Checks=$checks.ToArray();TestRoot=$base}|ConvertTo-Json -Depth 6
}finally{
 # Only the two explicit fixture harness processes are terminated.
 foreach($p in @($worker,$second)){if($p){$p.Refresh();if(-not$p.HasExited){$p.Kill();$p.WaitForExit()}}}
}
