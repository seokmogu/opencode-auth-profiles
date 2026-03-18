# opencode-auth-profiles

Portable multi-profile auth automation for OpenCode.

This repository extracts a local automation setup into a reusable public package with:
- provider-scoped profile snapshots
- inactive Anthropic OAuth refresh on the local machine
- access-only deployment to remote servers
- remote verification via Anthropic models endpoint
- launchd/systemd-based token propagation

## What problem it solves

If you use multiple Claude/OpenCode accounts and multiple remote servers, this toolkit lets you:
- keep browser login on one local machine
- map different accounts to different remote servers
- avoid copying refresh tokens to remotes by default
- monitor whether remotes still have usable Anthropic tokens

## Core files

- `src/oc-profiles.sh` - shell CLI for profile management
- `src/oc-refresh.mjs` - Anthropic refresh engine and verification helpers
- `src/oc-token-push.sh` - scheduler entrypoint
- `examples/manifest.example.json` - sanitized profile/server mapping example
- `launchd/com.opencode.token-push.plist.template` - macOS scheduler template

## Commands

- `oc-save <provider> <name> [label]`
- `oc-sync [provider...]`
- `oc-refresh`
- `oc-refresh --profile anthropic/<name> --force`
- `oc-apply --anthropic <name> --openai <name>`
- `oc-map <server> --anthropic <name> --openai <name>`
- `oc-deploy <server>`
- `oc-deploy --all`
- `oc-health`
- `oc-verify [server]`
- `oc-status`

## Install

```bash
git clone https://github.com/seokmogu/opencode-auth-profiles.git
cd opencode-auth-profiles
./install.sh
```

Then source the installed script:

```bash
source "$HOME/.local/share/opencode/profiles/oc-profiles.sh"
```

## Example setup

1. Copy the example manifest.

```bash
cp "$HOME/.local/share/opencode/profiles/manifest.json.example" "$HOME/.local/share/opencode/profiles/manifest.json"
```

2. Edit profile names and server mappings.

3. Log in locally with OpenCode.

```bash
opencode providers login -p anthropic
```

4. Save the current provider snapshot.

```bash
oc-save anthropic account-a "account-a@example.com"
```

5. Push access-only auth to remotes.

```bash
oc-deploy --all
```

6. Verify remote usability.

```bash
oc-verify
```

## Security model

- Local machine keeps refresh-capable OAuth state.
- Remotes receive access-only OAuth state by default.
- `oc-deploy --full-oauth` exists, but should be treated as unsafe.
- Never commit real profile JSON files or logs.

## Publication checklist

- verify examples only use placeholders such as `account-a`, `server-a`, and `example.com`
- verify the repository does not contain `auth.json`, profile snapshots, logs, or token-shaped strings
- verify launchd and install templates do not contain workstation-specific absolute paths
- verify `oc-deploy --full-oauth` is documented as an exceptional unsafe mode

## Verification commands

```bash
bash -n src/oc-profiles.sh
bash -n src/oc-token-push.sh
node --check src/oc-refresh.mjs
```

## Scheduler

### macOS

`install.sh` writes a launchd plist template into `~/Library/LaunchAgents/com.opencode.token-push.plist`.

To enable it:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.opencode.token-push.plist
```

The scheduler reacts to `auth.json` changes and also runs hourly.

### Linux

On Linux, `install.sh` writes user-level systemd units into `~/.config/systemd/user/`.

Enable them with:

```bash
systemctl --user daemon-reload
systemctl --user enable --now opencode-token-push.timer
```

Check timer state with:

```bash
systemctl --user status opencode-token-push.timer
systemctl --user list-timers | grep opencode-token-push
```

## Known limitation

If an inactive Anthropic profile starts returning `invalid_grant`, you must log in locally for that account again and re-save the profile snapshot.

## Optional integration

The original local setup also included an `oc-export-openclaw-auth` helper. This repository keeps the core OpenCode auth automation first; project-specific integrations can be added on top.
