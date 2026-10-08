#!/usr/bin/env bash
# Install the user systemd timer that rebases + rebuilds grok-jkubo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"
mkdir -p "$UNIT_DIR" "${HOME}/.local/state/grok-jkubo"
install -m 644 "$ROOT/fork/systemd/grok-jkubo-sync.service" "$UNIT_DIR/"
install -m 644 "$ROOT/fork/systemd/grok-jkubo-sync.timer" "$UNIT_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now grok-jkubo-sync.timer
systemctl --user list-timers grok-jkubo-sync.timer --no-pager
echo "Manual: systemctl --user start grok-jkubo-sync.service"
