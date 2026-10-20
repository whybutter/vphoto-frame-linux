#!/bin/sh
# Later snapshots: Wi-Fi association and DHCP land after the boot report.
sleep 60;  /usr/lib/frame-diag/diag.sh 60s
sleep 120; /usr/lib/frame-diag/diag.sh 180s
while sleep 600; do /usr/lib/frame-diag/diag.sh now; done
