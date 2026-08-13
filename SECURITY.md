# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Conclawd, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please email: **security@conclawd.com**

You should receive a response within 48 hours. We will work with you to understand the issue and address it promptly.

## Scope

This policy applies to the Conclawd macOS application and its source code in this repository.

## Important Notes

- Conclawd runs without App Sandbox (`ENABLE_APP_SANDBOX: NO`) because it needs direct access to terminal processes (PTY) and the filesystem. This is by design and not a vulnerability.
- Conclawd executes Claude Code CLI as a subprocess. Users are responsible for reviewing and understanding the commands that Claude Code agents execute.
- API keys and credentials are never stored in this repository. They are managed through Claude Code's own configuration (`~/.claude/`).
