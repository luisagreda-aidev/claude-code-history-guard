# Reproducible tests

All tests generate isolated filesystem fixtures. Process inventories are mocked
where needed; publication, hashing, parsing and backup I/O use real files.
Watcher and concurrency suites create actual fixture worker processes and stop
only the workers they created. They do not close or inspect real conversations.

```powershell
pwsh -NoProfile -File ./Run-Tests.ps1 -Tier Quick
pwsh -NoProfile -File ./Run-Tests.ps1 -Tier Full -RandomTrials 500
```

Run the Full suite in Windows PowerShell 5.1 as well when changing the core engines.
Installer integration requires PowerShell 7 and is skipped under 5.1. Node.js must
be on PATH for independent verifier checks.

## Coverage

- Strict JSON: duplicate keys, truncation, invalid UTF-8, unexpected shapes and size limits.
- Preservation: every preexisting file's bytes and modification date remain intact.
- Copy plans: selected scopes only, valid transcripts, divergence and missing destinations.
- Publication: atomic collisions, concurrent writers, interrupted stages and restart guards.
- Backups: corruption detection, immutable deduplication, version recovery and completion markers.
- Automatic operation: app exit, singleton worker, pause/resume, source coverage and pending copies.
- Installer: staged/headless installation, source preservation, pin checks and unsafe roots.
- Repository privacy: explicit file inventory, likely secrets and optional full Git-object review.

The randomized engines generate an independent collection of fixture accounts and
records, check the expected union and verify preservation/idempotence. The number
of trials is configurable and is not a count of real users or migrations.

The runner writes a compact local `artifacts/test-evidence.json` with suite summaries
and critical code hashes. Temporary fixtures remain outside the checkout, under a
unique temporary root, so PowerShell 5.1 path limits are less likely to interfere.
Results are local-only; CI does not upload raw logs, fixture transcripts or profile data.

## What these tests do not prove

Mocked account changes cannot prove a future Desktop release will load the same
storage format. Test one synthetic or non-sensitive session in the actual UI
before relying on a new version. Tests also cannot simulate every physical disk,
power-loss or operating-system failure.
