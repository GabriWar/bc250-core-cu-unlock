#!/usr/bin/env bash
#
# bc250-8core-unlock.sh -- enable all 8 CPU cores on the AMD BC-250.
#
# The BC-250 ships as a 6-core part, but the two dormant cores are NOT fused
# off: they are masked by a writable SMU register. SMN 0x0115A870 is a core
# enable bitmask -- 0x77 from the factory (cores 3 and 7 masked), 0xFF for all
# eight.
#
# The mask is flipped with an SMU mailbox command, message 0x98, reached over
# SMN through the PCI config index/data pair 0xB8/0xBC on device 00:00.0:
#
#     SmnWrite32(0x3B10A80, 0)           # clear response register
#     SmnWrite32(0x3B10A88, 0x115A870)   # arg0 = target register
#     SmnWrite32(0x3B10A8C, 0)           # arg1
#     SmnWrite32(0x3B10A20, 0x98)        # message id
#     poll 0x3B10A80 until == 1 (ok) or 0xFC..0xFF (error)
#
# CPU topology is fixed by firmware at reset, so the new cores do not show up
# until the platform re-enumerates. A WARM reset preserves the mask; a cold
# boot (power actually removed) resets it to 0x77 -- which is also the built-in
# escape hatch if anything misbehaves.
#
# Derived by reverse-engineering Bc250CoreUnlockDxe out of the MeiMeiDXE-T-v2
# BIOS mod (Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script).
# This does the same thing from Linux, with no BIOS flash.
#
# Usage:  bc250-8core-unlock.sh {status|apply|boot|install|uninstall}
#
set -uo pipefail

DEV=00:00.0
IDX=0xB8                      # SMN address register
DAT=0xBC                      # SMN data register

MASK_REG=0115A870             # core enable bitmask
RSP_REG=03B10A80              # SMU mailbox response
ARG0_REG=03B10A88             # SMU mailbox arg0
ARG1_REG=03B10A8C             # SMU mailbox arg1
MSG_REG=03B10A20              # SMU mailbox message id
MSG_UNLOCK=98                 # register-write backdoor

STOCK_MASK=0x77
UNLOCKED_MASK=0xff

REBOOT_MODE=/sys/kernel/reboot/mode
STATE_DIR=/var/lib/bc250-8core-unlock
ATTEMPT_FILE=$STATE_DIR/attempts
MAX_ATTEMPTS=2                # hard stop against a reboot loop

BIN_PATH=/usr/local/bin/bc250-8core-unlock
UNIT_NAME=bc250-8core-unlock.service
UNIT_PATH=/etc/systemd/system/$UNIT_NAME

die() { echo "error: $*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

need_tools() {
    command -v setpci >/dev/null || die "setpci not found (install pciutils)"
    [ -e "/sys/bus/pci/devices/0000:$DEV/config" ] \
        || die "PCI device $DEV not found -- is this a BC-250?"
}

# ---------------------------------------------------------------------------
# SMN access
#
# NOTE: amdgpu drives the very same 0xB8/0xBC pair and the same SMU mailbox.
# Reads are idempotent and harmless. For the write sequence we hand the whole
# thing to a SINGLE setpci invocation so the index/data pairs cannot be split
# across process boundaries -- that keeps the interleave window to the syscalls
# inside setpci rather than several process spawns.
# ---------------------------------------------------------------------------

smn_read() {                                  # $1 = hex addr (no 0x)
    setpci -s "$DEV" "$IDX.L=$1" 2>/dev/null
    setpci -s "$DEV" "$DAT.L"    2>/dev/null
}

save_index()    { setpci -s "$DEV" "$IDX.L" 2>/dev/null; }
restore_index() { setpci -s "$DEV" "$IDX.L=$1" 2>/dev/null; }

hex2dec() { printf '%d' "0x${1#0x}" 2>/dev/null || echo 0; }

read_mask() {                                  # -> decimal 0..255
    local v; v=$(smn_read "$MASK_REG")
    echo $(( $(hex2dec "$v") & 0xff ))
}

describe() {                                   # $1 = decimal mask
    local m=$1 on="" off="" i
    for i in 0 1 2 3 4 5 6 7; do
        if (( (m >> i) & 1 )); then on="$on$i "; else off="$off$i "; fi
    done
    printf '0x%02X  enabled=[%s] disabled=[%s]' "$m" "${on% }" "${off% }"
}

send_unlock() {
    # entire mailbox sequence in one setpci call
    setpci -s "$DEV" \
        "$IDX.L=$RSP_REG"  "$DAT.L=00000000" \
        "$IDX.L=$ARG0_REG" "$DAT.L=$MASK_REG" \
        "$IDX.L=$ARG1_REG" "$DAT.L=00000000" \
        "$IDX.L=$MSG_REG"  "$DAT.L=000000$MSG_UNLOCK" 2>/dev/null

    # poll response: done on 1 (ok) or 0xFC..0xFF (error codes)
    local i resp
    for i in $(seq 1 200); do
        resp=$(hex2dec "$(smn_read "$RSP_REG")")
        if [ "$resp" -eq 1 ] || { [ "$resp" -ge 252 ] && [ "$resp" -le 255 ]; }; then
            break
        fi
    done
    echo "$resp"
}

set_warm_reboot() {
    # Match the BIOS driver's EfiResetWarm. A cold-flagged reset is not what
    # was validated, and everything hinges on the mask surviving the reset.
    if [ -w "$REBOOT_MODE" ]; then
        echo warm > "$REBOOT_MODE" 2>/dev/null \
            || echo "warning: could not set warm reboot mode" >&2
    fi
}

get_attempts() { cat "$ATTEMPT_FILE" 2>/dev/null || echo 0; }
set_attempts() { mkdir -p "$STATE_DIR" 2>/dev/null && echo "$1" > "$ATTEMPT_FILE" 2>/dev/null; }

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

cmd_status() {
    need_tools
    local saved mask cores
    saved=$(save_index)
    mask=$(read_mask)
    restore_index "$saved"

    echo "SMN 0x$MASK_REG = $(describe "$mask")"
    case $mask in
        $((UNLOCKED_MASK))) echo "state: UNLOCKED (all 8 cores)" ;;
        $((STOCK_MASK)))    echo "state: STOCK (6 cores) -- run 'apply' to unlock" ;;
        *)                  echo "state: UNKNOWN mask" ;;
    esac

    cores=$(grep '^core id' /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
    echo "cores visible to this kernel: $cores"
    if [ "$mask" -eq $((UNLOCKED_MASK)) ] && [ "$cores" -lt 8 ]; then
        echo "note: mask is set but firmware has not re-enumerated yet -- warm reboot needed"
    fi
}

cmd_apply() {
    need_tools
    local saved before resp after
    saved=$(save_index)
    before=$(read_mask)
    echo "before: $(describe "$before")"

    if [ "$before" -eq $((UNLOCKED_MASK)) ]; then
        restore_index "$saved"; echo "already unlocked, nothing to do"; return 0
    fi
    if [ "$before" -ne $((STOCK_MASK)) ]; then
        restore_index "$saved"
        die "refusing: unexpected mask $(printf '0x%02X' "$before") (expected 0x77)"
    fi

    resp=$(send_unlock)
    after=$(read_mask)
    restore_index "$saved"

    if [ "$resp" -eq 1 ]; then
        echo "SMU response: 0x$(printf '%x' "$resp") (OK)"
    else
        echo "SMU response: 0x$(printf '%x' "$resp") (ERROR/timeout)"
    fi
    echo "after:  $(describe "$after")"

    [ "$after" -eq $((UNLOCKED_MASK)) ] \
        || die "unlock FAILED -- mask unchanged, nothing broken"

    echo
    echo "unlocked. cores appear after a WARM reboot:  sudo reboot"
    echo "a cold boot (power removed) reverts to 6 cores."

    if [ "${1:-}" = "--reboot" ]; then
        set_warm_reboot; echo "rebooting..."; exec systemctl reboot
    fi
}

cmd_boot() {
    need_tools
    local saved mask attempts resp after
    saved=$(save_index)
    mask=$(read_mask)

    if [ "$mask" -eq $((UNLOCKED_MASK)) ]; then
        restore_index "$saved"; set_attempts 0
        echo "already unlocked ($(describe "$mask")) -- continuing boot"; return 0
    fi
    if [ "$mask" -ne $((STOCK_MASK)) ]; then
        restore_index "$saved"
        echo "unexpected mask $(printf '0x%02X' "$mask"), not touching anything" >&2
        return 0
    fi

    attempts=$(get_attempts)
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        restore_index "$saved"
        echo "giving up after $attempts attempts -- mask is not surviving reset. Booting with 6 cores." >&2
        return 0
    fi

    set_attempts $((attempts + 1))
    echo "mask is stock -- unlocking (attempt $((attempts + 1))/$MAX_ATTEMPTS)"

    resp=$(send_unlock)
    after=$(read_mask)
    restore_index "$saved"

    if [ "$after" -ne $((UNLOCKED_MASK)) ]; then
        echo "unlock failed (SMU response $(printf '0x%x' "$resp")) -- booting with 6 cores" >&2
        return 0
    fi

    echo "unlocked -- warm rebooting so firmware enumerates all 8 cores"
    set_warm_reboot
    exec systemctl reboot
}

cmd_install() {
    need_root
    install -Dm755 "$0" "$BIN_PATH"

    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=BC-250 8-core unlock (SMU msg 0x98)
Documentation=https://github.com/gabriwar/bc250-8core-unlock
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target
Conflicts=shutdown.target
ConditionPathExists=/sys/bus/pci/devices/0000:$DEV/config

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN_PATH boot
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=sysinit.target
EOF

    systemctl daemon-reload
    systemctl enable "$UNIT_NAME"
    echo "installed:"
    echo "  $BIN_PATH"
    echo "  $UNIT_PATH  (enabled)"
    echo
    echo "On the next COLD boot the unit unlocks the cores and warm-reboots once,"
    echo "costing about 15 s. Warm reboots keep the mask, so it is a no-op there."
    echo "Capped at $MAX_ATTEMPTS attempts so it can never loop."
}

cmd_uninstall() {
    need_root
    systemctl disable --now "$UNIT_NAME" 2>/dev/null
    rm -f "$UNIT_PATH" "$BIN_PATH"
    rm -rf "$STATE_DIR"
    systemctl daemon-reload
    echo "removed. cores stay unlocked until the next cold boot."
}

usage() {
    cat <<EOF
bc250-8core-unlock -- enable all 8 CPU cores on the AMD BC-250

  status      show the current core mask and visible core count
  apply       unlock now              (--reboot to warm reboot right after)
  boot        boot-time path used by the systemd unit
  install     install binary + systemd unit, and enable it
  uninstall   remove both

Unlock is reverted by any cold boot (power removed). Nothing is written to flash.
EOF
}

case "${1:-}" in
    status)    cmd_status ;;
    apply)     need_root; cmd_apply "${2:-}" ;;
    boot)      need_root; cmd_boot ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    *)         usage; exit 1 ;;
esac
