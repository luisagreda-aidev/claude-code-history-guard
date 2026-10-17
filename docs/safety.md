# Safety model and storage boundaries

## What is protected

The sync engines publish only absent `local_*.json` session metadata in explicitly
selected account/organization directories. They preserve original bytes, use
`CreateNew` for staging and a no-overwrite move for publication. They do not edit
transcripts or write task definitions, group settings, credentials or application
configuration. Existing files, divergent versions and invalid metadata are not
repaired automatically.

The automatic engine additionally checks deletion markers and requires the source
metadata and its unique primary transcript to match a verified snapshot. A source
change or application restart can leave a batch incomplete. Completed additions
remain; nothing is deleted as rollback. A pending planned conversation prevents
the protected launcher from treating that batch as complete.

## Why offline operation matters

Desktop can cache its sidebar and rewrite its own metadata. A process guard
checks that the Desktop app is fully closed before backup/publication and checks
again during the operation. Closing a window is not always Quit. The helper does
not kill processes or intercept account switching. No process check can create an
atomic lock over a future application launch; use the protected shortcut instead
of opening Claude separately during a copy.

Claude Code CLI processes and background activity may still change shared files.
Backups check hashes and inventories and reject an unstable recovery point. Do not
assume that a completed snapshot contains writes made after its verification.

## Recovery snapshots

`Backup-ClaudeHistorySafe.ps1` creates standalone full snapshots.
`Archive-ClaudeHistoryIncremental.ps1` retains complete inventories while storing
identical file contents once by SHA-256. Changed files create new immutable blobs.
Neither format uses automatic retention or pruning. Deleting a shared blob can
damage more than one recovery point.

A completion marker is necessary but insufficient: verification also checks the
manifest and every referenced file. RestoreCopy validates before reconstruction
and writes into a new separate folder. Do not manually restore over a live profile.
Incomplete directories and failed staging files are retained for investigation;
their presence does not make them valid recovery snapshots.

The archive retains a 1 GiB free-space reserve. Full-file versions of large,
growing transcripts can still consume substantial disk space. A space or permission
error stops the operation; it does not trigger cleanup of original data.

## What is not guaranteed

- No official Anthropic migration or account API compatibility guarantee.
- No hot switching, cloud chat transfer, subscription changes or credential migration.
- No automatic selection of new account/organization directories.
- No automatic conflict resolution or deletion propagation.
- No protection against every hardware, operating-system, malicious-local-user or
  future application failure. Filesystem junction checks are not a security boundary
  against an attacker with the same local privileges.
- No claim that fixture tests prove every Desktop version can resume every copied session.

Keep a separate backup on another device when stronger failure isolation is needed.
Verify a single copied conversation before a wider manual migration.

## Repository privacy

Source files and synthetic generators belong in Git. Runtime configurations,
account IDs, manifests, transcript files, logs, screenshots and backup blobs do not.
The publication audit checks an explicit file allowlist and scans tracked content
and optional Git history. It supplements review; pattern matching is not proof
that arbitrary text contains no private information.

See [SECURITY.md](../SECURITY.md) for reporting a vulnerability without publishing data.
