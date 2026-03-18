#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${HOME}"
OPENCODE_HOME="${OPENCODE_HOME:-$HOME_DIR/.local/share/opencode}"
PROFILES_HOME="${OPENCODE_PROFILES_HOME:-$OPENCODE_HOME/profiles}"
LAUNCHD_DIR="$HOME_DIR/Library/LaunchAgents"
PLIST_PATH="$LAUNCHD_DIR/com.opencode.token-push.plist"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/systemd/user"

OS_NAME="$(uname -s)"

mkdir -p "$PROFILES_HOME"

cp "$REPO_DIR/src/oc-profiles.sh" "$PROFILES_HOME/oc-profiles.sh"
cp "$REPO_DIR/src/oc-refresh.mjs" "$PROFILES_HOME/oc-refresh.mjs"
cp "$REPO_DIR/src/oc-token-push.sh" "$PROFILES_HOME/oc-token-push.sh"
cp "$REPO_DIR/examples/manifest.example.json" "$PROFILES_HOME/manifest.json.example"

chmod +x "$PROFILES_HOME/oc-token-push.sh" "$PROFILES_HOME/oc-refresh.mjs"

if [[ "$OS_NAME" == "Darwin" ]]; then
  mkdir -p "$LAUNCHD_DIR"
  python3 - <<PY
from pathlib import Path
template = Path("$REPO_DIR/launchd/com.opencode.token-push.plist.template").read_text()
template = template.replace("__OC_HOME__", "$OPENCODE_HOME")
template = template.replace("__OPENCODE_HOME__", "$OPENCODE_HOME")
template = template.replace("__HOME__", "$HOME_DIR")
Path("$PLIST_PATH").write_text(template)
PY
else
  mkdir -p "$SYSTEMD_DIR"
  python3 - <<PY
from pathlib import Path
service = Path("$REPO_DIR/systemd/opencode-token-push.service.template").read_text()
timer = Path("$REPO_DIR/systemd/opencode-token-push.timer.template").read_text()
service = service.replace("__OC_HOME__", "$OPENCODE_HOME").replace("__HOME__", "$HOME_DIR")
Path("$SYSTEMD_DIR/opencode-token-push.service").write_text(service)
Path("$SYSTEMD_DIR/opencode-token-push.timer").write_text(timer)
PY
fi

echo "Installed scripts into: $PROFILES_HOME"
echo "Next steps:"
echo "  1. Copy examples/manifest.example.json to $PROFILES_HOME/manifest.json and edit it"
echo "  2. Source $PROFILES_HOME/oc-profiles.sh"
if [[ "$OS_NAME" == "Darwin" ]]; then
  echo "  3. bootstrap launchd: launchctl bootstrap gui/\$(id -u) $PLIST_PATH"
else
  echo "  3. enable systemd timer: systemctl --user daemon-reload && systemctl --user enable --now opencode-token-push.timer"
fi
