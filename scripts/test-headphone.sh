#!/bin/bash
# Bring the WCD9385 headphone path up with plain amixer and play a tone.
#
# Needs the "full" device tree (build/x1e80100-asus-vivobook-s15-full.dtb):
# the wsa-only variant has no WCD9385 nodes at all.
#
# Usage:  ./test-headphone.sh [card] [seconds]
set -u

C="${1:-0}"
SECS="${2:-3}"
SECS="${SECS%.*}"; [ -z "$SECS" ] && SECS=1; [ "$SECS" -lt 1 ] 2>/dev/null && SECS=1
fail=0

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
amixer -c"$C" scontrols 2>/dev/null | grep -iE "HPHL|HPHR|RX_|RX |Headphone" | sed 's/^/  /' | head -25

echo
echo "== 1. FE -> BE 路由（WCD playback -> MultiMedia1） =="
cset "RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1" 1

echo "== 2. RX macro =="
cset "RX_HPH PWR Mode" LOHIFI
cset "RX_MACRO RX0 MUX" AIF1_PB
cset "RX_MACRO RX1 MUX" AIF1_PB
cset "RX INT0_1 MIX1 INP0" RX0
cset "RX INT1_1 MIX1 INP0" RX1
cset "RX INT0 DEM MUX" CLSH_DSM_OUT
cset "RX INT1 DEM MUX" CLSH_DSM_OUT
cset "RX_COMP1 Switch" 1
cset "RX_COMP2 Switch" 1

echo "== 3. WCD9385 耳机输出 =="
for s in HPHL_RDAC HPHL HPHR_RDAC HPHR CLSH LO; do
	cset "$s Switch" 1
done
cset "HPHR_COMP Switch" 0
cset "HPHL_COMP Switch" 0
cset "RX HPH Mode" CLS_H_ULP
cset "HPHL Volume" 20
cset "HPHR Volume" 20

echo
echo "== 4. 播放测试（插上耳机，应该从耳机出声） =="
echo "  （PCM hw:$C,0 = MultiMedia1 = WCD playback）"
speaker-test -D hw:"$C",0 -c2 -twav -l1

echo
if [ "$fail" -ne 0 ]; then
	echo "有 $fail 个控件设置失败 —— 把上面 [FAIL] 的行发我"
else
	echo "控件全部设置成功。若耳机无声，检查耳机是否插好 + alsamixer 里 HPHL/HPHR Volume。"
fi
