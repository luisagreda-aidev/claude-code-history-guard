[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$WorkRoot)
$ErrorActionPreference = 'Stop'
if (-not [IO.Path]::IsPathRooted($WorkRoot)) { throw 'WorkRoot must be absolute.' }
$base = Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('c-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$root = Join-Path $base 'Claude\claude-code-sessions'
$tr = Join-Path $base '.claude\projects'
$scopes = @(); $paths = @(); $before = @{}
for ($acct = 0; $acct -lt 2; $acct++) {
    $scope = [guid]::NewGuid().ToString('D') + '/' + [guid]::NewGuid().ToString('D')
    $scopes += $scope; $dir = Join-Path $root $scope.Replace('/', '\'); $paths += $dir
    [void][IO.Directory]::CreateDirectory($dir)
    [void][IO.Directory]::CreateDirectory((Join-Path $tr 'p'))
    for ($i = 0; $i -lt 40; $i++) {
        $id = [guid]::NewGuid().ToString('D')
        $record = @{ sessionId = 'local_' + $id; cliSessionId = $id; cwd = $base; title = 'fixture-' + $acct + '-' + $i }
        $p = Join-Path $dir ('local_' + $id + '.json')
        [IO.File]::WriteAllText($p, ($record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $tr ('p\' + $id + '.jsonl')), '{"type":"fixture"}')
        $before[$p] = @{ Hash = (Get-FileHash $p).Hash; Ticks = [IO.File]::GetLastWriteTimeUtc($p).Ticks }
    }
}
$runner = Join-Path $base 'worker.ps1'
$runnerText = @'
param($Engine, $Root, $ScopeA, $ScopeB, $Transcripts, $Backup, $Result)
$ErrorActionPreference = 'Stop'
# Isolated test inventory, no modification to the production app guard.
function Get-Process { param($Name, $ErrorAction); return }
try {
    $r = & $Engine -Mode Apply -SessionRoot $Root -Scopes @($ScopeA, $ScopeB) -TranscriptRoot $Transcripts -BackupRoot $Backup -Confirm:$false
    [IO.File]::WriteAllText($Result, ($r | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
} catch { [IO.File]::WriteAllText($Result, ('{"error":' + ($_.Exception.Message | ConvertTo-Json -Compress) + '}')); exit 1 }
'@
[IO.File]::WriteAllText($runner, $runnerText, [Text.UTF8Encoding]::new($false))
$exe = if ([IO.File]::Exists((Join-Path $PSHOME 'pwsh.exe'))) { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
$engine = Join-Path $PSScriptRoot 'Sync-ClaudeSessionsSafe.ps1'
$workers = @()
for ($i = 0; $i -lt 4; $i++) {
    $result = Join-Path $base ('worker-' + $i + '.json')
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $runner + '"'), '-Engine', ('"' + $engine + '"'), '-Root', ('"' + $root + '"'), '-ScopeA', $scopes[0], '-ScopeB', $scopes[1], '-Transcripts', ('"' + $tr + '"'), '-Backup', ('"' + (Join-Path $base ('backup-' + $i)) + '"'), '-Result', ('"' + $result + '"'))
    $proc = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $workers += [pscustomobject]@{ Process = $proc; Result = $result }
}
$results = @()
foreach ($worker in $workers) {
    if (-not $worker.Process.WaitForExit(45000)) { throw 'Fixture worker timed out.' }
    $results += Get-Content -LiteralPath $worker.Result -Raw | ConvertFrom-Json
    if ($worker.Process.ExitCode -ne 0) { throw ('Fixture worker failed: ' + $results[-1].error) }
}
foreach ($path in $before.Keys) {
    if (-not [IO.File]::Exists($path) -or (Get-FileHash $path).Hash -cne $before[$path].Hash -or [IO.File]::GetLastWriteTimeUtc($path).Ticks -ne $before[$path].Ticks) { throw 'Original session changed in concurrency test.' }
}
foreach ($dir in $paths) {
    if (@(Get-ChildItem -LiteralPath $dir -File -Filter 'local_*.json').Count -ne 80) { throw 'Incomplete concurrent union.' }
    foreach ($original in $before.Keys) {
        $dest = Join-Path $dir ([IO.Path]::GetFileName($original))
        if ((Get-FileHash $dest).Hash -cne $before[$original].Hash) { throw 'Copied bytes differ.' }
    }
}
$adds = ($results | Measure-Object -Property AddedCount -Sum).Sum
if ($adds -ne 80) { throw 'Duplicate or missing publication count.' }
[pscustomobject]@{
    Runtime = $PSVersionTable.PSVersion.ToString(); Passed = $true; Workers = 4; OriginalSessions = 80
    PublishedSessions = $adds; OriginalsChanged = 0; OriginalDatesChanged = 0
    ConcurrentSkips = ($results | ForEach-Object { @($_.ConcurrentSkips).Count } | Measure-Object -Sum).Sum
    FixtureDirectory = $base
} | ConvertTo-Json -Depth 5
