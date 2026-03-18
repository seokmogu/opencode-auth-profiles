# Architecture

## Goal

Keep one local machine as the auth authority while remotes only receive access-only OAuth state.

## Flow

1. Local OpenCode refreshes the active provider in `auth.json`.
2. `oc-sync` snapshots the active state into profile files.
3. `oc-refresh` refreshes inactive Anthropic profiles directly from stored refresh tokens.
4. `oc-deploy --all` sends access-only auth to mapped remotes.
5. `oc-verify` checks that remotes can still access Anthropic models.

## Why access-only remotes

- remotes never hold refresh tokens
- token theft impact is limited by access token TTL
- remote servers stay browser-free

## Known limitation

If an inactive Anthropic profile returns `invalid_grant`, that profile needs a fresh local re-login before it can be maintained again.
