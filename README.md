# vphoto-frame-linux

Mainline Linux for VPhoto / Joyhong Allwinner A33 digital photo frames — U-Boot,
a 6.18 kernel with a MIPI-DSI panel driver, and Alpine, booted from microSD. The
internal eMMC and stock Android are never touched: pull the card and the frame
is stock again.

What you get on the glass is a full-screen web page (WebKitGTK in a Wayland
kiosk) that you can touch, with the frame's own hardware behind it: backlight,
light sensor, accelerometer, SoC temperature. The page can be anything. If it
is served by something that speaks [FRAME-API](docs/FRAME-API.md), the frame
also reports its sensors there and takes its screen policy (when to go dark,
how bright) from it.

How it got here — every wrong turn included — is in
[docs/bring-up.md](docs/bring-up.md). This file is the short version.

## Tested hardware

| | |
|---|---|
| Frame | VPhoto "Modern 10 Elite", 10.1" 1280x800 touch, Android 6.0.1 stock |
| Board | Joyhong `astar_ococci` (Allwinner A33, 4x Cortex-A7, 1 GB DDR3L, AXP223 PMIC) |
| Panel | `a00zp101b187_e40`, 800x1280 MIPI-DSI, 4 lanes, unnamed controller (our driver replays the vendor's init table) |
| Touch | Silead GSL1680 on TWI0 0x40 |
| Wi-Fi/BT | Realtek RTL8723DS (SDIO + UART) |
| Accelerometer | MiraMEMS DA280 on TWI1 0x27 (the vendor calls it "mir3da") |

One unit has been tested. Other Joyhong A33 frames are likely close; see
"Other models".

## What works

- Boot from microSD: U-Boot 2026.07 (based on the A33 reference tablet), Linux
  6.18 LTS, Alpine 3.22 (armv7).
- The panel, through our DSI panel driver (`kernel/panel-vphoto-a00zp101b187.c`).
- PWM backlight, including off/on and brightness from the shell.
- Touch, calibrated on the glass (the vendor's own settings are for Android's
  rotation and are wrong here; `kernel/*.dts` says why).
- Wi-Fi (RTL8723DS, mainline `rtw88_8723ds`).
- SSH over the USB cable: the micro-USB port is a CDC-ECM Ethernet gadget;
  the frame is `192.168.7.2` and hands your computer `192.168.7.1`. Works on
  macOS (which has no RNDIS driver) and Linux. And SSH over Wi-Fi.
- The accelerometer: the page turns upright whichever way up the frame hangs
  (0/180 degrees; touch turns with it).
- Light sensor (an analog phototransistor on the LRADC: trends, not lux) and
  the SoC's die temperature (not a room thermometer).
- The screen goes dark after a while without a touch (`FRAME_AWAKE_S`, 300 s
  by default) and the first touch on the dark glass wakes it without reaching
  the page.

Not on this unit: the PIR motion sensor the board has a footprint for (not
fitted), a microphone (not seen). On the board but not enabled yet: Bluetooth,
the IR receiver, audio/speaker.

## Known issues

- **Software rendering.** The Mali-400 (lima) is GLES 2 only and GTK 4's GL
  renderer wants more, so GTK draws in software. Fine for a mostly static
  page at ~0-2% CPU; animation-heavy pages will feel it.
- **JavaScriptCore runs without its JIT** (`JSC_useJIT=false` in
  `shell/start.sh`): the armv7 JIT hit an internal assertion minutes into a
  real page and killed the web process. The interpreter is slower; the shell
  also reloads the page if the web process ever dies.
- **Tap drift.** The touch controller reports a resting finger drifting
  10-25 px (Android hid this with a closed filter library). The shell allows
  40 px of slop so taps stay taps (`FRAME_TAP_SLOP`), but the click lands where
  the finger lifted, so a drift can pick a neighbouring small button.
- No suspend; the frame is meant to be mains-powered and always on.

## Building

Everything builds in Docker; nothing is installed on your machine. Tested on an
Apple-silicon Mac with Docker Desktop (the root filesystem is assembled in an
emulated `linux/arm/v7` container, which Docker Desktop provides). Sources and
object trees live in a Docker volume (`frame-linux-cache`), outputs in `out/`.

```sh
./build.sh fetch                 # pinned U-Boot, kernel, sunxi-tools (build/versions.env)
./build.sh uboot                 # out/u-boot-sunxi-with-spl.bin
./build.sh kernel                # out/zImage, the dtb, out/modules.tar.gz
./build.sh vendor                # the touch firmware, from YOUR frame (below)
FRAME_SSH_KEYS=~/.ssh/id_ed25519.pub ./build.sh rootfs   # the key that may log in as root
./build.sh rootfs-test           # boots its services in a chroot, checks SSH/network/reports
./build.sh image full            # out/frame-linux-full.img
./build.sh boot-test             # boots that image in qemu: U-Boot, the init hook, fsck, services
```

`./build.sh` with no argument lists the steps. Root has no password: the only
way in is the key you build in.

### The touch firmware

The GSL1680 needs a firmware blob that only the vendor ships, inside Android's
touch module. It is not in this repository and never will be: the `vendor` step
cuts it out of **your own frame's** files, put in `./backup` (or wherever
`FRAME_BACKUP` points), either

- `gslX680new.ko` — the module itself, from the frame's `/vendor/modules/`
  (e.g. `adb pull /vendor/modules/gslX680new.ko backup/` if adb is enabled), or
- `system.img` — a dump of the frame's Android system partition, read without
  mounting it.

`tools/gsl-fw-extract.py` picks this panel's table (`GSLX680_FW_Juhong101`) and
`build/vendor.sh` checks the result against the known-good checksum.

## Writing the card

Any microSD card of 2 GB or more. **Check which disk is the card before
writing** — `dd` to the wrong disk destroys it.

macOS:

```sh
diskutil list external physical        # find the card: its size, "external, physical"
diskutil unmountDisk /dev/diskN
sudo dd if=out/frame-linux-full.img of=/dev/rdiskN bs=1m
```

If `dd` says "Operation not permitted", give Terminal access to removable
volumes (System Settings → Privacy & Security → Full Disk Access, or
"Removable Volumes" under Files and Folders) and run it again.

Linux: `lsblk` to find the card, then
`sudo dd if=out/frame-linux-full.img of=/dev/sdX bs=4M conv=fsync`.

Then, on the card's FAT partition (it mounts as `FRAMEBOOT`), add:

- `wpa_supplicant.conf` for Wi-Fi:

  ```
  ctrl_interface=/var/run/wpa_supplicant
  country=US
  network={
      ssid="your network"
      psk="your password"
  }
  ```

- `frame-shell.conf` for the page (next section).

Both stay on the card, readable only by root on the frame; neither is ever
built into the image.

Card in, power on: the A33's boot ROM tries the microSD before the eMMC. The
backlight blinks three times (U-Boot), then the console, then the page. Card
out, power on: stock Android, untouched.

## Configuring the page

`FRAMEBOOT/frame-shell.conf` (shell syntax). The full list is at the top of
`shell/frame-shell.py`; the ones that matter:

```sh
FRAME_PAGE="https://example.org/"      # a plain kiosk: any page
# or a FRAME-API server (docs/FRAME-API.md): page at /frame, reports, policy
FRAME_API="https://dashboard.example"
FRAME_TOKEN="..."                      # its token, if it uses one
FRAME_AWAKE_S=300                      # dark after this long without a touch
FRAME_AUTOFLIP=1                       # turn the page with the frame (default)
```

Without the file the shell doesn't start and the glass keeps the console.
`FRAME_CALIBRATE=1` shows a crosshair page for checking rotation and touch;
`FRAME_DEBUG_TOUCH=1` logs every touch the page gets to
`/var/log/frame-shell.log`.

## Getting in, and seeing what happened

- `ssh root@192.168.7.2` over the USB cable, or `ssh root@<its Wi-Fi address>`.
- Every boot writes reports to the card, readable from any computer:
  `FRAMEBOOT/diag/{early,boot,60s,180s,now}.txt` (kernel log, addresses,
  services, Wi-Fi state with SSIDs masked; the Wi-Fi config is never copied).
  A short status block (addresses, USB state, failed services) is shown above
  the console login.
- `FRAMEBOOT/frame-run.sh`, if you put one there, runs once per boot as root
  with its output in `diag/run.txt` — a console without a keyboard. Off unless
  the file exists.

## Updating a card without rewriting it

The kernel (`zImage`) and device tree (`*.dtb`) are plain files on FRAMEBOOT:
replace them (keep the old ones as `.prev` to go back). For the root
filesystem, which a computer can't easily write, there is a hook:

- `boot.scr` starts the kernel with `init=/bin/sh -- -c "..."`, a one-liner
  that mounts the card's FAT, runs `FRAMEBOOT/frame-fix.sh` if present, and
  then hands over to the normal init. Every step is chained so that a missing
  file still boots.
- `frame-fix.sh` unpacks `FRAMEBOOT/frame-overlay.tar.gz` over the root
  filesystem — once per version (its sha256 is remembered) — and logs to
  `diag/fix.txt`.
- `./build.sh fat-update` builds those three files from the repo; copy them
  onto FRAMEBOOT. `./build.sh boot-test` boots an image with them applied,
  twice, before you trust them.

Physical access to the card already means root on the frame; the hook adds
convenience, not reach. Delete `frame-overlay.tar.gz` to stop updates.

## Safety

- The eMMC controller (`mmc@1c11000`) is **disabled in the device tree**:
  Linux has no block device for it, so nothing here can read or write Android.
- Nothing is ever written to the frame except the card you put in it.
- Root logs in by key only; there is no password and no other service
  listening (`dropbear` on 22, a DHCP server on the USB link only).

## Repository layout

```
build.sh, build/   the Docker build: one script per step, pinned versions
uboot/             U-Boot config fragment + boot script
kernel/            panel driver, board device tree, kernel config fragment
rootfs/            files laid over Alpine (services, network, fstab, diagnostics)
shell/             the kiosk: frame-shell.py (+ the in-page bridge, calibration)
boot/              frame-fix.sh, the FAT update hook's script
tools/             fex decoder, ELF readers, the touch-firmware and panel-init extractors
vendor/            data read out of the vendor firmware: sys_config.fex, panel init table
docs/              bring-up log, FRAME-API
```

## Other models

Joyhong builds many frames on the same A33 board for different brands. If you
have one, an issue with these helps tell whether this port fits it:

- brand, model and the Android build (`getprop ro.product.model`,
  `ro.product.board`, `ro.build.fingerprint`);
- the board config: `script.bin` / `sys_config.fex` (see docs/bring-up.md,
  "Where the board description was hiding" — `tools/bin2fex.py` decodes it);
- the panel name from the vendor kernel's command line or `lcd.ko`, and the
  touch module name in `/vendor/modules/`;
- photos of the board if you have it open.

The panel is the hard part: a different panel needs its own init table
(`tools/panel-init-extract.py` reads it out of the vendor `lcd.ko`).

## Licensing

- `kernel/panel-vphoto-a00zp101b187.c`: GPL-2.0-only (it is a Linux driver).
- `kernel/sun8i-a33-vphoto-modern10elite.dts`: GPL-2.0+ OR MIT, as the kernel's
  device trees are.
- `uboot/frame.config`, `uboot/boot.cmd`: GPL-2.0+, as U-Boot.
- Everything else written for this project: MIT (`LICENSE`).
- `vendor/` holds data read out of the frame's stock firmware (the board config
  and the panel's init sequence) for interoperability; it is not ours to
  license. The touch firmware is deliberately not included at all.
