#!/usr/bin/env bash
#
# bc250-40cu-unlock.sh -- enable all 40 GPU compute units on the AMD BC-250.
#
# This is a DIFFERENT mechanism from the CPU core unlock in this repo. The CU
# count is controlled by amdgpu, not by the SMU:
#
#   CC_GC_SHADER_ARRAY_CONFIG   tells the driver how many CUs exist
#   SPI_PG_ENABLE_STATIC_WGP_MASK  tells the SPI where to dispatch waves
#
# Both must be modified together or you get no compute scaling.
#
# The unlock itself is duggasco's work -- the kernel patch, the dual-register
# analysis and the whitepaper all live at:
#
#     https://github.com/duggasco/bc250-40cu-unlock
#
# This script does not reimplement any of that. It only manages the persistent
# configuration for the patched kernel: writing the modprobe.d entry, rebuilding
# the initramfs, and reporting state.
#
# Deliberately NOT done here: poking the GPU registers at runtime via umr or
# amdgpu debugfs. That path exists, but it races the live driver and has not
# been verified by this project. The kernel-patch route is what people run.
#
# Usage:  bc250-40cu-unlock.sh {status|enable|disable}
#
set -uo pipefail

CU_PARAM=/sys/module/amdgpu/parameters/bc250_cc_write_mode
CU_MODPROBE=/etc/modprobe.d/bc250-40cu.conf
CU_MODE=3                      # 3 = clear all shader arrays -> all 40 CUs
STOCK_CU=24
FULL_CU=40

need_root() { [ "$(id -u)" -eq 0 ] || { echo "error: must run as root" >&2; exit 1; }; }

kernel_supported() { [ -e "$CU_PARAM" ]; }

active_cu() {
    # the driver prints the final CU count during init
    dmesg 2>/dev/null | grep -oP 'active_cu_number \K[0-9]+' | tail -1
}

rebuild_initramfs() {
    if command -v mkinitcpio >/dev/null; then
        mkinitcpio -P >/dev/null 2>&1 && echo "regenerated initramfs (mkinitcpio)"
    elif command -v dracut >/dev/null; then
        dracut --force >/dev/null 2>&1 && echo "regenerated initramfs (dracut)"
    elif command -v update-initramfs >/dev/null; then
        update-initramfs -u >/dev/null 2>&1 && echo "regenerated initramfs (update-initramfs)"
    else
        echo "note: no known initramfs tool found -- rebuild it yourself if your" \
             "distro loads amdgpu from the initramfs"
    fi
}

no_kernel_patch() {
    cat >&2 <<EOF
error: this kernel does not support the CU unlock.

It needs duggasco's amdgpu patch, which adds the bc250_cc_write_mode module
parameter. Build it from:

    https://github.com/duggasco/bc250-40cu-unlock

On Arch/CachyOS this means rebuilding your kernel package with the patch
applied; on Debian/Bazzite the repo ships a helper script.
EOF
}

cmd_status() {
    local n mode
    n=$(active_cu)
    echo "active_cu_number (dmesg): ${n:-unknown}"

    if kernel_supported; then
        mode=$(cat "$CU_PARAM" 2>/dev/null)
        echo "kernel patch:  present (bc250_cc_write_mode=$mode)"
    else
        echo "kernel patch:  NOT present -- no bc250_cc_write_mode parameter"
    fi

    if [ -f "$CU_MODPROBE" ]; then
        # show only the effective option line, not the comments around it
        echo "modprobe conf: $CU_MODPROBE"
        grep -E '^[[:space:]]*options' "$CU_MODPROBE" | sed 's/^/               /'
    else
        echo "modprobe conf: absent (would not persist across reboots)"
    fi

    if command -v vulkaninfo >/dev/null 2>&1; then
        local vk
        vk=$(RADV_DEBUG=info vulkaninfo --summary 2>/dev/null | grep -oP 'num_cu\s*=?\s*\K[0-9]+' | head -1)
        [ -n "$vk" ] && echo "vulkan num_cu: $vk"
    fi

    if [ "${n:-0}" -ge "$FULL_CU" ] 2>/dev/null; then
        echo "state: $FULL_CU CU UNLOCKED"
    elif [ -n "$n" ]; then
        echo "state: $n CU (stock is $STOCK_CU)"
    else
        echo "state: unknown"
    fi
}

cmd_enable() {
    need_root
    kernel_supported || { no_kernel_patch; return 1; }

    echo "options amdgpu bc250_cc_write_mode=$CU_MODE" > "$CU_MODPROBE"
    echo "wrote $CU_MODPROBE"
    rebuild_initramfs

    cat <<EOF

Reboot to apply, then check with:  $0 status

WARNING: 40 CU raises power draw and temperature substantially, and shares the
SoC power/thermal envelope with the CPU. If you have also unlocked the CPU cores,
both draw from the same budget. Re-validate your governor curve, undervolt and
cooling afterwards -- do not assume a curve tuned at 24 CU still holds.

Not every board unlocks cleanly. duggasco's repo documents how to check your
harvest pattern and run compute-correctness tests.
EOF
}

cmd_disable() {
    need_root
    if [ -f "$CU_MODPROBE" ]; then
        rm -f "$CU_MODPROBE" && echo "removed $CU_MODPROBE"
    else
        echo "$CU_MODPROBE not present, nothing to remove"
    fi
    rebuild_initramfs
    echo "Reboot to return to $STOCK_CU CU."
}

usage() {
    cat <<EOF
bc250-40cu-unlock -- enable all 40 GPU compute units on the AMD BC-250

  status    show active CU count, kernel-patch presence and persistence
  enable    persist bc250_cc_write_mode=$CU_MODE and rebuild the initramfs
  disable   undo that

Requires a kernel built with duggasco's amdgpu patch:
  https://github.com/duggasco/bc250-40cu-unlock

For the CPU core unlock (6 -> 8 cores), see ./bc250-8core-unlock.sh
EOF
}

case "${1:-}" in
    status)  cmd_status ;;
    enable)  cmd_enable ;;
    disable) cmd_disable ;;
    *)       usage; exit 1 ;;
esac
