# ASUS Vivobook S 15 (X1E80100) Linux audio bring-up
#
#   make status     what is (not) applied right now
#   make build      build the DTB (needs the matching kernel source tree)
#   sudo make patch put the DTB into /boot/vmlinuz-$(uname -r)
#   sudo make ucm   install the ALSA UCM profile
#   sudo make hook  also re-apply automatically after apt/dpkg runs

REPO      := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
KVER_BASE := $(shell uname -r | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
# `sudo make ...` resets $HOME to /root, so look up the invoking user's home
# instead - otherwise the kernel source tree "disappears" under sudo.
USER_HOME := $(shell getent passwd $${SUDO_USER:-$$USER} | cut -d: -f6)
KSRC      ?= $(if $(USER_HOME),$(USER_HOME),$(HOME))/Workspace/linux-qcom-x1e-$(KVER_BASE)
DTB       := $(REPO)/build/x1e80100-asus-vivobook-s15-full.dtb
CAM_DTB   := $(REPO)/build/x1e80100-asus-vivobook-s15-cam-cci.dtb
CAMSEN_DTB := $(REPO)/build/x1e80100-asus-vivobook-s15-cam-sensor.dtb

.PHONY: help build build-wsa build-cam-cci build-cam-sensor patch patch-cam-cci patch-cam-sensor ucm reapply status hook unhook selftest speaker devices clean
.DEFAULT_GOAL := help

help:
	@echo "ASUS Vivobook S 15 (X1E80100) Linux audio bring-up"
	@echo
	@echo "  make status     报告当前状态（不需要 root）"
	@echo "  make build      编译 DTB (KSRC=$(KSRC))"
	@echo "  make build-full 同上，但带 WCD9385 耳机/耳麦节点（实验性）"
	@echo "  make build-cam-cci  打开两颗 CCI 摄像头 I²C 控制器（不含 sensor）"
	@echo "  make build-cam-sensor 外加 ov02c10 节点（0x36 / tlmm237 / MCLK4 / l7b+l3m）"
	@echo "  sudo make patch 把 DTB 写进 /boot/vmlinuz-$$(uname -r) 的 .dtbauto 段"
	@echo "  sudo make patch-cam-cci  打上面那份（探摄像头用，见 docs/camera-probe.md）"
	@echo "  sudo make ucm   安装 ALSA UCM profile"
	@echo "  sudo make hook  装 apt hook，升级后自动重打补丁"
	@echo "  make selftest   一键自检并生成报告"
	@echo "  make speaker    手动拉起扬声器链路并测试发声"
	@echo "  make clean      删除 build/ out/"

# "full" carries the WCD9385 nodes (speakers + headphones) and is what we run.
# "wsa" is the speaker-only variant, useful if a machine turns out to have no
# codec (then the full one would fail to register a card).
build:
	KSRC="$(KSRC)" VARIANT=full SYMBOLS=0 OUT="$(DTB)" $(REPO)/scripts/build-dtb.sh

build-wsa:
	KSRC="$(KSRC)" VARIANT=wsa SYMBOLS=0 \
		OUT="$(REPO)/build/x1e80100-asus-vivobook-s15-wsa.dtb" $(REPO)/scripts/build-dtb.sh

# CCI (= the I2C controller camera sensors sit on) is `status = "disabled"` in
# the SoC dtsi, so today this machine has no camera I2C bus at all.  This
# variant enables both controllers and nothing else: no sensor node, no power
# rail, no GPIO.  See docs/camera-probe.md.
build-cam-cci:
	KSRC="$(KSRC)" VARIANT=cam-cci SYMBOLS=0 \
		OUT="$(CAM_DTB)" $(REPO)/scripts/build-dtb.sh

# The full camera attempt: the sensor node plus the rails its own Windows
# resource sequence votes for.  Read dmesg for "ov02c10" after booting it.
build-cam-sensor:
	KSRC="$(KSRC)" VARIANT=cam-sensor SYMBOLS=0 \
		OUT="$(CAMSEN_DTB)" $(REPO)/scripts/build-dtb.sh

patch: $(DTB)
	sudo $(REPO)/scripts/patch-vmlinuz-dtb.py --dtb "$(DTB)"

# Depend on the built file, not on the (phony) build target: otherwise make
# rebuilds under sudo, where the kernel tree cannot be found.
patch-cam-cci:
	@test -f "$(CAM_DTB)" || { \
		echo "$(CAM_DTB) 不存在 - 先跑:  make build-cam-cci" >&2; exit 1; }
	sudo $(REPO)/scripts/patch-vmlinuz-dtb.py --dtb "$(CAM_DTB)"

patch-cam-sensor:
	@test -f "$(CAMSEN_DTB)" || { \
		echo "$(CAMSEN_DTB) 不存在 - 先跑:  make build-cam-sensor" >&2; exit 1; }
	sudo $(REPO)/scripts/patch-vmlinuz-dtb.py --dtb "$(CAMSEN_DTB)"

ucm:
	sudo $(REPO)/scripts/install-vivobook-ucm.sh

reapply:
	sudo $(REPO)/scripts/reapply-after-upgrade.sh

status:
	$(REPO)/scripts/reapply-after-upgrade.sh --status || true
	$(REPO)/scripts/selftest.sh || true

hook:
	sudo $(REPO)/scripts/reapply-after-upgrade.sh --install-hook

unhook:
	sudo $(REPO)/scripts/reapply-after-upgrade.sh --remove-hook

selftest:
	$(REPO)/scripts/selftest.sh

speaker:
	$(REPO)/scripts/test-speaker.sh

devices:
	@echo "sound devices:"; aplay -l 2>/dev/null || true
	@echo; echo "mixers:"; amixer -c0 scontrols 2>/dev/null | head -30 || true

clean:
	rm -rf "$(REPO)/build" "$(REPO)/out"
