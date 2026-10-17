# Contributing

Start with a small, reproducible improvement. Useful areas include storage-format
compatibility, recovery verification, Windows behavior and clearer documentation.

1. Describe the problem using generated data only.
2. Keep changes within the [safety boundaries](docs/safety.md).
3. Run the relevant fixture tests and the public-tree audit.
4. Explain changed behavior, validation and remaining limitations in your pull request.

```powershell
./Run-Tests.ps1 -Tier Quick
node tools/check-public-tree.cjs
```

Changes to publication, backup or process guards need the Full suite and appropriate
interruption/concurrency cases. Do not add tests against an actual user profile.

Do not commit local evidence, account identifiers, histories, screenshots, backup
manifests, machine paths or credentials. New source files must be added to
`tools/public-files.json` and reviewed. Do not weaken the allowlist to publish data.

Respectful, concrete reports help more than inflated claims. No fake stars,
undisclosed promotion, keyword stuffing or assertions of guaranteed data safety.
For vulnerabilities, follow [SECURITY.md](SECURITY.md) rather than opening a public
issue containing sensitive information.
