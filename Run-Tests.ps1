[CmdletBinding()]
param(
 [ValidateSet('Quick','Full')][string]$Tier='Quick',
 [ValidateRange(1,10000)][int]$RandomTrials=100,
 [string]$WorkRoot=(Join-Path ([IO.Path]::GetTempPath()) ('chg-'+[guid]::NewGuid().ToString('N').Substring(0,8))),
 [string]$EvidencePath=(Join-Path $PSScriptRoot 'artifacts\test-evidence.json')
)
$ErrorActionPreference='Stop'
if(-not[IO.Path]::IsPathRooted($WorkRoot)){throw 'WorkRoot must be absolute'}
[void][IO.Directory]::CreateDirectory($WorkRoot)
$suites=@('Test-ClaudeSessionsSafe.ps1','Test-AutomaticEngineRegression.ps1','Test-BackupRecovery.ps1','Test-ClaudeHistoryAutomatic.ps1','Test-AutomaticWatcher.ps1')
if($PSVersionTable.PSVersion.Major-ge7){$suites+=@('Test-PublicInstaller.ps1')}
if($Tier-eq'Full'){$suites+=@('Test-ConcurrentRuns.ps1','Test-AutomaticConcurrentRuns.ps1','Test-InterruptedSync.ps1','Test-AutomaticInterruptedSync.ps1')}
$summaries=New-Object System.Collections.Generic.List[object]
foreach($suite in $suites){
 Write-Host ('Testing '+$suite+' ...')
 $parameters=@{WorkRoot=$WorkRoot}
 if($suite-match'EngineRegression|ClaudeSessionsSafe'){$parameters.RandomTrials=$(if($Tier-eq'Full'){$RandomTrials}else{10})}
 $global:LASTEXITCODE=0
 $raw=&(Join-Path $PSScriptRoot $suite) @parameters
 if($LASTEXITCODE-ne0){throw ('Suite failed: '+$suite)}
 $report=($raw-join"`n")|ConvertFrom-Json
 $failed=0;$passed=0
 if($null-ne$report.FailedCases){$failed=[int]$report.FailedCases;$passed=[int]$report.PassedCases}
 elseif($null-ne$report.Failed){$failed=[int]$report.Failed;$passed=[int]$report.Passed}
 elseif($report.Passed-eq$true){$passed=1}else{throw ('Unrecognized report: '+$suite)}
 if($failed-ne0-or$passed-lt1){throw ('Failed assertions in '+$suite)}
 $summaries.Add([pscustomobject]@{Suite=$suite;Passed=$passed;Failed=$failed})
 Write-Host ('PASS: '+$passed+' checks')
}
$global:LASTEXITCODE=0
& node (Join-Path $PSScriptRoot 'tools\check-public-tree.cjs')
if($LASTEXITCODE-ne0){throw 'Public tree audit failed'}
$hashes=@{};foreach($name in @('Sync-ClaudeSessionsSafe.ps1','Sync-ClaudeSessionsAutomatic.ps1','Archive-ClaudeHistoryIncremental.ps1','ClaudeHistoryAutomatic.ps1')){$hashes[$name]=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash}
$evidence=[ordered]@{Format='ClaudeAutomaticTestEvidence-v1';AllPassed=$true;Runtime=$PSVersionTable.PSVersion.ToString();Tier=$Tier;ScriptSHA256=$hashes;Suites=$summaries.ToArray()}
$dest=[IO.Path]::GetFullPath($EvidencePath);[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
[IO.File]::WriteAllText($dest,($evidence|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
Write-Host 'All fixture suites passed. Local evidence generated; do not commit artifacts.'
