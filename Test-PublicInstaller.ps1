param([Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference='Stop'
$area=Join-Path $WorkRoot ('i-'+[guid]::NewGuid().ToString('N').Substring(0,8));[void][IO.Directory]::CreateDirectory($area)
$installer=Join-Path $PSScriptRoot 'Install-ClaudeHistoryAutomatic.ps1';$control=Join-Path $PSScriptRoot 'Control-ClaudeHistoryAutomatic.ps1'
$tests=New-Object System.Collections.Generic.List[object]
function Check($v,$m){if(-not$v){throw $m}}
function Refuses([scriptblock]$body){$failed=$false;try{&$body|Out-Null}catch{$failed=$true};Check $failed 'Expected refusal'}
function Case($n,[scriptblock]$body){try{&$body;$tests.Add([pscustomobject]@{Name=$n;Passed=$true;Detail=''})}catch{$tests.Add([pscustomobject]@{Name=$n;Passed=$false;Detail=$_.Exception.Message})}}
function Fixture {
 $base=Join-Path $area ([guid]::NewGuid().ToString('N').Substring(0,8));$sessions=Join-Path $base 'Claude\sessions';$projects=Join-Path $base '.claude\projects';$scopes=@();$paths=@()
 for($i=0;$i-lt2;$i++){$s=[guid]::NewGuid().ToString('D')+'/'+[guid]::NewGuid().ToString('D');$scopes+=$s;$paths+=Join-Path $sessions $s.Replace('/','\');[void][IO.Directory]::CreateDirectory($paths[-1])}
 [void][IO.Directory]::CreateDirectory((Join-Path $projects 'p'))
 $id=[guid]::NewGuid().ToString('D');$file=Join-Path $paths[0] ('local_'+$id+'.json');[IO.File]::WriteAllText($file,(@{sessionId=('local_'+$id);cliSessionId=$id;cwd=$base;title='synthetic conversation'}|ConvertTo-Json -Compress));[IO.File]::WriteAllText((Join-Path $projects ('p\'+$id+'.jsonl')),'synthetic transcript')
 $evidence=Join-Path $base 'evidence.json';$hashes=@{};foreach($name in @('Sync-ClaudeSessionsSafe.ps1','Sync-ClaudeSessionsAutomatic.ps1','Archive-ClaudeHistoryIncremental.ps1','ClaudeHistoryAutomatic.ps1')){$hashes[$name]=(Get-FileHash (Join-Path $PSScriptRoot $name)).Hash}
 @{Format='ClaudeAutomaticTestEvidence-v1';AllPassed=$true;ScriptSHA256=$hashes}|ConvertTo-Json -Depth 6|Set-Content $evidence -Encoding utf8
 [pscustomobject]@{Base=$base;File=$file;Scopes=$scopes;Parameters=@{SessionRoot=$sessions;TranscriptRoot=$projects;Scopes=$scopes;BackupRoot=(Join-Path $base 'backups');InstallRoot=(Join-Path $base 'install');EvidencePath=$evidence;SkipShortcuts=$true;DoNotStartWorker=$true}}
}
Case 'Preview creates neither runtime nor shortcuts and excludes existing names' {$f=Fixture;$p=$f.Parameters;$r=&$installer -Mode Preview @p;Check ($r.BaselineConversations-eq1-and$r.PlannedRetroactiveCopies-eq0-and-not(Test-Path $p.InstallRoot)) 'Preview wrote data'}
Case 'Headless staged installation uses only new fixture files and preserves original' {$f=Fixture;$p=$f.Parameters;$hash=(Get-FileHash $f.File).Hash;$ticks=[IO.File]::GetLastWriteTimeUtc($f.File).Ticks;$r=&$installer -Mode Install @p;Check ((Test-Path (Join-Path $p.InstallRoot 'installation.json'))-and-not$r.WorkerPID-and-not$r.StartupShortcut) 'Headless install failed';Check ((Get-FileHash $f.File).Hash-ceq$hash-and[IO.File]::GetLastWriteTimeUtc($f.File).Ticks-eq$ticks) 'Source changed'}
Case 'Repeated installation refuses to replace an existing record' {$f=Fixture;$p=$f.Parameters;$r=&$installer -Mode Install @p;$record=Join-Path $p.InstallRoot 'installation.json';$hash=(Get-FileHash $record).Hash;Refuses {&$installer -Mode Install @p};Check ((Get-FileHash $record).Hash-ceq$hash) 'Record replaced'}
Case 'Installer rejects a runtime inside Claude data' {$f=Fixture;$p=$f.Parameters;$p.InstallRoot=Join-Path $p.SessionRoot 'unsafe';Refuses {&$installer -Mode Install @p};Check (-not(Test-Path $p.InstallRoot)) 'Unsafe runtime created'}
Case 'Installer rejects a backup inside Claude data' {$f=Fixture;$p=$f.Parameters;$p.BackupRoot=Join-Path $p.TranscriptRoot 'unsafe';Refuses {&$installer -Mode Install @p};Check (-not(Test-Path $p.InstallRoot)) 'Runtime created before validation'}
Case 'Installer refuses modified code pins before creating a runtime' {$f=Fixture;$p=$f.Parameters;$e=Get-Content $p.EvidencePath -Raw|ConvertFrom-Json;$e.ScriptSHA256.'ClaudeHistoryAutomatic.ps1'=('0'*64);$e|ConvertTo-Json -Depth 6|Set-Content $p.EvidencePath -Encoding utf8;Refuses {&$installer -Mode Install @p};Check (-not(Test-Path $p.InstallRoot)) 'Integrity failure created runtime'}
Case 'Private control record supports pause resume and status without profiles' {$f=Fixture;$p=$f.Parameters;$r=&$installer -Mode Install @p;$record=Join-Path $p.InstallRoot 'installation.json';$null=&$control -InstallationPath $record -Mode Pause;Check (Test-Path (Join-Path $r.State 'PAUSE')) 'Pause missing';$status=(&$control -InstallationPath $record -Mode Status)|ConvertFrom-Json;Check $status.Paused 'Status missed pause';$null=&$control -InstallationPath $record -Mode Resume;Check (-not(Test-Path (Join-Path $r.State 'PAUSE'))) 'Resume failed'}
Case 'Caller can explicitly include preexisting sessions instead of excluding the baseline' {$f=Fixture;$p=$f.Parameters;$p.BaselineFileNames=@('local_synthetic-exclusion.json');$r=&$installer -Mode Preview @p;Check ($r.PlannedRetroactiveCopies-eq1) 'Explicit baseline ignored'}
$result=[pscustomobject]@{Runtime=$PSVersionTable.PSVersion.ToString();Passed=@($tests|Where-Object Passed).Count;Failed=@($tests|Where-Object {-not $_.Passed}).Count;Tests=$tests.ToArray()}
$result|ConvertTo-Json -Depth 6
if($result.Failed-ne0){exit 1}
