# Security Policy

## Reporting a Vulnerability

If you discover a security issue in Beamcore, **please open a public GitHub issue**.

We believe in transparency — security problems should be discussed in the open so the whole community can see, understand, and help fix them.

When filing an issue, include:

- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

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
