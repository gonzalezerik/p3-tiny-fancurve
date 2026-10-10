# p3-tiny-fancurve

Fan control for the **Lenovo ThinkStation P3 Tiny Gen 2** on Linux.

On this machine the CPU fan belongs to the embedded controller (EC). Linux gets
no PWM channel, no hwmon fan, and the ACPI fan device the firmware advertises is
a stub. In the BIOS "Balance" cooling mode the EC holds the fan near 900 rpm
even with the CPU at 90 °C+; "Full Speed" is a fixed ~5,970 rpm. The only
documented way to change between them is the BIOS setup screen (or `think-lmi`),
and that needs a reboot.

This project uses a cooling-mode method the firmware exposes over WMI to switch
modes **at runtime**, reads the real fan RPM out of EC RAM, and runs a small
temperature-driven curve on top.

## What it does

| CPU package temp | Fan |
|---|---|
| below `UP_FULL` (80 °C) | EC quiet curve (~900 rpm) |
| reaches `UP_FULL` | full speed (~5,970 rpm) |
| full speed held ≥ `HOLD` (300 s) **and** below `DOWN_BALANCE` (62 °C) | back to the quiet curve |

If the daemon exits, is stopped, or hits any error, it leaves the fan at full
speed. After a reboot the EC starts in whatever mode the BIOS has stored until
the service comes up.

### Measured on a 30K60008US (Core Ultra 9 285, BIOS M5PKT32A, EC 0.1.12)

| Mode | Fan | CPU package at ~20 W |
|---|---|---|
| Balance (EC) | ~900 rpm | ~91 °C |
| Performance (EC) | ~900 rpm until very hot | ~88 °C |
| Full Speed (EC) | ~5,970 rpm | ~47–55 °C |

Switching Balance → Full at runtime took the CPU from 93 °C to 69 °C in 40 s.

## Limitations

- **Two speeds, not a continuous curve.** "Balance" and "Performance" are both
  EC auto-curves that stay quiet into the high 80s; "Full Speed" is fixed. No
  fan-duty register is reachable: the 256-byte EC RAM page and the 0xA50/0xA51
  bank were dumped in each mode and only a mode-flag bit changes. The EC
  computes duty internally.
- **One model.** The ACPI paths and EC offsets come from this board's DSDT. The
  script refuses to run unless DMI says `ThinkStation P3 Tiny Gen 2`
  (`P3_FANCURVE_FORCE=1` overrides; only do that after reading your own tables).
- Tested on Proxmox VE 9 (Debian trixie), kernel 7.0.

## Install

Requires `python3` and the `acpi_call` kernel module (`acpi-call-dkms` on
Debian/Proxmox, which needs headers for your running kernel).

Debian / Proxmox package:

```sh
make deb
apt install ./build/p3-fancurve_0.1.0_all.deb
```

Or directly:

```sh
sudo make install            # PREFIX=/usr/local by default
sudo systemctl enable --now p3-fancurve
```

Thresholds live in `/etc/default/p3-fancurve`; restart the service after
editing.

```console
$ p3-fancurve status
mode=balance fan=876rpm cpu=71C ec_cpu=71C
$ p3-fancurve set full        # manual override (the daemon will re-assert its own choice)
$ journalctl -u p3-fancurve   # every mode change is logged with temp and rpm
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

### The runtime mode switch

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
