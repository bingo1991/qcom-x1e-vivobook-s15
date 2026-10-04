#!/bin/bash
# ============================================================================
# SUPERSEDED / KEPT FOR REFERENCE ONLY -- DO NOT USE
#
# This tried to get a custom DTB loaded via /boot/dtb-* + a GRUB menu entry.
# That does NOT work on Ubuntu's qcom-x1e images: the DTB is selected by the
# EFI stub out of the .dtbauto PE sections inside vmlinuz, and GRUB's
# "devicetree" line is ignored (see docs/dtb-delivery.md).
#
# Use scripts/patch-vmlinuz-dtb.py instead.
# ============================================================================
#
# Install a custom DTB so that GRUB actually loads it.
#
# Needs root.  Two things are done:
#
#   1. copy the DTB to /boot/dtb-$(uname -r).  Ubuntu's /etc/grub.d/10_linux
#      emits   devicetree /boot/dtb-<kver>   for every generated entry when
#      that path exists, so the *normal* boot entry picks it up automatically.
#      No menu selection, no grub-reboot needed.
#
#   2. add a dedicated menu entry that loads the DTB explicitly.  Useful when
#      the menu is visible (press ESC during the firmware splash).
#
# Note: grub-reboot is NOT usable on this machine - the installed GRUB does
# not implement the next_entry variable at all (verified by scanning every
# grub binary/module).  Use --reboot here, or pick the entry in the menu.
#
# Rescue, if the new DTB ever prevents booting: press ESC at the firmware
# splash to get the GRUB menu, press 'e' on the entry, delete the line that
# starts with "devicetree", then Ctrl-X to boot.  Or delete the file
# /boot/dtb-$(uname -r).
set -euo pipefail

SRC=""
AUTO=1
DO_REBOOT=0
for arg in "$@"; do
	case "$arg" in
	--entry-only) AUTO=0 ;;
	--reboot)     DO_REBOOT=1 ;;
	--*)          echo "unknown option: $arg" >&2; exit 1 ;;
	*)            SRC="$arg" ;;
	esac
done
SRC="${SRC:-$HOME/Workspace/out/x1e80100-asus-vivobook-s15.dtb}"
SLUG="$(basename "$SRC" .dtb)"
KVER="$(uname -r)"
DEST="/boot/dtb/qcom/$SLUG.dtb"
AUTODEST="/boot/dtb-$KVER"
HOOK="/etc/grub.d/36_x1e_custom_dtb_$SLUG"

[ "$(id -u)" -eq 0 ] || { echo "please run with sudo" >&2; exit 1; }
[ -f "$SRC" ] || { echo "DTB not found: $SRC" >&2; exit 1; }
[ -f "/boot/vmlinuz-$KVER" ] || { echo "kernel image missing for $KVER" >&2; exit 1; }

install -D -m 0644 "$SRC" "$DEST"
echo "installed $DEST"

if [ "$AUTO" = 1 ]; then
	install -m 0644 "$SRC" "$AUTODEST"
	echo "installed $AUTODEST  (picked up by every generated grub entry)"
fi

ROOTARG="$(sed -n 's/.* \(root=[^ ]*\).*/\1/p' /proc/cmdline)"
[ -n "$ROOTARG" ] || { echo "could not parse root= from /proc/cmdline" >&2; exit 1; }

# keep everything except BOOT_IMAGE, the root= token and the rw/ro flag
EXTRA="$(sed -e 's/BOOT_IMAGE=[^ ]* //' \
             -e "s/ $ROOTARG//" -e "s/^$ROOTARG[ ]*//" \
             -e 's/^\(ro\|rw\)[ ]*//' /proc/cmdline)"

cat > "$HOOK" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry 'Ubuntu X1E - custom DTB ($SLUG)' --class ubuntu --class gnu-linux {
	linux  /boot/vmlinuz-$KVER $ROOTARG ro x1e_dtb=$SLUG $EXTRA
	initrd /boot/initrd.img-$KVER
	devicetree $DEST
}
EOF
chmod 0755 "$HOOK"
echo "created $HOOK"

update-grub

cat <<EOM

Done.

The custom device tree will be used on the NEXT boot by the normal
"Ubuntu" entry (via $AUTODEST).

Now just reboot:
  sudo reboot

To tell afterwards which path was used, check /proc/cmdline:
  * "x1e_dtb=$SLUG" present -> the dedicated menu entry was used
  * no marker but /proc/device-tree/sound exists -> the auto path was used

Useful afterwards:
  dmesg | grep -iE 'snd-|snd_soc|x1e80100-sndcard|wsa|wcd|q6apm|swr'
  cat /proc/asound/cards
  aplay -l
  sudo alsamixer          # unmute / raise 'SpkrLeft', 'SpkrRight'
  speaker-test -c2 -twav -l1

Rollback (any of these works):
  sudo rm -f $AUTODEST && sudo rm -f $HOOK && sudo update-grub && sudo reboot
  # or at the GRUB menu: press 'e', delete the "devicetree" line, Ctrl-X
EOM

if [ "$DO_REBOOT" = 1 ]; then
	echo
	echo "rebooting in 5 seconds (Ctrl-C to abort)..."
	sleep 5
	systemctl reboot
fi
