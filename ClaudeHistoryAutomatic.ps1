# Offline-only automation. Own files live outside Claude; no scheduled tasks.
[CmdletBinding()]
param(
 [ValidateSet('Preview','Once','Watch','Launch','Status')][string]$Mode='Preview',
 [Parameter(Mandatory=$true)][string]$ConfigPath
)
$ErrorActionPreference='Stop'
function Safe([string]$p){
 if(-not$p-or$p-notmatch'^[A-Za-z]:\\'-or$p.Substring(2).Contains(':')){throw 'Local absolute path required'}
 $cursor=[IO.Path]::GetFullPath($p).TrimEnd('\')
 while($cursor){if((Test-Path -LiteralPath $cursor)-and(([IO.File]::GetAttributes($cursor)-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw 'Link refused'};$parent=[IO.Directory]::GetParent($cursor);$cursor=if($parent){$parent.FullName}else{$null}}
}
function AppOpen {
 foreach($p in @(Get-Process -Name Claude -ErrorAction SilentlyContinue)){$path=$null;try{$path=$p.Path}catch{};if(-not$path-or$path-notmatch'\\claude-code\\'){return $true}};return $false
}
Safe $ConfigPath
# Bootstrapping parser does not load unverified script code.
$config=[IO.File]::ReadAllText($ConfigPath)|ConvertFrom-Json
if($config.Format-cne'ClaudeOfflineAutomation-v1'){throw 'Unexpected configuration format'}
$names=@('Sync-ClaudeSessionsSafe.ps1','Sync-ClaudeSessionsAutomatic.ps1','Archive-ClaudeHistoryIncremental.ps1','ClaudeHistoryAutomatic.ps1')
function Integrity { foreach($name in $names){
 $file=Join-Path $PSScriptRoot $name;Safe $file
 $expected=$config.ScriptSHA256.$name
 if($expected-notmatch'^[0-9A-Fa-f]{64}$'-or(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash-ine$expected){throw 'Tested helper integrity check failed; no Claude data written'}
} }
Integrity
$engine=Join-Path $PSScriptRoot 'Sync-ClaudeSessionsAutomatic.ps1'
$archive=Join-Path $PSScriptRoot 'Archive-ClaudeHistoryIncremental.ps1'
$null=& $engine -Mode Inspect -SessionRoot $config.SessionRoot
$null=[SafeClaudeSessions.Json]::Parse([IO.File]::ReadAllBytes($ConfigPath))
foreach($p in @($config.SessionRoot,$config.TranscriptRoot,$config.BackupRoot,$config.StateRoot)){Safe $p}
foreach($root in @($config.SessionRoot,$config.TranscriptRoot)){
 $parent=[IO.Directory]::GetParent($root).FullName.TrimEnd('\')
 foreach($out in @($config.BackupRoot,$config.StateRoot)){
  if($out.Equals($parent,[StringComparison]::OrdinalIgnoreCase)-or$out.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Runtime data must be outside Claude data'}
 }
}
$parameters=@{SessionRoot=$config.SessionRoot;Scopes=@($config.Scopes);TranscriptRoot=$config.TranscriptRoot;BackupRoot=(Join-Path $config.BackupRoot 'metadata');ExcludeFileNames=@($config.BaselineFileNames)}
function Event([string]$state,[object]$detail){
 Safe $config.StateRoot;[void][IO.Directory]::CreateDirectory($config.StateRoot)
 $e=[pscustomobject]@{Utc=[DateTime]::UtcNow.ToString('o');State=$state;PID=$PID;Detail=$detail}
 $path=Join-Path $config.StateRoot ('event-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff')+'-'+[guid]::NewGuid().ToString('N')+'.json')
 [SafeClaudeSessions.Json]::WriteNew($path,([Text.UTF8Encoding]::new($false).GetBytes(($e|ConvertTo-Json -Depth 10))))
 return $e
}
function Cycle {
 Integrity
 if([IO.File]::Exists((Join-Path $config.StateRoot 'PAUSE'))){return (Event 'Paused' @{ClaudeDataWrites=0})}
 if(AppOpen){return (Event 'WaitingForClaudeExit' @{ClaudeDataWrites=0})}
 [void][IO.Directory]::CreateDirectory($config.StateRoot);Safe $config.StateRoot
 $guard=$null
 try{
  try{$guard=[IO.File]::Open((Join-Path $config.StateRoot '.cycle.lock'),'OpenOrCreate','ReadWrite','None')}catch [IO.IOException]{throw [TimeoutException]::new('Another protected copy is running')}
  if(AppOpen){throw 'Claude restarted before archive'}
  $preview=&$engine -Mode Preview @parameters
  $null=Event 'Archiving' @{PlannedAdds=$preview.PlannedAdds}
  $saved=&$archive -Mode Create -SessionRoot $config.SessionRoot -TranscriptRoot $config.TranscriptRoot -BackupRoot (Join-Path $config.BackupRoot 'history')
  if(-not$saved.Verified-or(AppOpen)){throw 'Verified offline snapshot required'}
  $result=&$engine -Mode Apply @parameters -RequiredSnapshotPath $saved.SnapshotPath -Confirm:$false
  foreach($planned in $preview.Plan){
   $destination=Join-Path $config.SessionRoot ($planned.TargetScope.Replace('/','\')+'\'+$planned.File)
   if(-not[IO.File]::Exists($destination)){throw 'A new conversation remains pending; source changed or copy was interrupted. Protected launch deferred.'}
  }
  # Preserve and report conflicts; never repair or overwrite them automatically.
  Event 'Complete' @{Added=$result.AddedCount;Replaced=0;Deleted=0;Snapshot=$saved.SnapshotPath;NewBackupBytes=$saved.NewBytes;VerifiedFiles=$saved.Files;Issues=@($result.Issues);ConcurrentSkips=@($result.ConcurrentSkips);TasksOrGroupsModified=$false}
 }finally{if($guard){$guard.Dispose()}}
}
if($Mode-eq'Preview'){return (&$engine -Mode Preview @parameters)}
if($Mode-eq'Status'){
 $event=Get-ChildItem -LiteralPath $config.StateRoot -Filter 'event-*.json' -File -ErrorAction SilentlyContinue|Sort-Object Name -Descending|Select-Object -First 1
 $workers=@(Get-ChildItem -LiteralPath $config.StateRoot -Filter 'worker-*.json' -File -ErrorAction SilentlyContinue|ForEach-Object{
  $w=Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json;$p=Microsoft.PowerShell.Management\Get-Process -Id $w.PID -ErrorAction SilentlyContinue
  if($p-and$p.StartTime.ToUniversalTime().Ticks-eq$w.StartTicks){$w}
 })
 return [pscustomobject]@{Workers=$workers;ClaudeOpen=(AppOpen);Paused=[IO.File]::Exists((Join-Path $config.StateRoot 'PAUSE'));Latest=$(if($event){Get-Content -LiteralPath $event.FullName -Raw|ConvertFrom-Json});Scopes=@($config.Scopes)}
}
if($Mode-eq'Once'){return (Cycle)}
if($Mode-eq'Launch'){
 try{
  if(AppOpen){throw 'Claude is still running. Use Quit in its system tray menu before using this shortcut.'}
  Write-Host 'Verifying and backing up Code history before opening Claude...'
  # If the watcher is in a cycle, wait for its lock rather than launch early.
  $deadline=[DateTime]::UtcNow.AddMinutes(15);$done=$false
  while(-not$done){
   try{$result=Cycle;$done=$true}catch [TimeoutException]{if([DateTime]::UtcNow-gt$deadline){throw};Start-Sleep -Seconds 2}
  }
  if($result.State-cne'Complete'){throw 'The protected copy did not complete; Claude will not be launched'}
  if($config.AppUserModelId-notmatch'^Claude_[A-Za-z0-9]+!Claude$'){throw 'Unrecognized Claude launch identity'}
  Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('shell:AppsFolder\'+$config.AppUserModelId)
  return $result
 }catch{
  Add-Type -AssemblyName System.Windows.Forms
  [void][Windows.Forms.MessageBox]::Show(('Claude was not launched. Review the history check: '+$_.Exception.Message),'Claude History Guard')
  throw
 }
}
# The watcher never closes, starts, signs out, or changes the running app.
$mutexName='Local\ClaudeHistoryAutomatic-'+((Get-FileHash -LiteralPath $ConfigPath).Hash.Substring(0,24))
$mutex=[Threading.Mutex]::new($false,$mutexName);$owned=$false
try{
 try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
 if(-not$owned){return}
 [void][IO.Directory]::CreateDirectory($config.StateRoot)
 $self=Microsoft.PowerShell.Management\Get-Process -Id $PID
 $worker=Join-Path $config.StateRoot ('worker-'+$PID+'-'+[guid]::NewGuid().ToString('N')+'.json')
 [SafeClaudeSessions.Json]::WriteNew($worker,([Text.UTF8Encoding]::new($false).GetBytes((@{PID=$PID;StartTicks=$self.StartTime.ToUniversalTime().Ticks;StartedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json))))
 $wasOpen=$true;$nextTry=[DateTime]::MinValue;$paused=$false
 $null=Event 'Started' @{OfflineOnly=$true;Scopes=@($config.Scopes)}
 while($true){
  if([IO.File]::Exists((Join-Path $config.StateRoot 'PAUSE'))){if(-not$paused){$null=Event 'Paused' @{ClaudeDataWrites=0};$paused=$true};Start-Sleep -Seconds 3;continue}
  if($paused){$wasOpen=$true;$nextTry=[DateTime]::MinValue}
  $paused=$false;$open=AppOpen
  if($open){if(-not$wasOpen){$null=Event 'WaitingForClaudeExit' @{ClaudeDataWrites=0}};$wasOpen=$true}
  elseif($wasOpen-and[DateTime]::UtcNow-ge$nextTry){
   Start-Sleep -Seconds 3
   try{$r=Cycle;if($r.State-eq'Complete'){$wasOpen=$false}}catch{
    $null=Event 'Deferred' @{Reason=$_.Exception.Message;OriginalFilesPreserved=$true};$nextTry=[DateTime]::UtcNow.AddMinutes(1)
   }
  }
  Start-Sleep -Seconds 2
 }
}finally{if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
