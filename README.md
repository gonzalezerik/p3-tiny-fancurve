# p3-tiny-fancurve

Fan control for the **Lenovo ThinkStation P3 Tiny Gen 2** on Linux.

On this machine the CPU fan belongs to the embedded controller (EC). Linux gets
no PWM channel, no hwmon fan, and the ACPI fan device the firmware advertises is
a stub. In the BIOS "Balance" cooling mode the EC holds the fan near 900 rpm
even with the CPU at 90 °C+; "Full Speed" is a fixed ~5,970 rpm. The only
documented way to change between them is the BIOS setup screen (or `think-lmi`),
and that needs a reboot.

The EC does have fixed fan levels. They're selected by a flag byte in its
banked RAM, which the firmware's own ACPI methods can read and write. This
project pins the fan to one of those levels, so it runs at a **constant**
speed, and keeps it there.

## What it does

| Level | Flag (BRAM `0x0e`) | Fan |
|---|---|---|
| `low` | `0x1e` | ~2,000 rpm, steady |
| `medium` (default) | `0x0f` | ~2,400 rpm, steady |
| `full` | `0x1d` | ~5,970 rpm (same as BIOS "Full Speed") |
| `max` | `0x17` | ~6,950 rpm |
| `auto` | `0x1f` | the EC's own curve (~900 rpm into the 90s °C) |

The daemon sets `LEVEL` and re-asserts it if the firmware ever rewrites the
byte. The fan doesn't cycle. Only if the CPU package reaches `SAFETY_TEMP`
(90 °C) does it go to full speed, returning to `LEVEL` below `SAFETY_CLEAR`
(75 °C).

A clean stop hands the fan back to the EC's curve (`auto`). A crash or error
leaves it at full speed.

### Measured on a 30K60008US (Core Ultra 9 285, BIOS M5PKT32A, EC 0.1.12)

| Fan | CPU package at ~20 W sustained |
|---|---|
| EC auto (Balance), ~900 rpm | ~91 °C |
| `medium`, ~2,400 rpm | ~58 °C (held 3 min, flag never overwritten) |
| `full`, ~5,970 rpm | ~47–55 °C |

`medium` gets most of the cooling of full speed at well under half the rpm.

## Limitations

- **Five levels, not arbitrary rpm.** Each level is a fixed duty the EC picks
  from that flag byte. Clearing bit 2 (`0x1b`) gives 3,000–3,600 rpm, but it
  drifts with temperature, so it isn't offered. No raw PWM register is
  reachable. The ACPI EC page (all 256 bytes, write-tested), the BRAM bank and
  the PMC2 page were all checked. The ITE "D2EC" back door is disabled by the
  firmware, and the EC firmware image in Lenovo's BIOS package is encrypted.
- **One model.** The ACPI paths and offsets come from this board's firmware.
  The script refuses to run unless DMI says `ThinkStation P3 Tiny Gen 2`
  (`P3_FANCURVE_FORCE=1` overrides; only do that after reading your own tables).
  The same BIOS package covers the ThinkCentre M90q Gen 6 and Neo Ultra Gen 2,
  which may share the EC, but that's untested.
- Tested on Proxmox VE 9 (Debian trixie), kernel 7.0.

## Install

Requires `python3` and the `acpi_call` kernel module (`acpi-call-dkms` on
Debian/Proxmox, which needs headers for your running kernel).

Debian / Proxmox package:

```sh
make deb
apt install ./build/p3-fancurve_0.2.0_all.deb
```

Or directly:

```sh
sudo make install            # PREFIX=/usr/local by default
sudo systemctl enable --now p3-fancurve
```

`LEVEL` and the safety thresholds live in `/etc/default/p3-fancurve`; restart the service after
editing.

```console
$ p3-fancurve status
level=medium fan=2393rpm cpu=58C
$ p3-fancurve set low         # manual override (the daemon re-asserts LEVEL within 5 s)
$ journalctl -u p3-fancurve   # safety overrides are logged with the temperature
```

## How it works

Everything below comes from the machine's own ACPI tables (`acpidump -b`,
`iasl -d`).

### Why the OS can't touch the fan

The DPTF fan participant `\_SB.IETM.TFN1` (`INTC1063`) implements `_FSL`
(set level) and `_FST` (status) by calling `\_SB.PC00.LPCB.H_EC.DPTF.FNSL` and
`GFNS`. Those methods are declared `External` and defined nowhere, so `_FSL` is a
no-op and `_FST` fails (`cur_state` reads return `EINVAL`). The reference
`H_EC` device's `_STA` returns 0. `thermald` and the kernel's ACPI fan
driver therefore can't control this fan.

### The EC

The real EC answers the standard ACPI EC protocol on ports 0x62/0x66. The DSDT
wraps it as `\_SB.GECR(addr)` (command 0x80, read) and exposes a banked window
at 0xA50/0xA51 as `\_SB.GBRM` / `\_SB.SBRM`.

| EC RAM | Meaning |
|---|---|
| `0x01` | CPU temperature (°C) |
| `0x09` (low), `0x0A` (high) | fan tachometer, rpm |

The fan offsets are confirmed by the firmware itself: a WMI data method
(`\WMI1.WQD4`) returns `GECR(0x0A) << 8 | GECR(0x09)`, and the DSDT's `FANC`
method treats `GECR(0x0A) == 0` as "fan stopped".

All reads go through `\_SB.GECR` via `acpi_call`, so they're serialized by the
ACPI interpreter instead of racing the firmware's own EC traffic on the raw
ports.

### The fan-level flag

The EC is an ITE part (Super I/O ID `0x5652` behind the standard ITE entry key
on 0x2E). Its BRAM bank at 0xA50/0xA51 is wrapped by the DSDT as
`\_SB.GBRM(idx)` / `\_SB.SBRM(idx, val)`. Byte `0x0e` reads `0x1f` under the
EC's normal curve. Switching the cooling mode to Full Speed (below) clears
bit 1 (`0x1d`). Clearing other single bits pins other fixed levels:

| Bit cleared | Value | Fan |
|---|---|---|
| 0 | `0x1e` | ~2,000 rpm |
| 1 | `0x1d` | ~5,970 rpm |
| 2 | `0x1b` | 3,000–3,600 rpm, temperature-dependent |
| 3 | `0x17` | ~6,950 rpm |
| 4 | `0x0f` | ~2,400 rpm |

The EC ramps between levels over 10–20 s, so changing level is smooth. The
EC didn't touch the byte while a level was held. The daemon still checks it
every `INTERVAL` seconds in case BIOS code rewrites it.

By hand:

```sh
modprobe acpi_call
echo '\_SB.SBRM 0x0e 0x0f' > /proc/acpi/call   # ~2,400 rpm
echo '\_SB.SBRM 0x0e 0x1f' > /proc/acpi/call   # back to the EC curve
```

### The runtime mode switch

The daemon doesn't use this (the level flag above is finer-grained). It's
documented because it's how the BIOS cooling modes are applied at runtime.

`\WMI2` (`PNP0C14`) registers method object `G0` under
**`887B54F3-DDDC-4B2C-8B88-68A26A8835D0`**, implemented by `WMG0`:

| Call | Effect |
|---|---|
| `WMG0(0, 6, 0)` | returns current mode: 2 = Balance, 3 = Performance, 4 = Full Speed |
| `WMG0(0, 5, 2)` | Balance (`ICE4 = 1`, SMI 0x93) |
| `WMG0(0, 5, 3)` | Performance (`ICE4 = 0`, SMI 0x94) |
| `WMG0(0, 5, 4)` | Full Speed (`ICE4 = 2`, SMI 0x95) |

Each set also updates the DPTF OEM variable `ODV0` and notifies `\_SB.IETM`.
The change is runtime only. The BIOS-stored `IntelligentCoolingPerformanceMode`
is untouched.

By hand:

```sh
modprobe acpi_call
echo '\WMI2.WMG0 0 5 4' > /proc/acpi/call; cat /proc/acpi/call   # full speed
echo '\_SB.GECR 0x0A' > /proc/acpi/call; cat /proc/acpi/call     # rpm high byte
```

This GUID sits in the same family as Lenovo's GameZone interface
(`887B54E3-…`, handled by the kernel's `lenovo-wmi-gamezone` driver on Legion
laptops), but it's a different object, and no in-tree driver binds it.

## Kernel updates

`acpi_call` is an out-of-tree DKMS module. A new kernel needs matching headers
or the module (and this service) won't load. On Proxmox, check that any other
DKMS modules you depend on (e.g. NVIDIA) also build for the new kernel before
rebooting into it.

## License

MIT, see [LICENSE](LICENSE).
