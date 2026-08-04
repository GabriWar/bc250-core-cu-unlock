# Kernel patches for the BC-250

Two `amdgpu` patches that matter once you've unlocked all 8 CPU cores.

```
patches/
  0001-bc250-8core-telemetry.patch   fixes GPU clock reporting  (by higorprado)
  0002-bc250-rocm-vm-flush.patch     ROCm VM-flush candidate    (UNCONFIRMED)
```

---

## 0001 — 8-core telemetry (fixes the broken GPU clock readout)

**This fixes the thing everyone reports as unfixable.** After unlocking 8 cores,
`pp_dpm_sclk` starts showing nonsense (`1: 15Mhz` instead of `1500Mhz`) and
`gpu_busy_percent` can come back empty. The consensus in the BC-250 community has
been *"it breaks GPU frequency monitoring and it's not possible to fix at the
moment."*

That's wrong, and the reason is genuinely interesting.

The SMU metrics table is a **fixed 116 bytes**. With 6 cores the layout is what
the stock driver expects. Turn on 8 cores and the firmware *redistributes the
per-core arrays inside the same window* — the expanded arrays consume the space
`GfxclkFrequency` used to live in:

```
uint16_t C0Residency[7];   /* 0x38, cores 0-6 */   <- [6] lands on 0x44
uint16_t GfxTemperature;   /* 0x46 */

GfxclkFrequency (was 0x44) has NO SLOT AT ALL in the 8-core layout
```

So the driver reads offset `0x44` expecting a clock and gets a **residency
counter**. Hence `15Mhz`.

It was never relocated — the firmware *dropped* it to make room. There is no
offset to correct, so the fix queries the SMU directly instead:

```c
case METRICS_CURR_GFXCLK:
    ret = smu_cmn_send_smc_msg(smu, SMU_MSG_GetGfxclkFrequency, value);
    if (ret) {                                     /* fallback, never breaks */
        *value = metrics->Current.GfxclkFrequency;
        ret = 0;
    }
```

### Coverage is not uniform

Even patched, the 8-core firmware layout simply doesn't expose everything:

| metric | cores covered |
|---|---|
| CoreFrequency | 0-7 (all) |
| CorePower | **1-7** — core 0 has no slot, folded into the CPU rail aggregate |
| CoreTemperature | **4,5 only** — the power expansion overwrote slots 0-3 |
| C0Residency | **0-6** |

Cores with no firmware slot report the `0xffff` sentinel rather than `0`, so you
can tell "no data" from "genuinely zero". Aggregate telemetry (socket power,
memory clocks, GPU rail) stays at the stock six-core offsets.

### Cost

One extra SMU mailbox message per GPU-clock read. It rides behind
`smu_cmn_get_metrics_table()`, which already does an SMU transfer on every
query — so it's a second, much cheaper round-trip, not a new class of work.
Invisible at normal monitoring rates. If you ever poll at very high frequency
and care, add a short TTL cache around it.

Layout auto-detects from physical core count; `cs_eight_core_map=1` forces it.
On 6 cores nothing changes.

---

## 0002 — ROCm VM flush ⚠️ UNCONFIRMED

**Do not treat this as a working fix.** It is a candidate, documented so the
reasoning isn't lost.

ROCm/PyTorch on the BC-250 dies on its first device allocation:

```
amdgpu: Timeout waiting for VM flush hub: 0!
amdgpu: GPU mode1 reset ... VRAM is lost due to GPU reset!
amdgpu: ring sdma1 test failed (-110)
```

The GRBM/CP register range `0x2000-0x2FFF` reads back `0xFFFFFFFF` on this die —
those IP blocks are disabled, and KIQ lives there. So a VM/TLB flush routed
through KIQ never completes. The patch stops the driver using KIQ for it.

**Why it might not be the answer:** a bare `hipMalloc` + `hipMemcpy` (H2D and
D2H) completes fine on this hardware. So the flush path is *not* universally
broken — only something PyTorch does reaches it. That doesn't fit a simple
"KIQ is dead" story, and the real cause may be in how torch's caching allocator
maps memory.

---

## Building

The module must ABI-match your running kernel. Building only `amdgpu` takes
~95 s on an 8-core BC-250 (vs ~60 min for a full kernel):

```bash
KREL=$(uname -r); KVER=${KREL%%-*}
curl -LO https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz
tar xf linux-$KVER.tar.xz && cd linux-$KVER

patch -p1 < ../patches/0001-bc250-8core-telemetry.patch
patch -p1 < ../patches/0002-bc250-rocm-vm-flush.patch
patch -p1 < /path/to/bc250-40cu-amdgpu.patch      # keep your 40 CU unlock!

cp /usr/lib/modules/$KREL/build/.config .
cp /usr/lib/modules/$KREL/build/Module.symvers .
scripts/config --set-str LOCALVERSION "-${KREL#*-}"
make olddefconfig && make modules_prepare -j$(nproc)
make -j$(nproc) M=drivers/gpu/drm/amd/amdgpu modules

modinfo drivers/gpu/drm/amd/amdgpu/amdgpu.ko | grep vermagic   # MUST match uname -r
```

> ⚠️ **Include the 40 CU patch.** Replacing `amdgpu.ko` without it drops you back
> to 24 CU. Verified working: vanilla kernel.org source builds a module whose
> vermagic matches a CachyOS `bore-lto` kernel, because `Module.symvers` +
> `.config` + `LOCALVERSION` pin the ABI.

Back up `amdgpu.ko.zst` before replacing it, and keep a bootloader entry with
`modprobe.blacklist=amdgpu` as an escape hatch.

---

## Credits

- **[higorprado](https://github.com/higorprado/bc250-8core-telemetry-report)** —
  the 8-core telemetry patch and the differential core-offline probing that
  mapped the hybrid firmware layout byte by byte. That work is what turns
  "GPU clock reporting is broken and unfixable" into a solved problem.
- **[FilippoR](https://github.com/filippor)** — credited in that patch for the
  physical-core-count detection.
- **[duggasco](https://github.com/duggasco/bc250-40cu-unlock)** — the 40 CU
  unlock patch you must keep applied.
