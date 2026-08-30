# Touchpad: stuck left click after resume (BTN_LEFT wedged on phantom Mouse node)

**Machine:** Lenovo ThinkBook 15 G4 ABA (21DL) · touchpad `SYNA2BA6:00 06CB:CE2D`
(Synaptics, I2C HID via `i2c_hid_acpi`, driven by `hid-multitouch`)
**First diagnosed:** 2026-08-29, kernel 7.1.9-arch1-2, Omarchy (Arch + Hyprland)

## Symptom

After resuming from suspend, left click misbehaves everywhere — clicks get
swallowed or act like drags, on the touchpad *and* on any external mouse.
Suspending again usually "fixes" it.

## Quick fix (instead of suspending)

Reset the touchpad's HID device; it disappears for ~1 s and comes back clean:

```sh
# device id may change across boots — confirm with: ls /sys/bus/hid/drivers/hid-multitouch/
sudo sh -c 'echo -n "0018:06CB:CE2D.0005" > /sys/bus/hid/drivers/hid-multitouch/unbind
            sleep 1
            echo -n "0018:06CB:CE2D.0005" > /sys/bus/hid/drivers/hid-multitouch/bind'
```

## How to confirm it's this bug

The kernel's button-state bitmap shows `BTN_LEFT` (0x110) held on the
touchpad's **Mouse** node while the **Touchpad** node is clean:

```sh
python3 - <<'EOF'
import os, fcntl, glob
for dev in glob.glob('/dev/input/event*'):
    try: fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
    except OSError: continue
    name = bytearray(512); fcntl.ioctl(fd, 0x82004506, name)   # EVIOCGNAME
    keys = bytearray(64);  fcntl.ioctl(fd, 0x80404518, keys)   # EVIOCGKEY
    pressed = [hex(i*8+b) for i,byte in enumerate(keys) for b in range(8) if byte >> b & 1]
    os.close(fd)
    if pressed: print(dev, name.split(b'\0')[0].decode(), 'STUCK', pressed)
EOF
```

## Root cause

The touchpad exposes two HID collections on one chip:

1. a legacy **boot mouse collection** (relative X/Y + buttons) for BIOS
   compatibility — normally silent;
2. the real **Precision TouchPad digitizer collection** (5 finger slots).

Which one talks is a firmware mode switch. The chip powers on in mouse mode;
`hid-multitouch` flips it to PTP mode by sending an `InputMode` feature report.

This laptop suspends in **deep** mode (`/sys/power/mem_sleep`), which cuts
touchpad power, so every resume the chip restarts in mouse mode. `i2c-hid`
hardware-resets it and calls the driver's `reset_resume`. In the window before
the mode switch lands, a physical touch/click (e.g. the click that wakes the
machine) is reported through the *mouse* collection. The release then goes out
through the *digitizer* collection after the switch — the mouse node's press
is never balanced, and the kernel holds `BTN_LEFT` down on it forever. Since
the compositor merges all pointers into one seat, one stuck bit breaks
clicking for every device.

**The kernel defect:** `mt_release_contacts()` in
`drivers/hid/hid-multitouch.c` — called from `mt_reset_resume()` — releases
stale *finger slots* only (`input_mt_report_slot_inactive`); it never clears
*button bits*, so a press orphaned on the mouse collection survives the
cleanup. The 2016 patch "HID: multitouch: Release all touch slots on
reset_resume" fixed exactly this staleness for touches; buttons were never
given the same treatment.

Why it never happened on Pop!_OS: likely s2idle suspend there (touchpad keeps
power → no mode reset → no race window), plus older kernel timing and possibly
different hardware.

## Incidents

| When | Evidence |
|---|---|
| 2026-08-29 ~19:03 | Resume from deep suspend 19:02:57; stuck `BTN_LEFT` confirmed via EVIOCGKEY on the Mouse node; cleared by unbind/rebind |
| 2026-08-31 ~08:00 | Resume 07:59:38 → bug; suspend 08:00:15 / resume 08:00:21 used as workaround (cleared it) |

## Permanent local workaround (not yet applied)

The phantom mouse node carries no useful input once the driver is up, so
libinput can be told to ignore it entirely — then no stuck press there can
ever wedge the pointer:

```
# /etc/udev/rules.d/99-ignore-touchpad-phantom-mouse.rules
ACTION=="add|change", KERNEL=="event*", ATTRS{name}=="SYNA2BA6:00 06CB:CE2D Mouse", ENV{LIBINPUT_IGNORE_DEVICE}="1"
```

Lives in `/etc`, so outside this repo's stow tree (`home/` → `~`).

## Upstream status (checked 2026-08-29)

No existing patch, bugzilla entry, or linux-input thread covers this exact
defect (buttons not released on `reset_resume`). The driver is actively
maintained (Benjamin Tissoires signing off monthly through 2026). Adjacent
work — "fix sticky fingers" (2025-10), its OOB follow-up (2026-07), "Check to
ensure report responses match the request" (2026-02) — is all touch-slot or
report-validation territory; none touches button state. The sibling failure
(mode switch failing entirely → pad stuck in mouse mode) is documented in a
Framework Laptop 12 community thread with the same unbind/rebind workaround.

**Where to file:** `linux-input@vger.kernel.org`, CC HID maintainers Jiri
Kosina <jikos@kernel.org> and Benjamin Tissoires <bentiss@kernel.org>.
Suggested fix direction: also release button state across all input nodes in
`mt_release_contacts()`, mirroring the 2016 touch-slot patch. Maintainers will
likely ask for a `hid-recorder` capture (`hid-tools` package).

References:
- <https://lkml.rescloud.iu.edu/1603.1/03734.html> — 2016 "Release all touch slots on reset_resume"
- <https://community.frame.work/t/framework-12-omarchy-quattro-dead-touchpad-after-hibernation-reboot/84334> — sibling failure, different vendor
- <https://patches.linaro.org/project/linux-input/patch/20210107112708.25990-1-hui.wang@canonical.com/> — set-inputmode quirk precedent
- <https://bugzilla.redhat.com/show_bug.cgi?id=1701766> — old i2c-hid stuck-button report (different cause)
