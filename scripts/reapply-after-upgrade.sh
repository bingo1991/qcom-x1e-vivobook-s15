#!/bin/bash
# Re-apply everything that a package upgrade overwrites.
#
# Two things this repo changes live in places that packages own:
#
#   1. the .dtbauto section inside /boot/vmlinuz-<kver>
#      -> overwritten whenever the linux-*-qcom-x1e kernel package is upgraded
#   2. /usr/share/alsa/ucm2/... (profile + dispatcher tweak)
#      -> overwritten when alsa-ucm-conf is upgraded
#
# Run this after an upgrade, or install the apt hook so it happens by itself:
#
#   sudo ./reapply-after-upgrade.sh              # re-apply if needed
#   sudo ./reapply-after-upgrade.sh --force      # re-patch even if already patched
#   sudo ./reapply-after-upgrade.sh --dry-run    # only report what is missing
#   sudo ./reapply-after-upgrade.sh --install-hook
#   sudo ./reapply-after-upgrade.sh --remove-hook
#   ./reapply-after-upgrade.sh --status          # no root needed
#
# Exit status: 0 = everything in place (or fixed), 1 = still broken.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KVER="$(uname -r)"
VMLINUZ="/boot/vmlinuz-$KVER"
PATCHER="$REPO/scripts/patch-vmlinuz-dtb.py"
# The "full" variant (with the WCD9385) is the one we run: it provides the
# headphones as well as the speakers.  Variant=full matches it.
DTB="$REPO/build/x1e80100-asus-vivobook-s15-full.dtb"
UCM_DIR=/usr/share/alsa/ucm2/Qualcomm/x1e80100
DISPATCHER="$UCM_DIR/x1e80100.conf"
HOOK=/etc/apt/apt.conf.d/99-x1e-reapply
WRAPPER=/usr/local/sbin/x1e-reapply

DRY=0
QUIET=0
for arg in "$@"; do
	case "$arg" in
	--dry-run)      DRY=1 ;;
	--quiet)        QUIET=1 ;;
	--status)       DRY=1 ;;
	--force)        FORCE=1 ;;
	--install-hook) INSTALL_HOOK=1 ;;
	--remove-hook)  REMOVE_HOOK=1 ;;
	-h|--help)      sed -n '2,22p' "$0"; exit 0 ;;
	*) echo "unknown option: $arg" >&2; exit 1 ;;
	esac
done

say() { [ "$QUIET" = 1 ] || echo "$@"; }
need_root() { [ "$(id -u)" -eq 0 ] || { echo "please run with sudo" >&2; exit 1; }; }

# ---------------------------------------------------------------- apt hook
if [ "${INSTALL_HOOK:-0}" = 1 ]; then
	need_root
	cat > "$WRAPPER" <<EOF
#!/bin/sh
# installed by $REPO/scripts/reapply-after-upgrade.sh
exec "$REPO/scripts/reapply-after-upgrade.sh" --quiet
EOF
	chmod 0755 "$WRAPPER"
	cat > "$HOOK" <<EOF
// Re-apply the ASUS Vivobook S 15 (X1E80100) audio patches after upgrades.
// Installed by $REPO/scripts/reapply-after-upgrade.sh
DPkg::Post-Invoke { "$WRAPPER >>/var/log/x1e-reapply.log 2>&1 || true"; };
EOF
	echo "installed: $WRAPPER"
	echo "installed: $HOOK"
	echo "(log goes to /var/log/x1e-reapply.log)"
	exit 0
fi
if [ "${REMOVE_HOOK:-0}" = 1 ]; then
	need_root
	rm -f "$HOOK" "$WRAPPER"
	echo "removed apt hook"
	exit 0
fi

# ---------------------------------------------------------------- checks
dtb_verify() {
	[ -r "$VMLINUZ" ] || return 2
	python3 "$PATCHER" --vmlinuz "$VMLINUZ" --verify >/dev/null 2>&1
}

ucm_verify() {
	[ -f "$DISPATCHER" ] || return 1
	grep -q "ASUS-Vivobook-S15.conf" "$DISPATCHER" || return 1
	grep -q "Zenbook A14|Vivobook S 15" "$DISPATCHER" && return 1
	[ -f "$UCM_DIR/ASUS-Vivobook-S15.conf" ] || return 1
	[ -f "$UCM_DIR/ASUS-Vivobook-S15-HiFi.conf" ] || return 1
	return 0
}

rc=0

# ---------------------------------------------------------------- 1. DTB
if [ "${FORCE:-0}" = 1 ]; then
	dtb_rc=1
else
	dtb_verify
	dtb_rc=$?
fi
if [ "$dtb_rc" = 0 ]; then
	say "[ ok ] vmlinuz $KVER already carries the custom DTB"
elif [ "$dtb_rc" = 2 ]; then
	say "[ ?? ] cannot read $VMLINUZ - re-run with sudo to check the DTB state"
	say "       (everything else is checked without root)"
elif [ "$dtb_rc" = 3 ]; then
	say "[ ?? ] $VMLINUZ has no .dtbauto section for this machine"
	rc=1
else
	say "[ .. ] vmlinuz $KVER does NOT carry the custom DTB"
	if [ "$DRY" = 1 ]; then
		say "       would rebuild the DTB and patch $VMLINUZ"
		rc=1
	else
		need_root
		ver_base="$(echo "$KVER" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
		KSRC_DIR="$(ls -d "$HOME"/Workspace/linux-qcom-x1e-* 2>/dev/null \
			    | grep -F "$ver_base" | head -1 || true)"
		if [ -n "$KSRC_DIR" ]; then
			say "       rebuilding from $KSRC_DIR"
			VARIANT=full "$REPO/scripts/build-dtb.sh" >/dev/null || rc=1
		elif [ ! -f "$DTB" ]; then
			say "       ERROR: no DTB available and no matching kernel source tree."
			say "              Extract the source tarball for $KVER and re-run."
			rc=1
		fi
		if [ -f "$DTB" ]; then
			if python3 "$PATCHER" --vmlinuz "$VMLINUZ" --dtb "$DTB" --yes; then
				say "[fixed] $VMLINUZ patched"
			else
				say "       ERROR: patching failed (DTB too large for the section?)"
				rc=1
			fi
		fi
	fi
fi

# ---------------------------------------------------------------- 2. UCM
if ucm_verify; then
	say "[ ok ] UCM profile installed"
else
	say "[ .. ] UCM profile missing or dispatcher changed"
	if [ "$DRY" = 1 ]; then
		say "       would run install-vivobook-ucm.sh"
		rc=1
	else
		need_root
		if "$REPO/scripts/install-vivobook-ucm.sh" >/dev/null 2>&1; then
			say "[fixed] UCM profile installed (restart wireplumber to apply)"
		else
			say "       ERROR: install-vivobook-ucm.sh failed"
			rc=1
		fi
	fi
fi

[ "$rc" = 0 ] && say "everything in place."
exit "$rc"
