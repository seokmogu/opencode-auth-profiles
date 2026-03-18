# AGENTS.md

## Scope

This repository provides a portable version of a local OpenCode profile manager with:
- per-provider profile registry
- inactive Anthropic OAuth refresh
- access-only remote deployment
- launchd scheduling helpers

## Conventions

- Keep scripts ASCII-only unless a file already requires Unicode.
- Never commit real profile snapshots or logs.
- Preserve access-only deployment as the default for remotes.
- Do not introduce provider-specific secrets into the repository.

## Validation

- `bash -n src/oc-profiles.sh`
- `bash -n src/oc-token-push.sh`
- `node --check src/oc-refresh.mjs`

## Publication Rule

All examples must use placeholders such as `account-a`, `server-a`, and `account-a@example.com`.
