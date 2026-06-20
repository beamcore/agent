# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Beamcore, please report it
responsibly. **Do not open a public GitHub issue.**

Instead, please email the maintainers at:

```
security@beamcore.dev
```

Include:

- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

## Response

We will acknowledge receipt within 48 hours and aim to provide a fix or
mitigation plan within 7 days for confirmed vulnerabilities.

## Scope

Beamcore runs arbitrary local code by design. The security model assumes a
trusted local operator. Vulnerabilities in scope include:

- Remote code execution without user intent
- Credential leakage (API keys, tokens) to third parties
- Bypass of path restrictions or `.beamcore` storage protection
- Corruption of the TUI or agent runtime through crafted input

Out of scope:

- Issues requiring physical access to the machine
- Issues in upstream dependencies (report those to the upstream maintainer)

## Supported Versions

| Version | Supported |
|---|---|
| 0.1.x | ✅ |
