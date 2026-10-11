# p3-tiny-fancurve

Fixed-speed fan control for the **Lenovo ThinkStation P3 Tiny Gen 2** on Linux.

The P3 Tiny's CPU fan is run entirely by its embedded controller (EC). Linux
gets no PWM channel and no hwmon fan, and the ACPI fan device the firmware
advertises is an empty stub. In practice you're left with the BIOS "Intelligent
Cooling" modes:

- **Balance / Performance:** the EC holds the fan near 900 rpm until the
  CPU is in the 90s °C.
- **Full Speed:** a fixed ~5,970 rpm, which is loud.

Changing modes takes a trip into BIOS setup and a reboot.

This project uses the EC's **fixed fan levels**, which are selected by a flag
byte the firmware's own ACPI methods can read and write. A small daemon pins
the fan to the level you choose, so it runs at a **constant speed** with no
cycling. A temperature safety override sits on top.

```console
$ p3-fancurve status
level=medium fan=2393rpm cpu=58C
```

---

## Contents

- [Results](#results)
- [Levels](#levels)
- [Install](#install)
- [Configuration](#configuration)
- [Command line](#command-line)
- [Safety model](#safety-model)
- [How it works](#how-it-works)
  - [Why stock Linux can't control this fan](#why-stock-linux-cant-control-this-fan)
  - [Hardware layout](#hardware-layout)
  - [The ACPI EC page](#the-acpi-ec-page)
  - [The fan-level flag (BRAM 0x0e)](#the-fan-level-flag-bram-0x0e)
  - [The runtime cooling-mode switch (WMI)](#the-runtime-cooling-mode-switch-wmi)
  - [Why everything goes through acpi_call](#why-everything-goes-through-acpi_call)
- [What was ruled out](#what-was-ruled-out)
- [Exploring your own machine](#exploring-your-own-machine)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Compatibility](#compatibility)
- [Kernel updates](#kernel-updates)
- [Disclaimer](#disclaimer)
- [License](#license)

---

## Results

Measured on a **30K60008US** (Core Ultra 9 285, RTX PRO 4000 Blackwell SFF,
BIOS M5PKT32A, EC 1.12) running Proxmox VE 9 with a steady ~20 W CPU package
load:

| Fan | rpm | CPU package |
|---|---|---|
| EC auto (BIOS "Balance") | ~900 | ~91 °C |
| **`medium` (default)** | **~2,400** | **~58 °C** |
| `full` (BIOS "Full Speed") | ~5,970 | ~47–55 °C |

`medium` delivers most of the cooling of full speed at about 40 % of the rpm.
While a level was held, the EC never overwrote the flag byte, and the rpm
stayed flat. Expect normal tach jitter of roughly ±100 rpm.

## Levels

| Level | Flag value | Fan |
|---|---|---|
| `low` | `0x1e` | ~2,000 rpm, constant |
| `medium` | `0x0f` | ~2,400 rpm, constant |
| `full` | `0x1d` | ~5,970 rpm, constant (identical to BIOS "Full Speed") |
| `max` | `0x17` | ~6,950 rpm, constant |
| `auto` | `0x1f` | the EC's own temperature curve |

The EC slews between levels over 10–20 s, so a level change is a smooth
ramp, not a jump. These are the only fixed levels the firmware exposes; see
[What was ruled out](#what-was-ruled-out).

## Install

### Requirements

- A ThinkStation P3 Tiny Gen 2 (the script checks DMI and refuses to run
  elsewhere).
- `python3` (standard library only).
- The `acpi_call` kernel module. On Debian/Proxmox it comes from
  `acpi-call-dkms`, which needs headers for your running kernel
  (`proxmox-headers-$(uname -r)` or `linux-headers-$(uname -r)`).

### Debian / Proxmox package

```sh
git clone https://github.com/gonzalezerik/p3-tiny-fancurve
cd p3-tiny-fancurve
make deb
sudo apt install ./build/p3-fancurve_0.2.0_all.deb
```

The package depends on `acpi-call-dkms`, loads `acpi_call` at boot
(`/usr/lib/modules-load.d/p3-fancurve.conf`), and enables and starts
`p3-fancurve.service`.

### Without packaging

```sh
sudo make install               # PREFIX=/usr/local by default
sudo systemctl enable --now p3-fancurve
```

This installs the script to `$PREFIX/sbin`, the unit to
`/etc/systemd/system`, the defaults to `/etc/default/p3-fancurve`, and an
`acpi_call` entry in `/etc/modules-load.d`.

## Configuration

`/etc/default/p3-fancurve`:

```sh
LEVEL=medium        # low | medium | full | max | auto
SAFETY_TEMP=90      # °C package temp that triggers full speed
SAFETY_CLEAR=75     # °C below which it returns to LEVEL
INTERVAL=5          # seconds between checks
```

Restart after editing:

```sh
sudo systemctl restart p3-fancurve
```

The BIOS "Intelligent Cooling" setting can stay on Balance. The daemon sets
the level directly and doesn't depend on the BIOS mode.

## Command line

```console
$ p3-fancurve status          # current level, fan rpm, CPU package temp
level=medium fan=2393rpm cpu=58C

$ sudo p3-fancurve set low    # one-off change (the daemon re-asserts LEVEL within INTERVAL)
$ sudo p3-fancurve set auto   # hand the fan back to the EC (stop the service first to keep it)

$ journalctl -u p3-fancurve   # start-up config and any safety override events
```

## Safety model

| Situation | Fan |
|---|---|
| Daemon running, CPU below `SAFETY_TEMP` | `LEVEL`, constant |
| CPU reaches `SAFETY_TEMP` | `full` until the CPU is back below `SAFETY_CLEAR` |
| Daemon stopped cleanly (`systemctl stop`, package removal) | `auto` (EC's own curve) |
| Daemon crashes or any ACPI call fails | `full`; systemd restarts it after 5 s |
| Something else rewrites the flag byte | re-asserted within `INTERVAL` |
| Boot, before the service starts | `auto`: the firmware resets the flag to `0x1f` on every boot (verified with a warm reboot). The service starts about 5 s into boot and sets `LEVEL` again |

The EC's own protections are untouched. The CPU still has its normal hardware
thermal throttling and critical shutdown.

---

## How it works

Everything here was worked out from the machine's own ACPI tables
(`acpidump -b && iasl -d *.dat`), read-only probing of the Super I/O, and
reversible write tests against the running EC.

### Why stock Linux can't control this fan

The firmware advertises an Intel DPTF fan participant, `\_SB.IETM.TFN1`
(`INTC1063`, "Fan 1"), which Linux binds as `cooling_device3` (`TFN1`). Its
methods look like this:

```asl
Method (_FSL, 1, Serialized)        // Fan Set Level
{
    If (CondRefOf (\_SB.PC00.LPCB.H_EC.DPTF.FNSL))
    {
        \_SB.PC00.LPCB.H_EC.DPTF.FNSL (FNID, Arg0, FSLV)
        ...
    }
    Else { ADBG ("_FSL: FNSL not available") }
}

Method (_FST, 0, Serialized)        // Fan Status
{
    If (CondRefOf (\_SB.PC00.LPCB.H_EC.DPTF.GFNS)) { ... }
    Else { ADBG ("_FST: GFNS not available") }
    Return (TFST)                   // { 0, 0xFFFFFFFF, 0xFFFFFFFF }
}
```

`FNSL` and `GFNS` are only declared as `External` and are defined nowhere,
in the DSDT or any SSDT. The `\_SB.PC00.LPCB.H_EC` device they'd live in is
Intel's reference EC, and its `_STA` returns 0. So:

- `_FSL` silently does nothing.
- `_FST` returns invalid data (reading `cur_state` gives `EINVAL`).
- `thermald`, the kernel's ACPI fan driver, `fancontrol`, `nct6683` and
  `it87` have nothing to talk to. No hwmon fan or PWM exists.

### Hardware layout

The real EC is an **ITE** part. Entering Super I/O config mode on port `0x2E`
with the standard ITE key (`87 01 55 55`) returns chip ID **`0x5652`**,
revision 1 (unknown to `sensors-detect` and `superiotool`). Its logical
devices:

| LDN | Function | Base | Used for |
|---|---|---|---|
| `0x11` | PMC1 | `0x62` / `0x66` | Standard ACPI EC interface (read cmd `0x80`, write `0x81`) |
| `0x12` | PMC2 | `0x68` / `0x6C` | Second host channel (unused by ACPI) |
| `0x10` | BRAM | `0xA50` / `0xA51` | Banked index/data RAM; **holds the fan-level flag** |
| `0x0F` | SMFI | `0xA40` | Shared memory / flash interface |
| `0x04` | SWUC | `0xA30` | Wake-up control |

The DSDT wraps the two interfaces it uses:

```asl
Method (GECR, 1)  { /* ACPI EC read:  cmd 0x80 on 0x66, addr/data on 0x62 */ }
Method (GBRM, 1)  { EA50 = Arg0; Return (EA51) }      // BRAM read
Method (SBRM, 2)  { EA50 = Arg0; EA51 = Arg1 }        // BRAM write
```

### The ACPI EC page

The 256-byte page behind `GECR` carries telemetry. Two offsets are confirmed by
the firmware's own code:

| Offset | Meaning | Evidence |
|---|---|---|
| `0x01` | CPU temperature, °C | tracks `x86_pkg_temp` to within 1–2 °C |
| `0x09` / `0x0A` | fan tach, rpm (low / high byte) | WMI method `\WMI1.WQD4` returns `GECR(0x0A) << 8 \| GECR(0x09)`; `FANC` treats `GECR(0x0A) == 0` as "fan stopped" |

The page is writable (cmd `0x81`), but no byte in it changes the fan (see
[What was ruled out](#what-was-ruled-out)).

### The fan-level flag (BRAM 0x0e)

BRAM index `0x0e` is a bitmask the EC uses to pick its fan level. It reads
`0x1f` under the EC's normal curve. Switching the BIOS cooling mode to Full
Speed at runtime (next section) changes it to `0x1d`, clearing bit 1. That
was the lead. Clearing each other bit on its own, one at a time with the fan
settled at idle first, gave these results:

| Bit cleared | Value | Behavior over 90–180 s |
|---|---|---|
| none | `0x1f` | EC auto curve (~900 rpm until very hot) |
| 0 | `0x1e` | steady ~1,990 rpm |
| 1 | `0x1d` | steady ~5,970 rpm (= Full Speed mode) |
| 2 | `0x1b` | 3,000–3,600 rpm, **drifts with temperature**, not offered |
| 3 | `0x17` | steady ~6,950 rpm (maximum) |
| 4 | `0x0f` | steady ~2,400 rpm |

The daemon writes one of these values with `\_SB.SBRM 0x0e <value>`, reads it
back with `\_SB.GBRM 0x0e` every `INTERVAL` seconds, and rewrites it only if
it changed. That's a single write in normal operation, not a pulse.

By hand:

```sh
sudo modprobe acpi_call
echo '\_SB.SBRM 0x0e 0x0f' | sudo tee /proc/acpi/call   # ~2,400 rpm
echo '\_SB.GBRM 0x0e'      | sudo tee /proc/acpi/call; sudo cat /proc/acpi/call
echo '\_SB.SBRM 0x0e 0x1f' | sudo tee /proc/acpi/call   # back to the EC curve
```

### The runtime cooling-mode switch (WMI)

The daemon doesn't use this, but it's how the BIOS cooling modes are applied
at runtime, and it's how the level flag was found.

`\WMI2` (`PNP0C14`) registers method object `G0` under GUID
**`887B54F3-DDDC-4B2C-8B88-68A26A8835D0`**, implemented by `WMG0`:

| Call | Effect |
|---|---|
| `WMG0(0, 6, 0)` | returns current mode: `2` Balance, `3` Performance, `4` Full Speed |
| `WMG0(0, 5, 2)` | Balance (`ICE4 = 1`, software SMI `0x93`) |
| `WMG0(0, 5, 3)` | Performance (`ICE4 = 0`, SMI `0x94`) |
| `WMG0(0, 5, 4)` | Full Speed (`ICE4 = 2`, SMI `0x95`) |

Each call also updates the DPTF OEM variable `ODV0` and notifies `\_SB.IETM`.
The change is runtime only, and the BIOS-stored
`IntelligentCoolingPerformanceMode` (visible through `think-lmi`) is
untouched. Balance and Performance both turned out to be EC auto curves that
sit near 900 rpm into the high 80s °C. Full Speed is the same fixed level as
flag `0x1d`.

```sh
echo '\WMI2.WMG0 0 6 0' | sudo tee /proc/acpi/call; sudo cat /proc/acpi/call
```

This GUID belongs to the same family as Lenovo's GameZone interface
(`887B54E3-…`, handled by the kernel's `lenovo-wmi-gamezone` driver on Legion
laptops), but it's a different object, and no in-tree driver binds it.

### Why everything goes through acpi_call

The firmware's own AML touches the same EC interfaces. For example, the DPTF
sensor zones call `GECR` whenever Linux polls their temperatures. Driving
ports `0x62`/`0x66` or `0xA50`/`0xA51` directly from userspace could interleave
with those transactions and corrupt one. Calling the firmware's methods
(`\_SB.GECR`, `\_SB.GBRM`, `\_SB.SBRM`) through `acpi_call` runs them inside
the kernel's ACPI interpreter, which serializes them with all other AML.

---

## What was ruled out

Each of these was checked before settling on the BRAM flag. A finer-grained
or arbitrary-rpm control would need EC firmware changes.

| Path | Result |
|---|---|
| DPTF `TFN1` `_FSL` / `_FST` | stubs; target methods don't exist |
| Runtime-loaded ACPI tables | none (`/sys/firmware/acpi/tables/dynamic` empty, no `Load`/`LoadTable`) |
| `nct6683`, `it87`, `sensors-detect`, `superiotool` | chip not supported; no hwmon |
| ACPI EC page, all 256 bytes | every non-zero config-looking byte (`0x2C`, `0x32`–`0x34`, `0x38`–`0x39`, `0x40`–`0x52`, `0x62`) and every zero byte write-tested and restored; no fan effect |
| PMC2 page (`0x68`/`0x6C`) | readable, almost empty, no fan data |
| ITE D2EC indirect access (Super I/O regs `0x10`–`0x12`) | disabled by firmware; reads return 0 |
| EC firmware reverse engineering | the EC image in Lenovo's BIOS capsule is encrypted (EC root of trust), and `flashrom` can't detect the SPI chip |
| Pulsing between auto and full to fake a middle speed | works electrically but sounds bad; rejected |

A Windows project for the ThinkCentre M70t Gen 6
([thinkcentre-fan-control](https://github.com/blazingphoenix7/thinkcentre-fan-control))
reached the same conclusion about the ACPI EC page on that sibling platform.

## Exploring your own machine

To check whether a related Lenovo desktop works the same way (read-only
first):

```sh
sudo apt install acpica-tools acpi-call-dkms
sudo acpidump -b && iasl -d *.dat
grep -n "Method (GBRM\|Method (SBRM\|Method (GECR\|Method (WMG0" *.dsl

sudo modprobe acpi_call
for i in $(seq 0 127); do
  echo "\\_SB.GBRM $i" | sudo tee /proc/acpi/call >/dev/null
  printf '%02x=%s ' "$i" "$(sudo tr -d '\0' < /proc/acpi/call)"
done; echo
```

If `GBRM`/`SBRM` exist and BRAM `0x0e` reads `0x1f`, the same flag probably
applies. Test one value at a time, watch rpm (`\_SB.GECR 0x0a` / `0x09`, if
your board uses the same tach offsets) and temperature, and restore `0x1f`
afterwards. Then run the daemon with `P3_FANCURVE_FORCE=1`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `unsupported machine (...)` | Not a P3 Tiny Gen 2. See [Exploring your own machine](#exploring-your-own-machine). |
| `/proc/acpi/call` missing | `sudo modprobe acpi_call`; if that fails, install headers for the running kernel and `sudo dkms autoinstall`. |
| `Error: AE_NOT_FOUND` | Firmware differs from the tested one; compare your DSDT paths. |
| Fan at full speed unexpectedly | Check `journalctl -u p3-fancurve` for a safety override or an error. |
| Level doesn't change after editing the config | `sudo systemctl restart p3-fancurve`. |

## Uninstall

```sh
sudo apt remove p3-fancurve       # package; the stop hands the fan back to the EC
# or
sudo make uninstall               # make install
```

`/etc/default/p3-fancurve` is kept. The BIOS mode takes over fully again from
the next boot.

## Compatibility

| | |
|---|---|
| Tested | ThinkStation P3 Tiny Gen 2, 30K60008US, BIOS M5PKT32A, EC 1.12 |
| OS | Proxmox VE 9 (Debian 13 "trixie"), kernel 7.0 |
| Probably related | ThinkCentre M90q Gen 6 and Neo Ultra Gen 2 share the same BIOS package (`m5pj*`, EC 1.12), but are untested; the DMI check blocks them by default |

Lenovo's latest BIOS for this platform (M5PKT37A) ships the same EC version
(1.12), so the flag should behave the same after a BIOS update. The P3 Tiny
thermal-table update in that changelog landed in M5PKT25A, before the tested
version.

## Kernel updates

`acpi_call` is an out-of-tree DKMS module, so each new kernel needs matching
headers or the module and this service won't load. On Proxmox, check that any
other DKMS modules you rely on (such as NVIDIA) also build for a new kernel
before rebooting into it.

## Disclaimer

This writes to EC memory through undocumented firmware interfaces. It was
tested on one machine; every value used here was verified there and is
restored on exit, but firmware revisions can change behavior. Use it at your
own risk. Lenovo doesn't endorse or support this project.

## License

MIT, see [LICENSE](LICENSE).
