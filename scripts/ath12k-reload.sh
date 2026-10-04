#!/bin/sh
# Reload the ath12k modules around suspend/resume.
#
# The WCN7850 (ath12k_wifi7) on this machine does not survive a suspend/resume
# cycle: after resuming, the driver loops with
#
#   ath12k_wifi7_pci 0004:01:00.0: wmi command 16387 timeout
#   ath12k_wifi7_pci 0004:01:00.0: failed to send WMI_PDEV_SET_PARAM cmd
#   ath12k_wifi7_pci 0004:01:00.0: failed to enable PMF QOS: -11
#   ath12k_wifi7_pci 0004:01:00.0: fail to start mac operations in pdev idx 0 ret -11
#
# and WiFi stays dead until the modules are reloaded.  Unloading them *before*
# the suspend avoids that entirely: the firmware gets downloaded and started
# from scratch on the way back up instead of being asked to resume.
#
# Install with scripts/install-wifi-suspend-hook.sh.

MODPROBE=/usr/sbin/modprobe

case "$1" in
pre)
	# ath12k_wifi7 owns the PCI driver and depends on ath12k,
	# so the dependent module goes first.
	echo "ath12k-reload: unloading ath12k_wifi7/ath12k before $2"
	"$MODPROBE" -r ath12k_wifi7 ath12k || true
	;;
post)
	echo "ath12k-reload: reloading ath12k_wifi7 after $2"
	"$MODPROBE" ath12k_wifi7 || true
	;;
esac

exit 0
