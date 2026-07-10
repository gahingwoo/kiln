#!/usr/bin/env bash
# Kiln install phase 2, run ONCE by kiln-phase2.service on the first boot into the
# patched 7.1.3 kernel (the systemd auto-handoff). It finishes the install FULLY
# OFFLINE from the cache phase 1 pre-downloaded -- the onboard wifi is down until
# this rebuilds it, so it must not need the network, and it doesn't.
#
# It: logs everything to /var/log/kiln-phase2.log, runs phase 2 (the driver +
# runtimes + demos + wifi via kiln-install.sh with the kernel step skipped),
# records a status marker (/etc/kiln/phase2-done or phase2-failed) that the login
# MOTD reports, DISABLES its own service (so it never runs again -- no boot loop),
# and on success reboots a second time into the finished system.
#
# Users who prefer to drive the two phases by hand set KILN_MANUAL=1 in phase 1;
# then this service is never installed and this script is never used.
#
# NOTE: intentionally NOT 'set -e' -- if phase 2 fails we still must reach the
# status marker + self-disable, or the box would re-run this every boot.
set -uo pipefail

# systemd starts us with a minimal environment; make sure the build tools
# (gcc/g++, make, dkms, dpkg, systemctl) resolve regardless.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
KILN_DIR="${KILN_DIR:-/opt/kiln}"
LOG=/var/log/kiln-phase2.log

# tee all output to the log AND the console/journal.
exec > >(tee -a "$LOG") 2>&1
echo
echo "=== kiln-phase2 starting on $(uname -r) ($(date -u '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || echo 'no rtc')) ==="

# Finish the install offline. KILN_SKIP_KERNEL=1: we're already on the patched
# kernel, so skip the kernel check (which would otherwise try to reach GitHub).
if KILN_SKIP_KERNEL=1 bash "$KILN_DIR/scripts/kiln-install.sh"; then
	status=done
else
	status=failed
fi

mkdir -p /etc/kiln
rm -f /etc/kiln/phase2-done /etc/kiln/phase2-failed
: > "/etc/kiln/phase2-$status"
echo "=== kiln-phase2 $status (marker: /etc/kiln/phase2-$status) ==="

# Disable the oneshot so it never fires again -- even on failure, so a broken
# phase 2 can't turn into a reboot loop. The user re-runs it by hand after fixing.
systemctl disable kiln-phase2.service >/dev/null 2>&1 || true

if [ "$status" = done ]; then
	echo "[kiln] phase 2 complete -- rebooting into the finished system (wifi + rknpu)."
	sync
	systemctl reboot
else
	echo "[kiln] phase 2 FAILED. NOT rebooting. Read $LOG, then re-run once fixed:"
	echo "         sudo bash $KILN_DIR/scripts/kiln-install.sh"
fi
