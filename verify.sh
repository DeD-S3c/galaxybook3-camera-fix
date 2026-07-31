#!/bin/bash
#
# Objective check of the camera. Read-only apart from re-applying the sensor
# format, which is what any application does when it opens the camera.
#
set -uo pipefail

FAIL=0
chk() { # chk <label> <actual> <expected>
    if [ "$2" = "$3" ]; then printf '  \033[1;32mOK\033[0m   %-22s %s\n' "$1" "$2"
    else printf '  \033[1;31mNO\033[0m   %-22s %s   (expected %s)\n' "$1" "$2" "$3"; FAIL=1; fi
}

SUBDEV=""
for d in /dev/v4l-subdev*; do
    v4l2-ctl -d "$d" --list-ctrls 2>/dev/null | grep -q analogue_gain && { SUBDEV="$d"; break; }
done
[ -n "$SUBDEV" ] || { echo "ov02c10 subdev not found - is the module loaded?"; exit 1; }

ENTITY="$(media-ctl -p -d /dev/media0 2>/dev/null |
          grep -o "ov02c10 [0-9]-[0-9a-f]*" | head -1)"

# An application sets the format before streaming, and the driver recomputes
# the blanking limits when it does.  Checking the controls without this step
# hides a whole class of bug, so force it first.
[ -n "$ENTITY" ] && media-ctl -d /dev/media0 \
    -V "'${ENTITY}':0 [fmt:SGRBG10_1X10/1928x1092]" >/dev/null 2>&1

get() { v4l2-ctl -d "$SUBDEV" --list-ctrls | grep -m1 "^ *$1 " | grep -o "$2=[-0-9]*" | cut -d= -f2; }

echo "=== sensor controls after set_format ($SUBDEV) ==="
chk "link_frequency"    "$(v4l2-ctl -d "$SUBDEV" --list-ctrls | grep -o '(5[0-9]* 0x' | tr -d '( 0x')" "541666666"
chk "pixel_rate"        "$(get pixel_rate max)"        "216666666"
chk "vblank default"    "$(get vertical_blanking default)" "2075"
chk "vblank value"     "$(get vertical_blanking value)"   "2075"
chk "exposure max"      "$(get exposure max)"          "3159"
chk "analogue_gain max" "$(get analogue_gain max)"     "992"
chk "analogue_gain def" "$(get analogue_gain default)" "16"
chk "sensor_rotation"   "$(get camera_sensor_rotation default)" "180"
if v4l2-ctl -d "$SUBDEV" --list-ctrls | grep -q digital_gain; then
    printf '  \033[1;31mNO\033[0m   %-22s present    (expected: gone)\n' "digital_gain"; FAIL=1
else
    printf '  \033[1;32mOK\033[0m   %-22s gone\n' "digital_gain"
fi

echo
echo "=== actual frame rate ==="
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
FPS="$(timeout 30 v4l2-ctl -d /dev/video1 \
        --set-fmt-video=width=1928,height=1092,pixelformat=BA10 \
        --stream-mmap --stream-count=120 2>&1 | grep -o "[0-9.]* fps" | tail -1)"
echo "  ${FPS:-no measurement}   (expected ~30.0 fps)"

echo
echo "=== CSI-2 errors during capture ==="
N="$(journalctl -k --since "$SINCE" --no-pager 2>/dev/null | grep -c "Frame sync error")"
[ "$N" -le 1 ] && echo "  $N  (0-1 at stream start is normal)" \
               || { echo "  $N - the link is still misconfigured"; FAIL=1; }

echo
echo "=== libcamera tuning ==="
if grep -q "blackLevel" /usr/share/libcamera/ipa/simple/ov02c10.yaml 2>/dev/null &&
   grep -q "Ccm" /usr/share/libcamera/ipa/simple/ov02c10.yaml 2>/dev/null; then
    echo "  OK   /usr/share/libcamera/ipa/simple/ov02c10.yaml (blackLevel + Ccm)"
else
    echo "  NO   tuning file missing or stale"; FAIL=1
fi

echo
[ "$FAIL" = 0 ] && echo "All good." || echo "Something is off - see the NO lines above."
exit $FAIL
