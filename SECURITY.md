# Security Policy

Please do not open public issues for secrets, credential leaks, or token-handling bugs.

Report vulnerabilities privately via GitHub Security Advisories or direct maintainer contact.

## Scope

This project manages local OAuth snapshots and access-only remote deployment. Sensitive areas include:
- local token storage
- refresh-token handling
- remote access-only deployment
- scheduler/install scripts

## Safe Publishing Rules

Never commit real profile JSON files, logs, or `auth.json`.
Never publish active tokens, refresh tokens, email addresses, hostnames, or internal URLs.
