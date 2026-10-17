# Immutable, deduplicated full history snapshots. Never writes in Claude data.
[CmdletBinding()]
param(
 [ValidateSet('Create','Verify','RestoreCopy')][string]$Mode='Create',
 [string]$SessionRoot,[string]$TranscriptRoot,[string]$BackupRoot,
 [string]$SnapshotPath,[string]$RestoreDestination
)
$ErrorActionPreference='Stop'
function Full([string]$p) {
 if(-not $p -or $p -notmatch '^[A-Za-z]:\\' -or $p.Substring(2).Contains(':')){throw 'Absolute local drive path required'}
 [IO.Path]::GetFullPath($p).TrimEnd('\')
}
function Within([string]$p,[string]$root){$p.Equals($root,[StringComparison]::OrdinalIgnoreCase)-or$p.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)}
function Safe([string]$p){
 $cursor=Full $p
 while($cursor){
  if(([IO.File]::Exists($cursor)-or[IO.Directory]::Exists($cursor))-and(([IO.File]::GetAttributes($cursor)-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw 'Links and junctions refused'}
  $parent=[IO.Directory]::GetParent($cursor);$cursor=if($parent){$parent.FullName}else{$null}
 }
}
function AppOpen {
 foreach($p in @(Get-Process -Name Claude -ErrorAction SilentlyContinue)){
  $path=$null;try{$path=$p.Path}catch{}
  if(-not$path-or$path-notmatch'\\claude-code\\'){return $true}
 };return $false
}
function Closed {if(AppOpen){throw 'Claude is running; incomplete work retained, synchronization refused'}}
function Hash([string]$p){
 Safe $p;$f=[IO.File]::Open($p,'Open','Read',([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete));$s=[Security.Cryptography.SHA256]::Create()
 try{([BitConverter]::ToString($s.ComputeHash($f))).Replace('-','').ToLowerInvariant()}finally{$f.Dispose();$s.Dispose()}
}
function WriteNew([string]$p,[object]$o){
 Safe $p;[SafeClaudeSessions.Json]::WriteNew($p,([Text.UTF8Encoding]::new($false).GetBytes(($o|ConvertTo-Json -Depth 8))))
}
function Tree([string]$root,[string]$kind){
 Safe $root
 foreach($f in @(Get-ChildItem -LiteralPath $root -Force)){
  if(($f.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Link in source tree refused'}
  if($f.PSIsContainer){Tree $f.FullName $kind}
  elseif($kind-eq'projects'-or$f.Name-match'^local_[A-Za-z0-9][A-Za-z0-9_-]{0,159}\.json$'-or$f.Name-match'^deleted_[0-9a-fA-F-]{36}$'-or$f.Name-eq'archived-sessions.idx'){$f}
 }
}
function Inventory([string]$sessions,[string]$projects){
 foreach($pair in @(@{Root=$sessions;Kind='sessions'},@{Root=$projects;Kind='projects'})){
  foreach($f in @(Tree $pair.Root $pair.Kind)){
   [pscustomobject]@{Source=$f.FullName;RelativePath=('data/'+$pair.Kind+'/'+$f.FullName.Substring($pair.Root.Length).TrimStart('\').Replace('\','/'));Length=$f.Length;SourceLastWriteTicks=$f.LastWriteTimeUtc.Ticks}
  }
 }
}
function CopyNew([string]$source,[string]$dest){
 Safe $source;Safe $dest;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
 $inputFile=[IO.File]::Open($source,'Open','Read',([IO.FileShare]::ReadWrite-bor[IO.FileShare]::Delete))
 try{$outputFile=[IO.File]::Open($dest,'CreateNew','Write','None');try{$inputFile.CopyTo($outputFile);$outputFile.Flush($true)}finally{$outputFile.Dispose()}}finally{$inputFile.Dispose()}
}
# Reuse the independently tested strict parser without changing that engine.
$inspectRoot=if($Mode-eq'Create'){$SessionRoot}else{$SnapshotPath}
$null=& (Join-Path $PSScriptRoot 'Sync-ClaudeSessionsSafe.ps1') -Mode Inspect -SessionRoot $inspectRoot
function Verify([string]$snapshot){
 $snapshot=Full $snapshot;Safe $snapshot
 $base=[IO.Directory]::GetParent([IO.Directory]::GetParent($snapshot).FullName).FullName
 $mp=Join-Path $snapshot 'manifest.json';$cp=Join-Path $snapshot 'COMPLETE.json'
 $null=[SafeClaudeSessions.Json]::Parse([IO.File]::ReadAllBytes($mp));$null=[SafeClaudeSessions.Json]::Parse([IO.File]::ReadAllBytes($cp))
 $manifest=[IO.File]::ReadAllText($mp)|ConvertFrom-Json;$complete=[IO.File]::ReadAllText($cp)|ConvertFrom-Json
 if($manifest.Format-cne'ClaudeHistoryDeduplicated-v1'-or$complete.Status-cne'Complete'-or(Hash $mp)-cne$complete.ManifestSHA256){throw 'Invalid or incomplete snapshot'}
 $seen=@{}
 foreach($e in @($manifest.Files)){
  $rel=[string]$e.RelativePath
  if($rel-notmatch'^data/(projects|sessions)/'-or$rel-match'(^|/)\.{1,2}(/|$)'-or$rel.Contains('\')-or$rel.Contains(':')-or$seen.ContainsKey($rel)-or$e.SHA256-notmatch'^[0-9a-f]{64}$'-or$e.Length-lt0){throw 'Unsafe manifest'}
  $seen[$rel]=$true;$blob=Join-Path $base ('blobs\'+$e.SHA256)
  Safe $blob
  if(-not[IO.File]::Exists($blob)-or([IO.FileInfo]$blob).Length-ne$e.Length-or(Hash $blob)-cne$e.SHA256){throw 'Missing or corrupt backup blob'}
 }
 if($seen.Count-eq0-or$seen.Count-ne$manifest.FileCount){throw 'Invalid snapshot count'}
 [pscustomobject]@{Manifest=$manifest;Base=$base;Snapshot=$snapshot}
}
if($Mode-ne'Create'){
 $v=Verify $SnapshotPath
 if($Mode-eq'RestoreCopy'){
  $dest=Full $RestoreDestination;Safe $dest
  if((Test-Path -LiteralPath $dest)-or(Within $dest $v.Base)){throw 'Restore requires a new folder outside the backup'}
  [void][IO.Directory]::CreateDirectory($dest)
  foreach($e in $v.Manifest.Files){
   $target=Full (Join-Path $dest $e.RelativePath.Replace('/','\'))
   if(-not(Within $target $dest)){throw 'Restore path escapes destination'}
   CopyNew (Join-Path $v.Base ('blobs\'+$e.SHA256)) $target
   if((Hash $target)-cne$e.SHA256){throw 'Restore hash mismatch'}
  }
 }
 return [pscustomobject]@{Mode=$Mode;Verified=$true;Files=$v.Manifest.FileCount;SnapshotPath=$v.Snapshot;RestoreDestination=$RestoreDestination}
}
$sessions=Full $SessionRoot;$projects=Full $TranscriptRoot;$backup=Full $BackupRoot
Safe $sessions;Safe $projects;Safe $backup;Closed
if(-not[IO.Directory]::Exists($sessions)-or-not[IO.Directory]::Exists($projects)){throw 'Source folders must exist'}
if((Within $backup ([IO.Directory]::GetParent($sessions).FullName))-or(Within $backup ([IO.Directory]::GetParent($projects).FullName))){throw 'Backup must be outside Claude data'}
[void][IO.Directory]::CreateDirectory($backup);Safe $backup
$lock=$null
try{
 $lock=[IO.File]::Open((Join-Path $backup '.archive.lock'),'OpenOrCreate','ReadWrite','None')
 $snapshot=Join-Path $backup ('snapshots\history-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
 [void][IO.Directory]::CreateDirectory($snapshot);[void][IO.Directory]::CreateDirectory((Join-Path $backup 'blobs'))
 $sources=@(Inventory $sessions $projects);$entries=New-Object System.Collections.Generic.List[object];$newBytes=[long]0
 foreach($source in $sources){
  Closed;$hash=Hash $source.Source;$blob=Join-Path $backup ('blobs\'+$hash);Safe $blob
  if([IO.File]::Exists($blob)){
   if(([IO.FileInfo]$blob).Length-ne$source.Length-or(Hash $blob)-cne$hash){throw 'Existing blob corrupt; not replaced'}
  }else{
   $free=([IO.DriveInfo]::new([IO.Path]::GetPathRoot($backup))).AvailableFreeSpace
   if($free-lt($source.Length+1073741824)){throw 'Insufficient free space; retain 1 GiB reserve'}
   $stage=Join-Path $snapshot ('pending-'+[guid]::NewGuid().ToString('N'));CopyNew $source.Source $stage
   if(([IO.FileInfo]$stage).Length-ne$source.Length-or(Hash $stage)-cne$hash){throw 'Source changed during copy'}
   Closed;[IO.File]::Move($stage,$blob);$newBytes+=$source.Length
  }
  $now=Get-Item -LiteralPath $source.Source -Force
  if($now.Length-ne$source.Length-or$now.LastWriteTimeUtc.Ticks-ne$source.SourceLastWriteTicks){throw 'Source changed during archive'}
  $entries.Add([pscustomobject]@{RelativePath=$source.RelativePath;Length=$source.Length;SourceLastWriteTicks=$source.SourceLastWriteTicks;SHA256=$hash})
 }
 # Re-read sources, then re-enumerate before claiming a complete recovery point.
 for($i=0;$i-lt$sources.Count;$i++){Closed;if((Hash $sources[$i].Source)-cne$entries[$i].SHA256){throw 'Source changed during final check'}}
 $final=@(Inventory $sessions $projects)
 if(@(Compare-Object @($sources|ForEach-Object Source|Sort-Object) @($final|ForEach-Object Source|Sort-Object)).Count-ne0){throw 'Inventory changed during archive'}
 Closed
 $manifest=[ordered]@{Format='ClaudeHistoryDeduplicated-v1';CreatedUtc=[DateTime]::UtcNow.ToString('o');FileCount=$entries.Count;Files=@($entries.ToArray())}
 $mp=Join-Path $snapshot 'manifest.json';WriteNew $mp $manifest
 WriteNew (Join-Path $snapshot 'COMPLETE.json') @{Status='Complete';ManifestSHA256=(Hash $mp)}
 $verified=Verify $snapshot;Closed
 [pscustomobject]@{Mode='Create';Verified=$true;Files=$verified.Manifest.FileCount;SnapshotPath=$snapshot;NewBytes=$newBytes;OriginalProfileModified=$false}
}finally{if($lock){$lock.Dispose()}}
