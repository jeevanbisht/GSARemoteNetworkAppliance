#!/bin/sh
#
# rnfleet-console-entry — getty entry wrapper that shows the first-boot
# enrollment wizard on WHICHEVER console the operator is using (the video
# console tty1 AND the serial port ttyS0), then hands off to a normal login
# once the appliance is enrolled.
#
# It is wired as the ExecStart of both getty@tty1.service and
# serial-getty@ttyS0.service (via drop-ins installed by provision-appliance.sh):
#
#     getty@tty1 / serial-getty@ttyS0  ->  rnfleet-console-entry <tty>
#         not enrolled -> run `rnfleet-setup --firstboot` on this tty
#         enrolled     -> exec agetty (standard login)
#
# Running it on both consoles is what makes the wizard appear on the Hyper-V /
# monitor screen AND the serial console at the same time. The wizard itself
# no-ops fast when a pre-seed makes enrollment unattended, or when the box was
# just enrolled from the other console (rnfleet-setup re-checks the sentinel
# before it commits, so there is no double-enrollment).
#
set -u
TTY="${1:-tty1}"
SENTINEL="/var/lib/rnfleet/.configured"

if [ ! -f "$SENTINEL" ] && [ -x /usr/local/sbin/rnfleet-setup ]; then
  # Bind this console's stdio to the wizard. getty already points our stdin/stdout
  # at /dev/$TTY, but redirect explicitly so the wizard's `-t 0` TTY test is true.
  /usr/local/sbin/rnfleet-setup --firstboot <"/dev/$TTY" >"/dev/$TTY" 2>&1 || true
fi

# Hand off to the standard login prompt on this console.
case "$TTY" in
  ttyS*) exec /sbin/agetty --keep-baud 115200,57600,38400,9600 "$TTY" vt220 ;;
  *)     exec /sbin/agetty --noclear "$TTY" linux ;;
esac
