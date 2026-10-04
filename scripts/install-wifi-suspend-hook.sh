#!/bin/bash
# Install (or remove) the ath12k suspend/resume reload hook.
#
# Usage:
#   sudo ./install-wifi-suspend-hook.sh            # install
#   sudo ./install-wifi-suspend-hook.sh --remove   # uninstall
#
# Test it with:  systemctl suspend
# After resuming:  wl=$(ls /sys/class/net | grep -m1 '^wl'); cat /sys/class/net/$wl/operstate
#                  journalctl -b -k | grep -i ath12k | tail
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK=/usr/lib/systemd/system-sleep/ath12k-reload.sh

[ "$(id -u)" -eq 0 ] || { echo "please run with sudo" >&2; exit 1; }

if [ "${1:-}" = "--remove" ]; then
	rm -f "$HOOK"
	echo "removed $HOOK"
	exit 0
fi

install -m 0755 "$REPO/scripts/ath12k-reload.sh" "$HOOK"
echo "installed: $HOOK"
cat <<'EOM'

The hook unloads ath12k_wifi7/ath12k before suspend and reloads them after
resume, so the WCN7850 firmware is re-initialised instead of being asked to
recover.  NetworkManager brings the interface back automatically; expect a
few seconds of downtime on resume.

Verify:
  systemctl suspend
  # after resume:
  journalctl -b -k | grep -i ath12k | tail
  nmcli device status          # wifi 应重新连上
EOM
