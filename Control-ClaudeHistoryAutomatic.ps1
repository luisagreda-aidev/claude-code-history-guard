param(
 [ValidateSet('Status','Pause','Resume')][string]$Mode='Status',
 [string]$InstallationPath=(Join-Path $env:LOCALAPPDATA 'ClaudeHistoryGuard\installation.json')
)
$ErrorActionPreference='Stop'
$installed=Get-Content -LiteralPath $InstallationPath -Raw|ConvertFrom-Json
$expectedRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($InstallationPath))
$runtime=[IO.Path]::GetFullPath($installed.Runtime);$state=Join-Path $runtime 'state'
if(-not$runtime.StartsWith($expectedRoot+'\',[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($runtime)-notmatch'^v1-[a-f0-9]{8}$'){throw 'Unexpected helper location'}
foreach($p in @($expectedRoot,$runtime,$state)){if((Test-Path -LiteralPath $p)-and(([IO.File]::GetAttributes($p)-band[IO.FileAttributes]::ReparsePoint)-ne0)){throw 'Link refused'}}
$pause=Join-Path $state 'PAUSE'
if($Mode-eq'Pause'){
 [void][IO.Directory]::CreateDirectory($state)
 if(-not[IO.File]::Exists($pause)){$f=[IO.File]::Open($pause,'CreateNew','Write','None');$f.Flush($true);$f.Dispose()}
 Write-Output 'Future runs are paused. An already active copy can finish safely.'
}elseif($Mode-eq'Resume'){
 if([IO.File]::Exists($pause)){Remove-Item -LiteralPath $pause}
 Write-Output 'Pause marker removed. Check Status to confirm the worker is running.'
}else{
 &(Join-Path $installed.Runtime 'ClaudeHistoryAutomatic.ps1') -Mode Status -ConfigPath $installed.Config|ConvertTo-Json -Depth 10
}
