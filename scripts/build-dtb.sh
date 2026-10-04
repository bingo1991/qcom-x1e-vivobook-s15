#!/bin/bash
# Build the machine DTB for the ASUS Vivobook S 15 (X1E80100) out of a kernel
# source tree, without running the full kbuild (which needs flex/bison and a
# complete .config).  It replicates what scripts/Makefile.dtbs does:
#     cpp preprocess  ->  dtc
# and uses the prebuilt dtc that ships in the linux-headers package.
#
# It also (re-)installs dts/x1-asus-vivobook-s15-{audio,camera-probe}.dtsi into
# the kernel tree and makes sure x1e80100-asus-vivobook-s15.dts includes them,
# so a fresh tree needs no manual editing (the camera one does nothing unless
# X1E_CAMERA_PROBE is defined, i.e. VARIANT=cam-cci).
#
# Environment:
#   KSRC=DIR        kernel source tree        (default: auto-detected)
#   VARIANT=wsa     wsa (speakers only)
#           full    audio (WSA8845 + WCD9385) **and the camera**   <- default
#                   cam-cci (camera I2C controllers only, no sensor - the probe)
#                   cam-sensor (same as full; kept because the docs and the
#                               camera bring-up notes use the name)
#   SYMBOLS=0       pass dtc -@ or not.  0 is required when the DTB has to fit
#                   the fixed-size .dtbauto section inside vmlinuz.
#   OUT=FILE        output path
#
# Usage:  ./build-dtb.sh
#         VARIANT=full OUT=/tmp/full.dtb ./build-dtb.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KVER_BASE="$(uname -r | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"

if [ -z "${KSRC:-}" ]; then
	for d in "$HOME/Workspace/linux-qcom-x1e-$KVER_BASE" \
		 "$HOME/linux-qcom-x1e-$KVER_BASE" \
		 "$REPO/linux-qcom-x1e-$KVER_BASE"; do
		[ -d "$d/arch/arm64/boot/dts/qcom" ] && { KSRC="$d"; break; }
	done
fi

VARIANT="${VARIANT:-wsa}"
SYMBOLS="${SYMBOLS:-0}"
DTC="${DTC:-$(ls -d /usr/src/linux-headers-*/scripts/dtc/dtc 2>/dev/null | tail -1)}"
OUT="${OUT:-$REPO/build/x1e80100-asus-vivobook-s15-$VARIANT.dtb}"

QTREE="$KSRC/arch/arm64/boot/dts/qcom"
DTS="$QTREE/x1e80100-asus-vivobook-s15.dts"
DTD_INC="x1-asus-vivobook-s15-audio.dtsi"
DTD_CAM="x1-asus-vivobook-s15-camera-probe.dtsi"

[ -d "$QTREE" ]  || { echo "kernel source tree not found (set KSRC=)" >&2; exit 1; }
[ -x "$DTC" ]    || { echo "prebuilt dtc not found (set DTC=)" >&2; exit 1; }
[ -f "$DTS" ]    || { echo "machine dts not found: $DTS" >&2; exit 1; }

# ---------------------------------------------------------------- apply dtsi
install -m 0644 "$REPO/dts/$DTD_INC" "$QTREE/$DTD_INC"
if ! grep -q "$DTD_INC" "$DTS"; then
	sed -i "/#include \"x1-asus-vivobook-s15.dtsi\"/a #include \"$DTD_INC\"" "$DTS"
	echo "==> added #include \"$DTD_INC\" to $(basename "$DTS")"
fi
install -m 0644 "$REPO/dts/$DTD_CAM" "$QTREE/$DTD_CAM"
if ! grep -q "$DTD_CAM" "$DTS"; then
	sed -i "/#include \"$DTD_INC\"/a #include \"$DTD_CAM\"" "$DTS"
	echo "==> added #include \"$DTD_CAM\" to $(basename "$DTS")"
fi

case "$VARIANT" in
# full = everything that works on this machine: speakers, headphones and the
# camera.  It is what `make build` and therefore `make reapply` produce, so a
# kernel upgrade cannot silently drop the camera nodes.
wsa)        CPP_EXTRA="-DX1E_AUDIO_WSA_ONLY" ;;
full)       CPP_EXTRA="-DX1E_CAMERA_PROBE -DX1E_CAMERA_SENSOR" ;;
cam-cci)    CPP_EXTRA="-DX1E_CAMERA_PROBE" ;;
cam-sensor) CPP_EXTRA="-DX1E_CAMERA_PROBE -DX1E_CAMERA_SENSOR" ;;
*)          echo "unknown VARIANT: $VARIANT (use wsa|full|cam-cci|cam-sensor)" >&2; exit 1 ;;
esac
[ "$SYMBOLS" = 1 ] && SYMFLAGS="-@" || SYMFLAGS=""

DTC_INCLUDE="$KSRC/scripts/dtc/include-prefixes"
TMP="$(mktemp -d)"
trap 'rm -f "$TMP"/*.tmp 2>/dev/null; rmdir "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$(dirname "$OUT")"

# ---------------------------------------------------------------- preprocess
gcc -E -nostdinc $CPP_EXTRA \
    -I "$DTC_INCLUDE" \
    -undef -D__DTS__ \
    -x assembler-with-cpp \
    -o "$TMP/board.dts.tmp" "$DTS"

# ---------------------------------------------------------------- compile
echo "==> building $OUT (variant=$VARIANT symbols=$SYMBOLS)"
"$DTC" -o "$OUT" -b 0 \
    -i "$QTREE" -i "$DTC_INCLUDE" \
    -Wno-unique_unit_address -Wno-unit_address_vs_reg \
    -Wno-avoid_unnecessary_addr_size -Wno-alias_paths \
    -Wno-interrupt_map -Wno-simple_bus_reg \
    $SYMFLAGS \
    "$TMP/board.dts.tmp"

echo "==> built: $OUT ($(stat -c %s "$OUT") bytes)"

if [ "${VERIFY:-1}" = 1 ]; then
	# note the "|| true": grep -c exits 1 when the count is zero, which under
	# `set -e` would turn a perfectly good build into a failure
	"$DTC" -I dtb -O dts "$OUT" 2>/dev/null | grep -c "qcom,x1e80100-sndcard" \
		| sed 's/^/    sound card node  : /' || true
	"$DTC" -I dtb -O dts "$OUT" 2>/dev/null | grep -c "sdw20217020400" \
		| sed 's/^/    WSA8845 amps     : /' || true
	# status sits ~12 lines into the node, not 3
	"$DTC" -I dtb -O dts "$OUT" 2>/dev/null | grep -A14 "cci@ac1[56]000" \
		| grep -c 'status = "okay"' \
		| sed 's/^/    CCI buses enabled: /' || true
	"$DTC" -I dtb -O dts "$OUT" 2>/dev/null | grep -c 'ovti,ov02c10' \
		| sed 's/^/    ov02c10 nodes    : /' || true
fi
