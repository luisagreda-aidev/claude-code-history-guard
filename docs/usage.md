# Installation, backup and recovery

Start with the [README quick start](../README.md#quick-start). All account and path
arguments must come from your own inspection, not from examples in an issue.

## Manual existing-history copy

1. Run Inspect and identify the exact account/organization pairs you authorize.
2. Run Preview and review conflicts, invalid files and missing transcripts.
3. Quit Desktop completely from the tray.
4. Create, verify and preferably reconstruct a full backup into a separate folder.
5. Apply the missing-only plan; inspect returned Issues and ConcurrentSkips.
6. Reopen Desktop and verify one history before copying more.

The manual sync engine creates metadata backups but does **not** itself create a
full transcript backup. The preceding full backup is a separate required workflow
step. The automatic helper performs that full-inventory archive step for each
offline cycle before publication.

## Optional automatic helper

Run `Run-Tests.ps1` to generate ignored local evidence. Preview and Install require
that the critical scripts still match the evidence hashes. Editing the scripts
after testing invalidates that evidence.

Installation defaults to `%LOCALAPPDATA%\ClaudeHistoryGuard`. The private pointer
`installation.json` contains the active runtime and configuration paths. Each
runtime is new; an existing installation record is never overwritten.

For an alternate `-InstallRoot`, pass its private record explicitly:

```powershell
./Control-ClaudeHistoryAutomatic.ps1 -Mode Status `
  -InstallationPath '<absolute private installation.json path>'
```

`-SkipShortcuts -DoNotStartWorker` stages a headless installation without creating
Windows shortcuts or starting a process. This is also how installer fixtures avoid
changing the actual desktop or startup folder.

By default, the automatic helper excludes all session names present at installation.
An advanced `-BaselineFileNames` list lets an operator choose those exclusions.
Review the preview carefully; do not use this to bypass the initial single-session
check. The selected account/organization scopes are frozen in the private config.

Status reports the currently running worker, app state, pause marker and most recent
event. Pause blocks future cycles; an already active cycle can finish. Resume
removes the pause marker but does not promise a dead worker was restarted. Use the
protected launcher or a subsequent Windows login, and verify Status.

## Event states

| State | Meaning |
| --- | --- |
| Started | The background helper has initialized. |
| WaitingForClaudeExit | No publication while Desktop is running. |
| Archiving | Creating and verifying an offline recovery snapshot. |
| Complete | Snapshot verified and planned missing destinations checked. Inspect Issues as well. |
| Deferred | Interruption, unstable source or error; inspect before relying on the copy. |
| Paused | Future automatic cycles are suspended. |

Events can contain local paths and account/session identifiers. Keep them private.
The helper does not perform backup rotation or email/remote notifications.

## Verify and reconstruct a deduplicated archive

```powershell
$snapshotPath = '<absolute private snapshot directory>'
$newRecoveryFolder = '<new absolute folder outside Claude and backup data>'

./Archive-ClaudeHistoryIncremental.ps1 -Mode Verify -SnapshotPath $snapshotPath
./Archive-ClaudeHistoryIncremental.ps1 -Mode RestoreCopy `
  -SnapshotPath $snapshotPath -RestoreDestination $newRecoveryFolder

node ./Verify-IncrementalHistoryIndependent.cjs $snapshotPath $newRecoveryFolder
```

These commands never authorize restoring into a live Claude profile. Keep the
reconstructed files separate and verify them before deciding on a manual recovery.

Standalone full snapshots use `Backup-ClaudeHistorySafe.ps1 -Mode Verify` and
`-Mode RestoreCopy`. Their manifests use a different format; do not mix formats
or manually move shared blobs between backup roots.

## Stop or remove the helper

Pause it first and check that no archive/copy is active. Disable its own startup
shortcut and stop only the positively identified helper process, if necessary.
Removing the helper's own shortcuts/runtime does not require deleting any Claude
data. Keep private recovery snapshots unless you have deliberately reviewed a
separate retention plan. There is no automatic profile restore or destructive uninstall.
