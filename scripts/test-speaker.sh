#!/bin/bash
# 手动拉起 WSA 扬声器通路并发声测试（绕过 UCM / WirePlumber）
#
# 目的：区分"内核链路没配好"和"只有 UCM/WirePlumber 那一层没配好"。
# 用法:  ./test-speaker.sh [card]       # 默认 card 0
set -u
C="${1:-0}"
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
amixer -c"$C" scontrols 2>/dev/null | grep -iE "MultiMedia|Spkr|WSA" | sed 's/^/  /' | head -40

echo
echo "== 1. FE -> BE 路由（来自 tplg） =="
cset "WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2" 1

echo "== 2. WSA macro =="
cset "WSA WSA RX0 MUX" AIF1_PB
cset "WSA WSA RX1 MUX" AIF1_PB
cset "WSA WSA_RX0 INP0" RX0
cset "WSA WSA_RX1 INP0" RX1
cset "WSA WSA_COMP1 Switch" 1
cset "WSA WSA_COMP2 Switch" 1

echo "== 3. WSA8845 功放 =="
for s in SpkrLeft SpkrRight; do
	cset "$s WSA MODE" 0
	cset "$s COMP Switch" 1
	cset "$s BOOST Switch" 1
	cset "$s DAC Switch" 1
	cset "$s PBR Switch" 1
	cset "$s VISENSE Switch" 0
	cset "$s PA Volume" 6
done

echo
echo "== 回读关键控件 =="
amixer -c"$C" cget name='WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2' 2>&1 | sed 's/^/  /'

echo
echo "== 播放测试（应该从扬声器出声） =="
speaker-test -D hw:$C,1 -c2 -twav -l1

echo
if [ "$fail" -ne 0 ]; then
	echo "有 $fail 个控件设置失败 —— 把上面 [FAIL] 的行发我"
else
	echo "控件全部设置成功。若仍无声，说明问题在更底层（DAPM/功放供电/SoundWire）。"
fi
