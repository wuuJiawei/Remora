# Security Policy

## Supported Versions

Remora is pre-1.0 and evolves quickly. We recommend using the latest `main` branch or latest release tag once releases are published.

## Reporting a Vulnerability

Please do **not** open a public issue for suspected vulnerabilities.

Instead:

1. Email the maintainer with:
   - vulnerability summary
   - impact
   - reproduction steps
   - suggested fix (if any)
2. Use the email subject prefix: `[Remora Security]`.

If you are unsure whether something is security-sensitive, report it privately first.

## Response Targets

Best-effort targets:

- Initial acknowledgment: within 3 business days
- Triage decision: within 7 business days
- Patch timeline: depends on severity and reproducibility

## Scope

Security reports are especially helpful for:

- credential/key handling
- host key verification
- command/argument injection risks
- path traversal and file operation safety
- sensitive log leakage
