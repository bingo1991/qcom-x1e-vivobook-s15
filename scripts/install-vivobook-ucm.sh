#!/bin/bash
# Install a dedicated ALSA UCM profile for the ASUS Vivobook S 15 (X1E80100).
#
# Why this is needed:
#   /usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf dispatches by DMI, and
#   its "LENOVO-T14s" branch also matches "ASUS Vivobook S 15" (the regex is
#   "...|ASUSTeK COMPUTER.*ASUS (Zenbook A14|Vivobook S 15)|...").  That pulls
#   in LENOVO-T14s.conf -> T14s-HiFi.conf, whose boot sequence drives WCD9385
#   controls (HPHL/HPHR/ADC2 Volume) that do not exist when the device tree
#   only exposes the WSA amplifiers.  snd_use_case_mgr_open() then fails,
#   alsactl falls back to the "generic method" and WirePlumber ends up with no
#   usable profile -> only "Dummy Output".
#
#   Note: every If branch in the dispatcher is evaluated independently, so
#   *adding* a branch for this machine without narrowing the T14s regex makes
#   two branches match and the merge fails with
#   "compound type expected for the merged block" (-22).  This script does both.
#
# Usage:  sudo ./install-vivobook-ucm.sh
#         sudo ./install-vivobook-ucm.sh --restore
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
UCM_SRC="$REPO/ucm"
UCM=/usr/share/alsa/ucm2/Qualcomm/x1e80100
DISP="$UCM/x1e80100.conf"

[ "$(id -u)" -eq 0 ] || { echo "please run with sudo" >&2; exit 1; }
[ -f "$DISP" ] || { echo "UCM dispatcher not found: $DISP" >&2; exit 1; }

if [ "${1:-}" = "--restore" ]; then
	latest=$(ls -1t "$DISP".orig-* 2>/dev/null | head -1 || true)
	[ -n "$latest" ] || { echo "no backup of $DISP found" >&2; exit 1; }
	cp -a "$latest" "$DISP"
	rm -f "$UCM/ASUS-Vivobook-S15.conf" "$UCM/ASUS-Vivobook-S15-HiFi.conf"
	echo "restored $DISP from $latest"
	echo "now run:  systemctl --user restart wireplumber"
	exit 0
fi

FILES="ASUS-Vivobook-S15.conf ASUS-Vivobook-S15-Speaker.conf ASUS-Vivobook-S15-Headphones.conf"
for f in $FILES; do
	[ -f "$UCM_SRC/$f" ] || { echo "missing $UCM_SRC/$f" >&2; exit 1; }
	# The UCM2 parser only understands '#' comments.  A single C-style
	# /* ... */ makes the whole profile fail to load and WirePlumber then
	# silently falls back to its generic profile, which is very confusing.
	if grep -q '/\*' "$UCM_SRC/$f"; then
		echo "error: $UCM_SRC/$f contains a C-style comment; use '#' instead" >&2
		exit 1
	fi
done

STAMP=$(date +%Y%m%d-%H%M%S)
cp -a "$DISP" "$DISP.orig-$STAMP"
echo "backup: $DISP.orig-$STAMP"

for f in $FILES; do
	install -m 0644 "$UCM_SRC/$f" "$UCM/$f"
done
# drop files from older layouts
rm -f "$UCM/ASUS-Vivobook-S15-HiFi.conf"
echo "installed: $UCM/ASUS-Vivobook-S15{,-Speaker,-Headphones}.conf"

# 1) add our dispatch branch, before the Lenovo T14s one
if ! grep -q "ASUS-Vivobook-S15.conf" "$DISP"; then
	awk '
		/^If\.LENOVOT14s \{/ && !done {
			print "If.ASUSVivobookS15 {"
			print "\tCondition {"
			print "\t\tType RegexMatch"
			print "\t\tString \"${var:DMI_info}\""
			print "\t\tRegex \"ASUSTeK COMPUTER.*ASUS Vivobook S 15\""
			print "\t}"
			print "\tTrue.Include.vivobook.File \"/Qualcomm/x1e80100/ASUS-Vivobook-S15.conf\""
			print "}"
			print ""
			done = 1
		}
		{ print }
	' "$DISP" > "$DISP.new"
	mv "$DISP.new" "$DISP"
	echo "dispatcher patched: $DISP"
else
	echo "dispatcher already has the Vivobook branch"
fi

# 2) narrow the T14s regex so that only one If can match (see header comment)
if grep -q 'Zenbook A14|Vivobook S 15' "$DISP"; then
	sed -i 's/(Zenbook A14|Vivobook S 15)/(Zenbook A14)/' "$DISP"
	echo "narrowed T14s regex: removed 'Vivobook S 15'"
fi

cat <<'EOM'

Done.  Verify that UCM parses (no reboot and no service restart needed):

  alsaucm -c x1e80100 list _verbs      # expect "0: HiFi", no errors

Then reload the session audio stack:

  systemctl --user restart wireplumber
  wpctl status                         # Sinks should now list "Speaker playback"
  speaker-test -c2 -twav -l1
EOM
