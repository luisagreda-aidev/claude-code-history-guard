[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkRoot,
    [int]$RandomTrials = 150,
    [int]$Seed = 73129
)
$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot 'Sync-ClaudeSessionsSafe.ps1'
if (-not [IO.Path]::IsPathRooted($WorkRoot)) { throw 'WorkRoot must be absolute.' }
$testRoot = Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ('t-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($testRoot)
$oldAppData = $env:APPDATA; $oldLocalData = $env:LOCALAPPDATA
$env:APPDATA = Join-Path $testRoot 'appdata'; $env:LOCALAPPDATA = Join-Path $testRoot 'localdata'
$global:SafeSyncTestRunning = $false
# Only the process inventory is mocked. All file operations and parser execution
# are real. Every path passed to the engine is inside this unique fixture tree.
function Get-Process {
    param([string]$Name, $ErrorAction)
    if ($Name -eq 'Claude') {
        if ($global:SafeSyncTestRunning) { [pscustomobject]@{ Path = 'C:\fixture\Claude.exe' } }
        return
    }
    Microsoft.PowerShell.Management\Get-Process -Name $Name -ErrorAction $ErrorAction
}
$tests = New-Object System.Collections.Generic.List[object]
function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $tests.Add([pscustomobject]@{ Name = $Name; Passed = $true; Detail = '' }) }
    catch { $tests.Add([pscustomobject]@{ Name = $Name; Passed = $false; Detail = $_.Exception.Message }) }
}
function New-Fixture([int]$Accounts = 2) {
    $base = Join-Path $testRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $root = Join-Path $base 'Claude\claude-code-sessions'
    $tr = Join-Path $base '.claude\projects'
    $sc = @(); $paths = @()
    for ($n = 0; $n -lt $Accounts; $n++) {
        $scope = [guid]::NewGuid().ToString('D') + '/' + [guid]::NewGuid().ToString('D')
        $path = Join-Path $root $scope.Replace('/', '\')
        [void][IO.Directory]::CreateDirectory($path); $sc += $scope; $paths += $path
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $tr 'project'))
    [pscustomobject]@{ Base = $base; Root = $root; Transcripts = $tr; Scopes = $sc; Paths = $paths; Backup = (Join-Path $base 'backups') }
}
function New-Chat($Fixture, [int]$Account = 0, [string]$Id = ([guid]::NewGuid().ToString('D')), [string]$Title = 'Conversation', [switch]$NoTranscript, [switch]$Bom) {
    $name = 'local_' + $Id + '.json'
    $doc = [ordered]@{ sessionId = 'local_' + $Id; cliSessionId = $Id; cwd = $Fixture.Base; title = $Title; transcriptUnavailable = $false; futureField = @{ keep = @(1, $true, $null) } }
    $text = $doc | ConvertTo-Json -Depth 8 -Compress
    $path = Join-Path $Fixture.Paths[$Account] $name
    [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($Bom.IsPresent))
    if (-not $NoTranscript) { [IO.File]::WriteAllText((Join-Path $Fixture.Transcripts ('project\' + $Id + '.jsonl')), '{"type":"user","message":"fixture"}') }
    return $path
}
function Invoke-Fixture($Fixture, [string]$Mode = 'Apply', [switch]$WhatIf) {
    $p = @{ Mode = $Mode; SessionRoot = $Fixture.Root; Scopes = $Fixture.Scopes; TranscriptRoot = $Fixture.Transcripts; BackupRoot = $Fixture.Backup; Confirm = $false }
    if ($WhatIf) { $p.WhatIf = $true }
    & $engine @p
}
function Get-TreeState([string]$Root) {
    $state = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File)) {
        $state[$file.FullName] = @{ Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash; Ticks = $file.LastWriteTimeUtc.Ticks; Length = $file.Length }
    }
    return $state
}
function Assert-OriginalsPreserved($Before) {
    foreach ($path in $Before.Keys) {
        Assert-True ([IO.File]::Exists($path)) "Original deleted: $path"
        Assert-True ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $Before[$path].Hash) "Original overwritten: $path"
        Assert-True ([IO.File]::GetLastWriteTimeUtc($path).Ticks -eq $Before[$path].Ticks) "Original timestamp changed: $path"
    }
}
function Assert-Throws([scriptblock]$Body) { $threw = $false; try { & $Body | Out-Null } catch { $threw = $true }; Assert-True $threw 'Expected refusal did not occur' }

try {
 Test-Case 'Default Inspect is read-only and lists scopes without contents' {
    $f = New-Fixture; $null = New-Chat $f
    $before = Get-TreeState $f.Base
    $r = & $engine -SessionRoot $f.Root
    Assert-True ($r.Mode -eq 'Inspect' -and $r.Roots[0].Scopes.Count -eq 2 -and $r.Writes -eq 0) 'Unexpected inventory'
    Assert-OriginalsPreserved $before
    Assert-True ((Get-TreeState $f.Base).Count -eq $before.Count) 'Inspect wrote files'
 }
 Test-Case 'Preview proposes missing sessions without any filesystem changes' {
    $f = New-Fixture; $null = New-Chat $f; $before = Get-TreeState $f.Base
    $r = Invoke-Fixture $f Preview
    Assert-True ($r.PlannedAdds -eq 1 -and $r.AddedCount -eq 0 -and $r.Mode -eq 'Preview') 'Bad preview'
    Assert-OriginalsPreserved $before
    Assert-True ((Get-TreeState $f.Base).Count -eq $before.Count) 'Preview wrote files'
 }
 Test-Case 'Apply -WhatIf is read-only' {
    $f = New-Fixture; $null = New-Chat $f; $before = Get-TreeState $f.Base
    $r = Invoke-Fixture $f Apply -WhatIf
    Assert-True ($r.AddedCount -eq 0 -and $r.Mode -eq 'Preview') 'WhatIf not respected'
    Assert-True ((Get-TreeState $f.Base).Count -eq $before.Count) 'WhatIf wrote files'
 }
 Test-Case 'Basic copying preserves byte hashes and creates verified backups' {
    $f = New-Fixture; $src = New-Chat $f; $before = Get-TreeState $f.Base
    $r = Invoke-Fixture $f
    Assert-True ($r.AddedCount -eq 1 -and $r.DeletedCount -eq 0 -and $r.ReplacedCount -eq 0) 'Bad copy result'
    $dst = Join-Path $f.Paths[1] ([IO.Path]::GetFileName($src))
    Assert-True ((Get-FileHash $src).Hash -ceq (Get-FileHash $dst).Hash) 'Copy not byte-exact'
    Assert-True ([IO.File]::Exists((Join-Path $r.BackupDirectory ($r.Added[0].SHA256 + '.json')))) 'Backup missing'
    Assert-OriginalsPreserved $before
 }
 Test-Case 'Second run is idempotent and creates no extra backup' {
    $f = New-Fixture; $null = New-Chat $f; $null = Invoke-Fixture $f; $before = Get-TreeState $f.Base
    $r = Invoke-Fixture $f
    Assert-True ($r.AddedCount -eq 0 -and $null -eq $r.BackupDirectory) 'Second run changed data'
    Assert-OriginalsPreserved $before
    Assert-True ((Get-TreeState $f.Base).Count -eq $before.Count) 'Second run created files'
 }
 Test-Case 'Regression: adding a third account with its own chat retains every old session' {
    $f = New-Fixture; $old = New-Chat $f; $null = New-Chat $f; $null = Invoke-Fixture $f
    $scope = [guid]::NewGuid().ToString('D') + '/' + [guid]::NewGuid().ToString('D')
    $path = Join-Path $f.Root $scope.Replace('/', '\'); [void][IO.Directory]::CreateDirectory($path)
    $f.Scopes += $scope; $f.Paths += $path; $null = New-Chat $f -Account 2
    $before = Get-TreeState $f.Base; $r = Invoke-Fixture $f
    Assert-OriginalsPreserved $before
    Assert-True ($r.AddedCount -eq 4) 'New account union incomplete'
    Assert-True ([IO.File]::Exists((Join-Path $path ([IO.Path]::GetFileName($old))))) 'Old session not copied'
 }
 Test-Case 'Empty account receives sessions without deletion inference' {
    $f = New-Fixture 3; $null = New-Chat $f; $r = Invoke-Fixture $f
    Assert-True ($r.AddedCount -eq 2) 'Empty scopes not seeded'
 }
 Test-Case 'Missing session is restored additively; deletions never propagate' {
    $f = New-Fixture; $src = New-Chat $f; $null = New-Chat $f; $null = Invoke-Fixture $f
    # Delete only a fixture copy to model a user action outside the engine.
    $dst = Join-Path $f.Paths[1] ([IO.Path]::GetFileName($src)); [IO.File]::Delete($dst)
    $before = Get-TreeState $f.Base; $r = Invoke-Fixture $f
    Assert-True ($r.AddedCount -eq 1 -and [IO.File]::Exists($dst)) 'Absence was not reseeded'
    Assert-OriginalsPreserved $before
 }
 Test-Case 'Different versions of the same name remain untouched and do not propagate' {
    $f = New-Fixture 3; $id = [guid]::NewGuid().ToString('D')
    $null = New-Chat $f -Id $id -Title 'Original'; $null = New-Chat $f -Account 1 -Id $id -Title 'Renamed'
    $before = Get-TreeState $f.Base; $r = Invoke-Fixture $f
    Assert-True ($r.AddedCount -eq 0 -and $r.Issues.Count -gt 0) 'Conflict propagated'
    Assert-OriginalsPreserved $before
 }
 Test-Case 'Regression: truncated newer JSON never overwrites or propagates' {
    $f = New-Fixture 3; $src = New-Chat $f
    $dst = Join-Path $f.Paths[1] ([IO.Path]::GetFileName($src))
    [IO.File]::WriteAllText($dst, '{"cliSessionId":"' + [IO.Path]::GetFileNameWithoutExtension($src).Substring(6) + '","title":')
    $before = Get-TreeState $f.Base; $r = Invoke-Fixture $f
    Assert-True ($r.AddedCount -eq 0 -and $r.Issues.Count -gt 0) 'Invalid JSON propagated'
    Assert-OriginalsPreserved $before
 }
 Test-Case 'Locked source is skipped with no partial target' {
    $f = New-Fixture; $src = New-Chat $f
    $lock = [IO.File]::Open($src, 'Open', 'ReadWrite', 'None')
    try { $r = Invoke-Fixture $f; Assert-True ($r.AddedCount -eq 0 -and $r.Issues.Count -gt 0) 'Locked file used' } finally { $lock.Dispose() }
    Assert-True (-not [IO.File]::Exists((Join-Path $f.Paths[1] ([IO.Path]::GetFileName($src))))) 'Partial destination'
 }
 Test-Case 'A source open for writing is refused even when readable' {
    $f = New-Fixture; $src = New-Chat $f
    $writer = [IO.File]::Open($src, 'Open', 'ReadWrite', 'ReadWrite')
    try { $r = Invoke-Fixture $f; Assert-True ($r.AddedCount -eq 0) 'Concurrent writer was accepted' } finally { $writer.Dispose() }
 }
 Test-Case 'UTF8 BOM, non-ASCII, emoji and future fields survive byte-exactly' {
    $f = New-Fixture; $src = New-Chat $f -Title ('Espa' + [char]0x00f1 + 'ol ' + [char]0x4e2d + [char]::ConvertFromUtf32(0x1F642)) -Bom
    $r = Invoke-Fixture $f; Assert-True ($r.AddedCount -eq 1) 'Unicode rejected'
    Assert-True ((Get-FileHash $src).Hash -ceq (Get-FileHash (Join-Path $f.Paths[1] ([IO.Path]::GetFileName($src)))).Hash) 'Unicode bytes changed'
 }
 Test-Case 'No transcript means no propagation' {
    $f = New-Fixture; $null = New-Chat $f -NoTranscript; $r = Invoke-Fixture $f
    Assert-True ($r.AddedCount -eq 0 -and $r.Issues.Count -gt 0) 'Missing transcript accepted'
 }
 Test-Case 'An empty transcript means no propagation' {
    $f = New-Fixture; $src = New-Chat $f; $id = [IO.Path]::GetFileNameWithoutExtension($src).Substring(6)
    [IO.File]::WriteAllBytes((Join-Path $f.Transcripts ('project\' + $id + '.jsonl')), [byte[]]@())
    $r = Invoke-Fixture $f; Assert-True ($r.AddedCount -eq 0) 'Empty transcript accepted'
 }
 Test-Case 'Tasks, groups, config, credentials, transcript contents and timestamps remain unchanged' {
    $f = New-Fixture; $null = New-Chat $f
    foreach ($p in @((Join-Path $f.Paths[0] 'scheduled-tasks.json'), (Join-Path $f.Paths[1] 'scheduled-tasks.json'), (Join-Path $f.Base 'Claude\claude_desktop_config.json'), (Join-Path $f.Base 'Claude\config.json'), (Join-Path $f.Base 'Claude\Local Storage\leveldb\000001.ldb'), (Join-Path $f.Base '.claude\.credentials.json'))) {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p)); [IO.File]::WriteAllText($p, 'DO NOT TOUCH ' + [guid]::NewGuid().ToString('N'))
    }
    $before = Get-TreeState $f.Base; $r = Invoke-Fixture $f; Assert-OriginalsPreserved $before
    Assert-True ($r.AddedCount -eq 1) 'Copy did not run'
 }
 Test-Case 'Only selected accounts are used; unselected fourth account remains untouched' {
    $f = New-Fixture 4; $null = New-Chat $f; $hidden = New-Chat $f -Account 3
    $name = [IO.Path]::GetFileName($hidden); $f.Scopes = @($f.Scopes[0], $f.Scopes[1]); $r = Invoke-Fixture $f
    Assert-True ($r.AddedCount -eq 1 -and -not [IO.File]::Exists((Join-Path $f.Paths[0] $name))) 'Unselected scope included'
 }
 Test-Case 'Multiple organizations require explicit selection; nothing is guessed' {
    $f = New-Fixture; $null = New-Chat $f
    $account = ($f.Scopes[0] -split '/')[0]; $other = $account + '/' + [guid]::NewGuid().ToString('D')
    [void][IO.Directory]::CreateDirectory((Join-Path $f.Root $other.Replace('/', '\')))
    $f.Scopes += $other; $before = Get-TreeState $f.Base
    Assert-Throws { Invoke-Fixture $f }; Assert-OriginalsPreserved $before
 }
 Test-Case 'Scopes reject traversal, duplicate entries and nonexisting accounts' {
    $f = New-Fixture; $null = New-Chat $f
    $saved = $f.Scopes; $f.Scopes = @($saved[0], '../outside'); Assert-Throws { Invoke-Fixture $f }
    $f.Scopes = @($saved[0], $saved[0]); Assert-Throws { Invoke-Fixture $f }
    $f.Scopes = @($saved[0], ([guid]::NewGuid().ToString('D') + '/' + [guid]::NewGuid().ToString('D'))); Assert-Throws { Invoke-Fixture $f }
 }
 Test-Case 'Relative, network and alternate-data-stream paths are refused' {
    $f = New-Fixture; $null = New-Chat $f
    foreach ($root in @('relative', '\\server\share', ($f.Root + ':stream'))) {
        Assert-Throws { & $engine -Mode Preview -SessionRoot $root -Scopes $f.Scopes -TranscriptRoot $f.Transcripts }
    }
 }
 Test-Case 'Backup inside Claude data is refused before any changes' {
    $f = New-Fixture; $null = New-Chat $f; $before = Get-TreeState $f.Base
    $f.Backup = Join-Path $f.Root 'backup'; Assert-Throws { Invoke-Fixture $f }; Assert-OriginalsPreserved $before
 }
 Test-Case 'Backup creation failure leaves session data untouched' {
    $f = New-Fixture; $null = New-Chat $f; [IO.File]::WriteAllText($f.Backup, 'not a directory')
    $before = Get-TreeState $f.Base; Assert-Throws { Invoke-Fixture $f }; Assert-OriginalsPreserved $before
 }
 Test-Case 'Locked sync guard refuses a second run without publishing' {
    $f = New-Fixture; $null = New-Chat $f; [void][IO.Directory]::CreateDirectory($f.Backup)
    $guard = [IO.File]::Open((Join-Path $f.Backup '.safe-sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try { Assert-Throws { Invoke-Fixture $f }; Assert-True (@(Get-ChildItem $f.Paths[1] -File).Count -eq 0) 'Published while guard locked' } finally { $guard.Dispose() }
 }
 Test-Case 'Claude running blocks Apply but allows read-only Preview' {
    $f = New-Fixture; $null = New-Chat $f; $before = Get-TreeState $f.Base; $global:SafeSyncTestRunning = $true
    try { Assert-Throws { Invoke-Fixture $f }; $r = Invoke-Fixture $f Preview; Assert-True ($r.AppRunning -and $r.AddedCount -eq 0) 'Preview behavior wrong' } finally { $global:SafeSyncTestRunning = $false }
    Assert-OriginalsPreserved $before
 }
 Test-Case 'Existing directory with a session filename is preserved' {
    $f = New-Fixture; $src = New-Chat $f; $dst = Join-Path $f.Paths[1] ([IO.Path]::GetFileName($src)); [void][IO.Directory]::CreateDirectory($dst)
    $r = Invoke-Fixture $f; Assert-True ($r.AddedCount -eq 0 -and [IO.Directory]::Exists($dst)) 'Directory replaced'
 }
 Test-Case 'Oversized metadata is skipped' {
    $f = New-Fixture; $src = New-Chat $f; [IO.File]::WriteAllBytes($src, (New-Object byte[] 4194305))
    $r = Invoke-Fixture $f; Assert-True ($r.AddedCount -eq 0 -and $r.Issues.Count -gt 0) 'Oversized metadata propagated'
 }
 Test-Case 'Read-only source and destination files preserve attributes and contents' {
    $f = New-Fixture; $src = New-Chat $f; [IO.File]::SetAttributes($src, [IO.FileAttributes]::ReadOnly)
    $before = Get-TreeState $f.Base; $r = Invoke-Fixture $f; Assert-OriginalsPreserved $before
    Assert-True ($r.AddedCount -eq 1) 'Read-only valid source was not copied'
    Assert-True (([IO.File]::GetAttributes($src) -band [IO.FileAttributes]::ReadOnly) -ne 0) 'Source attributes changed'
    $dst = Join-Path $f.Paths[1] ([IO.Path]::GetFileName($src)); [IO.File]::SetAttributes($dst, [IO.FileAttributes]::ReadOnly)
    $r = Invoke-Fixture $f; Assert-True ($r.AddedCount -eq 0) 'Read-only existing destination used as overwrite target'
 }
 Test-Case 'Equal-size conflicting files with identical timestamps are detected by content hashes' {
    $f = New-Fixture 3; $id = [guid]::NewGuid().ToString('D')
    $a = New-Chat $f -Id $id -Title 'AAAA'; $b = New-Chat $f -Account 1 -Id $id -Title 'BBBB'
    [IO.File]::SetLastWriteTimeUtc($b, [IO.File]::GetLastWriteTimeUtc($a)); $before = Get-TreeState $f.Base
    $r = Invoke-Fixture $f; Assert-True ($r.AddedCount -eq 0 -and $r.Issues.Count -gt 0) 'Equal size/time conflict missed'; Assert-OriginalsPreserved $before
 }
 Test-Case 'Junction destinations and junction parents are refused' {
    $f = New-Fixture; $null = New-Chat $f
    $outside = Join-Path $f.Base 'outside'; [void][IO.Directory]::CreateDirectory($outside)
    $junction = Join-Path $f.Root 'junction'; $null = New-Item -ItemType Junction -Path $junction -Target $outside
    Assert-Throws { & $engine -Mode Inspect -SessionRoot $junction }
    $f.Backup = Join-Path $junction 'backup'; Assert-Throws { Invoke-Fixture $f }
 }
 Test-Case 'Automatic root discovery supports unpackaged, MSIX and third-party locations without writing' {
    $f = New-Fixture; $acct = $f.Scopes[0].Replace('/', '\')
    foreach ($root in @((Join-Path $env:APPDATA 'Claude\claude-code-sessions'), (Join-Path $env:LOCALAPPDATA 'Claude-3p\claude-code-sessions'), (Join-Path $env:LOCALAPPDATA 'Packages\Claude_fixture\LocalCache\Roaming\Claude\claude-code-sessions'))) {
        [void][IO.Directory]::CreateDirectory((Join-Path $root $acct))
    }
    $before = Get-TreeState $testRoot; $r = & $engine
    Assert-True ($r.Roots.Count -eq 3 -and $r.Writes -eq 0) 'Discovery failed'; Assert-OriginalsPreserved $before
 }

 # Parser adversarial corpus: a missing type must never count as a rejection.
 Assert-True ($null -ne ('SafeClaudeSessions.Json' -as [type])) 'JSON parser failed to load; parser tests cannot run.'
 $invalidJson = @(
    '', ' ', '{', '{} trailing', '[]', 'null', '{"x":1,}', '{"x":/*comment*/1}',
    '{"x":1,"x":2}', '{"x":{"y":1,"y":2}}', '{"x":01}', '{"x":+1}', '{"x":1.}',
    '{"x":1e}', '{"x":NaN}', '{"x":Infinity}', '{"x":undefined}', '{"x":"\q"}',
    '{"x":"\uZZZZ"}', '{"x":"\uD800"}', '{"x":"\uDC00"}', '{"x":[1,]}',
    ('{"x":"line' + "`n" + 'break"}'), ('{"x":' + ('[' * 66) + '0' + (']' * 66) + '}')
 )
 $parserIndex = 0
 foreach ($json in $invalidJson) {
    $parserIndex++; $sample = $json
    Test-Case ('Strict JSON rejects malformed sample ' + $parserIndex) { Assert-Throws { [SafeClaudeSessions.Json]::Parse([Text.UTF8Encoding]::new($false).GetBytes($sample)) } }
 }
 Test-Case 'Strict JSON rejects invalid UTF8 bytes' { Assert-Throws { [SafeClaudeSessions.Json]::Parse([byte[]]@(123,34,120,34,58,34,0xC3,0x28,34,125)) } }
 Test-Case 'Strict JSON accepts complete RFC-style values' {
    foreach ($json in @('{}', '{"x":-1.25e+2,"y":[true,false,null,0],"z":{"a":"\uD83D\uDE42"}}', '{"a":"escaped \\ \" \/ \b \f \n \r \t"}')) {
        $null = [SafeClaudeSessions.Json]::Parse([Text.UTF8Encoding]::new($false).GetBytes($json))
    }
 }
 Test-Case 'Every truncated prefix of a complete metadata object is rejected' {
    $f = New-Fixture; $src = New-Chat $f; $bytes = [IO.File]::ReadAllBytes($src)
    for ($len = 1; $len -lt $bytes.Length; $len++) {
        $part = New-Object byte[] $len; [Array]::Copy($bytes, $part, $len)
        Assert-Throws { [SafeClaudeSessions.Json]::Parse($part) }
    }
 }
 Test-Case 'JSON fuzz: 1000 valid generated objects and 3000 malformed mutations' {
    $rng = New-Object Random ($Seed + 7)
    for ($i = 0; $i -lt 1000; $i++) {
        $value = [ordered]@{ n = $rng.Next(-10000, 10000); s = ('value-' + $i + '-\"'); a = @($true, $false, $null, ('unicode-' + [char]0x00f1)); nested = @{ future = $rng.NextDouble() } }
        $json = $value | ConvertTo-Json -Depth 8 -Compress
        $null = [SafeClaudeSessions.Json]::Parse([Text.UTF8Encoding]::new($false).GetBytes($json))
        foreach ($bad in @($json.Substring(0, $json.Length - 1), ($json + ' trailing'), ('{"duplicate":1,"duplicate":2,"data":' + $json + '}'))) {
            Assert-Throws { [SafeClaudeSessions.Json]::Parse([Text.UTF8Encoding]::new($false).GetBytes($bad)) }
        }
    }
 }
 Test-Case 'Schema rejects unavailable transcript flags, bad IDs, relative cwd and mismatched sessionId' {
    foreach ($mutate in @(
        { param($d) $d.transcriptUnavailable = $true }, { param($d) $d.transcriptUnavailable = 'false' },
        { param($d) $d.cliSessionId = '../escape' }, { param($d) $d.cwd = 'relative' }, { param($d) $d.sessionId = 'wrong' }
    )) {
        $f = New-Fixture; $src = New-Chat $f; $d = Get-Content -LiteralPath $src -Raw | ConvertFrom-Json
        & $mutate $d; [IO.File]::WriteAllText($src, ($d | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
        $r = Invoke-Fixture $f; Assert-True ($r.AddedCount -eq 0) 'Invalid schema propagated'
    }
 }
 Test-Case 'Atomic publication never replaces a destination that appears after planning (250 attempts)' {
    $dir = Join-Path $testRoot 'atomic'; [void][IO.Directory]::CreateDirectory($dir)
    for ($i = 0; $i -lt 250; $i++) {
        $stage = Join-Path $dir ('pending-' + $i); $dest = Join-Path $dir ('existing-' + $i)
        [SafeClaudeSessions.Json]::WriteNew($stage, [byte[]]@(1,2,3)); [SafeClaudeSessions.Json]::WriteNew($dest, [byte[]]@(4,5,6))
        Assert-Throws { [IO.File]::Move($stage, $dest) }
        Assert-True (([BitConverter]::ToString([IO.File]::ReadAllBytes($dest))) -ceq '04-05-06') 'Atomic move clobbered existing file'
        Assert-True ([IO.File]::Exists($stage)) 'Failed staging disappeared'
    }
 }
 Test-Case ('Randomized preservation and union invariants: ' + $RandomTrials + ' trials, seed ' + $Seed) {
    $rng = New-Object Random $Seed
    for ($trial = 0; $trial -lt $RandomTrials; $trial++) {
        $f = New-Fixture ($rng.Next(2, 5)); $unique = @{}
        for ($n = 0; $n -lt $rng.Next(1, 7); $n++) {
            $account = $rng.Next(0, $f.Paths.Count); $src = New-Chat $f -Account $account
            $unique[[IO.Path]::GetFileName($src)] = (Get-FileHash $src).Hash
        }
        $before = Get-TreeState $f.Base; $r = Invoke-Fixture $f; Assert-OriginalsPreserved $before
        Assert-True ($r.Issues.Count -eq 0) 'Random valid fixture generated issues'
        foreach ($target in $f.Paths) { foreach ($name in $unique.Keys) {
            $dest = Join-Path $target $name
            Assert-True ([IO.File]::Exists($dest)) 'Union incomplete'
            Assert-True ((Get-FileHash $dest).Hash -ceq $unique[$name]) 'Union bytes changed'
        } }
        $after = Get-TreeState $f.Base; $r2 = Invoke-Fixture $f
        Assert-True ($r2.AddedCount -eq 0) 'Random second run not idempotent'; Assert-OriginalsPreserved $after
    }
 }
} finally {
    $env:APPDATA = $oldAppData; $env:LOCALAPPDATA = $oldLocalData; $global:SafeSyncTestRunning = $false
}
$failed = @($tests | Where-Object { -not $_.Passed })
$report = [pscustomobject]@{
    Runtime = $PSVersionTable.PSVersion.ToString(); TimestampUtc = [DateTime]::UtcNow.ToString('o'); Seed = $Seed
    RandomTrials = $RandomTrials; AtomicCollisionAttempts = 250; GeneratedValidJsonObjects = 1000; MalformedJsonMutations = 3000
    TotalCases = $tests.Count; PassedCases = $tests.Count - $failed.Count; FailedCases = $failed.Count
    FixtureDirectory = $testRoot; Tests = @($tests.ToArray())
}
[IO.File]::WriteAllText((Join-Path $testRoot 'test-results.json'), ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 8
if ($failed.Count -gt 0) { exit 1 }
