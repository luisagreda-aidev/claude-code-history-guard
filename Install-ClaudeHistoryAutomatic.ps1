[CmdletBinding()]
param(
 [ValidateSet('Preview','Install')][string]$Mode='Preview',
 [Parameter(Mandatory=$true)][string]$SessionRoot,
 [Parameter(Mandatory=$true)][string]$TranscriptRoot,
 [Parameter(Mandatory=$true)][string[]]$Scopes,
 [Parameter(Mandatory=$true)][string]$BackupRoot,
 [Parameter(Mandatory=$true)][string]$EvidencePath,
 [string[]]$BaselineFileNames,
 [string]$PowerShellPath=(Join-Path $PSHOME 'pwsh.exe'),
 [string]$InstallRoot=(Join-Path $env:LOCALAPPDATA 'ClaudeHistoryGuard'),
 [switch]$SkipShortcuts,
 [switch]$DoNotStartWorker,
 [string]$AppUserModelId='Claude_pzs8sxrjxfjjc!Claude'
)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major-lt7){throw 'Use PowerShell 7 to install the long-path capable runtime'}
function SafeInstallPath([string]$p){
 if(-not$p-or$p-notmatch'^[A-Za-z]:\\'-or$p.Substring(2).Contains(':')){throw 'Absolute local drive path required'}
 $cursor=[IO.Path]::GetFullPath($p).TrimEnd('\')
 while($cursor){if(([IO.File]::Exists($cursor)-or[IO.Directory]::Exists($cursor))-and(([IO.File]::GetAttributes($cursor)-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw 'Links and junctions refused'};$parent=[IO.Directory]::GetParent($cursor);$cursor=if($parent){$parent.FullName}else{$null}}
}
SafeInstallPath $InstallRoot;SafeInstallPath $BackupRoot
$InstallRoot=[IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$installationPath=Join-Path $InstallRoot 'installation.json'
if(Test-Path -LiteralPath $installationPath){throw 'An installation record already exists; inspect it rather than overwrite'}
foreach($sourceRoot in @($SessionRoot,$TranscriptRoot)){
 $parent=[IO.Directory]::GetParent([IO.Path]::GetFullPath($sourceRoot)).FullName.TrimEnd('\')
 foreach($target in @($InstallRoot,[IO.Path]::GetFullPath($BackupRoot).TrimEnd('\'))){if($target.Equals($parent,[StringComparison]::OrdinalIgnoreCase)-or$target.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Helper and backups must be outside Claude data'}}
}
$names=@('Sync-ClaudeSessionsSafe.ps1','Sync-ClaudeSessionsAutomatic.ps1','Archive-ClaudeHistoryIncremental.ps1','ClaudeHistoryAutomatic.ps1')
$evidence=Get-Content -LiteralPath $EvidencePath -Raw|ConvertFrom-Json
if(-not$evidence.AllPassed-or$evidence.Format-cne'ClaudeAutomaticTestEvidence-v1'){throw 'Passing test evidence required'}
foreach($name in $names){if((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash-ine$evidence.ScriptSHA256.$name){throw 'Code differs from tested version'}}
if(-not[IO.File]::Exists($PowerShellPath)){throw 'PowerShell runtime missing'}
$baseline=@()
if($BaselineFileNames){
 foreach($name in $BaselineFileNames){if($name-notmatch'^local_[A-Za-z0-9][A-Za-z0-9_-]{0,159}\.json$'){throw 'Invalid baseline filename'}}
 $baseline=@($BaselineFileNames)
}else{
 foreach($scope in $Scopes){$path=Join-Path $SessionRoot $scope.Replace('/','\');$baseline+=@(Get-ChildItem -LiteralPath $path -File -Filter 'local_*.json'|ForEach-Object Name)}
}
$baseline=@($baseline|Sort-Object -Unique)
# Validate roots, exact account/org pairs and metadata with the tested engine.
$plan=&(Join-Path $PSScriptRoot 'Sync-ClaudeSessionsAutomatic.ps1') -Mode Preview -SessionRoot $SessionRoot -TranscriptRoot $TranscriptRoot -Scopes $Scopes -ExcludeFileNames $baseline
$startup=Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude History Guard - background.lnk'
$desktop=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude History Guard.lnk'
if(-not$SkipShortcuts-and((Test-Path -LiteralPath $startup)-or(Test-Path -LiteralPath $desktop))){throw 'Helper shortcut already exists; inspect installation rather than overwrite'}
if($Mode-eq'Preview'){return [pscustomobject]@{Mode='Preview';Scopes=@($Scopes);BaselineConversations=$baseline.Count;PlannedRetroactiveCopies=$plan.PlannedAdds;ClaudeDataWrites=0;StartupShortcut=$startup;DesktopShortcut=$desktop}}
$runtime=Join-Path $InstallRoot ('v1-'+[guid]::NewGuid().ToString('N').Substring(0,8))
if(Test-Path -LiteralPath $runtime){throw 'Runtime destination must be new'}
[void][IO.Directory]::CreateDirectory($runtime)
foreach($name in $names){[IO.File]::Copy((Join-Path $PSScriptRoot $name),(Join-Path $runtime $name),$false);if((Get-FileHash (Join-Path $runtime $name)).Hash-ine$evidence.ScriptSHA256.$name){throw 'Installed script hash mismatch'}}
$configPath=Join-Path $runtime 'config.json';$state=Join-Path $runtime 'state'
$config=@{Format='ClaudeOfflineAutomation-v1';SessionRoot=$SessionRoot;TranscriptRoot=$TranscriptRoot;Scopes=@($Scopes);BaselineFileNames=$baseline;BackupRoot=$BackupRoot;StateRoot=$state;ScriptSHA256=$evidence.ScriptSHA256;AppUserModelId=$AppUserModelId}
[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
$null=&(Join-Path $runtime 'ClaudeHistoryAutomatic.ps1') -Mode Preview -ConfigPath $configPath
if(-not$SkipShortcuts){
 $shell=New-Object -ComObject WScript.Shell
 foreach($pair in @(@{Path=$startup;Mode='Watch';Style=7},@{Path=$desktop;Mode='Launch';Style=1})){
 if(Test-Path -LiteralPath $pair.Path){throw 'Shortcut appeared; do not overwrite'}
 $stagedLink=Join-Path $runtime ($pair.Mode+'-shortcut.lnk')
 $link=$shell.CreateShortcut($stagedLink);$link.TargetPath=$PowerShellPath
 $link.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle '+$(if($pair.Mode-eq'Watch'){'Hidden'}else{'Normal'})+' -File "'+(Join-Path $runtime 'ClaudeHistoryAutomatic.ps1')+'" -Mode '+$pair.Mode+' -ConfigPath "'+$configPath+'"'
 $link.WorkingDirectory=$runtime;$link.WindowStyle=$pair.Style
 $link.Description='Verify local backups and add missing Code conversations while Claude is closed.'
 $link.Save()
 $check=$shell.CreateShortcut($stagedLink);if($check.TargetPath-ine$PowerShellPath-or$check.Arguments-cne$link.Arguments){throw 'Shortcut verification failed'}
 [IO.File]::Move($stagedLink,$pair.Path)
 }
}
$process=$null
if(-not$DoNotStartWorker){$process=Start-Process -FilePath $PowerShellPath -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $runtime 'ClaudeHistoryAutomatic.ps1')+'" -Mode Watch -ConfigPath "'+$configPath+'"') -WindowStyle Hidden -PassThru}
$record=[pscustomobject]@{Mode='Install';Runtime=$runtime;Config=$configPath;State=$state;BackupRoot=$BackupRoot;WorkerPID=$(if($process){$process.Id});StartupShortcut=$(if(-not$SkipShortcuts){$startup});DesktopShortcut=$(if(-not$SkipShortcuts){$desktop});BaselineConversations=$baseline.Count;RegisteredScopes=@($Scopes);ClaudeDataWritesDuringInstall=0;ClaudeTasksModified=$false;WindowsScheduledTasksCreated=0;GroupsModified=$false}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Depth 8))
$f=[IO.File]::Open($installationPath,'CreateNew','Write','None');try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
$record
