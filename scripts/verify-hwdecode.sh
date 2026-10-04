#!/bin/bash
# Verify that iris (the X1E80100 video decoder) really decodes, and how fast.
#
# Background: this SoC's iris driver is a *stateful* V4L2 mem2mem decoder (it
# has no request API and no stateless controls - see docs/video-decode.md), so
# the working userspace is the ordinary v4l2m2m one:
#
#     ffmpeg -c:v h264_v4l2m2m ...      mpv --hwdec=v4l2m2m-copy ...      gst ... ! v4l2h264dec
#
# "It ran without errors" is not proof though - a broken driver can hand back
# frames full of zeros.  So this script decodes a clip twice - once in hardware
# and once in software - and compares the per-frame checksums (framemd5).  They
# must be identical; the pixel format is forced to yuv420p on both sides so the
# hashes are comparable (NV12 -> yuv420p is a plane reordering, bit exact).
#
# Usage:
#   scripts/verify-hwdecode.sh                # generate a 1080p clip, test it
#   scripts/verify-hwdecode.sh /path/to.mp4   # test an existing file
#   CLIP_SECS=30 scripts/verify-hwdecode.sh   # longer clip (better for speed)
#   KEEP=1 scripts/verify-hwdecode.sh         # keep the temp files around
#
# Exit status: 0 = hardware decode produced byte-identical frames, 2 = it did
# not (or the decoder could not be opened), 3 = ran but the checksums differ.
set -euo pipefail

WORK=${WORK:-/tmp/hwdecode-check}
CLIP_SECS=${CLIP_SECS:-10}
# the decoder under test; hevc_v4l2m2m / vp9_v4l2m2m for other codecs, and
# HW_CODEC=h264 turns this into a self-test of the script itself
HW_CODEC=${HW_CODEC:-h264_v4l2m2m}
CLIP=${1:-}
KEEP=${KEEP:-0}

die() { echo "$*" >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }
have ffmpeg || die "ffmpeg is needed (apt install ffmpeg)"

mkdir -p "$WORK"

# ---------------------------------------------------------------- the clip --
if [ -z "$CLIP" ]; then
	CLIP="$WORK/testsrc-1080p.mp4"
	if [ ! -f "$CLIP" ]; then
		echo "== 生成测试片（1080p / ${CLIP_SECS}s / libx264） =="
		# testsrc2 has moving detail; a plain colour would flatter the decoder
		ffmpeg -hide_banner -loglevel error -y \
			-f lavfi -i "testsrc2=size=1920x1080:rate=30" -t "$CLIP_SECS" \
			-c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p "$CLIP"
	fi
fi
[ -f "$CLIP" ] || die "no such clip: $CLIP"
echo "clip: $CLIP ($(du -h "$CLIP" | cut -f1))"
echo

# ------------------------------------------------------------ the decoder --
if [ ! -e /dev/video0 ]; then
	echo "note: /dev/video0 is not there - is qcom_iris bound?" >&2
fi
ffmpeg -hide_banner -loglevel info -c:v "$HW_CODEC" -i "$CLIP" \
	-pix_fmt yuv420p -f framemd5 "$WORK/hw.md5" 2>"$WORK/hw.log" ||
	{
		grep -iE "v4l2m2m|could not|error|invalid|failed|busy" "$WORK/hw.log" |
			tail -12 >&2 || true
		die "硬件解码打不开（完整日志 $WORK/hw.log）
      常见原因：qcom_iris 没绑定 /dev/video0（scripts/selftest.sh 会报），
      或者这个文件不是 H.264（试试 -c:v hevc_v4l2m2m / vp9_v4l2m2m）"
	}

# the decoder line is the interesting part of the log
grep -iE "Using device|driver '|requesting formats" "$WORK/hw.log" | sed 's/^/  /' || true

echo
echo "== 软解同样的片子（作为参考答案） =="
ffmpeg -hide_banner -loglevel error -i "$CLIP" \
	-pix_fmt yuv420p -f framemd5 "$WORK/sw.md5"

# ---------------------------------------------------------------- compare --
# framemd5 lines: "0, 0, 0, 1, 921600, <hash>" (+ comments).  Strip the
# comments and compare only the hashes.
grep -hv '^#' "$WORK/hw.md5" | awk -F', ' '{print $6}' >"$WORK/hw.hashes"
grep -hv '^#' "$WORK/sw.md5" | awk -F', ' '{print $6}' >"$WORK/sw.hashes"
hw_n=$(wc -l <"$WORK/hw.hashes")
sw_n=$(wc -l <"$WORK/sw.hashes")

if [ "$hw_n" != "$sw_n" ]; then
	echo "FAIL: 帧数不一样（硬解 $hw_n，软解 $sw_n）" >&2
	[ "$KEEP" = 1 ] || rm -rf "$WORK"
	exit 3
fi

if cmp -s "$WORK/hw.hashes" "$WORK/sw.hashes"; then
	echo
	echo "PASS: $hw_n 帧，硬件解码结果与软解逐帧一致"
	RESULT=0
else
	echo
	echo "FAIL: $hw_n 帧里内容不一致（硬解出的是错的/黑帧）：" >&2
	diff <(cat -n "$WORK/hw.hashes") <(cat -n "$WORK/sw.hashes") | head -10 >&2
	RESULT=3
fi

# ------------------------------------------------------------- throughput --
echo
echo "== 吞吐对比 =="
for mode in hw sw; do
	if [ "$mode" = hw ]; then
		args=(-c:v "$HW_CODEC")
	else
		args=()
	fi
	# 3 runs, report the best wall time
	best=
	for _ in 1 2 3; do
		start=$(date +%s.%N)
		ffmpeg -hide_banner -loglevel error "${args[@]}" -i "$CLIP" \
			-pix_fmt yuv420p -f null - 2>/dev/null
		end=$(date +%s.%N)
		t=$(echo "$end $start" | awk '{printf "%.3f", $1-$2}')
		if [ -z "$best" ] || awk -v a="$t" -v b="$best" 'BEGIN { exit !(a < b) }'; then
			best=$t
		fi
	done
	printf '  %-3s decode: %ss  (被测片段越短，初始化开销占比越大)\n' "$mode" "$best"
done

[ "$KEEP" = 1 ] || rm -rf "$WORK"
exit "$RESULT"
