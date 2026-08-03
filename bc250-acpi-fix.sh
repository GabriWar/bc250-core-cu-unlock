#!/usr/bin/env bash
#
# bc250-acpi-fix.sh -- install the 8-core ACPI table override on the AMD BC-250.
#
# The BC-250's stock ACPI tables do not describe usable C-states or P-states, so
# the community replaces them with hand-edited SSDTs. The original 6-core fix is
# bc250-collective/bc250-acpi-fix; the 8-core rebuild used here is:
#
#     https://github.com/mendesrr/bc250-acpi-fix-updated-8c
#
# WHY THIS MATTERS AFTER THE CORE UNLOCK
#
# SSDT-CST declares one processor object per THREAD. The 6-core tables stop at
# C00B (12 threads). Once you unlock all 8 cores you have 16 threads, so CPUs
# 12-15 end up with NO cpuidle states at all -- they cannot enter any C-state and
# sit burning power. Verified on a real board:
#
#     cpu0:  4 idle states
#     cpu6:  4 idle states
#     cpu12: 0 idle states   <-- no C-states
#     cpu14: 0 idle states
#     cpu15: 0 idle states
#
# The 8-core tables extend the declarations to C00F, covering all 16 threads.
#
# Usage:  bc250-acpi-fix.sh {status|install|revert}
#
set -uo pipefail

RAW=https://github.com/mendesrr/bc250-acpi-fix-updated-8c/raw/refs/heads/main
TABLES="SSDT-CST.aml SSDT-PST.aml"

OVERRIDE_DIR=/etc/initcpio/acpi_override
BACKUP_DIR=/etc/initcpio/acpi_override-backups
MKINITCPIO_CONF=/etc/mkinitcpio.conf

die() { echo "error: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

# count ACPI processor objects (C0xx) inside an AML blob
cst_objects() {
    [ -f "$1" ] || { echo 0; return; }
    grep -aoE 'C0[0-9A-F]{2}' "$1" 2>/dev/null | sort -u | wc -l
}

threads() { grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 0; }

cpus_without_idle() {
    local n=0 c
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$c/cpuidle" ] || { n=$((n+1)); continue; }
        compgen -G "$c/cpuidle/state*" >/dev/null || n=$((n+1))
    done
    echo "$n"
}

cmd_status() {
    local t missing n
    t=$(threads); missing=$(cpus_without_idle)
    echo "logical threads: $t"

    if [ -f "$OVERRIDE_DIR/SSDT-CST.aml" ]; then
        n=$(cst_objects "$OVERRIDE_DIR/SSDT-CST.aml")
        echo "installed SSDT-CST: $n processor objects ($(stat -c%s "$OVERRIDE_DIR/SSDT-CST.aml")B)"
        if [ "$n" -lt "$t" ]; then
            echo "  ^ TOO FEW for $t threads -- run 'install' to fix"
        fi
    else
        echo "installed SSDT-CST: none ($OVERRIDE_DIR/SSDT-CST.aml absent)"
    fi

    echo "CPUs with no cpuidle states: $missing"
    if [ "$missing" -gt 0 ]; then
        echo "  affected:"
        for c in /sys/devices/system/cpu/cpu[0-9]*; do
            compgen -G "$c/cpuidle/state*" >/dev/null || echo "    ${c##*/}"
        done
    else
        echo "  all CPUs have idle states -- ACPI tables match the core count"
    fi

    grep -q 'acpi_override' "$MKINITCPIO_CONF" 2>/dev/null \
        && echo "mkinitcpio hook: present" \
        || echo "mkinitcpio hook: MISSING from $MKINITCPIO_CONF"
}

cmd_install() {
    need_root
    command -v curl >/dev/null || command -v wget >/dev/null \
        || die "need curl or wget to fetch the tables"

    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    local f
    for f in $TABLES; do
        echo "fetching $f"
        if command -v curl >/dev/null; then
            curl -fsSL "$RAW/$f" -o "$tmp/$f" || die "download failed: $f"
        else
            wget -qO "$tmp/$f" "$RAW/$f" || die "download failed: $f"
        fi
        [ -s "$tmp/$f" ] || die "$f came back empty"
        head -c4 "$tmp/$f" | grep -q SSDT || die "$f is not an SSDT blob"
    done

    local n; n=$(cst_objects "$tmp/SSDT-CST.aml")
    echo "downloaded SSDT-CST declares $n processor objects (this machine has $(threads) threads)"

    if [ -d "$OVERRIDE_DIR" ] && compgen -G "$OVERRIDE_DIR/*.aml" >/dev/null; then
        local bk="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$bk" && cp "$OVERRIDE_DIR"/*.aml "$bk"/
        echo "backed up existing tables -> $bk"
    fi

    mkdir -p "$OVERRIDE_DIR"
    cp "$tmp"/*.aml "$OVERRIDE_DIR"/
    echo "installed into $OVERRIDE_DIR"

    # NOTE: the acpi_override hook globs *.aml NON-recursively, so backups kept
    # in a subdirectory would be ignored anyway -- but we store them outside the
    # override dir regardless, so nobody can accidentally load two table sets.

    if ! grep -q 'acpi_override' "$MKINITCPIO_CONF" 2>/dev/null; then
        sed -i '/^HOOKS=/ { /acpi_override/q; s/microcode/& acpi_override/; q }' "$MKINITCPIO_CONF"
        echo "added acpi_override to HOOKS in $MKINITCPIO_CONF"
    fi

    echo "rebuilding initramfs..."
    mkinitcpio -P || die "mkinitcpio failed"

    echo
    echo "Reboot, then verify with:  $0 status"
    echo "Expect every CPU to report idle states, and cpupower idle-info to work."
}

cmd_revert() {
    need_root
    local latest
    latest=$(ls -1d "$BACKUP_DIR"/*/ 2>/dev/null | tail -1)
    [ -n "$latest" ] || die "no backup found in $BACKUP_DIR"
    cp "$latest"/*.aml "$OVERRIDE_DIR"/ || die "restore failed"
    echo "restored tables from $latest"
    mkinitcpio -P || die "mkinitcpio failed"
    echo "Reboot to apply."
}

usage() {
    cat <<EOF
bc250-acpi-fix -- 8-core ACPI table override for the AMD BC-250

  status    show thread count, declared processor objects, CPUs missing C-states
  install   fetch the 8-core SSDTs, back up existing ones, rebuild the initramfs
  revert    restore the most recent backup

Needed after unlocking all 8 CPU cores: the 6-core tables only declare 12 threads,
leaving CPUs 12-15 with no C-states at all.

Tables by mendesrr: https://github.com/mendesrr/bc250-acpi-fix-updated-8c
Arch/CachyOS (mkinitcpio) only. For Bazzite/SteamOS see that repo's README.
EOF
}

case "${1:-}" in
    status)  cmd_status ;;
    install) cmd_install ;;
    revert)  cmd_revert ;;
    *)       usage; exit 1 ;;
esac
