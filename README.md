# bc250-core-cu-unlock

Unlock the hidden silicon on the AMD BC-250: **8 CPU cores** (from 6) and **40 GPU compute units** (from 24).

The BC-250 ships as a 6-core part. The two dormant cores are **not fused off**: they are
masked by a writable SMU register. This flips the mask with a single SMU mailbox command
and re-enumerates via a warm reboot.

```
before:  Core(s) per socket: 6    CPU(s): 12
after:   Core(s) per socket: 8    CPU(s): 16
```

Measured on a stock-clocked BC-250: **7-zip 53,610 → 68,039 MIPS (+26.9%)**.

---

## Quick start

```bash
git clone https://github.com/GabriWar/bc250-core-cu-unlock
cd bc250-core-cu-unlock

sudo ./bc250-8core-unlock.sh status     # show the current core mask
sudo ./bc250-8core-unlock.sh apply      # unlock now (then: sudo reboot)
sudo ./bc250-8core-unlock.sh install    # persist it: installs + enables the systemd unit
```

`install` drops the script at `/usr/local/bin/bc250-8core-unlock` and enables
`bc250-8core-unlock.service`, which applies the unlock early at every boot.

Remove it with `sudo ./bc250-8core-unlock.sh uninstall`.

---

## How it works

`SMN 0x0115A870` is a **core-enable bitmask** — one bit per core:

```
0x77 = 0b0111_0111   bits 3 and 7 clear   -> 6 cores (factory)
0xFF = 0b1111_1111   all bits set         -> 8 cores
```

It is written through an **SMU mailbox command, message `0x98`**, reached over SMN via the
PCI config index/data pair `0xB8`/`0xBC` on device `00:00.0`:

```
SmnWrite32(0x3B10A80, 0)           # clear response register
SmnWrite32(0x3B10A88, 0x115A870)   # arg0 = target register
SmnWrite32(0x3B10A8C, 0)           # arg1
SmnWrite32(0x3B10A20, 0x98)        # message id
poll 0x3B10A80 until == 1 (ok) or 0xFC..0xFF (error)
```

CPU topology is fixed by firmware at reset, so the new cores do not appear until the
platform re-enumerates — hence the reboot.

### Warm vs cold

| reset | mask |
|---|---|
| **warm** (`reboot`, `systemctl reboot`) | **preserved** → cores stay unlocked |
| **cold** (`poweroff`, PSU switch, unplug) | **reverts to `0x77`** → back to 6 cores |

The script sets `/sys/kernel/reboot/mode=warm` before rebooting to match what the BIOS
driver does (`EfiResetWarm`).

This is why the systemd unit exists: after a cold boot it re-applies the unlock and warm
reboots **once** (~15 s). Warm reboots are a no-op. The unit is capped at 2 consecutive
attempts, so it can never end up in a reboot loop.

---

## Are the extra cores any good?

**Yes — fully working, 100% healthy.** This is product binning, not defect harvesting.
The two unlocked cores are indistinguishable from the six you already had.

Verify it on your own board:

```bash
./test-cores.sh          # 20s per core, ~3 min total
./test-cores.sh 60       # longer, more thorough
```

Per-core `stress-ng --cpu-method all --verify`, 20 s pinned to each physical core:

| core | bogo-ops/s | vs median | verify failures |
|---|---|---|---|
| 0 | 1526.19 | +0.0% | 0 |
| 1 | 1526.74 | +0.1% | 0 |
| 2 | 1529.30 | +0.2% | 0 |
| **3** | **1530.10** | **+0.3%** | **0** |
| 4 | 1524.21 | −0.1% | 0 |
| 5 | 1525.53 | +0.0% | 0 |
| 6 | 1522.13 | −0.2% | 0 |
| **7** | **1524.00** | **−0.1%** | **0** |

Cores 3 and 7 are the newly unlocked ones. Whole-die spread is **±0.3%** — measurement
noise. Core 3 was in fact the **fastest core on the die**.

| check | result |
|---|---|
| per-core verify failures | **0 / 8 cores** |
| 60 s all-16-thread `--verify` | **passed 16, failed 0**, untrustworthy 0 |
| machine-check / hardware errors | **0** |
| Tctl under full 16-thread load | 82.4 °C |

Zero wrong results anywhere. These are healthy, fully functional cores that were switched
off for market segmentation, nothing more.

> Silicon lottery still applies — this is one die. Run `./test-cores.sh` on yours. Any
> core reporting verify failures is producing wrong answers and should not be trusted.

---

## Known issues

- **GPU frequency monitoring breaks.** `pp_dpm_sclk` starts reporting nonsense (e.g.
  `1: 15Mhz` instead of `1500Mhz`), and `gpu_busy_percent` may come back empty. The GPU
  still clocks correctly according to your governor curve — this is a reporting bug only.
  Reported by the BC-250 Telegram community and reproduced here.
- **Your existing overclock is no longer valid.** See below — this is the big one.

---

## ⚠️ Your overclock is no longer valid

This is the part people will get wrong. **Two extra cores change the electrical and
thermal behaviour of the whole SoC.** A curve tuned at 6 cores is not a curve that holds
at 8, and the failure mode is not a clean error — it is intermittent instability that
looks like a bad game, a bad driver, or a bad kernel.

What actually changes:

- **Load-line droop gets worse.** Eight cores pulling current sag the rail further than
  six at the same requested voltage. A voltage that was marginal-but-stable at 6 cores can
  land below the silicon's floor at 8 under an all-core transient. Undervolts are the
  first thing to break.
- **Thermals rise.** More cores in the same package. Measured here: **82.4 °C Tctl at
  stock clocks** under a 16-thread load — before any OC.
- **The shared budget shifts.** CPU and GPU draw from one SoC power/thermal envelope. Two
  more cores take a bigger slice, so the GPU has less headroom than it did. If you also
  ran the [CU unlock](#gpu-compute-units-40-cu), both ends are now competing harder.
- **Your sweet spot moves.** Peak-throughput frequency, the efficiency knee and the
  point where extra clock stops buying anything are all functions of the thermal envelope,
  and that envelope just changed.

So after unlocking, redo the work:

```bash
./test-cores.sh 60                 # per-core correctness first, all 8 cores
```

Then, in order:

1. **Re-run your CPU benchmark** and find the new plateau. Frequencies that paid off at
   6 cores may be past the knee at 8.
2. **Re-check droop** — measure actual voltage under an all-core load, not at idle, and
   compare against what you requested. Widen the margin where it sagged.
3. **Re-cliff the undervolt** at 8 cores. Do not carry the old curve over.
4. **Re-validate thermals** under sustained load, not a short burst, with the CPU and GPU
   loaded *together* — that co-load case is where the shared envelope actually bites.
5. **Re-tune the CPU/GPU split** if you were balancing them.

Treat the old numbers as a starting hypothesis, not a configuration.

## Safety

Nothing is written to flash. The unlock lives in a volatile SMU register, so **a cold boot
is a guaranteed escape hatch** — cut power and you are back to a stock 6-core machine.

The script refuses to act on any mask other than `0x77`, verifies the result before
rebooting, and never reboots if the SMU rejects the command.

One real caveat: `amdgpu` drives the same `0xB8`/`0xBC` pair and the same SMU mailbox. The
whole write sequence is issued as a *single* `setpci` invocation to keep the interleave
window as small as possible, but the race is not formally eliminated.

Requires `pciutils` (`setpci`) and root.

---

## GPU compute units (40 CU)

The BC-250 also ships with 24 of its 40 RDNA2 compute units active. That is a **separate
mechanism** — controlled by `amdgpu`, not the SMU — and the unlock is
**[duggasco's](https://github.com/duggasco/bc250-40cu-unlock)** work: the kernel patch,
the dual-register analysis and the whitepaper are all theirs.

`bc250-40cu-unlock.sh` in this repo does not reimplement any of it. It only manages the
persistent config for a kernel already built with that patch:

```bash
sudo ./bc250-40cu-unlock.sh status     # active CU count, patch presence, persistence
sudo ./bc250-40cu-unlock.sh enable     # persist bc250_cc_write_mode=3, rebuild initramfs
sudo ./bc250-40cu-unlock.sh disable    # undo
```

It deliberately does **not** poke the GPU registers at runtime via `umr` or debugfs. That
path exists but it races the live driver and is unverified by this project — the
kernel-patch route is the one people actually run.

Running both unlocks together means the CPU and GPU are competing for the same SoC budget
much harder than stock. See the overclock warning above.

## Making it permanent (BIOS route)

The systemd unit costs one extra reboot per cold boot. To avoid that entirely, the
`Bc250CoreUnlockDxe` driver from the MeiMeiDXE BIOS mod can be injected into your own BIOS
image so it runs pre-OS on every boot. That is a BIOS flash — do not attempt it without an
SPI programmer (CH341A + SOIC-8 clip) and a verified backup of your current chip.

---

## Credits

- **[gabriwar](https://github.com/gabriwar)** — reverse engineering of the mechanism and this tool
- **The BC-250 Telegram community** — for finding, testing and documenting the 8-core
  unlock in the first place, and for reporting the GPU-monitoring side effect
- **[Forbidden-Darkness](https://github.com/Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script)**
  — author of the MeiMeiDXE-T-v2 BIOS mod containing `Bc250CoreUnlockDxe`, from which the
  SMU sequence used here was reverse engineered

The mechanism was recovered by module-diffing the modded BIOS against stock, isolating the
`Bc250CoreUnlockDxe` DXE driver (GUID `2F3D426D-6A54-4A6B-82D0-1207CC5B6D92`), and
disassembling its 4 KiB `.text` section.

## License

MIT
