#!/usr/bin/env bash
#
# bc250-8core-unlock.sh -- enable all 8 CPU cores on the AMD BC-250.
#
# The BC-250 ships as a 6-core part, but the two dormant cores are NOT fused
# off: they are masked by a writable SMU register. SMN 0x0115A870 is a core
# enable bitmask -- 0xFF for all eight. From the factory one core per 4-core
# cluster is masked; which one varies by board: 0x77 (cores 3 and 7) is the
# common case, 0x7D (cores 1 and 7) and 0xD7 (cores 3 and 5) have also been
# seen.
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
# boot (power actually removed) resets it to the factory mask -- the built-in
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

UNLOCKED_MASK=0xff
STATE_DIR=/var/lib/bc250-8core-unlock
ORIG_MASK_FILE=$STATE_DIR/factory-mask   # read by test-cores.sh to label new cores

REBOOT_MODE=/sys/kernel/reboot/mode
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

# A factory 6-core mask has exactly one core disabled in each 4-core cluster
# (bits 0-3 and bits 4-7), and nothing above bit 7. Anything else -- fewer
# cores, a lopsided pattern, stray upper bits, or a misread -- is refused.
is_factory_mask() {                            # $1 = decimal mask
    local m=$1 lo hi
    (( (m & ~0xff) == 0 )) || return 1
    lo=$(( m & 0xf )); hi=$(( (m >> 4) & 0xf ))
    case $lo in 7|11|13|14) ;; *) return 1 ;; esac
    case $hi in 7|11|13|14) ;; *) return 1 ;; esac
}

# Remember the factory mask so test-cores.sh can tell which cores are new.
# Best effort only: a failure here must never block or undo the unlock.
save_factory_mask() {                          # $1 = decimal mask
    mkdir -p "$STATE_DIR" 2>/dev/null \
        && printf '0x%02X\n' "$1" > "$ORIG_MASK_FILE" 2>/dev/null \
        || echo "warning: could not record factory mask in $ORIG_MASK_FILE" >&2
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
        *)
            if is_factory_mask "$mask"; then
                echo "state: STOCK (6 cores) -- run 'apply' to unlock"
            else
                echo "state: UNKNOWN mask -- 'apply' will refuse it"
            fi ;;
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
    if ! is_factory_mask "$before"; then
        restore_index "$saved"
        die "refusing: unexpected mask $(printf '0x%02X' "$before") (expected one core off per cluster, e.g. 0x77)"
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
    save_factory_mask "$before"

    echo
    echo "unlocked. cores appear after a WARM reboot:  sudo reboot"
    echo "a cold boot (power removed) reverts to 6 cores."

    if [ "${1:-}" = "--reboot" ]; then
        set_warm_reboot; echo "rebooting..."; exec systemctl reboot
    fi
}

# Boot-time path used by the systemd unit.
#
# This sets the mask and NOTHING ELSE. It deliberately does not reboot.
#
# An earlier version rebooted here so the firmware would re-enumerate in the
# same session. That bootlooped a real board: the reset it triggered did not
# preserve the mask, so every boot read the factory mask, re-applied, and reset again. The
# attempt counter meant to cap that never persisted (/var is not reliably
# writable that early, and the reset was too abrupt to flush), and
# `systemctl reboot` cannot even work before D-Bus is up:
#
#     systemctl[533]: Failed to connect to system scope bus via local transport
#
# So: no automatic reboots, ever. The mask takes effect on your NEXT reboot,
# whenever you choose to do one.
cmd_boot() {
    need_tools
    local saved mask resp after
    saved=$(save_index)
    mask=$(read_mask)

    if [ "$mask" -eq $((UNLOCKED_MASK)) ]; then
        restore_index "$saved"
        echo "already unlocked ($(describe "$mask")) -- nothing to do"; return 0
    fi
    if ! is_factory_mask "$mask"; then
        restore_index "$saved"
        echo "unexpected mask $(printf '0x%02X' "$mask"), not touching anything" >&2
        return 0
    fi

    resp=$(send_unlock)
    after=$(read_mask)
    restore_index "$saved"

    if [ "$after" -ne $((UNLOCKED_MASK)) ]; then
        echo "unlock failed (SMU response $(printf '0x%x' "$resp")) -- staying at 6 cores" >&2
        return 0
    fi
    save_factory_mask "$mask"
    echo "mask set to 0xFF -- all 8 cores will appear on your next reboot"
}

cmd_install() {
    need_root
    install -Dm755 "$0" "$BIN_PATH"

    # Ordinary late-boot unit with normal dependencies. It only writes an SMU
    # register and never reboots, so there is no reason to run it early -- and
    # running early is exactly what broke the previous version.
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=BC-250 8-core unlock (SMU msg 0x98)
Documentation=https://github.com/GabriWar/bc250-core-cu-unlock
After=multi-user.target
ConditionPathExists=/sys/bus/pci/devices/0000:$DEV/config

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN_PATH boot

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$UNIT_NAME"
    echo "installed:"
    echo "  $BIN_PATH"
    echo "  $UNIT_PATH  (enabled)"
    echo
    echo "This unit NEVER reboots. After a cold boot it sets the mask, and the"
    echo "cores appear on your next reboot -- whenever you choose to do one."
}

cmd_uninstall() {
    need_root
    systemctl disable --now "$UNIT_NAME" 2>/dev/null
    rm -f "$UNIT_PATH" "$BIN_PATH"
    rm -rf "$STATE_DIR"                     # recorded factory mask
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

For the GPU compute-unit unlock (24 -> 40 CU), see ./bc250-40cu-unlock.sh

WARNING: this changes the shared SoC power/thermal envelope. Any existing
overclock or undervolt curve must be re-validated afterwards -- see README.
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
