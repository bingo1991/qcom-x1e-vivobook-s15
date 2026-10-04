#!/bin/bash
# Remove the leftovers of the early "/boot/dtb-* + GRUB devicetree" attempt.
#
# That approach was a dead end: the EFI stub picks the DTB out of the .dtbauto
# PE sections inside vmlinuz and ignores whatever GRUB passes (see
# docs/dtb-delivery.md), which is why the real fix replaces that section.
#
# What it left behind:
#   /etc/grub.d/36_x1e_custom_dtb_*   an extra, useless menu entry
#   /boot/dtb-$(uname -r)             makes every entry emit a "devicetree"
#                                     line that the stub ignores
#   /boot/dtb/qcom/*.dtb              the DTB copy itself
#   /boot/vmlinuz-*.orig-*            vmlinuz backups, 26 MB each; the oldest
#                                     is the untouched original and is kept
#
# Usage:  sudo ./cleanup-legacy-grub.sh [--dry-run]
set -euo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

KVER="$(uname -r)"
KEEP_BACKUP="$(ls -1t /boot/vmlinuz-"$KVER".orig-* 2>/dev/null | tail -1 || true)"

say() { echo "$@"; }
run() {	# print + execute (or just print)
	if [ "$DRY" = 1 ]; then
		say "  would: $*"
	else
		say "  $*"
		"$@"
	fi
}

if [ "$DRY" = 0 ] && [ "$(id -u)" -ne 0 ]; then
	echo "please run with sudo (or use --dry-run)" >&2
	exit 1
fi

say "== GRUB menu entry / hook =="
for f in /etc/grub.d/36_x1e_custom_dtb_*; do
	[ -e "$f" ] || continue
	run rm -f "$f"
done

say
say "== /boot DTB leftovers =="
if [ -f "/boot/dtb-$KVER" ]; then
	run rm -f "/boot/dtb-$KVER"
else
	say "  (/boot/dtb-$KVER not a regular file - left alone)"
fi
if [ -f /boot/dtb/qcom/x1e80100-asus-vivobook-s15-wsa-only.dtb ]; then
	run rm -f /boot/dtb/qcom/x1e80100-asus-vivobook-s15-wsa-only.dtb
fi
if [ -d /boot/dtb ]; then
	# only removes the tree if nothing but our qcom/ leftovers remain
	run rmdir /boot/dtb/qcom 2>/dev/null || true
	run rmdir /boot/dtb 2>/dev/null || true
fi

say
say "== vmlinuz backups (26 MB each) =="
say "  keeping the oldest (untouched original): ${KEEP_BACKUP:-<none>}"
say "  -> moved out of /boot: GRUB enumerates kernels with /boot/vmlinuz-*, so"
say "     a backup there becomes an extra menu entry whose matching initrd"
say "     does not exist (booting it panics with 'Unable to mount root fs')."
if [ -n "$KEEP_BACKUP" ] && [ "$DRY" = 0 ]; then
	mkdir -p /var/backups/x1e
fi
for f in /boot/vmlinuz-"$KVER".orig-*; do
	[ -e "$f" ] || continue
	if [ "$f" = "$KEEP_BACKUP" ]; then
		run mv -f "$f" /var/backups/x1e/
	else
		run rm -f "$f"
	fi
done

say
say "== update-grub =="
if [ "$DRY" = 1 ]; then
	say "  would: update-grub"
else
	update-grub >/dev/null
	say "  done"
	say
	say "== verify =="
	printf "  'custom DTB' entries : %s\n" "$(grep -c 'custom DTB' /boot/grub/grub.cfg || true)"
	printf "  devicetree lines     : %s (expected 0)\n" "$(grep -c 'devicetree' /boot/grub/grub.cfg || true)"
	printf "  vmlinuz backups left : %s\n" "$(ls /boot/vmlinuz-"$KVER".orig-* 2>/dev/null | wc -l)"
fi

say
say "Note: the DTB is still supplied by the patched .dtbauto section inside"
say "vmlinuz - removing the GRUB entry and /boot/dtb-* does not affect audio."
