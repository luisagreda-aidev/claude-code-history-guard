[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference='Stop'
$engine=Join-Path $PSScriptRoot 'Sync-ClaudeSessionsAutomatic.ps1'
$backupTool=Join-Path $PSScriptRoot 'Backup-ClaudeHistorySafe.ps1'
$source=[IO.File]::ReadAllText($engine)
$area=Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('k-'+[guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($area)
$exe=if([IO.File]::Exists((Join-Path $PSHOME 'pwsh.exe'))){Join-Path $PSHOME 'pwsh.exe'}else{Join-Path $PSHOME 'powershell.exe'}
$results=New-Object System.Collections.Generic.List[object]
function Check($v,$m){if(-not $v){throw $m}}
function Case([string]$name,[scriptblock]$body){try{& $body;$results.Add([pscustomobject]@{Name=$name;Passed=$true;Detail=''})}catch{$results.Add([pscustomobject]@{Name=$name;Passed=$false;Detail=$_.Exception.Message})}}
function Fixture {
    $base=Join-Path $area ([guid]::NewGuid().ToString('N').Substring(0,8));$root=Join-Path $base 'Claude\claude-code-sessions';$tr=Join-Path $base '.claude\projects'
    $scopes=@();$paths=@();$before=@{};$all=@{}
    [void][IO.Directory]::CreateDirectory((Join-Path $tr 'project'))
    for($acct=0;$acct -lt 2;$acct++){
        $scope=[guid]::NewGuid().ToString('D')+'/'+[guid]::NewGuid().ToString('D');$scopes+=$scope
        $path=Join-Path $root $scope.Replace('/','\');$paths+=$path;[void][IO.Directory]::CreateDirectory($path)
        for($j=0;$j -lt 3;$j++){
            $id=[guid]::NewGuid().ToString('D');$file=Join-Path $path ('local_'+$id+'.json')
            $doc=@{sessionId='local_'+$id;cliSessionId=$id;cwd=$base;title='fixture-'+$acct+'-'+$j}
            [IO.File]::WriteAllText($file,($doc|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
            $all[[IO.Path]::GetFileName($file)]=(Get-FileHash $file).Hash
            [IO.File]::WriteAllText((Join-Path $tr ('project\'+$id+'.jsonl')),'{"type":"fixture","message":"preserve entire conversation"}')
        }
        [IO.File]::WriteAllText((Join-Path $path 'scheduled-tasks.json'),'untouched tasks')
    }
    foreach($file in @(Get-ChildItem $root,$tr -Recurse -File)){$before[$file.FullName]=@{Hash=(Get-FileHash $file.FullName).Hash;Ticks=$file.LastWriteTimeUtc.Ticks}}
    return [pscustomobject]@{Base=$base;Root=$root;Transcripts=$tr;Scopes=$scopes;Paths=$paths;Before=$before;All=$all;Backup=(Join-Path $base 'backups')}
}
function OriginalsPreserved($f){foreach($p in $f.Before.Keys){Check ([IO.File]::Exists($p)) 'Original missing';Check ((Get-FileHash $p).Hash -ceq $f.Before[$p].Hash) 'Original content changed';Check ([IO.File]::GetLastWriteTimeUtc($p).Ticks -eq $f.Before[$p].Ticks) 'Original timestamp changed'}}
function NoPartialFiles($f){foreach($dir in $f.Paths){foreach($p in @(Get-ChildItem $dir -File -Filter 'local_*.json')){Check ($f.All.ContainsKey($p.Name)) 'Unknown session published';Check ((Get-FileHash $p.FullName).Hash -ceq $f.All[$p.Name]) 'Partial or damaged session published'}}}
function InvokeOriginal($f){& $engine -Mode Apply -SessionRoot $f.Root -Scopes $f.Scopes -TranscriptRoot $f.Transcripts -BackupRoot $f.Backup -Confirm:$false}
# Parent tests use a fixture process inventory only. The production guard stays intact.
function Get-Process {param($Name,$ErrorAction);return}
$anchors=[ordered]@{
    AfterPlan='$runDir = $null; $guard = $null'
    AfterManifest="[SafeClaudeSessions.Json]::WriteNew((Join-Path `$runDir 'manifest.json'), `$manifestBytes)"
    AfterFirstBackup='[SafeClaudeSessions.Json]::WriteNew($saved, $first.Bytes)'
    AfterFirstStage='[SafeClaudeSessions.Json]::WriteNew($stage, $plan.Bytes)'
    AfterFirstPublish='[IO.File]::Move($stage, $plan.Destination)'
}
function FaultWorker($f,[string]$checkpoint,[string]$action) {
    $anchor=$anchors[$checkpoint]
    Check ($source.Split([string[]]@($anchor),[StringSplitOptions]::None).Length -eq 2) 'Fault anchor must be unique'
    $injection=switch($action){
        'Kill' {"[IO.File]::WriteAllText(`$env:SAFE_SYNC_FIXTURE_MARKER,'ready'); while(`$true){Start-Sleep -Milliseconds 50}"}
        'DiskError' {"[IO.File]::WriteAllText(`$env:SAFE_SYNC_FIXTURE_MARKER,'ready'); throw [IO.IOException]::new('Injected fixture I/O failure')"}
        'Denied' {"[IO.File]::WriteAllText(`$env:SAFE_SYNC_FIXTURE_MARKER,'ready'); throw [UnauthorizedAccessException]::new('Injected fixture access failure')"}
        'ReopenApp' {"[IO.File]::WriteAllText(`$env:SAFE_SYNC_FIXTURE_MARKER,'ready'); `$global:FixtureAppReopened=`$true"}
    }
    $instrumented=Join-Path $f.Base 'instrumented.ps1'
    [IO.File]::WriteAllText($instrumented,$source.Replace($anchor,($anchor+"`n"+$injection)),[Text.UTF8Encoding]::new($false))
    $runner=Join-Path $f.Base 'worker.ps1';$marker=Join-Path $f.Base 'checkpoint.txt';$result=Join-Path $f.Base 'worker-result.json'
    $runnerText=@'
param($Engine,$Root,$A,$B,$Transcripts,$Backup,$Marker,$Result)
$ErrorActionPreference='Stop';$env:SAFE_SYNC_FIXTURE_MARKER=$Marker;$global:FixtureAppReopened=$false
function Get-Process {param($Name,$ErrorAction);if($global:FixtureAppReopened){[pscustomobject]@{Path='C:\fixture\Claude.exe'}}}
try{$r=& $Engine -Mode Apply -SessionRoot $Root -Scopes @($A,$B) -TranscriptRoot $Transcripts -BackupRoot $Backup -Confirm:$false;[IO.File]::WriteAllText($Result,($r|ConvertTo-Json -Depth 6))}
catch{[IO.File]::WriteAllText($Result,('ERROR: '+$_.Exception.Message));exit 1}
'@
    [IO.File]::WriteAllText($runner,$runnerText,[Text.UTF8Encoding]::new($false))
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$runner+'"'),'-Engine',('"'+$instrumented+'"'),'-Root',('"'+$f.Root+'"'),'-A',$f.Scopes[0],'-B',$f.Scopes[1],'-Transcripts',('"'+$f.Transcripts+'"'),'-Backup',('"'+$f.Backup+'"'),'-Marker',('"'+$marker+'"'),'-Result',('"'+$result+'"'))
    $proc=Start-Process -FilePath $exe -ArgumentList $args -PassThru -WindowStyle Hidden
    try{
        if($action -eq 'Kill'){
            $deadline=[DateTime]::UtcNow.AddSeconds(25)
            while(-not [IO.File]::Exists($marker) -and -not $proc.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 30}
            Check ([IO.File]::Exists($marker)) 'Worker did not reach the checkpoint'
            Stop-Process -Id $proc.Id -Force;$proc.WaitForExit()
        }else{
            Check ($proc.WaitForExit(25000)) 'Worker timed out'
            # Once Move has committed, an IOException is conservatively treated by
            # the engine as an already-created destination. This may exit normally;
            # byte/hash preservation below is the safety criterion.
            if(-not ($action -eq 'DiskError' -and $checkpoint -eq 'AfterFirstPublish')){Check ($proc.ExitCode -ne 0) 'Injected failure did not stop operation'}
            Check ([IO.File]::Exists($marker)) 'Injected failure checkpoint was never reached'
        }
    }finally{if(-not $proc.HasExited){Stop-Process -Id $proc.Id -Force;$proc.WaitForExit()}}
}
foreach($checkpoint in $anchors.Keys){
    foreach($fault in @('Kill','DiskError')){
        $point=$checkpoint;$kind=$fault
        Case ($kind+' at '+$point+': originals survive, no partial publication, rerun completes') {
            $f=Fixture;FaultWorker $f $point $kind;OriginalsPreserved $f;NoPartialFiles $f
            $r=InvokeOriginal $f;OriginalsPreserved $f;NoPartialFiles $f
            foreach($path in $f.Paths){Check (@(Get-ChildItem $path -File -Filter 'local_*.json').Count -eq 6) 'Resume did not complete union'}
        }
    }
}
Case 'Permission error during staging preserves originals and permits a successful rerun' {
    $f=Fixture;FaultWorker $f 'AfterFirstStage' 'Denied';OriginalsPreserved $f;NoPartialFiles $f;$null=InvokeOriginal $f;OriginalsPreserved $f
}
Case 'App reopening after the first publication halts remaining writes without damaging sessions' {
    $f=Fixture;FaultWorker $f 'AfterFirstPublish' 'ReopenApp';OriginalsPreserved $f;NoPartialFiles $f
    $count=0;foreach($path in $f.Paths){$count+=@(Get-ChildItem $path -File -Filter 'local_*.json').Count};Check ($count -eq 7) 'Unexpected publication count after reopening'
    $null=InvokeOriginal $f;OriginalsPreserved $f;NoPartialFiles $f
}
Case 'Simulated scanner damage does not spread and the full backup recovers original conversations in a new folder' {
    $f=Fixture;$snapshot=& $backupTool -Mode Create -SessionRoot $f.Root -TranscriptRoot $f.Transcripts -BackupRoot (Join-Path $f.Base 'history')
    $null=InvokeOriginal $f;$victim=Get-ChildItem $f.Paths[1] -File -Filter 'local_*.json'|Select-Object -First 1
    $damaged=Get-Content $victim.FullName -Raw|ConvertFrom-Json;$damaged.PSObject.Properties.Remove('cliSessionId');$damaged|Add-Member NoteProperty transcriptUnavailable $true
    [IO.File]::WriteAllText($victim.FullName,($damaged|ConvertTo-Json -Compress));$damagedHash=(Get-FileHash $victim.FullName).Hash
    $r=InvokeOriginal $f;Check ($r.AddedCount -eq 0 -and $r.Issues.Count -gt 0) 'Scanner damage was not reported'
    Check ((Get-FileHash $victim.FullName).Hash -ceq $damagedHash) 'Damaged original was automatically replaced'
    $restored=Join-Path $f.Base 'recovered';$rr=& $backupTool -Mode RestoreCopy -SnapshotPath $snapshot.SnapshotPath -RestoreDestination $restored
    Check $rr.Verified 'Full recovery failed'
    $manifest=Get-Content (Join-Path $snapshot.SnapshotPath 'manifest.json') -Raw|ConvertFrom-Json
    foreach($entry in $manifest.Files){Check ((Get-FileHash (Join-Path $restored $entry.RelativePath)).Hash.ToLowerInvariant() -ceq $entry.SHA256) 'Recovery changed conversation bytes'}
}
$failed=@($results|Where-Object {-not $_.Passed})
[pscustomobject]@{Runtime=$PSVersionTable.PSVersion.ToString();EngineSHA256=(Get-FileHash $engine).Hash;Cases=$results.Count;Passed=$results.Count-$failed.Count;Failed=$failed.Count;Method='Checkpoint pauses or injected I/O errors in test copies, original production engine used for every retry';Tests=@($results.ToArray());FixtureRoot=$area}|ConvertTo-Json -Depth 6
if($failed.Count -gt 0){exit 1}
