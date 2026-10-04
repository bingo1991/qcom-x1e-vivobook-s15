#!/bin/bash
# Install the missing VSS ("video subsystem") firmware for the iris driver, so
# that hardware video decode works on this laptop.
#
# The stubble DTB of this machine carries `firmware-name` for five files, all
# under qcom/x1e80100/ASUSTeK/vivobook-s15/:
#
#   qcadsp8380.mbn + adsp_dtbs.elf   ADSP            installed
#   qccdsp8380.mbn + cdsp_dtbs.elf   CDSP            installed
#   qcdxkmsuc8380.mbn                GPU (zap)       installed
#   qcvss8380.mbn                    iris / video    *** missing ***
#
# `scripts/selftest.sh` (section "DT firmware-name blobs") reports this list.
# Without the blob the driver probes and then gives up:
#
#   qcom-iris aa00000.video-codec: Direct firmware load for
#       qcom/x1e80100/ASUSTeK/vivobook-s15/qcvss8380.mbn failed with error -2
#
# linux-firmware ships no ASUSTeK/vivobook-s15 branch, but it does ship the
# same-SoC blob for Lenovo machines (LENOVO/21N1, LENOVO/83ED), and the
# Windows driver package for *this* laptop contains it too.  Both work as a
# source; the Windows one is preferred because it belongs to the firmware set
# that is already installed here (the GPU/ADSP/CDSP blobs were taken from the
# same qcdx8380.inf_arm64_* driver directory).
#
# Usage:
#   scripts/install-video-firmware.sh --list              # show what is available
#   sudo scripts/install-video-firmware.sh                # auto-pick + install
#   sudo scripts/install-video-firmware.sh --from-lenovo  # use linux-firmware's copy
#   sudo scripts/install-video-firmware.sh --file some/qcvss8380.mbn
#   sudo scripts/install-video-firmware.sh --zip ~/Workspace/qcom-info.zip
#   sudo scripts/install-video-firmware.sh --revert
#
# Then reload the driver (no reboot needed):
#   sudo modprobe -r qcom_iris && sudo modprobe qcom_iris
#   dmesg -T | tail -20          # expect no "firmware ... failed" line
#
set -euo pipefail

# This is also where the DTB looks for adsp/cdsp/gpu blobs, i.e. the set that is
# already installed here - so it doubles as the reference to match against.
REF=/lib/firmware/updates/qcom/x1e80100/ASUSTeK/vivobook-s15
DEST=$REF
BACKUP_DIR=/var/backups/x1e
MANIFEST="$BACKUP_DIR/video-firmware.manifest"
FWNAME=qcvss8380.mbn

# Where the export usually ends up.  Note $HOME is /root once this runs under
# sudo, so the invoking user's home is looked up explicitly as well.
ZIP_CANDIDATES=(
	"$PWD/qcom-info.zip"
	"$(dirname "$PWD")/qcom-info.zip"
	"$HOME/qcom-info.zip"
	"$HOME/Workspace/qcom-info.zip"
	"/home/${SUDO_USER:-$USER}/qcom-info.zip"
	"/home/${SUDO_USER:-$USER}/Workspace/qcom-info.zip"
)
for d in /home/*/qcom-info.zip /home/*/Workspace/qcom-info.zip; do
	[ -f "$d" ] && ZIP_CANDIDATES+=("$d")
done
LENOVO_DIRS=(/lib/firmware/qcom/x1e80100/LENOVO/21N1 /lib/firmware/qcom/x1e80100/LENOVO/83ED)

src_file=
src_zip=
src_dir=
use_lenovo=0
do_list=0
do_revert=0
force=0

die() { echo "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed -n 's/^# \{0,1\}//p' | head -n -1; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--file) src_file=${2:?--file needs a path}; shift 2 ;;
	--zip) src_zip=${2:?--zip needs a path}; shift 2 ;;
	--dir) src_dir=${2:?--dir needs a path}; shift 2 ;;
	--from-lenovo|--lenovo) use_lenovo=1; shift ;;
	--dest) DEST=${2:?--dest needs a path}; shift 2 ;;
	--list) do_list=1; shift ;;
	--revert|--remove) do_revert=1; shift ;;
	--force) force=1; shift ;;
	-h|--help) usage 0 ;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

# ---------------------------------------------------------------- --revert --
if [ "$do_revert" = 1 ]; then
	[ "$(id -u)" -eq 0 ] || die "please run the revert with sudo"
	removed=0
	if [ -f "$MANIFEST" ]; then
		while read -r path _; do
			[ -n "$path" ] || continue
			[ -e "$path" ] && { rm -f "$path"; removed=$((removed + 1)); echo "removed $path"; }
		done < <(grep -v '^#' "$MANIFEST")
		rm -f "$MANIFEST"
	else
		[ "$force" = 1 ] || die "no manifest at $MANIFEST - nothing was installed by this script (use --force to remove $DEST/$FWNAME anyway)"
		[ -e "$DEST/$FWNAME" ] && { rm -f "$DEST/$FWNAME"; removed=$((removed + 1)); echo "removed $DEST/$FWNAME"; }
	fi
	echo "removed $removed file(s); reboot (or 'modprobe -r qcom_iris') to go back"
	exit 0
fi

md5_of() { md5sum "$1" | cut -d' ' -f1; }

# The kms/zap blob identifies the driver generation: the machine already has
# one installed, so the zip directory whose copy hashes the same is the one the
# rest of the (already installed) firmware came from.
installed_kms_md5=
for f in "$REF/qcdxkmsucpurwa.mbn" "$REF/qcdxkmsuc8380.mbn"; do
	[ -f "$f" ] && { installed_kms_md5=$(md5_of "$f"); break; }
done

# Which source?  Explicit options win; otherwise use the Windows export if one
# of the usual paths exists, and only then fall back to linux-firmware.
if [ -z "$src_file" ] && [ -z "$src_dir" ] && [ -z "$src_zip" ] && [ "$use_lenovo" = 0 ]; then
	for z in "${ZIP_CANDIDATES[@]}"; do
		[ -f "$z" ] && { src_zip=$z; break; }
	done
	if [ -n "$src_zip" ]; then
		echo "using Windows export: $src_zip"
	else
		echo "no Windows export found in: ${ZIP_CANDIDATES[*]}"
		echo "falling back to the blob linux-firmware ships for the same SoC"
		use_lenovo=1
	fi
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Candidate list: "<source> <label> <size> <md5> [<path-inside-source>]"
candidates=()

if [ -n "$src_file" ]; then
	[ -f "$src_file" ] || die "no such file: $src_file"
	candidates+=("file|$src_file|$(stat -c%s "$src_file")|$(md5_of "$src_file")")
fi

if [ -n "$src_zip" ]; then
	[ -f "$src_zip" ] || die "no such zip: $src_zip"
	command -v unzip >/dev/null || die "unzip is required to read $src_zip"
	# every .../qcdx8380.inf_arm64_*/ directory in the export is a candidate
	while IFS= read -r inner; do
		[ -n "$inner" ] || continue
		base=$(dirname "$inner")
		out="$workdir/$(basename "$base").mbn"
		unzip -p "$src_zip" "$inner" >"$out" 2>/dev/null || continue
		size=$(stat -c%s "$out")
		[ "$size" -gt 100000 ] || continue
		# DriverVer of the package this blob belongs to (INF is UTF-16LE:
		# dropping NUL bytes is enough to read it as ASCII)
		ver=$(unzip -p "$src_zip" "$base/qcdx8380.inf" 2>/dev/null | tr -d '\0' |
			grep -aiE '^DriverVer' | head -1 | cut -d, -f1 | cut -d= -f2 | tr -d ' \r')
		# hash of the matching kms blob -> ties the candidate to this machine
		kms=$(unzip -p "$src_zip" "$base/qcdxkmsucpurwa.mbn" 2>/dev/null | md5sum | cut -d' ' -f1)
		candidates+=("zip|$src_zip!$base|$size|$(md5_of "$out")|${ver:-unknown}|$kms|$out")
	done < <(unzip -Z1 "$src_zip" 2>/dev/null | grep -E "/qcdx8380\.inf_arm64_[0-9a-f]+/$FWNAME$" || true)
	[ ${#candidates[@]} -gt 0 ] || die "no $FWNAME found inside $src_zip (expected .../qcdx8380.inf_arm64_*/$FWNAME)"
fi

if [ -n "$src_dir" ]; then
	[ -f "$src_dir/$FWNAME" ] || die "no $FWNAME in $src_dir"
	candidates+=("dir|$src_dir|$(stat -c%s "$src_dir/$FWNAME")|$(md5_of "$src_dir/$FWNAME")")
fi

if [ "$use_lenovo" = 1 ]; then
	found=0
	for d in "${LENOVO_DIRS[@]}"; do
		[ -f "$d/$FWNAME.zst" ] || continue
		out="$workdir/lenovo-$(basename "$d").mbn"
		zstd -dc "$d/$FWNAME.zst" >"$out"
		candidates+=("lenovo|$d|$(stat -c%s "$out")|$(md5_of "$out")|linux-firmware $(basename "$d")|")
		found=1
	done
	[ "$found" = 1 ] || die "linux-firmware has no LENOVO/*/$FWNAME.zst on this system"
fi

# ----------------------------------------------------------------- --list --
show() {
	printf '  %-46s %9s  %-32s %s\n' "source" "size" "md5" "note"
	local i=0 c src label size md5 note
	for c in "${candidates[@]}"; do
		IFS='|' read -r kind src size md5 note _ <<<"$c"
		printf '  [%d] %-42s %9s  %-32s %s\n' "$i" "$kind:$src" "$size" "$md5" "${note:-}"
		i=$((i + 1))
	done
}

if [ "$do_list" = 1 ]; then
	echo "installed set: $DEST"
	if [ -n "$installed_kms_md5" ]; then
		echo "  kms blob    : $installed_kms_md5  (identifies the driver generation)"
	else
		echo "  kms blob    : (none installed yet - no published set to match against)"
	fi
	echo "  $FWNAME: $([ -e "$DEST/$FWNAME" ] && echo present || echo MISSING)"
	echo
	echo "sources:"
	show
	exit 0
fi

# ---------------------------------------------------------------- pick one --
pick=-1
[ ${#candidates[@]} -gt 0 ] || die "no $FWNAME source available - pass --file, --zip or --dir"

# 1. the blob that belongs to the driver generation already installed here
if [ "$pick" -lt 0 ] && [ ${#candidates[@]} -gt 1 ] && [ -n "$installed_kms_md5" ]; then
	i=0
	for c in "${candidates[@]}"; do
		IFS='|' read -r kind src size md5 note kms _ <<<"$c"
		if [ -n "${kms:-}" ] && [ "$kms" = "$installed_kms_md5" ]; then
			pick=$i
			echo "selected [${i}] - its qcdxkmsuc blob matches the one already installed"
			break
		fi
		i=$((i + 1))
	done
fi

# 2. only linux-firmware left? then there is no driver package to match against
#    (and no DriverVer either) - take the preferred one, 21N1 first
if [ "$pick" -lt 0 ] && [ ${#candidates[@]} -gt 1 ]; then
	all_lenovo=1
	for c in "${candidates[@]}"; do
		IFS='|' read -r kind _ <<<"$c"
		[ "$kind" = lenovo ] || all_lenovo=0
	done
	if [ "$all_lenovo" = 1 ]; then
		pick=0
		echo "selected [0] - linux-firmware source, nothing to match against"
	fi
fi

# 3. several Windows driver generations: refuse, unless --force takes the newest
if [ "$pick" -lt 0 ] && [ ${#candidates[@]} -gt 1 ]; then
	if [ "$force" != 1 ]; then
		echo "several candidates and none of them matches the installed firmware set:" >&2
		show >&2
		echo >&2
		die "re-run with --file/--dir to pick one explicitly, or with --force to take the newest"
	fi
	best=''
	best_ts=0
	for c in "${candidates[@]}"; do
		IFS='|' read -r kind src size md5 note _ <<<"$c"
		v=$(echo "$note" | grep -aoE '[0-9]+/[0-9]+/[0-9]+' | head -1)
		[ -n "$v" ] || continue
		ts=$(date -d "$v" +%s 2>/dev/null || echo 0)
		if [ -z "$best" ] || [ "$ts" -gt "$best_ts" ]; then
			best=$c
			best_ts=$ts
		fi
	done
	i=0
	for c in "${candidates[@]}"; do
		[ "$c" = "$best" ] && { pick=$i; break; }
		i=$((i + 1))
	done
	echo "selected [${pick}] - newest driver package"
fi

[ "$pick" -ge 0 ] || pick=0

IFS='|' read -r kind src size md5 note extra source_path <<<"${candidates[$pick]}"

echo "firmware : $FWNAME ($size bytes, md5 $md5)"
echo "source   : $kind:$src"
echo "install  : $DEST/$FWNAME"

if [ "$DEST" = "/lib/firmware/updates/qcom/x1e80100/ASUSTeK/vivobook-s15" ]; then
	[ "$(id -u)" -eq 0 ] || die "please run the install with sudo (or pass --dest for a test install)"
fi

mkdir -p "$DEST"

if [ -n "${source_path:-}" ] && [ -f "$source_path" ]; then
	cp -f "$source_path" "$DEST/$FWNAME"
elif [ "$kind" = lenovo ]; then
	zstd -dc "$src/$FWNAME.zst" >"$DEST/$FWNAME"
elif [ "$kind" = dir ]; then
	cp -f "$src/$FWNAME" "$DEST/$FWNAME"
elif [ "$kind" = file ]; then
	cp -f "$src" "$DEST/$FWNAME"
else
	die "internal error: no way to materialise the candidate"
fi

installed_md5=$(md5_of "$DEST/$FWNAME")
[ "$installed_md5" = "$md5" ] || die "copy mismatch: $DEST/$FWNAME is $installed_md5, expected $md5"
chmod 644 "$DEST/$FWNAME"

if [ "$DEST" = "/lib/firmware/updates/qcom/x1e80100/ASUSTeK/vivobook-s15" ]; then
	mkdir -p "$BACKUP_DIR"
	{
		echo "# installed by scripts/install-video-firmware.sh on $(date -Is)"
		echo "# source: $kind:$src"
		echo "$DEST/$FWNAME $installed_md5"
	} >"$MANIFEST"
	echo "manifest : $MANIFEST"
fi

cat <<EOF

done.  Reload the driver (no reboot needed):

  sudo modprobe -r qcom_iris && sudo modprobe qcom_iris
  dmesg -T | tail -20

Expect no "firmware download failed" line any more, and a /dev/video* per
codec instance.  Check the decode formats with:

  sudo apt install v4l-utils          # if v4l2-ctl is not there yet
  v4l2-ctl -d /dev/video0 --list-formats-out

If the kernel still refuses the blob it is a signed-image mismatch (the Windows
blob of a *different* generation, or the Lenovo one on a board it does not know)
- try another source, or revert:

  sudo scripts/install-video-firmware.sh --revert
EOF
