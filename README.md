# frame-linux

A mainline-Linux port for the VPhoto "Modern 10 Elite" photo frame (Allwinner A33,
1 GB, 800x1280 MIPI-DSI panel with Silead touch), booting **from the TF card only**.
The eMMC keeps its Android 6; pull the card and the frame is a VPhoto again. This is
the second of two parallel takes on the frame — the other keeps the stock Android and
ships an APK — and both are meant to run the same interactive cortex page served by
`panels`, with a small native bridge for PIR / light / screen power / brightness.

Shared ground truth for the device (access rules, the backup, who may reboot it) is
`./backup/FRAME-FACTS.md`. This team is **read-only on the
device**: every number below came from copies of the backup images or from read-only
adb (`cat`, `dumpsys`, `/sys/kernel/debug`), never from a write.

Status (2026-10-19): Phase 1 done; the owner approved the direction. Phase 2 builds
U-Boot, the kernel (with our panel driver and board DT), an Alpine rootfs and the card
image, all reproducibly in Docker (see "Building"). ~~**Nothing has run on the frame
yet**: milestones 1-2 are waiting on a card in the slot.~~

2026-10-20, first card test (`frame-linux-full.img`, sha256 f47b62cd…): the BROM
booted the card, the kernel came up and **the panel works** — a login prompt on the
glass, so U-Boot, our panel driver, DSI and fbcon are right first time (M1+M2
display). The USB network didn't: the gadget enumerated as "RNDIS/Ethernet Gadget",
macOS has no RNDIS driver and made no interface. The kernel now builds g_ether with
ECM only (kernel/frame.config); the fix is the new zImage alone, copied onto
FRAMEBOOT — same release string (6.18.57-frame) and no MODVERSIONS, so the modules
already on the card still load, and the dtb is byte-identical to the card's.
There is no console login on purpose (root is locked, the frame has no keyboard):
the ways in are SSH over USB or Wi-Fi.

Second card test (ECM zImage): macOS now binds the gadget (en15) but reports it
"inactive", and Wi-Fi didn't join either. On ECM the gadget only signals a
connection once usb0 is opened, so usb0 was never brought up -- and with neither
way in nor a console, the card couldn't say why. Offline (`./build.sh
rootfs-test`), the same interfaces file brings usb0 up fine; what it also showed
is that `ifup` of an interface that doesn't exist *yet* fails once and nothing
retries. So the next card is built to come up regardless and to report on itself:
- `frame-netwait` waits (bounded, never failing) for usb0 and wlan0 before
  networking; `usb-dhcpd` brings usb0 up itself and no longer `need`s all of
  networking; wpa_supplicant names wlan0 and respawns until it appears.
- `frame-diag` writes /boot/diag/{early,boot,60s,180s,now}.txt on the FAT
  (dmesg, addresses, rc-status, rc.log, syslog, udc state, lsmod, iw, wpa state,
  SSIDs masked, the conf never copied) and a status block above the login prompt.
- `/boot/frame-run.sh`, if present, runs once per boot as root into
  /boot/diag/run.txt: the console stand-in. Off unless the file is put there.
  (A tty1 autologin would be useless: the OTG port is the gadget, so no keyboard.)
- the page (frame-shell) only starts with /boot/frame-shell.enable, so cage
  doesn't cover the status block while the hardware is brought up.
- fixed gadget MACs (one enX on the Mac, not a new one per boot), wireless-regdb,
  cfg80211 regdom MX.

Third card test (811ea0eb), from a photo of tty1: **the real cause of all three**.
OpenRC's boot runlevel aborted in fsck: fstab named /boot as
PARTUUID=f4a3e001-01, which only the kernel can resolve -- busybox/mdev make no
/dev/disk/by-partuuid links -- so fsck.fat got a path that doesn't exist and
fsck's rc-abort stopped the boot. Networking, dropbear, wpa_supplicant and
frame-diag never ran on any of the three boots (hostname never ran either:
"(none) login:"). rootfs-test missed it because it commented those fstab lines
out to mount by hand: the one test that would have caught it, skipped. The card
also came up as mmcblk1, so device numbering follows probe order.
- fstab by LABEL (busybox mount resolves it from /proc/partitions), fsck pass 0,
  nofail on /boot, fsck_abort_on_errors=no.
- the fix reaches the card as files on FRAMEBOOT (`./build.sh fat-update`):
  boot.scr now passes `init=/bin/sh -- -c "..."`, which mounts the FAT, runs
  FRAMEBOOT/frame-fix.sh, and execs /sbin/init; frame-fix.sh unpacks
  frame-overlay.tar.gz over / once per version (log: diag/fix.txt). Every rootfs
  fix from here on can be a FAT copy instead of a dd.
- the hook can't reach the eMMC: its controller (mmc@1c11000) is disabled in
  our DT, so Linux has no block device for it; the card is the only mmcblk
  (mmcblk1 on the frame, mmcblk0 in qemu -- the hook tries both).
- `./build.sh boot-test` now boots the actual card image (+ the FAT update) in
  qemu vexpress-a9: the real boot.scr through U-Boot's own hush, the kernel's
  init-arg parsing, the hook, OpenRC with an mdev-only /dev -- twice, so the
  second boot proves the overlay isn't re-applied. Only the zImage and dtb are
  vexpress ones. This is the test that would have caught the fsck abort.
- mdev: "can't create /proc/sys/kernel/hotplug" is CONFIG_UEVENT_HELPER being
  off. It costs nothing here: devtmpfs creates the device nodes itself, usb0 and
  wlan0 are netdevs (no /dev node), firmware is loaded by the kernel directly,
  and the modules are coldplugged by hwdrivers plus modules-load.d.

```
tools/bin2fex.py            script.bin -> .fex (sunxi-tools' bin2fex, rewritten in 60
                            lines so the extraction needs nothing but python3)
tools/elfrel.py             minimal ELF32 reader shared by the two extractors below
tools/gsl-fw-extract.py     touch firmware out of the vendor gslX680new.ko
tools/panel-init-extract.py DSI init table out of the vendor lcd.ko
vendor/sys_config.fex       the decoded board config (the A33 has no device tree in
                            its 3.4 kernel; this file IS the board description)
vendor/a00zp101b187-init.txt the panel's DCS init sequence, as C rows
```

Vendor blobs (the touch firmware, Realtek firmware, the .ko files) are **not committed**;
the build will cut them out of the backup at build time with the tools above.

## Where the board description was hiding

The brief guessed `bootloader.img` (the vfat `/bootloader`) would hold `script.bin`. It
doesn't — only boot logos, battery BMPs and fonts. On this Allwinner BSP (sun8iw5,
U-Boot 2011.09 dated Jul 17 2025) the compiled `sys_config` is **appended to U-Boot**
in the raw head of the eMMC:

```
head-raw.img @ 8 KiB          eGON.BT0 (boot0 / DRAM init)
head-raw.img @ 19554304       "uboot" header (sector 38192), length 0xd0000
             + 0xc4000        script.bin: 76 sections, 0xa094 bytes
```

The kernel cmdline confirms it is the live copy: `config_size=41108` = 0xa094. Extract:

```bash
dd if=head-raw.img of=script.bin bs=1 skip=$((19554304+0xc4000)) count=$((0xc000))
python3 tools/bin2fex.py script.bin > sys_config.fex
```

Kernel cmdline (boot.img, empty header cmdline; U-Boot builds it):
`console=ttyS0,115200 root=/dev/mmcblk0p7 init=/init ion_cma_list=120m,256m loglevel=4 partitions=...`.
`boot.img`'s kernel is an uncompressed 3.4.39 `Image` (gcc 4.6.3, built "joy@joy-PowerEdge-T550").

## The board, pin by pin

GPIO numbers in the vendor kernel are `32 * port + pin`, PA = 0 ... PL = 11 (PL0 = 352).

| What | Vendor config | Notes for mainline DT |
|---|---|---|
| SoC / DRAM | A33, DDR3 480 MHz, zq 15339 (0x3beb), odt on, tpr13 0x10900 | U-Boot `CONFIG_DRAM_CLK=480`, `DRAM_ZQ=15339`, `DRAM_ODT_EN=y` |
| PMIC | AXP223 on RSB (PL0/PL1); dcdc1 3.3, dcdc2/3 1.2 (cpu/gpu), dcdc5 1.35 (DDR3), aldo1 3.3, aldo3 3.0 | standard `axp22x.dtsi`; **no battery present** (sysfs `battery PRESENT=0`), mains only |
| Panel | `lcd_if=4` = **MIPI-DSI, 4 lanes**, `a00zp101b187_e40`, 800x1280 portrait, 135x216 mm | power `dc1sw`; reset **PL5** (`lcd_gpio_0`) |
| Timings | dclk 77 MHz, ht 980, hbp 100 (incl. hspw 20), vt 1316, vbp 16 (incl. vspw 4) | 800+80+20+80 / 1280+20+4+12 → 59.7 Hz |
| Backlight | PWM ch0 on **PH0**, 50 kHz, enable **PL4** active high | exactly the A33 reference tablet (`sun8i-reference-design-tablet.dtsi`) |
| Touch | Silead `gslX680_juhong101`, **TWI0 (PH2/PH3) @ 0x40**, irq **PB5**, wake/power **PH1**, vdd `ldoio1` 3.3 V; swap x/y + invert x | `silead,gsl1680`, `touchscreen-swapped-x-y`, `touchscreen-inverted-x` |
| PIR | **PG12** (gpio 204), plain input, *polled* by a timer in `bl_h18l232b.ko` ("BL-H18L232B-2 human sensor", Regan Yuan @ococci) — `/sys/class/humansensor/sleepmode` is that pin. **Not fitted on this unit**: the owner waved at it for 2 min and it stayed 0, and `ro.fullja.human_sensor=0` | needs nothing but `gpiod`; touch is the only wake source here |
| Light | "pt3r850" is **not an I2C chip**: it is an analog phototransistor on the **LRADC**, read by the vendor's hacked `sunxi-keyboard.ko` (input `pt3r850-lsensor`, ABS_MISC 0..200, read 94 indoors) | needs a driver, see below |
| "Ambient temperature" | Android's `AW.` temperature sensor is input `sunxi-ths` = the **SoC die thermal sensor** (read 45 °C) | not a room thermometer — see FRAME-FACTS fix |
| Wi-Fi | RTL8723DS SDIO on **mmc1** (PG0-PG5), `wl_reg_on` **PL6**, host-wake **PL7** | `mmc-pwrseq-simple` reset PL6 active-low |
| BT | same chip, **UART1** (PG6-PG9, RTS/CTS), reset **PL8**, wake **PL10**, host-wake **PL9** | serdev `realtek,rtl8723ds-bt` |
| TF slot | mmc0 PF0-PF5, card-detect **PB4** (pull-up, active low) | `cd-gpios = <&pio 1 4 GPIO_ACTIVE_LOW>` |
| Serial | `uart0` is **muxed onto the TF pins** PF2/PF4 (A33 BROM default) | only reachable with a microSD breakout — see "Seeing it boot" |
| Accelerometer | mir3da @ TWI1 0x27 | mainline `da280` claims 0x27 (MiraMEMS); not needed |
| IR receiver | `s_ir0` PL3 | `sun6i-a31-ir`; not needed |
| Audio | A33 codec, speaker PA enable **PH9** | `sun8i-a33-codec`; not needed |
| Buttons | none on LRADC (that is the light sensor); only the AXP power key | `axp20x-pek` |

### Panel power sequence (from `lcd.ko` disassembly)

`LCD_power_on`: enable `dc1sw`, 5 ms, mux DSI pins, 50 ms, PL5 = 1, 10 ms, PL5 = 0,
10 ms, PL5 = 1, 10 ms. `LCD_panel_init`: DSI clock on, 10 ms, the 27-row DCS table in
`vendor/a00zp101b187-init.txt` (ends `0x11`, 250 ms, `0x29`, 100 ms). Then the TCON,
and 200 ms later PWM + PL4. Close is the reverse with 200/500 ms.

The controller isn't named anywhere in the module. The unlock pair `E0 AB BA / E1 BA AB`
matches no mainline panel driver I could find; it is *not* the JD9365 (`E0 00 / E1 93
/ E2 65`) whose table sits first in the same `lcd.ko` — an extractor that grabbed that
one by name is why `panel-init-extract.py` scopes the symbol lookup to the panel's own
`.c` file.

## Boot path

- **BROM order:** every Allwinner BROM since the A10, A33 included, tries the FEL pin,
  then **SD (mmc0)**, then eMMC (mmc2), then SPI NOR, then FEL. A card with a valid
  `eGON.BT0` at 8 KiB therefore wins over the eMMC without touching it, and pulling
  the card falls back to the untouched Android. (To be *confirmed on hardware* by
  milestone 1 — the one thing that would break it is a vendor efuse forcing eMMC, which
  this cheap a board almost certainly doesn't burn.)
- **FEL:** no FEL/"uboot" button is known on this frame. Two ways in that keep the eMMC
  untouched: a TF card holding linux-sunxi's `fel-sdboot.sunxi` at 8 KiB (BROM loads it
  and it jumps straight to FEL), or `reboot efex` from Android (a reboot — the Android
  team's call). FEL then runs over the same micro-USB adb uses.
- **U-Boot:** closest defconfig is `q8_a33_tablet_800x480_defconfig` (A33 reference
  tablet: same PMIC, PWM backlight on PH0, enable PL4). Changes: DRAM clock/ZQ/ODT
  above, drop the parallel-LCD `CONFIG_VIDEO_LCD_*` (mainline U-Boot's sunxi video has
  no DSI, so **U-Boot shows nothing on this panel** — first light on glass is Linux),
  `CONFIG_MMC0_CD_PIN="PB4"`, `CONFIG_DEFAULT_DEVICE_TREE` our DT.
- **Kernel:** `sun8i-a33.dtsi` already has the DSI controller + D-PHY nodes, lima's
  Mali-400 MP2, `sun8i-a33-ths`, the codec. Our board `.dts` is the reference-tablet
  include plus the table above.

## Per-peripheral mainline status

| Peripheral | Status | Why |
|---|---|---|
| DSI host (`sun6i_mipi_dsi`) | **works, with a risk** | Upstream since 4.17; Maxime Ripard's series was tested on an A33 with a 4-lane ILI9881C 720x1280 panel and called "a bit rough around the edges"; Jagan Teki reworked A33 in 2019 (v10 series). No public report of an 800x1280 DSI panel on A33 found. |
| This panel | **needs a driver** | Unknown controller, no generic "init table from DT" DSI panel exists upstream. A ~200-line drm_panel modelled on `panel-ilitek-ili9881c.c` (table-driven) with the extracted table + PL5 reset. Mechanical, but only provable on the glass. |
| Backlight | needs DT only | `pwm-backlight` on PWM0 + `enable-gpios` PL4 — identical to the reference tablet DT. |
| GPU Mali-400 (lima) | works | Mesa ≥ 19.1 / kernel ≥ 5.2; GLES2 only; Mesa docs warn Utgard is "quite limited". |
| Wi-Fi RTL8723DS SDIO | works | `rtw88_8723ds`, mainline since 6.5 (Martin Blumenstingl); our ID 0xd723 is the two-antenna variant. FW `rtw88/rtw8723d_fw.bin` in linux-firmware. |
| BT | works (not needed) | `hci_uart` Realtek serdev + `rtl_bt/rtl8723ds_*`. |
| Touch (Silead) | needs DT + firmware | `silead.c` loads exactly the vendor's `{u32 offset, u32 val}` array (4818 words, md5 b74d4960...). Risk: the vendor also feeds a closed `gsl_point_id` filter with `gsl_config_data_id_Juhong101`; mainline has no equivalent, so jitter/ghost touches are possible. |
| PIR | needs DT only (or nothing) | a GPIO; `gpio-keys` with polling, or the bridge reads it with libgpiod. |
| Light sensor | **needs a driver** | Mainline `sun4i-lradc-keys` only turns LRADC into keys. Options: a ~100-line IIO driver for the LRADC, or the bridge reading LRADC_DATA from `/dev/mem` (LRADC at 0x01c22800, per `sun8i-a23-a33.dtsi`; Phase 1 said 0x01c21800, which was wrong). The channel (0 or 1) is still to be confirmed on hardware. |
| Temperature | works, but it's the SoC | `sun8i-thermal` (`sun8i-a33-ths`). There is no room thermometer on this board. |
| AXP223 | works | `axp20x-rsb`, regulators, PEK; `ldo_io1` regulator for the touch. |
| Audio | works (not needed) | `sun8i-codec` + analog, as on the Q8 tablets. |
| Cedrus video | works (not needed) | A33 is supported (MPEG-2/H.264). |

## Distro and UI engine

**The engine.** The frame has 1 GB and a GLES2-only GPU.

- **Cog / WPE WebKit** (recommended): a single-window kiosk browser made for this
  (cog's own man page: "web application container for embedded devices in kiosk mode");
  renders through GLES2, which lima provides. Digi's embedded docs recommend
  `--doc-viewer` / `--enable-page-cache=false` exactly for boards with ≤ 1 GiB. Cairo
  must be ≥ 1.18 (a 1.16 leak grew cog ~1 MiB/min on i.MX8M). A bonus over the Android
  route: current WPE is a *current* engine, so the page doesn't have to target
  Chrome 106 (oklch / color-mix are fine) on this port.
- **Chromium kiosk**: NORTH-STAR turned Chromium down for **server-side rendering**
  (subprocesses, zombies, image size on the `panels` host). Those reasons don't carry
  over to a device kiosk — there it is one long-lived process, not a render farm. What
  does argue against it here is memory and GPU: Chromium's multi-process model on 1 GB
  armv7, and its frequent blocklisting of lima, which would drop it to software
  compositing. Kept as the fallback if WPE misrenders the page, not the plan.
- **Native client** (Qt/LVGL): would mean a second implementation of the UI, the thing
  the shared-page design exists to avoid. Rejected.

None of these memory numbers are measured on this board yet; milestone 4 measures RSS
of cog with the real page and reports it before anything else is built on top.

**The distro.** Buildroot is the reproducible choice but means compiling WebKit (hours,
in a Docker VM on this Mac) on every toolchain bump. **Recommendation: our own
U-Boot + mainline kernel (built in Docker from pinned tags), with an Alpine armv7
userspace** — Phase 1 said Alpine ships `cog`, `wpewebkit`, Mesa with lima and
`linux-firmware-rtw88` as packages, so the only things we compile are the bootloader,
the kernel (with the panel driver) and the bridge.

*That was half wrong, found while building the rootfs:* Alpine ships Mesa with lima,
`linux-firmware-rtw88`, `cage` (a Wayland kiosk compositor), WebKitGTK
(`webkit2gtk-6.0`) and Chromium for armv7, but **no `cog` and no `wpewebkit` on any
branch or architecture** (checked v3.22, v3.23, edge; armv7 and aarch64). The engine
is the same WebKit either way; what changes is the wrapper. Options, in the order I'd
try them: (1) `cage` + a ~100-line WebKitGTK kiosk window (same script-message bridge
as WPE, packaged, nothing to compile; heavier than WPE and GTK4 may fall back to its
software renderer on a GLES2-only GPU — that is what milestone 4 has to measure);
(2) Chromium under `cage`, the packaged fallback; (3) WPE + cog cross-built ourselves
(Buildroot has both), the hours-of-WebKit-compile path this recommendation was trying
to avoid. The rest of the plan (Alpine base, own kernel) stands. Rootfs is assembled by a script from pinned `apk` versions;
the card image is the output, never committed. postmarketOS was the other candidate
(Alpine underneath, same packages) but adds its own device-package workflow for no gain
on a single board.

## The shell contract, and what it costs this port

The shell builds against `panels/frame/FRAME-API.md` (from the Android team's branch,
commit 9ab4dea). Two parts of it are cheap on Android and are not cheap here:

- **The page is 1280x800 landscape; the panel is 800x1280 portrait.** On Android the
  window manager rotates. Here the rotation is ours: the DRM primary plane `rotation`
  property, if sun4i's mixer will do 90° (unverified; the DE2 mixer may not), otherwise
  cog's GLES renderer, which rotates its output (cog ≥ 0.14). Touch must be rotated in
  the same direction, either with the DT `touchscreen-swapped-x-y`/`inverted-*` flags
  or with a libinput calibration matrix. Choose one place to rotate, so touch and pixels
  can't drift apart.
- **`window.CortexFrame` methods are synchronous** (the shape of Android's
  `@JavascriptInterface`). WPE only gives page→native *asynchronous* messages
  (`window.webkit.messageHandlers.*.postMessage`). The void methods (`policy`,
  `screenOff`, `setBrightness`, `reload`) map onto that directly. `info()` returns a
  value, so the shell will inject a user script that keeps a JS copy of the last
  readings, which the native side refreshes with `evaluate_javascript`, and `info()`
  returns that copy. It's debug-only per the contract, so a value up to a second
  old is fine.

The rest maps directly: the report is a `POST` from the native half, the policy rule
(force → motion/touch window → brightness) is a 1 s loop in the same process, "a
touch on a dark screen wakes it and is NOT passed to the page" means the shell
reads the touchscreen itself and only hands events to cog while the backlight is on,
and the offline "can't reach panels" screen is a local file cog loads when the
page's first load fails.

## What a first image does, and what comes later

First image (milestones 1-2): U-Boot from TF → mainline kernel → panel lit by our
driver → Wi-Fi on the LAN → SSH. Then touch + PIR + light (3), then cog full-screen on
the cortex page with the bridge (4).

Later / maybe never: BT, audio, the IR remote, the accelerometer's auto-rotate, suspend.

**Risks, biggest first:**
1. **The panel.** Unknown controller + a DSI host never publicly shown with an
   800x1280 panel on A33. If the table or the DSI mode (video burst vs sync pulses) is
   wrong, the screen stays black and nothing else is visible either. Mitigation: get
   SSH over Wi-Fi first-class (milestone 2 succeeds over the network even if the glass
   is dark), so the panel can be iterated on blind.
2. **No console.** uart0 is on the TF pins, U-Boot can't drive the DSI panel, and
   Wi-Fi only comes up at the end of boot. Milestone 1 is observed by the backlight
   (U-Boot toggles PL4/PWM0 — a visible blink means our SPL + U-Boot ran from the card)
   and by U-Boot enumerating over USB on the Mac (fastboot gadget). A $5 microSD
   breakout + FEL boot is the escape hatch if that's not enough.
3. **Touch filtering** without the closed gsl library (see above).
4. **Light sensor** needs our own small driver or a `/dev/mem` read.
5. **Engine memory** on 1 GB: to be measured, not assumed.

## Building

Everything runs in Docker (Docker Desktop on this Mac; `open -a Docker` if its engine
is down). Nothing is compiled on the host. Inputs are pinned in `build/versions.env`.

```bash
./build.sh fetch          # pinned U-Boot, kernel, sunxi-tools sources (out/dl + a docker volume)
./build.sh sunxi-tools    # sunxi-fel, fel-sdboot.sunxi (USB can't reach Docker on macOS; see the script)
./build.sh uboot          # out/u-boot-sunxi-with-spl.bin, out/boot.scr
./build.sh kernel         # out/zImage, out/sun8i-a33-vphoto-modern10elite.dtb, out/modules.tar.gz
./build.sh vendor         # touch firmware, cut from the eMMC backup (mounted read-only)
cp ~/.ssh/id_*.pub out/authorized_keys
./build.sh rootfs         # out/rootfs.ext4 (Alpine armv7, in Docker's emulated arm/v7)
./build.sh image m1       # 64 MiB card: U-Boot + boot.scr only
./build.sh image full     # ~830 MiB card: + kernel, dtb, rootfs
```

Times on this Mac: kernel ~3 min from cold, U-Boot ~1 min, rootfs ~20 s. Sources and
object trees live in the Docker volume `frame-linux-cache`, not under `out/`: the
first attempt unpacked the kernel onto the bind mount and macOS's case-insensitive
filesystem collided `xt_TCPMSS.h` with `xt_tcpmss.h`.

Card layout: MBR (disk id fixed at 0xf4a3e001, so root is `PARTUUID=f4a3e001-02`),
U-Boot at 8 KiB, `FRAMEBOOT` FAT32 at 1 MiB (boot.scr, zImage, dtb, and the owner's
`wpa_supplicant.conf` — Wi-Fi credentials never pass through this repo), ext4 root at
64 MiB. The frame is also `192.168.7.2` over the USB cable (Ethernet gadget, DHCP
hands the Mac `.1`), so SSH works before Wi-Fi does. Root has no password; dropbear
takes the key from `out/authorized_keys`.

## Seeing it boot

Until milestone 2, the only signals are the backlight and USB. The milestone requests
to the owner will spell out each step, always starting with `diskutil list` — the Mac
has other USB storage attached, so no `dd of=` is ever written without that check.
