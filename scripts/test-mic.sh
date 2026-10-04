#!/bin/bash
# Bring a DMIC capture path up with plain amixer and record a sample, bypassing
# UCM / WirePlumber.  Useful to tell "kernel path broken" apart from "only the
# userspace profile is missing".
#
# There are two possible places the mics can be wired to on X1E:
#   va  - the LPASS VA macro (always-on/voice path, hw:<card>,3 = MultiMedia4)
#   tx  - the LPASS TX macro (audio path, hw:<card>,2 = MultiMedia3), which
#         needs the WCD9385 to be present because it lives on the WCD capture
#         dai link
#
# Usage:  ./test-mic.sh [--path va|tx] [card] [seconds]
set -u

PATH_MODE="va"
while [ $# -gt 0 ]; do
	case "$1" in
	--path) PATH_MODE="$2"; shift 2 ;;
	--path=*) PATH_MODE="${1#--path=}"; shift ;;
	-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
	*) break ;;
	esac
done
C="${1:-0}"
SECS="${2:-5}"
OUT="${OUT:-/tmp/mic-test.wav}"
fail=0

case "$PATH_MODE" in
va) PCM_DEV="hw:$C,3" ;;
tx) PCM_DEV="hw:$C,2" ;;
adc) PCM_DEV="hw:$C,2" ;;
*)  echo "unknown --path '$PATH_MODE' (use va|tx|adc)" >&2; exit 1 ;;
esac

cset() {
	local name="$1" val="$2" out
	if out=$(amixer -c"$C" cset name="$name" "$val" 2>&1); then
		echo "  [ ok ] $name = $val"
	else
		echo "  [FAIL] $name = $val"
		echo "$out" | sed 's/^/         /'
		fail=$((fail + 1))
	fi
}

echo "== 相关控件是否存在 =="
amixer -c"$C" scontrols 2>/dev/null | grep -iE "VA|MultiMedia4|DMIC" | sed 's/^/  /' | head -30

echo
if [ "$PATH_MODE" = adc ]; then
	echo "== WCD9385 模拟麦（耳麦，INP2 / ADC2） =="
	cset "MultiMedia3 Mixer TX_CODEC_DMA_TX_3" 1
	# codec side - upstream wcd938x/HeadphoneMicEnableSeq.conf
	cset "ADC2_MIXER Switch" 1
	cset "HDR12 MUX" NO_HDR12
	cset "ADC2 MUX" INP2
	cset "ADC2 Switch" 1
	cset "TX1 MODE" ADC_NORMAL
	# SoC side - upstream qcom-lpass/tx-macro/HeadphoneMicEnableSeq.conf
	cset "TX DEC0 MUX" SWR_MIC
	cset "TX SMIC MUX0" ADC1
	cset "TX_AIF1_CAP Mixer DEC0" 1
	cset "TX_DEC0 Volume" 110
elif [ "$PATH_MODE" = va ]; then
	echo "== 1. FE -> BE 路由（VA capture -> MultiMedia4） =="
	cset "MultiMedia4 Mixer VA_CODEC_DMA_TX_0" 1

	echo "== 2. VA macro: DMIC0 / DMIC1 =="
	cset "VA DEC0 MUX" VA_DMIC
	cset "VA DMIC MUX0" DMIC0
	cset "VA_AIF1_CAP Mixer DEC0" 1
	cset "VA_DEC0 Volume" 100
	cset "VA DEC1 MUX" VA_DMIC
	cset "VA DMIC MUX1" DMIC1
	cset "VA_AIF1_CAP Mixer DEC1" 1
	cset "VA_DEC1 Volume" 100
else
	echo "== 1. FE -> BE 路由（WCD/TX macro capture -> MultiMedia3） =="
	cset "MultiMedia3 Mixer TX_CODEC_DMA_TX_3" 1

	echo "== 2. TX macro: DMIC0 / DMIC1 =="
	cset "TX DEC0 MUX" MSM_DMIC
	cset "TX DMIC MUX0" DMIC0
	cset "TX DMIC MUX1" DMIC1
	cset "TX_AIF1_CAP Mixer DEC0" 1
	cset "TX_AIF1_CAP Mixer DEC1" 1
	cset "TX_DEC0 Volume" 100
	cset "TX_DEC1 Volume" 100
fi

echo
echo "== 3. 录 $SECS 秒（对着麦克风说话，注意下面的电平条 #####） =="
USED="$PCM_DEV"
if ! arecord -D "$USED" -f S16_LE -r 48000 -c 2 -V mono -d "$SECS" "$OUT"; then
	# hw:0,3 is single-substream: if WirePlumber/PipeWire already holds it we
	# get EBUSY.  Fall back to "default", which goes through the PipeWire
	# ALSA plugin - that also exercises the desktop path end to end.
	echo "  $PCM_DEV 打不开（通常是被 PipeWire 占用），改用 default 走 PipeWire 重试"
	USED="default"
	if ! arecord -D "$USED" -f S16_LE -r 48000 -c 2 -V mono -d "$SECS" "$OUT"; then
		echo "  [FAIL] arecord 两种设备都失败"
		echo "         想跑裸设备可以先: systemctl --user stop pipewire wireplumber pipewire-pulse"
		fail=$((fail + 1))
	fi
fi
echo "  (使用 $USED)"

echo
echo "== 4. 回放录音（走默认设备；也可以直接打开 $OUT） =="
aplay "$OUT" 2>/dev/null || echo "  (aplay 失败，手动播放 $OUT 看看)"

echo
if [ "$fail" -ne 0 ]; then
	echo "有 $fail 个步骤失败 —— 把上面的错误发我"
else
	echo "控件全部设置成功。若录到的全是静音："
	echo "  - 看 VA_DEC0/DEC1 Volume 是否被别的服务改回去"
	echo "  - 需要确认 vreg_l1b_1p8（DMIC 偏压）有没有使能"
fi
