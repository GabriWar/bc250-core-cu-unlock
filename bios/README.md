# BC-250 modded BIOS — P5.00_clv + 8 core unlock + custom logo

A ready-to-flash BIOS that unlocks all 8 CPU cores **in firmware**, so you need no script,
no systemd unit and nothing running in the OS. Flash it, turn the option on, done.

```
BC250_P5clv_8core_v2.ROM   16 MB
sha256 e7347f3aafc40202a0aad3811b607442d3a51fe31d3df467726a03423185b5c2
```

**Verified on real hardware.** Flashed twice on a BC-250; the DXE volume reads back
byte-identical from the chip, and the toggle switches between 6 and 8 cores as expected.

---

## What's in it

| | |
|---|---|
| base | **P5.00_clv** — the "unlock everything" mod. Every hidden menu is exposed. |
| CPU cores | `Bc250CoreUnlockDxe` from MeiMeiDXE-T-v2, ported in |
| boot logo | custom (replaces the CLEVOCORE splash) |
| default | **cores OFF** — boots at 6 until you enable it |

Because the base is `P5.00_clv`, this is the "everything unlocked" BIOS: ReBAR, chipset
menus, debug options, the lot. That also means it is **easy to brick yourself** by changing
something you don't understand. Change what you came for and leave the rest alone.

---

## 🔓 Turning the cores ON

After flashing, boot into BIOS setup (`Del` / `F2`) and go to:

```
Advanced  →  Advanced CPU Settings  →  Unlock CPU Cores  →  Enabled
```

Save & exit. The board will **unlock and reset itself once** — that extra reboot is normal
and expected, it is the firmware re-enumerating the CPU topology. When it comes back you
have 8 cores / 16 threads.

Verify:

```bash
lscpu | grep -E 'Core\(s\) per socket|^CPU\(s\):'
# Core(s) per socket:  8
# CPU(s):              16
```

## 🔒 Turning the cores back OFF

Same path:

```
Advanced  →  Advanced CPU Settings  →  Unlock CPU Cores  →  Disabled
```

Save & exit, then **power off completely** (not just reset). The core mask lives in a
volatile SMU register that only clears on a true power cycle, so a warm reboot will keep
showing 8 cores until you actually cut power.

### Or just clear CMOS

Because this build defaults to **Disabled**, clearing CMOS always returns you to a
bootable 6-core machine. That is the deliberate escape hatch — see below.

---

## Why the default is OFF

An earlier build defaulted to **on**. That is a trap: if the board ever ends up in a boot
loop, the normal fix is a CMOS clear — but a CMOS clear reloads the *default*, which would
be "on" again, straight back into the loop. No software can save you from a firmware loop.

Defaulting to **off** means CMOS clear is always a working recovery. You give up nothing
except one trip into the BIOS menu after flashing.

---

## Flashing

Copy the whole contents of this folder to the root of a **FAT32** USB stick:

```
BC250_P5clv_8core_v2.ROM
AfuEfix64.efi
flash.nsh
EFI/BOOT/BOOTX64.EFI
```

1. Boot from the stick (it lands in the UEFI shell)
2. Find the right filesystem — type `fs0:`, then `ls`; if you don't see the ROM, try
   `fs1:`, `fs2:` … **This is the step people get wrong.**
3. Run:

```
flash
```

which does:

```
AfuEfix64.efi PREFLASH.ROM /O
AfuEfix64.efi BC250_P5clv_8core_v2.ROM /p /b /n /k /x /rlc:e /clrcfg
```

4. **Power off completely** when it finishes — do not press reset.
5. Boot, enter BIOS, enable the option (path above).

`/clrcfg` resets BIOS settings to defaults, so expect to redo any custom settings (VRAM
split etc.). It is included deliberately: it guarantees you start from the known-good
default state, which for this build is cores-off.

`PREFLASH.ROM` is your own chip's contents, saved before writing. **Keep it.**

---

## ⚠️ Risk

This writes the **boot block** (`/b`). A failed write means the board will not POST and
cannot be recovered in software — there is no dual-BIOS and no USB recovery on this
hardware.

**Do not flash this without an SPI programmer on hand.** CH341A + SOIC-8 clip, ~10 USD.

### Recovery

```bash
# board unplugged from mains, clip on the chip
sudo flashrom -p ch341a_spi                       # must identify W25Q128.V, 16384 kB
sudo flashrom -p ch341a_spi -r check1.rom
sudo flashrom -p ch341a_spi -r check2.rom
cmp check1.rom check2.rom                          # must match, else reseat the clip
sudo flashrom -p ch341a_spi -w PREFLASH.ROM -V     # your own backup
```

Rules: never write unless step 1 identified the chip; two differing reads means stop and
reseat; the chip is **3.3 V — never 5 V**.

---

## Credits

- **[Forbidden-Darkness](https://github.com/Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script)**
  — `Bc250CoreUnlockDxe`, the driver that does the actual unlock, from MeiMeiDXE-T-v2
- **clevocore** — the P5.00_clv "unlock everything" base this is built on
- **The BC-250 Telegram community** — for finding and testing the 8-core unlock

The port itself (driver injection into P5, the Setup-menu changes, default-off behaviour
and logo) is documented in [../README.md](../README.md).
