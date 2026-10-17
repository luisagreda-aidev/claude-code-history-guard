# Repository instructions

This is a Windows PowerShell toolkit for preserving local Claude Code Desktop
session history. It is independent software, not an Anthropic product.

- Never read or mutate actual Claude profiles while developing or testing.
- Use generated fixtures and mocked process inventories for every test.
- Keep Preview as the default for commands that can publish conversation metadata.
- Require explicit account/organization pairs; do not infer ownership from empty folders.
- Never overwrite or delete existing conversation files or propagate deletions.
- Keep scheduled tasks, groups, settings, credentials and cloud APIs out of writes.
- Refuse publication while Claude Desktop is running; preserve incomplete backups.
- Any published session must be covered by a verified recovery snapshot.
- Use CreateNew and atomic no-overwrite publication. Do not add destructive repair.
- Test failure, restart, concurrency and recovery behavior when changing file I/O.
- Keep local results, configs, logs, backups and transcripts outside Git history.
- Run `node tools/check-public-tree.cjs` before committing.
- README claims must match tests. Never promise zero risk, ranking or stars.
- Do not edit or run generated runtime/config files from another checkout.

Run `pwsh -NoProfile -File ./Run-Tests.ps1 -Tier Quick` on Windows for the fast
fixture suite. Full adds preservation fuzzing and concurrency/interruption suites.
Node.js is required for the independent verifier and publication checks.
