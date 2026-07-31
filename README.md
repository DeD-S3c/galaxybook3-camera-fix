# Galaxy Book3 Pro — OV02C10 / IPU6 camera fix

Samsung Galaxy Book3 Pro, Fedora, kernel 7.1.5, libcamera 0.7.1, PipeWire 1.6.8.
Sensor: OmniVision OV02C10 behind an Intel IPU6 (RaptorLake), 2 MIPI lanes,
1928x1092 SGRBG10, driven by libcamera's *simple* pipeline handler + software ISP.

Out of the box the camera either does not probe at all (the in-tree driver
rejects the 26 MHz clock the firmware feeds it) or, with the usual "remove the
clock check" patch, produces an upside-down, grainy, washed-out picture with
`Frame sync error` in the kernel log. This fixes all of it in the driver and
in a libcamera tuning file — six separate bugs, each measured rather than
guessed. The section below says what each one was.

```bash
sudo dnf install -y dkms kernel-devel gcc make v4l-utils libcamera-tools
git clone https://github.com/DeD-S3c/galaxybook3-camera-fix
cd galaxybook3-camera-fix
./install.sh     # build + install module and tuning file
./verify.sh      # objective check afterwards
./uninstall.sh   # revert
```

The module is installed through DKMS, so it survives kernel updates. Nothing
here touches PipeWire, WirePlumber or audio.

**Scope.** Developed and verified on a Galaxy Book3 Pro (DMI `940XFG`). Other
machines with an OV02C10 on an IPU6 will likely need §1 and §3 too, but the
26 MHz assumption, the 180° rotation and the CCM are specific to this unit —
check `verify.sh` output before trusting the numbers. It is a patched
out-of-tree driver: read `ov02c10.c` before running it as root.

---

## What was actually wrong

### 1. The 26 MHz clock was accepted but never accounted for

The firmware feeds the sensor **26 MHz**, not the 19.2 MHz upstream assumes.
The previous patch removed the clock check but left the PLL register set alone,
so every clock the sensor derives came out a factor 26/19.2 = **1.3542 too high**
while the driver kept advertising the nominal numbers:

| | advertised | actual |
|---|---|---|
| MIPI link freq | 400 MHz (800 Mbps/lane) | **541.67 MHz (1083 Mbps/lane)** |
| pixel rate | 160 MHz | **216.67 MHz** |
| frame rate | 30 fps | **40.8 fps** |
| max exposure | 33.2 ms | **24.5 ms** |

Measured, not inferred: a plain `v4l2-ctl --stream-mmap` on `/dev/video1`
reported `40.82 fps`, which is exactly 30.14 × 26/19.2.

Two consequences:

* **The frame sync errors.** `ipu6_isys_csi2_calc_timing()` derives the CSI-2
  receiver's TERMEN/SETTLE counters linearly from the sensor's
  `V4L2_CID_LINK_FREQ` control. Telling it 400 MHz while the sensor transmits at
  541.67 MHz makes the settle window 35% too long, and the receiver samples the
  data lanes at the wrong moment. That is where `csi2-0 error: Frame sync error`
  came from — it happens with **raw v4l2-ctl captures and no userspace ISP at
  all**, so it was never a CPU-load or CCM problem.
* **26% of the light was being thrown away.** Running at 40.8 fps instead of 30
  caps the integration time at 24.5 ms instead of 33.2 ms, and the AGC then has
  to make up the difference with gain, i.e. with noise.

Fix: advertise the real link frequency and pixel rate, and stretch VTS from 2328
to 3167 lines so the sensor genuinely runs at 30.0 fps with a 33.2 ms exposure
ceiling.

> **Gotcha, found the hard way.** The blanking limits are recomputed in *two*
> places: `ov02c10_init_controls()` and `ov02c10_set_format()`. Patching only
> the first one looks like it works — `v4l2-ctl --stream-mmap` measures 30.01
> fps because it does not issue a `SUBDEV_S_FMT` when the format is already
> set. Every real application does, and `set_format()` then resets VBLANK to
> the upstream `vts_min * lanes` value, quietly putting the sensor back to
> 40.8 fps with a 24.5 ms exposure ceiling. The symptom in the libcamera log is
> `IPASoft: Exposure 4-2320` instead of `4-3159`. `verify.sh` now forces a
> `set_format` before reading the controls, precisely so this cannot hide again.

### 2. The analogue gain default was pinning the AGC to a permanent 8x floor

libcamera has **no `CameraSensorHelper` for ov02c10** (confirmed in the log:
`Failed to create camera sensor helper for ov02c10`). When the helper is missing,
`IPASoftSimple::configure()` falls back to:

```c
context_.configuration.agc.again10 = againDef;   /* the driver's DEFAULT gain */
```

`again10` is the AGC's "unity gain" — the point below which it stops reducing
gain and starts reducing exposure instead:

```c
if (exposureMSV > optimal + 0.2) {
        if (again > again10)  reduce gain;
        else                  reduce exposure;
}
```

With `OV02C10_ANAL_GAIN_DEFAULT = 0x80` the AGC's floor became **8x**, so it
could never go below 8x analogue gain and instead crushed the exposure — the
sensor was found sitting at exposure=32 lines (456 µs) with 7.3x gain. Short
exposure plus high gain is the worst possible SNR, and that is the grain.

Fix: default back to `0x10` (1x). The AGC then does the right thing — it drives
exposure all the way to 33 ms *first* and only then raises gain.

### 3. Fixed 6x digital gain

libcamera's software ISP never touches `V4L2_CID_DIGITAL_GAIN`, so the 6x set as
a driver default was permanent. Measured on this unit: the sensor's own BLC
block re-targets black to 64/1023 after the gain stage, so it did *not* lift the
pedestal — but it did compress everything above black into 1/6 of the ADC range,
which is the washed-out, posterised look.

Fix: `V4L2_CID_ANALOGUE_GAIN` now spans **1x…62x** and the driver splits it —
analogue up to 15.5x, sensor digital gain beyond that. One knob, driven by the
AGC, 1x when there is enough light. The separate `V4L2_CID_DIGITAL_GAIN` control
is gone so nothing can leave a stale multiplier behind.

This matters more than it looks: the GPU debayer shader reads only **the 8 high
bits** of each 10-bit pixel (see `bayer_1x_packed.frag`). In a dim room the raw
signal can occupy 10-bit values 64→150, i.e. 8-bit 16→37 — about 21 tonal levels.
Sensor digital gain is applied before that truncation, so it recovers real
resolution rather than just multiplying an already-quantised value.

### 4. The tuning file was being ignored

`BlackLevel` reads the key **`blackLevel`**, not `black`:

```c
auto blackLevel = tuningData["blackLevel"].get<int16_t>();
definedLevel_ = blackLevel.value() >> 8;   /* 16-bit -> 8-bit */
```

So `black: 16` did nothing. Likewise `gamma: 0.5` did nothing — `Adjust::init()`
declares its `tuningData` argument `[[maybe_unused]]`; gamma, contrast and
saturation are *runtime controls* (`controls::Gamma` etc.), defaulting to
2.2 / 1.0 / 1.0. Same for `Agc`, which takes no tuning parameters at all.

Measured black level, exposure 57 µs, all gain combinations tried: **63.94–64.07
on every Bayer channel**, i.e. exactly the 0x40 that register 0x4003 programs.
That is 16 in 8-bit terms, so the correct tuning key is `blackLevel: 4096`
(4096 >> 8 = 16).

The file was also being installed into `ipa/soft/` and `/usr/local/share/...`.
The soft ISP's IPA module reports its name as `simple`, and `LIBCAMERA_DATA_DIR`
is `/usr/share`, so the only path that is ever read is
`/usr/share/libcamera/ipa/simple/ov02c10.yaml`.

### 5. The CCM was blamed for a problem it did not cause

Fedora builds libcamera with `softisp-gpu`, and `SoftwareIsp` picks `DebayerEGL`
by default — the CCM is a `mat3` multiply in a fragment shader. Measured with
the CCM from this repo enabled: **801 frames in 19.65 s = 40.8 fps**, i.e. the
full sensor rate, on the Iris Xe. It costs nothing. The 1 fps stall was the
D-PHY problem from §1.

Without a CCM the raw sensor primaries go straight through and everything is
grey/desaturated — this is the main cause of the remaining "milky" look. The
matrix here is deliberately moderate (rows sum to 1.0 so the neutral axis and
AWB stay valid); this sensor is noise-limited and an aggressive matrix would
amplify chroma noise more than it helps.

### 6. Reloading the module leaves PipeWire holding a dead camera

`intel_ipu6_isys` keeps `/dev/media0` alive across an `ov02c10` reload, so
libcamera's udev enumerator never sees a remove/add event — but the sensor
subdev comes back under a **new** number (`v4l-subdev4` → `v4l-subdev5`).
PipeWire's libcamera plugin is left holding a camera object that points at a
device node which no longer exists, and every client fails with:

```
gstpipewiresrc.c(929): on_state_changed (): ... streaming stopped, reason not-negotiated (-4)
```

GNOME Snapshot reports this as *"Errore nella riproduzione del flusso della
fotocamera"*. `qcam` still works, because it builds its own `CameraManager`.
The tell is `object.serial` on the camera node: if it is low, the node dates
back to when PipeWire started and is stale.

`install.sh` now restarts **wireplumber only** (never `pipewire` or
`pipewire-pulse`) to force re-enumeration, after snapshotting the default
source/sink *by name* along with their volume and mute state, and putting them
back if anything moved. Verified: microphone and speaker come back byte
identical.

### 7. The picture is upside down

The camera module on this machine is mounted inverted, but the SSDB reports
`degree = 0`, so ipu-bridge hands the driver a `rotation` property of 0 and
nothing downstream knows to flip.

The out-of-tree Intel driver papered over it at the end of `start_streaming`,
XOR-ing the mirror+flip bits into register 0x3820 for three known module names
(`2BG203N3`, `CJFME32`, `KBFC645`). That is the wrong layer for the mainline
driver: libcamera *writes* `V4L2_CID_HFLIP`/`VFLIP` itself, derived from
`V4L2_CID_CAMERA_SENSOR_ROTATION`, so a rotation applied behind its back gets
overwritten on the next `setFormat()`.

So the driver now reports the rotation instead — same module-name detection via
the `822ace8f-…` `_DSM`, but the answer goes into `props.rotation` before the
control is created, and libcamera does the flip. A `rotation=` module parameter
(`-1` autodetect, `0`, `180`) overrides it without recompiling.

Note that the flips do *not* alter the Bayer order here: the driver shifts the
ISP window by a pixel to compensate, and correspondingly does not set
`V4L2_CTRL_FLAG_MODIFY_LAYOUT`. Verified by capturing with and without the
flips — the picture comes out upright with skin tones unchanged, no red/blue
swap.

---

## Expected values after installing

```
link_freq      541666666
pixel_rate     216666666
vertical_blanking  default 2075   -> VTS 3167 -> 30.0 fps
exposure       4..3159            -> up to 33.2 ms
analogue_gain  16..992 default 16 -> 1x .. 62x, starts at 1x
```

`digital_gain` no longer appears — that is intentional.

## Known limitation

The software ISP has **no denoiser**. In a genuinely dark room the AGC will run
out of exposure and start adding gain, and the result will be grainy no matter
what — Windows hides this with temporal denoising in the IPU6 hardware ISP,
which has no upstream Linux driver. Everything above removes the *artificial*
noise (the 48x gain floor and the 26% shorter exposure); the physics that is
left is the sensor's.

---

## Licence and provenance

`ov02c10.c` is derived from the mainline Linux driver
`drivers/media/i2c/ov02c10.c` (Copyright © 2022 Intel Corporation) and is
therefore **GPL-2.0**, like the rest of this repository — see `LICENSE`.
`ov02c10.yaml` is CC0-1.0.

The module-name detection in §7 (`2BG203N3`, `CJFME32`, `KBFC645` via the
`822ace8f-…` `_DSM`) comes from Intel's out-of-tree IPU6 driver; the rotation
is reported to userspace here instead of being applied behind libcamera's back.

Bug reports and results from other Galaxy Book models are welcome — please
include the full `./verify.sh` output and `dmesg | grep ov02c10`.
