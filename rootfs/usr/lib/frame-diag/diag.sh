#!/bin/sh
# frame-diag <stage>: everything we'd want from a console, written where the Mac
# can read it -- /boot/diag/<stage>.txt on the card's FAT partition -- plus a
# short status block on the glass (/etc/issue, above the login prompt, and
# straight to tty1 for the later stages).
#
# Why: the second card test came back "panel fine, USB enumerates, no carrier,
# no Wi-Fi" with no way in and no console. Every card round-trip is a power-off
# and a swap for the owner, so the card now reports on itself whatever happens.
#
# Never copies /boot/wpa_supplicant.conf, and masks SSIDs in what it does copy.
stage=${1:-now}
dir=/boot/diag
mkdir -p $dir 2>/dev/null || dir=/tmp/diag && mkdir -p $dir
out=$dir/$stage.txt

mask() { sed -e "s/SSID '[^']*'/SSID '<masked>'/g" -e 's/^\(\s*ssid=\).*/\1<masked>/' -e '/psk/d'; }
sec() { printf '\n===== %s\n' "$*"; sh -c "$*" 2>&1; }

{
	echo "frame-diag $stage  $(date)  up $(cut -d' ' -f1 /proc/uptime)s"
	sec uname -a
	sec cat /proc/cmdline
	sec mount
	sec df -h
	sec 'rc-status -a; rc-status --crashed'
	sec 'ls -l /sys/class/net; ip -d addr; ip route'
	sec 'for u in /sys/class/udc/*; do echo "$u state=$(cat $u/state) function=$(cat $u/function 2>/dev/null)"; done'
	sec 'netstat -tulnp'
	sec 'ps -o pid,stat,args'
	sec lsmod
	sec 'iw dev; iw reg get'
	sec 'wpa_cli -i wlan0 status 2>&1 | grep -v "^ssid=\|^bssid=\|psk"'
	sec 'ls -l /boot /boot/wpa_supplicant.conf /etc/wpa_supplicant/; echo "conf: $(grep -c . /boot/wpa_supplicant.conf 2>/dev/null) lines, network blocks=$(grep -c "network=" /boot/wpa_supplicant.conf 2>/dev/null), country=$(grep -o "^country=..." /boot/wpa_supplicant.conf 2>/dev/null), crlf=$(grep -c "$(printf "\r")" /boot/wpa_supplicant.conf 2>/dev/null)"'
	sec 'ls -l /lib/firmware/rtw88/rtw8723d* /lib/firmware/silead /lib/firmware/regulatory.db*'
	sec 'ls -ld /root /root/.ssh /root/.ssh/authorized_keys; grep -c . /root/.ssh/authorized_keys'
	sec 'cat /sys/class/backlight/*/brightness /sys/class/backlight/*/bl_power; cat /sys/class/thermal/thermal_zone0/temp'
	sec 'tail -n 150 /var/log/rc.log'
	sec 'tail -n 80 /var/log/frame-shell.log'
	sec 'grep -v "^$" /var/log/messages | tail -n 300'
	sec dmesg
} 2>&1 | mask > $out.part && mv $out.part $out

# the opt-in hook: /boot/frame-run.sh, if the owner (or we, via the owner) put
# one on the card, runs once per boot as root with its output beside the rest.
# Default off; physical access to the card already means root on this box.
if [ "$stage" = boot ] && [ -f /boot/frame-run.sh ]; then
	timeout 120 sh /boot/frame-run.sh > $dir/run.txt 2>&1
fi

# status block for the glass
ip4() { ip -4 -o addr show dev $1 2>/dev/null | awk '{print $4}'; }
udc=$(cat /sys/class/udc/*/state 2>/dev/null)
wlan=$(wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')
[ -e /sys/class/net/wlan0 ] || wlan="no wlan0"
usb=$(ip4 usb0)
cat > /etc/issue <<EOF

 frame-linux $(uname -r)   diag: $stage $(date +%H:%M:%S)
 usb0  ${usb:-down}   udc ${udc:-none}   ssh root@192.168.7.2
 wlan0 $(ip4 wlan0) ${wlan:-unknown}
 services crashed/stopped: $(rc-status --crashed 2>/dev/null | awk '{printf "%s ", $1}')
 full report: FRAMEBOOT/diag/$stage.txt

EOF
[ "$stage" = early ] || [ "$stage" = boot ] || cat /etc/issue > /dev/tty1 2>/dev/null
sync
