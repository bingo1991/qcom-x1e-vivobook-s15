#!/bin/bash
# x1e-selftest.sh - post-boot bring-up self check for the ASUS Vivobook S 15
#                   (Snapdragon X Elite / X1E80100, Ubuntu qcom-x1e kernel).
#
# What it checks
#   1. environment (kernel, cmdline, machine / compatible)
#   2. is a custom device tree actually in use, does it carry the audio nodes,
#      and are the firmware blobs it names present in /lib/firmware
#   3. ADSP / CDSP remoteproc
#   4. kernel modules for the audio stack
#   5. SoundWire bus: which slaves (speaker amps / codec) enumerated
#   6. ALSA: card present? controls present?
#   7. kernel log analysis with hints
#   8. WiFi (ath12k) state, including the known suspend/resume failure
#   9. a PASS/FAIL/WARN summary with next steps
#
# Usage
#   ./selftest.sh                         # run now, save report under <repo>/logs
#   sudo ./selftest.sh                    # same but with full dmesg / debugfs access
#   sudo ./selftest.sh --install          # also run it automatically on every boot
#   sudo ./selftest.sh --uninstall
#
# Exit status: 0 = everything critical is up, 2 = at least one FAIL, 3 = warnings only.
set -u

# systemd starts us with a minimal environment
HOME="${HOME:-/root}"

SELF="$(readlink -f "$0")"
LOGDIR="${LOGDIR:-$(cd "$(dirname "$0")/.." && pwd)/logs}"
OUTFILE="${OUTFILE:-}"
QUIET=0
DO_INSTALL=0
DO_UNINSTALL=0

for arg in "$@"; do
	case "$arg" in
	--install)   DO_INSTALL=1 ;;
	--uninstall) DO_UNINSTALL=1 ;;
	--quiet)     QUIET=1 ;;
	--out=*)     OUTFILE="${arg#--out=}" ;;
	-h|--help)   sed -n '2,30p' "$SELF"; exit 0 ;;
	*)           echo "unknown option: $arg" >&2; exit 1 ;;
	esac
done

if [ "$DO_UNINSTALL" = 1 ]; then
	[ "$(id -u)" = 0 ] || { echo "need root" >&2; exit 1; }
	systemctl disable --now x1e-selftest.service 2>/dev/null || true
	rm -f /etc/systemd/system/x1e-selftest.service /usr/local/sbin/x1e-selftest.sh
	systemctl daemon-reload
	echo "uninstalled"
	exit 0
fi

if [ "$DO_INSTALL" = 1 ]; then
	[ "$(id -u)" = 0 ] || { echo "need root" >&2; exit 1; }
	install -m 0755 "$SELF" /usr/local/sbin/x1e-selftest.sh
	cat > /etc/systemd/system/x1e-selftest.service <<'EOF'
[Unit]
Description=X1E board bring-up self check
After=multi-user.target sound.target
Wants=sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/x1e-selftest.sh --out=/var/log/x1e-selftest.log
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now x1e-selftest.service
	echo "installed; report: /var/log/x1e-selftest.log  (journalctl -u x1e-selftest)"
	exit 0
fi

if [ -z "$OUTFILE" ]; then
	mkdir -p "$LOGDIR"
	OUTFILE="$LOGDIR/selftest-$(date +%Y%m%d-%H%M%S).log"
else
	mkdir -p "$(dirname "$OUTFILE")"
fi
# everything below goes to the report *and* to the console
exec > >(tee "$OUTFILE") 2>&1

SUMMARY=()
PASS=0; FAIL=0; WARN=0
ok()   { SUMMARY+=("PASS|$*"); }
warn() { SUMMARY+=("WARN|$*"); }
bad()  { SUMMARY+=("FAIL|$*"); }
hdr()  { printf '\n===== %s =====\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }
sread() { [ -r "$1" ] && tr -d '\0' < "$1" || echo "?"; }

echo "X1E self test - $(date)"
echo "report: $OUTFILE"

# ---------------------------------------------------------------- 1. environment
hdr "1. environment"
KVER="$(uname -r)"
echo "kernel     : $KVER"
echo "uptime     : $(uptime -p 2>/dev/null || cat /proc/uptime)"
echo "cmdline    : $(cat /proc/cmdline)"
case "$(cat /proc/cmdline)" in
*x1e_dtb=*) echo "dtb marker : $(sed -n 's/.*\(x1e_dtb=[^ ]*\).*/\1/p' /proc/cmdline) (dedicated menu entry)" ;;
*)          echo "dtb marker : none (either the stock entry, or the auto /boot/dtb-\$(uname -r) path)" ;;
esac
if [ -e "/boot/dtb-$(uname -r)" ]; then
	echo "auto dtb   : /boot/dtb-$(uname -r) exists"
else
	echo "auto dtb   : /boot/dtb-$(uname -r) absent"
fi
echo "model      : $(sread /proc/device-tree/model)"
echo "compatible : $(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null)"
echo "boot id    : $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"

# ---------------------------------------------------------------- 2. device tree
hdr "2. device tree (is our custom DTB live?)"
DT_SOUND=0
if [ -e /proc/device-tree/sound ]; then
	DT_SOUND=1
	sc="$(tr '\0' ' ' < /proc/device-tree/sound/compatible 2>/dev/null)"
	echo "sound node : present, compatible = $sc"
	case "$sc" in
	*qcom,x1e80100-sndcard*) ok "DTB: sound 节点存在且 compatible 正确" ;;
	*) warn "DTB: sound 节点存在但 compatible 不是 qcom,x1e80100-sndcard ($sc)" ;;
	esac
else
	echo "sound node : MISSING"
	bad "DTB: 没有 sound 节点 -> 自定义 DTB 没生效"
fi

SPKR_NODE="/proc/device-tree/soc@0/soundwire@6b10000/speaker@0,0"
if [ -e "$SPKR_NODE" ]; then
	echo "custom flag: speaker@0,0 present, compatible = $(tr '\0' ' ' < "$SPKR_NODE/compatible" 2>/dev/null)"
	CUSTOM_DTB=1
elif [ "$DT_SOUND" = 1 ]; then
	echo "custom flag: sound node present but no speaker@0,0 node (不是我们那份 DTB)"
	CUSTOM_DTB=2
else
	CUSTOM_DTB=0
fi

for n in speaker@0,0 speaker@0,1 codec@0,4 codec@0,3; do
	if [ -e "/proc/device-tree/soc@0/soundwire@6b10000/$n" ] \
	   || [ -e "/proc/device-tree/soc@0/soundwire@6ad0000/$n" ] \
	   || [ -e "/proc/device-tree/soc@0/soundwire@6d30000/$n" ]; then
		echo "  node $n : present"
	else
		echo "  node $n : absent"
	fi
done

# The DTB names the firmware of everything it drives (ADSP, CDSP, GPU zap
# shader, iris video).  A blob that is missing there stays silent until the
# subsystem is actually used - which is how the missing qcvss8380.mbn went
# unnoticed for so long - so check them all up front.
echo
echo "--- firmware blobs named by the device tree ---"
FW_TOTAL=0
FW_MISSING=()
while IFS= read -r fwnode; do
	[ -f "$fwnode" ] || continue
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		FW_TOTAL=$((FW_TOTAL + 1))
		found=
		for base in /lib/firmware/updates /lib/firmware; do
			for suffix in "" .zst .xz; do
				if [ -e "$base/$name$suffix" ]; then
					found="$base/$name$suffix"
				fi
			done
		done
		if [ -n "$found" ]; then
			echo "  [ ok ] $name"
		else
			echo "  [MISS] $name"
			FW_MISSING+=("$name")
		fi
	done < <(tr '\0' '\n' < "$fwnode")
# note the trailing slash: /proc/device-tree is a symlink to
# /sys/firmware/devicetree/base and find does not descend into a symlink
done < <(find /proc/device-tree/ -name firmware-name 2>/dev/null)

if [ "$FW_TOTAL" -gt 0 ]; then
	if [ ${#FW_MISSING[@]} -eq 0 ]; then
		ok "固件: DT 点名的 $FW_TOTAL 个 blob 全都在 /lib/firmware"
	else
		bad "DT 点名的固件不存在: ${FW_MISSING[*]}"
		echo "    -> iris/VSS (qcvss8380.mbn) 用 scripts/install-video-firmware.sh 补"
	fi
fi

# ---------------------------------------------------------------- 3. remoteproc
# The firmware check above only says the file exists - the interesting part is
# whether the iris driver actually came up with it (see docs/video-decode.md).
# On success the driver prints nothing at all, so do not judge by dmesg.
if [ -d /proc/device-tree/soc@0/video-codec@aa00000 ]; then
	iris_nodes=
	for v in /sys/class/video4linux/video*; do
		[ -d "$v" ] || continue
		case "$(cat "$v/name" 2>/dev/null)" in
		qcom-iris*) iris_nodes="$iris_nodes $(basename "$v")" ;;
		esac
	done
	if [ -n "$iris_nodes" ]; then
		echo "  iris    :${iris_nodes}"
		ok "视频硬解: qcom_iris 已绑定，节点${iris_nodes}"
	else
		warn "视频硬解: 没有 qcom-iris 的 /dev/video*（固件没装或没装对）"
	fi
fi

hdr "3. remoteproc (ADSP / CDSP)"
for rp in /sys/class/remoteproc/*; do
	[ -e "$rp" ] || continue
	st="$(cat "$rp/state" 2>/dev/null)"
	fw="$(cat "$rp/firmware" 2>/dev/null)"
	echo "$(basename "$rp"): $st <- $fw"
	case "$fw" in
	*qcadsp*|*adsp*)
		[ "$st" = running ] && ok "ADSP running" || bad "ADSP 不是 running ($st)" ;;
	*qccdsp*|*cdsp*) : ;;
	esac
done

# ---------------------------------------------------------------- 4. modules
hdr "4. audio modules"
MODS="snd_soc_x1e80100 snd_soc_qcom_sdw snd_soc_wsa884x snd_soc_wcd938x snd_soc_wcd938x_sdw \
      snd_soc_lpass_wsa_macro snd_soc_lpass_va_macro snd_soc_lpass_rx_macro \
      snd_soc_lpass_tx_macro snd_soc_lpass_macro_common \
      soundwire_qcom snd_q6apm q6apm_dai q6apm_lpass_dais q6prm q6prm_clocks \
      snd_q6dsp_common apr"
for m in $MODS; do
	if grep -q "^$m " /proc/modules 2>/dev/null; then
		echo "loaded   : $m"
	elif [ -e "/sys/module/$m" ]; then
		echo "builtin  : $m"
	else
		echo "absent   : $m"
	fi
done

if [ -e /sys/module/snd_soc_x1e80100 ] || grep -q "^snd_soc_x1e80100 " /proc/modules 2>/dev/null; then
	ok "机器驱动 snd_soc_x1e80100 已加载"
else
	warn "机器驱动 snd_soc_x1e80100 未加载（通常= sound 节点没被驱动匹配）"
fi

# ---------------------------------------------------------------- 5. soundwire
hdr "5. SoundWire"
if [ -d /sys/bus/soundwire/devices ]; then
	sw="$(ls /sys/bus/soundwire/devices 2>/dev/null | tr '\n' ' ')"
	if [ -n "$sw" ]; then
		echo "slaves/masters: $sw"
		echo "$sw" | tr ' ' '\n' | grep -c ':' | sed 's/^/slave count(approx): /'
		ok "SoundWire 总线上有设备枚举"
	else
		echo "(empty)"
		bad "SoundWire 没有任何设备 -> 功放/编解码器没上电或复位不对"
	fi
else
	echo "(soundwire bus not registered)"
	bad "SoundWire 总线未注册（swr0/1/2 没 enable 或驱动没加载）"
fi
if [ -r /sys/kernel/debug/soundwire ]; then
	echo "--- debugfs ---"
	ls /sys/kernel/debug/soundwire 2>/dev/null
	for f in /sys/kernel/debug/soundwire/master*/status /sys/kernel/debug/soundwire/*/status; do
		[ -r "$f" ] && { echo "$f:"; sed 's/^/    /' "$f"; }
	done
fi

# ---------------------------------------------------------------- 6. ALSA
hdr "6. ALSA"
if [ -e /proc/asound/cards ]; then
	cards="$(cat /proc/asound/cards)"
	echo "$cards"
	if echo "$cards" | grep -q '^ *[0-9]'; then
		ok "ALSA 声卡已注册"
		if [ -d /dev/snd ]; then
			have aplay && aplay -l 2>&1 | sed 's/^/    /'
		else
			warn "此 shell 里没有 /dev/snd（受限 /dev），请在普通终端执行 aplay -l / speaker-test"
		fi
		if have amixer; then
			echo "--- controls (c0) ---"
			amixer -c0 scontrols 2>&1 | sed 's/^/    /' | head -40
			if amixer -c0 scontrols 2>/dev/null | grep -qi 'SpkrLeft'; then
				ok "混音控件里有 SpkrLeft（功放节点已探测）"
			else
				warn "混音控件里没有 SpkrLeft（功放可能没起来）"
			fi
		fi
	else
		bad "没有 ALSA 声卡 -> 见日志分析一节"
	fi
else
	bad "/proc/asound/cards 不存在（snd 模块没加载）"
fi
[ -d /dev/snd ] && echo "/dev/snd entries: $(ls /dev/snd | tr '\n' ' ')" \
		|| echo "/dev/snd missing"

# ---------------------------------------------------------------- 7. log
hdr "7. kernel log analysis"
LOG=""
if dmesg >/dev/null 2>&1; then
	LOG="$(dmesg)"
	SRC=dmesg
	elif [ -r /var/log/kern.log ]; then
		# keep only the part belonging to the current boot: everything after the
		# last "Linux version ..." banner
		if have tac; then
		LOG="$(tac /var/log/kern.log 2>/dev/null | awk '{print} index($0,"Linux version"){exit}' | tac 2>/dev/null)"
		else
			LOG="$(cat /var/log/kern.log)"
		fi
	SRC=/var/log/kern.log
elif have journalctl && journalctl -k -b 0 --no-pager >/dev/null 2>&1; then
	LOG="$(journalctl -k -b 0 --no-pager)"
	SRC=journal
else
	echo "(no log access - rerun with sudo for this section)"
	warn "拿不到内核日志，音频/固件细节无法分析（用 sudo 重跑）"
fi
if [ -n "$LOG" ]; then
	echo "log source : $SRC"
	if ! echo "$LOG" | grep -q "Linux version"; then
		warn "日志里没有本次启动的 banner，可能混入上一次启动的内容"
	fi
	echo "--- audio related ---"
	echo "$LOG" | grep -iE 'x1e80100-sndcard|snd-soc-x1e80100|snd_soc_x1e80100|wsa884|wcd938|q6apm|q6prm|apr |soundwire|swr[0-9]' \
		| tail -40 | sed 's/^/    /'
	echo "--- hints ---"
	if echo "$LOG" | grep -qiE 'x1e80100-sndcard.*(defer|EPROBE_DEFER)'; then
		warn "机器驱动 probe deferred：某个 codec/功放没就绪，先只留 WSA 再逐步加回"
	elif echo "$LOG" | grep -iE 'wsa884|wcd938|sdw|soundwire' \
			| grep -qiE 'error|fail|timeout|clash|defer'; then
		echo "    有 codec/功放相关错误，重点看上面的行"
	else
		echo "    (codec/功放日志都是 'bound ...' 这类正常信息)"
	fi
	if echo "$LOG" | grep -q "no matching ACPI device found"; then
		echo "    注: 'no matching ACPI device found, ignoring peripheral' 是纯 DT 启动路径下的正常提示"
		echo "        （功放已经通过 DT 绑定到 wsa884x-codec，看下一节的 Attached 状态）"
	fi
	if echo "$LOG" | grep -q "Bus clash"; then
		warn "SoundWire 总线冲突（WCD9385 TX 侧），会卡住 codec 的采集路径 —— 见 docs/audio-bringup.md"
	fi
	echo "$LOG" | grep -iE 'asoc.*(fail|error)|failed to (create|register).*(card|dai)|-EPROBE_DEFER' \
		| tail -20 | sed 's/^/    /'
	echo "--- other qcom/audio/pci errors ---"
	echo "$LOG" | grep -iE '(error|fail|timeout|denied)' \
		| grep -iE 'qcom|remoteproc|adsp|cdsp|snd|asoc|sound|pci|ath12k|firmware|regulator' \
		| grep -viE 'apparmor|audit' | tail -20 | sed 's/^/    /'
	echo "--- missing firmware blobs ---"
	miss="$(echo "$LOG" | grep -oE 'Direct firmware load for [^ ]+ failed' | sort -u)"
	if [ -n "$miss" ]; then
		while read -r line; do
			fw="${line#Direct firmware load for }"; fw="${fw% failed}"
			if [ -e "/lib/firmware/$fw" ] || [ -e "/lib/firmware/$fw.zst" ] \
			   || [ -e "/lib/firmware/updates/$fw" ]; then
				echo "    $fw  (文件现在存在 -> 多半是早期探测时未就绪，可忽略)"
			else
				echo "    $fw  (真的缺文件)"
				bad "固件缺失: $fw"
			fi
		done <<< "$miss"
	else
		echo "    (none)"
	fi
	echo "--- ADSP audio service ---"
	if echo "$LOG" | grep -qiE 'gprsvc.*CMD timeout|qcom-apm.*timeout'; then
		echo "$LOG" | grep -iE 'gprsvc|qcom-apm' | tail -5 | sed 's/^/    /'
		warn "ADSP 音频服务(APM/GPR)有命令超时，声卡起来后也可能没有声音"
	else
		echo "    (no APM/GPR timeout)"
	fi
fi

# ---------------------------------------------------------------- 8. wifi
hdr "8. wifi (ath12k)"
WDEV=""
for d in /sys/class/net/*; do
	drv="$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null)"
	case "$drv" in
	ath12k*|ath11k*|ath10k*) WDEV="$(basename "$d")" ;;
	esac
done
if [ -n "$WDEV" ]; then
	echo "interface  : $WDEV"
	echo "driver     : $(basename "$(readlink -f /sys/class/net/$WDEV/device/driver)")"
	echo "operstate  : $(cat /sys/class/net/$WDEV/operstate 2>/dev/null)"
	echo "mac        : $(cat /sys/class/net/$WDEV/address 2>/dev/null)"
	if [ "$(cat /sys/class/net/$WDEV/operstate 2>/dev/null)" = up ]; then
		ok "WiFi $WDEV 处于 up"
	elif [ "$(cat /sys/class/net/$WDEV/carrier 2>/dev/null)" = 1 ]; then
		ok "WiFi $WDEV 已关联（carrier=1）"
	else
		warn "WiFi $WDEV 存在但未连接（若刚睡醒过，见下面）"
	fi
else
	bad "没有找到 ath12k 无线网卡"
fi
if [ -n "$LOG" ]; then
	n_to="$(echo "$LOG" | grep -c 'wmi command .* timeout')"
	n_mac="$(echo "$LOG" | grep -c 'fail to start mac operations')"
	echo "wmi timeouts: $n_to, mac-start failures: $n_mac"
	if [ "$n_to" -gt 0 ] || [ "$n_mac" -gt 0 ]; then
		bad "ath12k 固件卡死（挂起唤醒后常见）——临时恢复: sudo modprobe -r ath12k_wifi7 ath12k && sudo modprobe ath12k"
		echo "    永久规避: sudo scripts/install-wifi-suspend-hook.sh（睡前卸载、唤醒重载）"
		echo "$LOG" | grep -iE 'ath12k.*(timeout|fail to start mac)' | tail -5 | sed 's/^/    /'
	else
		ok "本次启动没有 ath12k timeout"
	fi
fi
if [ -x /usr/lib/systemd/system-sleep/ath12k-reload.sh ]; then
	ok "ath12k 挂起/唤醒 hook 已安装"
else
	warn "未安装 ath12k 挂起 hook（sudo scripts/install-wifi-suspend-hook.sh）"
fi

# ---------------------------------------------------------------- 9. summary
hdr "9. summary"
for line in "${SUMMARY[@]}"; do
	tag="${line%%|*}"; msg="${line#*|}"
	case "$tag" in
	PASS) PASS=$((PASS+1)); printf '  [ OK ] %s\n' "$msg" ;;
	WARN) WARN=$((WARN+1)); printf '  [WARN] %s\n' "$msg" ;;
	FAIL) FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$msg" ;;
	esac
done
echo
echo "  pass=$PASS warn=$WARN fail=$FAIL"
echo
echo "下一步："
if [ "$DT_SOUND" = 0 ]; then
	echo "  - 自定义 DTB 没生效：sudo scripts/reapply-after-upgrade.sh 重打一次"
elif [ "$FAIL" -gt 0 ]; then
	echo "  - 回看 docs/audio-bringup.md 的「症状 -> 下一步」表"
	echo "  - 若是升级后失效：sudo scripts/reapply-after-upgrade.sh"
	echo "  - 把这份报告 ($OUTFILE) 发回来"
else
	echo "  - 全部关键项正常，试: speaker-test -c2 -twav -l1"
fi
echo
echo "报告文件: $OUTFILE"

[ "$FAIL" -gt 0 ] && exit 2
[ "$WARN" -gt 0 ] && exit 3
exit 0
