#!/bin/bash
# Brute-force scan for the input path the internal microphone array is wired to.
#
# On X1E there are three possible places a mic can sit:
#   * the SoC PDM pins, read by the LPASS VA macro or the LPASS TX macro
#   * the WCD9385's own digital (PDM) mic inputs, forwarded over SoundWire
#   * the WCD9385's analog mic inputs (ADC0..3)
# Only one of them is populated on a given board, and the schematics are not
# public, so try them all and look at the recorded level.
#
# Every candidate is configured with plain amixer, recorded for a couple of
# seconds and scored by RMS.  Nothing here needs a reboot.
#
# Usage:  ./mic-scan.sh [--keep-pipewire] [card] [seconds-per-try]   (整数秒)
#
# PipeWire/WirePlumber are stopped for the scan by default (they hold the raw
# capture PCMs once the UCM "Mic" source exists, and every arecord would then
# fail with EBUSY); they are started again on exit.  --keep-pipewire skips
# that if you really want it.
set -u

STOP_PW=1
while [ $# -gt 0 ]; do
	case "$1" in
	--stop-pipewire) STOP_PW=1; shift ;;
	--keep-pipewire) STOP_PW=0; shift ;;
	-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
	*) break ;;
	esac
done
C="${1:-0}"
SECS_RAW="${2:-2}"
# arecord -d only accepts whole seconds
SECS="${SECS_RAW%.*}"
[ -z "$SECS" ] && SECS=1
[ "$SECS" -lt 1 ] 2>/dev/null && SECS=1
[ "$SECS" != "$SECS_RAW" ] && echo "(arecord -d 只吃整数秒: $SECS_RAW -> $SECS)"
TMP="$(mktemp -d)"

cleanup() {
	rm -f "$TMP"/* 2>/dev/null
	rmdir "$TMP" 2>/dev/null
	if [ "$STOP_PW" = 1 ] && [ "${PW_STOPPED:-0}" = 1 ]; then
		echo
		echo "== 重启会话音频栈 =="
		systemctl --user start pipewire wireplumber pipewire-pulse 2>/dev/null || true
	fi
}
trap cleanup EXIT

if [ "$STOP_PW" = 1 ]; then
	echo "== 暂停 PipeWire/WirePlumber（扫描完自动恢复） =="
	if [ "$(id -u)" -eq 0 ]; then
		echo "!! 以 root 运行：无法访问用户会话，停不掉 PipeWire/WirePlumber。"
		echo "   请改用普通用户执行本脚本（amixer/arecord 不需要 root）。"
	elif systemctl --user stop pipewire wireplumber pipewire-pulse filter-chain 2>/dev/null; then
		PW_STOPPED=1
		sleep 1
	else
		echo "!! 停 PipeWire 失败（不在图形会话里？），采集 PCM 可能被占用。"
	fi
fi

echo "== 设备预检 =="
head -2 /proc/asound/cards 2>/dev/null | sed 's/^/  /'
for d in 2 3; do
	if [ -e "/proc/asound/card$C/pcm${d}c" ]; then
		echo "  hw:$C,$d 存在"
	else
		echo "  hw:$C,$d 不存在！"
	fi
done
echo

CS_FAIL=0
cs() {
	if amixer -c"$C" cset name="$1" "$2" >/dev/null 2>&1; then
		return 0
	fi
	CS_FAIL=$((CS_FAIL + 1))
	return 1
}

# record.  On failure REC_ERR holds the last stderr line.
# arecord prints its normal "Recording WAVE ..." banner to stderr as well, so
# the exit status decides success - never the presence of output.
REC_ERR=""
rec() {
	REC_ERR=""
	if arecord -D "hw:$C,$1" -f S16_LE -r 48000 -c 2 -d "$SECS" "$2" \
			>/dev/null 2>"$TMP/rec.err"; then
		return 0
	fi
	tail -n 1 "$TMP/rec.err" > "$TMP/rec.msg" 2>/dev/null
	read -r REC_ERR < "$TMP/rec.msg" || true
	[ -n "$REC_ERR" ] || REC_ERR="(arecord 没有输出错误信息)"
	return 1
}

# RMS of the *steady state* part only.  The first ~0.6 s of any capture shows
# a big power-up transient (DC step that decays to zero) which is NOT audio
# and which otherwise fakes a healthy RMS on silent paths.
rms() {
	python3 - "$1" <<'PY' 2>/dev/null || echo "n/a"
import sys, wave, struct
w = wave.open(sys.argv[1], 'rb')
skip = int(0.6 * w.getframerate())          # skip the power-up transient
w.setpos(min(skip, w.getnframes()))
d = w.readframes(w.getnframes() - skip)
v = struct.unpack('<%dh' % (len(d) // 2), d) if d else (0,)
print("%.0f" % ((sum(x * x for x in v) / len(v)) ** 0.5))
PY
}

# ---------------------------------------------------------------- helpers
codec_all_dmic_on() {
	for n in 0 1 2 3 4 5 6 7; do cs "DMIC${n} Switch" 1; done
}
# Codec analog mic.  $1 = codec ADC number as it appears in the control names
# (1..4), $2 = input (INP1..INP5).  Note the off-by-one between the codec's
# ADCn and the TX macro's "TX(n-1) MODE" / "ADC(n-1)" SMIC value - this is
# exactly what the upstream headset-mic sequences do:
#   wcd938x/HeadphoneMicEnableSeq.conf  -> ADC2_MIXER, ADC2 MUX = INP2, TX1 MODE
#   qcom-lpass/tx-macro/HeadphoneMicEnableSeq.conf -> TX SMIC MUX0 = ADC1
codec_analog_mic() {	# $1 = ADC number (1..4), $2 = input (INP1..INP5)
	cs "ADC${1}_MIXER Switch" 1
	cs "HDR12 MUX" NO_HDR12
	cs "ADC${1} MUX" "$2"
	cs "ADC${1} Switch" 1
	cs "TX$(( $1 - 1 )) MODE" ADC_NORMAL
}
tx_route() {	# FE -> BE, WCD capture link
	cs "MultiMedia3 Mixer TX_CODEC_DMA_TX_3" 1
}
va_route() {
	cs "MultiMedia4 Mixer VA_CODEC_DMA_TX_0" 1
}

# ---------------------------------------------------------------- candidates
# name|pcm|setup function
try_va_dmic() {	# $1,$2 = DMIC index pair
	va_route
	cs "VA DEC0 MUX" VA_DMIC; cs "VA DMIC MUX0" "DMIC$1"
	cs "VA_AIF1_CAP Mixer DEC0" 1; cs "VA_DEC0 Volume" 100
	cs "VA DEC1 MUX" VA_DMIC; cs "VA DMIC MUX1" "DMIC$2"
	cs "VA_AIF1_CAP Mixer DEC1" 1; cs "VA_DEC1 Volume" 100
}
try_tx_dmic() {	# $1,$2 = DMIC index pair
	tx_route
	cs "TX DEC0 MUX" MSM_DMIC
	cs "TX DMIC MUX0" "DMIC$1"; cs "TX DMIC MUX1" "DMIC$2"
	cs "TX_AIF1_CAP Mixer DEC0" 1; cs "TX_AIF1_CAP Mixer DEC1" 1
	cs "TX_DEC0 Volume" 100; cs "TX_DEC1 Volume" 100
}
try_tx_swr_dmic() {	# $1,$2 = SMIC index (0..7) -> SWR_DMICn
	tx_route
	codec_all_dmic_on
	cs "TX DEC0 MUX" SWR_MIC
	cs "TX SMIC MUX0" "SWR_DMIC$1"; cs "TX SMIC MUX1" "SWR_DMIC$2"
	cs "TX_AIF1_CAP Mixer DEC0" 1; cs "TX_AIF1_CAP Mixer DEC1" 1
	cs "TX_DEC0 Volume" 100; cs "TX_DEC1 Volume" 100
}
try_tx_swr_adc() {	# $1 = ADC number (1..4), $2 = INPx
	tx_route
	codec_analog_mic "$1" "$2"
	cs "TX DEC0 MUX" SWR_MIC
	cs "TX SMIC MUX0" "ADC$(( $1 - 1 ))"
	cs "TX_AIF1_CAP Mixer DEC0" 1
	cs "TX_DEC0 Volume" 110
}

run() {	# $1=label $2=pcm(0..3) $3=setup-func $4..=args
	local label="$1" pcm="$2" fn="$3"; shift 3
	CS_FAIL=0
	"$fn" "$@"
	local out="$TMP/out.wav"
	if ! rec "$pcm" "$out"; then
		printf "%-20s hw:%s,%s  打不开: %s\n" "$label" "$C" "$pcm" "${REC_ERR:-未知错误}"
		return
	fi
	printf "%-20s hw:%s,%s  rms=%-8s (控件失败 %s)\n" \
		"$label" "$C" "$pcm" "$(rms "$out")" "$CS_FAIL"
}

echo "card=$C  每次录 ${SECS}s  —— 请全程对着麦克风大声说话/拍手"
echo

# 先预演一次：15 个候选跑完要几十秒，先确认采集设备真能打开，
# 否则只会刷 15 行一模一样的错误。
probe="$TMP/probe.wav"
probe_ok=0
for d in 3 2; do
	if arecord -D "hw:$C,$d" -f S16_LE -r 48000 -c 2 -d 1 "$probe" >/dev/null 2>"$TMP/probe.err"; then
		echo "（预演：hw:$C,$d 可以打开）"
		probe_ok=1
		break
	fi
	echo "（预演：hw:$C,$d 打开失败）"
done
if [ "$probe_ok" = 0 ]; then
	echo "!! 采集设备打不开，扫描无法进行："
	sed 's/^/   /' "$TMP/probe.err" | head -3
	echo
	echo "   排查建议："
	echo "     fuser -v /dev/snd/pcmC${C}D*c      # 看谁占着"
	echo "     wpctl status                        # Sources 里是不是有活跃流"
	echo "     scripts/mic-scan.sh --keep-pipewire # 不自动停 PipeWire"
	exit 1
fi
echo "（开始扫描，共约 $((15 * SECS)) 秒）"
echo
echo "-- SoC PDM 引脚（VA macro）--"
run "va-dmic01" 3 try_va_dmic 0 1
run "va-dmic23" 3 try_va_dmic 2 3
run "va-dmic45" 3 try_va_dmic 4 5
run "va-dmic67" 3 try_va_dmic 6 7

echo "-- SoC PDM 引脚（TX macro）--"
run "tx-dmic01" 2 try_tx_dmic 0 1
run "tx-dmic23" 2 try_tx_dmic 2 3
run "tx-dmic45" 2 try_tx_dmic 4 5
run "tx-dmic67" 2 try_tx_dmic 6 7

echo "-- WCD9385 数字麦（经 SoundWire）--"
run "swr-dmic01" 2 try_tx_swr_dmic 0 1
run "swr-dmic23" 2 try_tx_swr_dmic 2 3
run "swr-dmic45" 2 try_tx_swr_dmic 4 5
run "swr-dmic67" 2 try_tx_swr_dmic 6 7

echo "-- WCD9385 模拟麦 --"
run "swr-adc1-inp1" 2 try_tx_swr_adc 1 INP1
run "swr-adc2-inp2" 2 try_tx_swr_adc 2 INP2
run "swr-adc3-inp3" 2 try_tx_swr_adc 3 INP3

echo
echo "rms 明显高于其它行的那一条就是对的通路（静音通路通常是 0）。"
echo "把整张表发回来即可。"
