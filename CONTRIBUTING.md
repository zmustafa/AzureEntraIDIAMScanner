# Contributing

Thanks for taking the time to improve this project.

## Development Setup

Requirements:

- Windows PowerShell 5.1 or PowerShell 7+
- Node.js 18+
- Azure CLI, if running live scans

Install dependencies:

```powershell
npm ci
```

Generate the dummy workbook sample:

```powershell
npm run sample
```

Run package validation:

```powershell
npm run validate
```

## Pull Request Guidelines

Before opening a pull request:

- Run `npm run validate`.
- Do not commit real scan output.
- Do not commit secrets, tenant IDs, subscription IDs, user names, emails, or organization-specific data.
- Use synthetic data under `samples/` for examples.
- Keep new collectors best-effort and resilient; one collector failure should not stop the whole scan unless it is a startup failure.
- Document new flags, output columns, and workbook sheets in `README.md`.

## Code Style

- Keep PowerShell compatible with Windows PowerShell 5.1 unless explicitly changing support policy.
- Prefer structured CSV/JSON output over log-only data.
- Preserve collector status and error reporting for every new access surface.
- Keep sample data obviously fake, using `example.invalid` and synthetic IDs.

## Public Data Safety

Real scan outputs can reveal privileged access and identity relationships. Treat generated workbooks and CSVs as sensitive security data.
