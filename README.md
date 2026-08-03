# bc250-8core-unlock

Enable all **8 CPU cores** on the AMD BC-250 from Linux — no BIOS flash, no kernel patch.

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
git clone https://github.com/gabriwar/bc250-8core-unlock
cd bc250-8core-unlock

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

They are ordinary cores — this is product binning, not defect harvesting. Per-core
`stress-ng --cpu-method all --verify`, 20 s pinned to each physical core:

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

Cores 3 and 7 are the newly unlocked ones. Whole-die spread is ±0.3% — measurement noise.
Core 3 was in fact the fastest core on the die. A 60 s all-16-thread `--verify` run passed
with zero failures and zero machine-check events.

---

## Known issues

- **GPU frequency monitoring breaks.** `pp_dpm_sclk` starts reporting nonsense (e.g.
  `1: 15Mhz` instead of `1500Mhz`), and `gpu_busy_percent` may come back empty. The GPU
  still clocks correctly according to your governor curve — this is a reporting bug only.
  Reported by the BC-250 Telegram community and reproduced here.
- **Thermals shift.** Two more cores share the same SoC power/thermal envelope as the GPU.
  A stock-clocked 16-thread load hit **82.4 °C** Tctl. If you run a tuned CPU/GPU curve,
  re-validate it after unlocking.

---

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
