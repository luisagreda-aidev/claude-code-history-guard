# Independent history snapshot and restore-to-a-new-folder. Never restores into
# a live profile. No overwrite, deletion, scheduler, config or group operations.
[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Create', 'Verify', 'RestoreCopy')][string]$Mode = 'Preview',
    [string]$SessionRoot,
    [string]$TranscriptRoot = (Join-Path $env:USERPROFILE '.claude\projects'),
    [string]$BackupRoot,
    [string]$SnapshotPath,
    [string]$RestoreDestination
)
$ErrorActionPreference = 'Stop'
function Full([string]$p) {
    if (-not $p -or $p -notmatch '^[A-Za-z]:\\' -or $p.Substring(2).Contains(':')) { throw 'Absolute local drive path required.' }
    return [IO.Path]::GetFullPath($p).TrimEnd('\')
}
function Within([string]$child, [string]$parent) { $child.Equals($parent,[StringComparison]::OrdinalIgnoreCase) -or $child.StartsWith($parent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) }
function NoLinks([string]$p) {
    $cursor = Full $p
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Links and junctions are not supported.' }
        }
        $parent=[IO.Directory]::GetParent($cursor); $cursor=if($parent){$parent.FullName}else{$null}
    }
}
function Hash([string]$p) {
    $f=[IO.File]::Open($p,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)); $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($f))).Replace('-','').ToLowerInvariant() } finally {$f.Dispose();$sha.Dispose()}
}
function NewBytes([string]$p,[byte[]]$bytes) {
    $f=[IO.File]::Open($p,'CreateNew','Write','None')
    try {$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
}
function CopyNew([string]$source,[string]$dest) {
    NoLinks $source; NoLinks $dest
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
    $inputStream=[IO.File]::Open($source,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $outputStream=[IO.File]::Open($dest,'CreateNew','Write','None')
        try {$inputStream.CopyTo($outputStream);$outputStream.Flush($true)}finally{$outputStream.Dispose()}
    }finally{$inputStream.Dispose()}
}
function ListTree([string]$root,[string]$kind) {
    NoLinks $root
    foreach($item in @(Get-ChildItem -LiteralPath $root -Force)) {
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-ne0){throw 'Source contains a link; snapshot refused.'}
        if($item.PSIsContainer){ListTree $item.FullName $kind}
        elseif($kind -eq 'projects' -or $item.Name -match '^local_[A-Za-z0-9][A-Za-z0-9_-]{0,159}\.json$' -or $item.Name -match '^deleted_[0-9a-fA-F-]{36}$' -or $item.Name -eq 'archived-sessions.idx') { $item }
    }
}
function AppRunning {
    foreach($p in @(Get-Process -Name Claude -ErrorAction SilentlyContinue)) {
        $path=$null;try{$path=$p.Path}catch{}
        if(-not $path -or $path -notmatch '\\claude-code\\'){return $true}
    };return $false
}
function VerifySnapshot([string]$snapshot) {
    $snapshot=Full $snapshot;NoLinks $snapshot
    $manifestPath=Join-Path $snapshot 'manifest.json';$completePath=Join-Path $snapshot 'COMPLETE.json'
    if(-not [IO.File]::Exists($manifestPath) -or -not [IO.File]::Exists($completePath)){throw 'Incomplete snapshot: completion marker or manifest absent.'}
    # The strict reader from the sibling engine validates manifests before use.
    $null=& (Join-Path $PSScriptRoot 'Sync-ClaudeSessionsSafe.ps1') -Mode Inspect -SessionRoot $snapshot
    $null=[SafeClaudeSessions.Json]::Parse([IO.File]::ReadAllBytes($manifestPath))
    $null=[SafeClaudeSessions.Json]::Parse([IO.File]::ReadAllBytes($completePath))
    $manifest=[IO.File]::ReadAllText($manifestPath)|ConvertFrom-Json
    $complete=[IO.File]::ReadAllText($completePath)|ConvertFrom-Json
    if($complete.Status -cne 'Complete' -or (Hash $manifestPath) -cne $complete.ManifestSHA256 -or $manifest.Format -cne 'ClaudeHistorySnapshot-v1'){throw 'Manifest or completion marker invalid.'}
    $seen=@{};$verified=New-Object System.Collections.Generic.List[object]
    foreach($entry in @($manifest.Files)) {
        $rel=[string]$entry.RelativePath
        if($rel -notmatch '^data/(projects|sessions)/' -or $rel -match '(^|/)\.\.?(/|$)' -or $rel.Contains('\') -or $rel.Contains(':') -or $seen.ContainsKey($rel) -or $entry.SHA256 -notmatch '^[0-9a-f]{64}$'){throw 'Unsafe or duplicate manifest entry.'}
        $seen[$rel]=$true;$file=Full (Join-Path $snapshot ($rel.Replace('/','\')))
        if(-not (Within $file $snapshot)){throw 'Manifest escapes snapshot.'};NoLinks $file
        if(-not [IO.File]::Exists($file) -or ([IO.FileInfo]$file).Length -ne $entry.Length -or (Hash $file) -cne $entry.SHA256){throw 'Snapshot verification failed: missing or corrupted file.'}
        $verified.Add($entry)
    }
    if($verified.Count -eq 0 -or $verified.Count -ne $manifest.FileCount){throw 'Empty or inconsistent snapshot.'}
    return [pscustomobject]@{Snapshot=$snapshot;Files=@($verified.ToArray());FileCount=$verified.Count;Bytes=($verified.ToArray()|Measure-Object Length -Sum).Sum}
}

if($Mode -eq 'Verify' -or $Mode -eq 'RestoreCopy') {
    $verified=VerifySnapshot $SnapshotPath
    if($Mode -eq 'Verify'){return [pscustomobject]@{Mode='Verify';Verified=$true;Files=$verified.FileCount;Bytes=$verified.Bytes;SnapshotPath=$verified.Snapshot}}
    $dest=Full $RestoreDestination;NoLinks $dest
    if([IO.Directory]::Exists($dest) -or [IO.File]::Exists($dest) -or (Within $dest $verified.Snapshot)){throw 'RestoreDestination must be a new folder outside the snapshot.'}
    [void][IO.Directory]::CreateDirectory($dest)
    foreach($entry in $verified.Files) {
        $source=Join-Path $verified.Snapshot $entry.RelativePath.Replace('/','\')
        $target=Join-Path $dest $entry.RelativePath.Replace('/','\')
        CopyNew $source $target
        if((Hash $target) -cne $entry.SHA256){throw 'Restore verification failed.'}
    }
    return [pscustomobject]@{Mode='RestoreCopy';Verified=$true;Files=$verified.FileCount;Bytes=$verified.Bytes;RestoreDestination=$dest;OriginalProfileModified=$false}
}
$sessions=Full $SessionRoot;$projects=Full $TranscriptRoot
if(-not [IO.Directory]::Exists($sessions) -or -not [IO.Directory]::Exists($projects)){throw 'Both source directories must exist.'}
NoLinks $sessions;NoLinks $projects
$sources=@()
foreach($pair in @(@{Root=$sessions;Kind='sessions'},@{Root=$projects;Kind='projects'})) {
    foreach($file in @(ListTree $pair.Root $pair.Kind)) {
        $relative=$file.FullName.Substring($pair.Root.Length).TrimStart('\').Replace('\','/')
        $sources += [pscustomobject]@{Source=$file.FullName;RelativePath=('data/'+$pair.Kind+'/'+$relative);Length=$file.Length;LastWriteTicks=$file.LastWriteTimeUtc.Ticks}
    }
}
if($Mode -eq 'Preview'){return [pscustomobject]@{Mode='Preview';Files=$sources.Count;Bytes=($sources|Measure-Object Length -Sum).Sum;AppRunning=(AppRunning);Writes=0}}
if(AppRunning){throw 'Close Claude Desktop completely before creating a definitive history snapshot. Nothing was copied.'}
$backup=Full $BackupRoot;NoLinks $backup
if((Within $backup ([IO.Directory]::GetParent($sessions).FullName)) -or (Within $backup ([IO.Directory]::GetParent($projects).FullName))){throw 'Backup must be outside Claude data.'}
$snapshot=Join-Path $backup ('history-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($snapshot);$entries=New-Object System.Collections.Generic.List[object]
foreach($source in $sources) {
    if(AppRunning){throw 'Claude Desktop restarted; snapshot is incomplete and must not be used.'}
    $target=Join-Path $snapshot $source.RelativePath.Replace('/','\');CopyNew $source.Source $target
    $hash=Hash $target;$current=Get-Item -LiteralPath $source.Source -Force
    if($current.Length -ne $source.Length -or $current.LastWriteTimeUtc.Ticks -ne $source.LastWriteTicks -or (Hash $source.Source) -cne $hash){throw 'Source changed while copying; snapshot is incomplete.'}
    $entries.Add([pscustomobject]@{RelativePath=$source.RelativePath;Length=$source.Length;SHA256=$hash;SourceLastWriteTicks=$source.LastWriteTicks})
}
# Re-read every source and re-enumerate before marking a snapshot complete.
for($n=0;$n -lt $sources.Count;$n++) {
    if((Hash $sources[$n].Source) -cne $entries[$n].SHA256){throw 'Source changed during final verification; snapshot is incomplete.'}
}
$finalFiles=@(ListTree $sessions 'sessions')+@(ListTree $projects 'projects')
$finalPaths=@($finalFiles | Select-Object -ExpandProperty FullName | Sort-Object)
$initialPaths=@($sources|Select-Object -ExpandProperty Source|Sort-Object)
if(@(Compare-Object $initialPaths $finalPaths).Count -gt 0 -or (AppRunning)){throw 'Source inventory or app state changed; snapshot is incomplete.'}
$manifest=[ordered]@{Format='ClaudeHistorySnapshot-v1';CreatedUtc=[DateTime]::UtcNow.ToString('o');FileCount=$entries.Count;Files=@($entries.ToArray())}
$utf8=[Text.UTF8Encoding]::new($false);$manifestPath=Join-Path $snapshot 'manifest.json'
NewBytes $manifestPath $utf8.GetBytes(($manifest|ConvertTo-Json -Depth 6))
$complete=@{Status='Complete';ManifestSHA256=(Hash $manifestPath)}
NewBytes (Join-Path $snapshot 'COMPLETE.json') $utf8.GetBytes(($complete|ConvertTo-Json -Compress))
$verified=VerifySnapshot $snapshot
[pscustomobject]@{Mode='Create';Verified=$true;Files=$verified.FileCount;Bytes=$verified.Bytes;SnapshotPath=$snapshot;OriginalProfileModified=$false}
