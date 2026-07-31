#!/bin/bash
#
# Galaxy Book3 Pro (OV02C10 / IPU6) camera fix.
#
# Installs a patched ov02c10 kernel module and a libcamera software-ISP tuning
# file.  Does NOT touch PipeWire, WirePlumber or any audio configuration.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

KVER="$(uname -r)"
DKMS_NAME=ov02c10
DKMS_VER=1.0

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  + %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
say "1/7  Clean out any previous install"

sudo dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all >/dev/null 2>&1 || true
# DKMS stashes whatever module it displaced as an "original module" and puts it
# back on removal.  Ours is not the distro's, so drop the stash instead of
# letting a stale binary come back later.
sudo rm -rf "/var/lib/dkms/${DKMS_NAME}"
sudo rm -f "/lib/modules/${KVER}/updates/ov02c10.ko.xz" \
           "/lib/modules/${KVER}/extra/ov02c10.ko.xz"

# The first version of this script overwrote the distro's own module inside
# kernel/drivers/.  Both extra/ and updates/ take priority over it, so it is
# harmless and the next kernel-modules update replaces it - just report it.
INTREE="/lib/modules/${KVER}/kernel/drivers/media/i2c/ov02c10.ko.xz"
if [ -e "$INTREE" ] && rpm -Vf "$INTREE" 2>/dev/null | grep -q ov02c10; then
    warn "the stock module in kernel/drivers/ is still the one an earlier"
    warn "version of this script overwrote.  Harmless (extra/ wins), but to"
    warn "put the distro file back:  sudo dnf reinstall -y kernel-modules"
fi

# ---------------------------------------------------------------------------
say "2/7  Build"
make clean >/dev/null 2>&1 || true
make -j"$(nproc)"
ok "module built"

# ---------------------------------------------------------------------------
say "3/7  Install the libcamera tuning file"
# The soft ISP's IPA module reports itself as "simple", so libcamera looks for
# <datadir>/libcamera/ipa/simple/<sensor model>.yaml.  Nothing reads ipa/soft/
# or /usr/local/share, so drop the leftovers from earlier attempts.
sudo install -D -m 0644 ov02c10.yaml /usr/share/libcamera/ipa/simple/ov02c10.yaml
sudo rm -f /usr/share/libcamera/ipa/soft/ov02c10.yaml \
           /usr/local/share/libcamera/ipa/simple/ov02c10.yaml \
           /usr/local/share/libcamera/ipa/soft/ov02c10.yaml
sudo rmdir --ignore-fail-on-non-empty \
           /usr/share/libcamera/ipa/soft \
           /usr/local/share/libcamera/ipa/simple \
           /usr/local/share/libcamera/ipa/soft \
           /usr/local/share/libcamera/ipa \
           /usr/local/share/libcamera 2>/dev/null || true
ok "/usr/share/libcamera/ipa/simple/ov02c10.yaml"

# ---------------------------------------------------------------------------
say "4/7  Install the module via DKMS (survives kernel updates)"
sudo mkdir -p "/usr/src/${DKMS_NAME}-${DKMS_VER}"
sudo rm -f "/usr/src/${DKMS_NAME}-${DKMS_VER}"/*
sudo install -m 0644 ov02c10.c Makefile dkms.conf "/usr/src/${DKMS_NAME}-${DKMS_VER}/"

DKMS_OK=0
if sudo dkms add -m "$DKMS_NAME" -v "$DKMS_VER" >/dev/null 2>&1 &&
   sudo dkms build -m "$DKMS_NAME" -v "$DKMS_VER" >/dev/null 2>&1 &&
   sudo dkms install -m "$DKMS_NAME" -v "$DKMS_VER" --force >/dev/null 2>&1; then
    DKMS_OK=1
fi

# On Fedora, DKMS ignores DEST_MODULE_LOCATION and always installs into extra/.
INSTALLED="$(find "/lib/modules/${KVER}" -name 'ov02c10.ko*' \
             \( -path '*/extra/*' -o -path '*/updates/*' \) 2>/dev/null | head -1)"

if [ "$DKMS_OK" = 1 ] && [ -n "$INSTALLED" ]; then
    ok "DKMS installed ${INSTALLED}"
else
    warn "DKMS failed, falling back to a plain install in updates/"
    # Fedora's kernel decompressor only accepts CRC32; xz defaults to CRC64,
    # which fails with "decompression failed with status 6".
    xz -f --check=crc32 -k ov02c10.ko
    sudo install -D -m 0644 ov02c10.ko.xz "/lib/modules/${KVER}/updates/ov02c10.ko.xz"
    ok "installed in updates/ (will need re-running after a kernel update)"
fi
sudo depmod -a "$KVER"

# ---------------------------------------------------------------------------
say "5/7  Reload the module"
if ! sudo modprobe -r ov02c10 2>/dev/null; then
    warn "ov02c10 is in use - close every camera app (browser tabs count)."
    warn "The module is installed; rebooting picks it up too."
    exit 1
fi
sudo modprobe ov02c10
sleep 2

# ---------------------------------------------------------------------------
say "6/7  Check the driver"
#
# Before the wireplumber restart, never after: verify.sh grabs /dev/video1
# directly, and doing that once PipeWire has already enumerated the camera
# leaves its libcamera plugin holding a device someone else is streaming from.
# The symptom is a viewfinder that stutters badly and then dies.
#
sudo dmesg | grep -i "ov02c10.*mclk" | tail -1 || warn "no probe line in dmesg"
./verify.sh || warn "some checks failed - see above"

# ---------------------------------------------------------------------------
say "7/7  Make PipeWire re-enumerate the camera"
#
# intel_ipu6_isys keeps /dev/media0 alive across an ov02c10 reload, so libcamera
# never sees a hotplug remove/add - but the sensor subdev comes back under a new
# number (v4l-subdev4 -> v4l-subdev5).  PipeWire's libcamera plugin is left
# holding a camera that points at a device node that no longer exists, and every
# client fails with "not-negotiated (-4)".  Restarting wireplumber re-enumerates.
#
# Only wireplumber, never pipewire/pipewire-pulse, and the audio state is
# snapshotted by *name* first and put back if anything moved.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if systemctl --user is-active --quiet wireplumber; then
    A_SRC="$(pactl get-default-source 2>/dev/null || true)"
    A_SNK="$(pactl get-default-sink 2>/dev/null || true)"
    A_SRCV="$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null || true)"
    A_SNKV="$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)"

    systemctl --user restart wireplumber
    sleep 3

    CHANGED=0
    [ -n "$A_SRC" ] && [ "$(pactl get-default-source 2>/dev/null)" != "$A_SRC" ] && {
        pactl set-default-source "$A_SRC" 2>/dev/null && CHANGED=1; }
    [ -n "$A_SNK" ] && [ "$(pactl get-default-sink 2>/dev/null)" != "$A_SNK" ] && {
        pactl set-default-sink "$A_SNK" 2>/dev/null && CHANGED=1; }
    for spec in "@DEFAULT_AUDIO_SOURCE@:$A_SRCV" "@DEFAULT_AUDIO_SINK@:$A_SNKV"; do
        tgt="${spec%%:*}"; want="${spec#*:}"
        [ -n "$want" ] || continue
        if [ "$(wpctl get-volume "$tgt" 2>/dev/null)" != "$want" ]; then
            vol="$(printf '%s' "$want" | grep -o '[0-9.]*$')"
            [ -n "$vol" ] && wpctl set-volume "$tgt" "$vol" 2>/dev/null
            case "$want" in *MUTED*) wpctl set-mute "$tgt" 1 ;;
                            *)       wpctl set-mute "$tgt" 0 ;; esac 2>/dev/null
            CHANGED=1
        fi
    done
    [ "$CHANGED" = 1 ] && warn "audio state moved on restart, restored from snapshot" \
                       || ok "camera re-enumerated, audio untouched"
else
    warn "wireplumber not running - log out and back in to refresh the camera"
fi

cat <<'EOF'

Done.  Nothing must grab the camera from here on, or PipeWire ends up holding a
device another process is streaming from and the viewfinder stutters and dies.
If that happens, this puts it right without touching audio:

    systemctl --user restart wireplumber

EOF
