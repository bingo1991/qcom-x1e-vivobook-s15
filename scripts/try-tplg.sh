#!/bin/bash
# Try a different machine topology file (tplg) for the sound card.
#
# linux-firmware ships per-machine names for these, but most are *symlinks* to a
# handful of real files (Romulus, DEVKIT, the Yoga Slim 7x one, two Dell ones) -
# see --list.  This machine's "own" file is one of those aliases, so switching
# means borrowing another machine's audio graph.
#
# The tplg is the control skeleton of the card: the "... Audio Mixer
# MultiMediaN" / "TX_CODEC_DMA_TX_3 Capture" names our UCM profile sets come
# from it.  Switch to a topology that does not provide them and UCM cannot open
# the card any more - PipeWire then falls back to 虚拟输出 (Dummy Output), with
# no sound and no microphone until you revert.  That has happened twice here
# (EVK/DEVKIT, then Yoga-Slim7x), so the UCM match is checked *before* touching
# anything.
#
# Usage:
#   ./try-tplg.sh --show               # what is in use right now (no root)
#   ./try-tplg.sh --list               # all candidates + what they resolve to
#   ./try-tplg.sh --check Yoga-Slim7x  # dry run: would the UCM still match?
#   sudo ./try-tplg.sh EVK             # switch (runs the check first)
#   sudo ./try-tplg.sh --force EVK     # ... even if the check says no
#   sudo ./try-tplg.sh --revert        # restore the original link
#
# After switching: sudo reboot, then
#   scripts/mic-scan.sh                                   # both capture paths
#   arecord -D hw:0,3 -f S16_LE -r 48000 -c 4 -d 2 /tmp/va.wav ; echo rc=$?
#   wpctl status                                          # real sink/source left?
#
# hw:0,3 is the VA capture path (internal 4-mic array): it opens today but
# returns all zeros, which is what a topology that never enables the VA PDM
# clock would look like.  hw:0,2 is the codec path (pcm_read EIO today).
set -euo pipefail

FW=/lib/firmware/qcom/x1e80100
DIR="$FW/ASUSTeK/vivobook-s15"
TARGET="$DIR/X1E80100-ASUS-Vivobook-S15-tplg.bin.zst"
BAK=/var/backups/x1e-tplg-original
REPO=$(cd "$(dirname "$0")/.." && pwd)
UCM_DIR="$REPO/ucm"

# ---------------------------------------------------------------- helpers --
# zstd refuses to read a symlink ("is a symbolic link, ignoring") and most of
# these entries are symlinks, so go through stdin.
tplg_strings() { zstd -dc <"$1" 2>/dev/null | strings -n 4 | sort -u; }

# resolve the whole symlink chain; empty if it dangles
leaf() { readlink -e "$1" 2>/dev/null; }

# The control names our UCM profiles set.  A tplg provides them in pieces
# ("RX_CODEC_DMA_RX_0 Audio Mixer" + "MultiMedia1"), so for each name find the
# longest word-prefix the *current* topology actually contains and then require
# the candidate to contain that same prefix.
ucm_control_names() {
	[ -d "$UCM_DIR" ] || return 0
	{
		grep -ohE "name='[^']+'" "$UCM_DIR"/*.conf 2>/dev/null |
			sed "s/name='//; s/'$//"
		grep -ohE '(Playback|Capture)MixerElem "[^"]+"' "$UCM_DIR"/*.conf 2>/dev/null |
			sed 's/.*"\(.*\)"/\1/'
	} | sort -u
}

prefix_in() { # $1 = control name, $2 = strings file
	local -a words
	local i cand
	read -ra words <<<"$1"
	for ((i = ${#words[@]}; i > 0; i--)); do
		cand="${words[*]:0:i}"
		if grep -qF -- "$cand" "$2"; then
			printf '%s' "$cand"
			return 0
		fi
	done
	return 1
}

check_topology() { # $1 = candidate path (unresolved)
	local cand=$1 cand_leaf cur_leaf tmp rc=0
	local -a missing=()
	local lost=0 name p

	cand_leaf=$(leaf "$cand") ||
		{ echo "  ❌ 断链：$(basename "$cand") 解析不到真实文件（符号链接断了吗？）"; return 1; }
	cur_leaf=$(leaf "$TARGET") || cur_leaf=

	if [ -n "$cur_leaf" ] && [ "$cur_leaf" = "$cand_leaf" ]; then
		echo "  ✅ 和当前实际用的拓扑是同一个文件（$(basename "$cand_leaf")）"
		return 0
	fi

	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN
	tplg_strings "$cand_leaf" >"$tmp/cand"
	[ -s "$tmp/cand" ] || { echo "  ❌ 解不开或内容是空的：$cand_leaf"; return 1; }

	echo "  候选：$(basename "$cand_leaf")（解出 $(wc -l <"$tmp/cand") 个字符串）"
	if [ -n "$cur_leaf" ]; then
		tplg_strings "$cur_leaf" >"$tmp/cur"
		echo "  当前：$(basename "$cur_leaf")（$(wc -l <"$tmp/cur") 个）"
		lost=$(comm -23 "$tmp/cur" "$tmp/cand" | wc -l)
		echo "  当前有、候选没有的字符串：$lost 个"

		while IFS= read -r name; do
			[ -n "$name" ] || continue
			p=$(prefix_in "$name" "$tmp/cur") || continue  # 不由 tplg 提供
			grep -qF -- "$p" "$tmp/cand" || missing+=("$name")
		done < <(ucm_control_names)
	fi

	if [ ${#missing[@]} -gt 0 ]; then
		echo
		echo "  ❌ UCM 会打不开：下列控件是 UCM profile 要设的，当前 tplg 有、候选没有"
		printf '       %s\n' "${missing[@]}"
		echo "     换过去 WirePlumber 只会剩「虚拟输出」，Sources 也会消失（前两次就是如此）"
		rc=1
	elif [ -n "$cur_leaf" ] && [ "$lost" -gt 20 ]; then
		echo "  ⚠️  没发现 UCM 直接引用的控件缺失，但两者差异很大（少 $lost 个字符串）；换完先看 wpctl status"
	else
		echo "  ✅ UCM 引用的控件在候选里都还在"
		echo "     （只保证控件层面。换完仍要用 wpctl status 确认 Sink/Sources 没变成「虚拟输出」）"
	fi
	return $rc
}

case "${1:-}" in
--show|"")
	ls -l "$TARGET"
	echo "resolves to: $(leaf "$TARGET" || echo '（断链！）')"
	[ -e "$BAK" ] && echo "backup: $BAK -> $(leaf "$BAK" || echo 'regular file')"
	exit 0
	;;
--list)
	cur_leaf=$(leaf "$TARGET" || true)
	printf '%s %-42s %-6s %s\n' "" "候选" "字符串" "实际用的文件"
	for t in "$FW"/*tplg.bin.zst; do
		[ -e "$t" ] || continue
		l=$(leaf "$t") || { printf '  %-42s %s\n' "$(basename "$t")" "（断链）"; continue; }
		mark=' '
		[ -n "$cur_leaf" ] && [ "$l" = "$cur_leaf" ] && mark='*'
		printf '%s %-42s %-6s %s\n' "$mark" "$(basename "$t")" \
			"$(tplg_strings "$l" | wc -l)" "$(basename "$l")"
	done
	echo
	echo "* = 当前生效"
	echo "注意：很多条目只是同一个真实文件的别名（Zenbook-A14 / Vivobook-16 /"
	echo "      Thinkpad-T14s 都指向 Romulus），真正不同的没几个。"
	exit 0
	;;
--check)
	shift
	NAME=${1:?--check 需要一个名字，例如 --check Yoga-Slim7x（先看 --list）}
	CAND="$FW/X1E80100-$NAME-tplg.bin.zst"
	if [ ! -e "$CAND" ]; then
		matches=()
		for t in "$FW"/*"$NAME"*tplg.bin.zst; do [ -e "$t" ] && matches+=("$t"); done
		[ ${#matches[@]} -eq 1 ] || { echo "匹配到 ${#matches[@]} 个，请说得更准确（--list）" >&2; exit 1; }
		CAND=${matches[0]}
	fi
	echo "== UCM 兼容性预检：$(basename "$CAND") =="
	if check_topology "$CAND"; then exit 0; else exit 1; fi
	;;
--revert)
	[ "$(id -u)" -eq 0 ] || { echo "please run with sudo" >&2; exit 1; }
	if [ -e "$BAK" ]; then
		cp -a "$BAK" "$TARGET"
		echo "restored $TARGET from $BAK"
	else
		# No backup: the original shipped link pointed at the Romulus tplg.
		echo "no backup at $BAK - restoring the original (Romulus) link"
		ln -sf ../../X1E80100-Romulus-tplg.bin.zst "$TARGET"
	fi
	ls -l "$TARGET"
	echo "now reboot and re-test"
	exit 0
	;;
esac

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi
NAME="${1:-}"
if [ -z "$NAME" ]; then
	sed -n '2,/^set -euo/p' "$0" | sed -n 's/^# \{0,1\}//p' | head -n -1
	exit 1
fi
CAND="$FW/X1E80100-$NAME-tplg.bin.zst"

# Forgive the exact name: "Yoga-Slim7x", "LENOVO-Yoga-Slim7x" or the full
# "X1E80100-LENOVO-Yoga-Slim7x-tplg.bin.zst" all work, as long as they identify
# exactly one file (case matters - globs are case sensitive - and
# X1E001DE-DEVKIT is only reachable this way, for instance).
if [ ! -e "$CAND" ]; then
	matches=()
	for t in "$FW"/*"$NAME"*tplg.bin.zst; do
		[ -e "$t" ] || continue
		matches+=("$t")
	done
	[ ${#matches[@]} -eq 1 ] ||
		{ echo "no (unique) topology matching '$NAME' in $FW - try $0 --list" >&2; exit 1; }
	CAND=${matches[0]}
fi
SRC=$(basename "$CAND")
[ -e "$TARGET" ] || { echo "target link missing: $TARGET" >&2; exit 1; }

echo "== 换之前先做 UCM 兼容性预检 =="
if ! check_topology "$CAND"; then
	if [ "$FORCE" != 1 ]; then
		cat >&2 <<EOF

拒绝切换（要看细节：$0 --check $NAME）。
明知会砸掉桌面音频也要换：
    sudo $0 --force $NAME
EOF
		exit 1
	fi
	echo "  （--force：继续；出事用 $0 --revert 回来）"
fi
echo

[ "$(id -u)" -eq 0 ] || { echo "please run with sudo" >&2; exit 1; }

# keep the original once; -a preserves the symlink itself
if [ ! -e "$BAK" ]; then
	cp -a "$TARGET" "$BAK"
	echo "saved original link to $BAK"
fi

# the target lives in ASUSTeK/vivobook-s15/, so ../../ reaches the tplg dir
ln -sf "../../$SRC" "$TARGET"
echo "switched to $SRC:"
ls -l "$TARGET"
echo
cat <<EOF
next:  sudo reboot

然后测量（重点是 VA 那几行 —— 内部 4 麦阵列）：

  scripts/mic-scan.sh
  arecord -D hw:0,3 -f S16_LE -r 48000 -c 4 -d 2 /tmp/va.wav ; echo rc=\$?
  wpctl status        # Sink/Sources 还在不在（别变成「虚拟输出」）

revert with:  sudo $0 --revert
EOF
