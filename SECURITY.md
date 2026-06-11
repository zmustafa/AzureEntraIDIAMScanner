# Security Policy

## Reporting a Vulnerability

Please do not open a public issue for suspected security vulnerabilities.

Report security issues privately to the repository maintainers through the security advisory feature on GitHub, or through the private contact method published by the repository owner.

Include as much detail as possible:

- affected version or commit
- operating system and PowerShell version
- Azure CLI version
- reproduction steps
- relevant sanitized logs
- impact and suggested remediation, if known

## Sensitive Output Warning

This scanner is read-only, but its outputs can contain sensitive information about users, groups, service principals, role assignments, effective access, subscriptions, management groups, resources, Key Vault access policies, and ownership relationships.

Do not commit real scan outputs to a public repository. Keep generated output folders private unless they have been reviewed and sanitized.

The default output location is outside the repository:

```text
%TEMP%\azure-scanners\all-azure-access\<timestamp>\
```

You can also set a custom output root with `-OutputRoot`, or set `AZURE_IAM_SCANNER_OUTPUT_ROOT` for your shell session.

## Credentials

The scanner uses the local Azure CLI session. It does not ask for, store, or write Azure passwords, client secrets, certificates, refresh tokens, or private keys.

Do not place credentials in `.env` files or command-line arguments. `.env` files are ignored by `.gitignore` as a defense-in-depth measure.
