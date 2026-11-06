#!/bin/bash
# USB gadget: RNDIS network to the connected PC (usb0 = 192.168.7.2).
set -euo pipefail

GADGET_NAME="${GADGET_NAME:-kenzo}"
GADGET="/sys/kernel/config/usb_gadget/${GADGET_NAME}"
CONFIGFS="/sys/kernel/config"
UDC="${UDC:-}"
PHONE_IP="${PHONE_IP:-192.168.7.2/24}"
IFACE="${IFACE:-usb0}"

# The RNDIS gadget logs "unknown RNDIS 0x0000000 len 16" / "RNDIS command error -524" at KERN_ERR whenever the
# Windows RNDIS driver sends an empty control message. The link still works (SSH proves it) but, with the boot
# cmdline's ignore_loglevel, the messages scribble over fbcon/the login prompt. Keep them in dmesg only.
# Disable with KENZO_QUIET_CONSOLE=0 when debugging.
quiet_console() {
	[[ "${KENZO_QUIET_CONSOLE:-1}" == 1 ]] || return 0
	echo N > /sys/module/printk/parameters/ignore_loglevel 2>/dev/null || true
	echo "3 4 1 3" > /proc/sys/kernel/printk 2>/dev/null || true
}

mount_configfs() {
	if ! mountpoint -q "$CONFIGFS"; then
		mkdir -p "$CONFIGFS"
		mount -t configfs none "$CONFIGFS"
	fi
}

find_udc() {
	local udc

	if [[ -n "$UDC" ]]; then
		echo "$UDC"
		return
	fi

	for _ in $(seq 1 60); do
		udc=$(ls /sys/class/udc 2>/dev/null | head -1 || true)
		[[ -n "$udc" ]] && { echo "$udc"; return; }
		sleep 0.5
	done
	return 1
}

setup_gadget() {
	local udc host_mac dev_mac

	mount_configfs
	[[ -d "$GADGET" ]] && return 0

	mkdir -p "$GADGET"
	cd "$GADGET"

	echo high-speed > max_speed 2>/dev/null || true
	# Google Android RNDIS (native inbox driver in all Windows 10/11 versions without manual inf install)
	echo "${USB_VID:-0x18d1}" > idVendor
	echo "${USB_PID:-0x4ee3}" > idProduct
	echo 0x0200 > bcdDevice
	echo 0x0200 > bcdUSB
	echo 0xef > bDeviceClass; echo 0x04 > bDeviceSubClass; echo 0x01 > bDeviceProtocol

	mkdir -p strings/0x409
	echo "kenzo-usb-net" > strings/0x409/serialnumber
	echo "Google" > strings/0x409/manufacturer
	echo "Kenzo RNDIS Network" > strings/0x409/product

	mkdir -p configs/c.1/strings/0x409
	echo "RNDIS" > configs/c.1/strings/0x409/configuration
	echo 500 > configs/c.1/MaxPower

	mkdir -p functions/rndis.usb0
	# Fixed MACs so the host always sees enx020000000701. RANDOM MACs
	# made a new interface every boot; NetworkManager then DHCP-failed
	# and flushed 192.168.7.1.
	host_mac="${HOST_MAC:-02:00:00:00:07:01}"
	dev_mac="${DEV_MAC:-02:00:00:00:07:02}"
	echo "$host_mac" > functions/rndis.usb0/host_addr
	echo "$dev_mac" > functions/rndis.usb0/dev_addr

	ln -sf functions/rndis.usb0 configs/c.1/

	# Microsoft OS descriptors: RNDIS compatible_id with 5162001 matching Windows rndiscmp.inf
	mkdir -p os_desc
	echo 1 > os_desc/use; echo 0xcd > os_desc/b_vendor_code; echo MSFT100 > os_desc/qw_sign
	echo RNDIS > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
	echo 5162001 > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id
	ln -sf configs/c.1 os_desc/ 

	quiet_console
	udc=$(find_udc) || { echo "usb-gadget: no UDC found" >&2; return 1; }
	echo "$udc" > UDC
	echo "usb-gadget: bound to UDC $udc" >&2
}

wait_iface() {
	for _ in $(seq 1 40); do
		ip link show "$IFACE" &>/dev/null && return 0
		sleep 0.25
	done
	return 1
}

setup_network() {
	wait_iface || { echo "usb-gadget: $IFACE not found" >&2; return 1; }
	ip link set "$IFACE" up
	ip addr flush dev "$IFACE" 2>/dev/null || true
	ip addr add "$PHONE_IP" dev "$IFACE"
	echo "usb-gadget: $IFACE $PHONE_IP ready" >&2
}

teardown_network() {
	ip addr flush dev "$IFACE" 2>/dev/null || true
	ip link set "$IFACE" down 2>/dev/null || true
}

teardown_gadget() {
	[[ -d "$GADGET" ]] || return 0
	echo "" > "$GADGET/UDC" 2>/dev/null || true
	rm -f "$GADGET/os_desc/c.1" 2>/dev/null || true
	rm -f "$GADGET/configs/c.1/rndis.usb0" 2>/dev/null || true
	rmdir "$GADGET/functions/rndis.usb0" 2>/dev/null || true
	rmdir "$GADGET/configs/c.1/strings/0x409" 2>/dev/null || true
	rmdir "$GADGET/configs/c.1" 2>/dev/null || true
	rmdir "$GADGET/strings/0x409" 2>/dev/null || true
	rmdir "$GADGET" 2>/dev/null || true
}

case "${1:-start}" in
	start)
		setup_gadget
		setup_network
		;;
	stop)
		teardown_network
		teardown_gadget
		;;
	restart)
		teardown_network
		teardown_gadget
		setup_gadget
		setup_network
		;;
	*)
		echo "Usage: $0 {start|stop|restart}" >&2
		exit 1
		;;
esac
