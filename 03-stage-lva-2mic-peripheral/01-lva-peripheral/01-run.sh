#!/bin/bash -e

# Stage that drops the LVA + ReSpeaker 2-Mic peripheral compose project into
# the rootfs at /compose/lva-peripheral/. Both images are built from cloned
# source on first boot, so the LVA peripheral API and the ReSpeaker
# controller line up against the same unmerged branch:
#
#   genericJE/linux-voice-assistant : feat/peripheral-led-light-entity
#
# That branch is based on the in-flight upstream PR
# omaramin-2000:leds-and-buttons-events (OHF-Voice/linux-voice-assistant#266)
# plus the Light entity / Rainbow effect / peripheral-startup-wait commits.

LVA_REPO_URL="${LVA_REPO_URL:-https://github.com/genericJE/linux-voice-assistant.git}"
LVA_BRANCH="${LVA_BRANCH:-feat/peripheral-led-light-entity}"

SRC="/tmp/lva-src-clone-$$"
DEST="${ROOTFS_DIR}/compose/lva-peripheral"

rm -rf "$SRC"
echo "Cloning $LVA_REPO_URL ($LVA_BRANCH)..."
git clone --depth 1 --branch "$LVA_BRANCH" "$LVA_REPO_URL" "$SRC"

mkdir -p "$DEST/lva-src"

# Copy LVA source minus history/tests/docs/examples to keep the image small.
# The peripheral example lives under examples/ — we pull it out separately
# below, so excluding examples/ from the LVA build context is safe.
(cd "$SRC" && tar \
    --exclude='.git' \
    --exclude='tests' \
    --exclude='docs' \
    --exclude='examples' \
    --exclude='*.egg-info' \
    --exclude='.venv' \
    --exclude='uv.lock' \
    -cf - .) | (cd "$DEST/lva-src" && tar -xf -)

# Peripheral controller (Dockerfile + compose.yml + respeaker_2mic_hat.py)
# straight from the branch.
mkdir -p "$DEST/peripheral"
cp -r "$SRC/examples/ReSpeaker 2mic HAT/." "$DEST/peripheral/"

# Pin the LVA commit baked into this image so the user can confirm which
# build they have on the running Pi.
LVA_HASH="$(cd "$SRC" && git rev-parse HEAD)"
echo "$LVA_HASH" > "$DEST/lva-src/version_githash.txt"
echo "$LVA_HASH" > "$DEST/LVA_COMMIT"

# Compose project files we ship from this stage.
install -v -m 644 files/lva-peripheral/docker-compose.yml "$DEST/docker-compose.yml"
install -v -m 644 files/lva-peripheral/picompose.conf    "$DEST/picompose.conf"
install -v -m 644 files/lva-peripheral/.env              "$DEST/.env"
install -v -m 644 files/lva-peripheral/Dockerfile.lva    "$DEST/lva-src/Dockerfile.local"

# Helper that rewrites /dev/gpiochip0 → /dev/gpiochip4 on Pi 5 (where the
# 40-pin header sits on gpiochip4). Runs once before picompose deploys.
install -v -D -m 755 files/lva-peripheral-gpiochip-fix.sh \
    "${ROOTFS_DIR}/usr/local/sbin/lva-peripheral-gpiochip-fix.sh"
install -v -D -m 644 files/lva-peripheral-gpiochip-fix.service \
    "${ROOTFS_DIR}/etc/systemd/system/lva-peripheral-gpiochip-fix.service"

# Helper that enables systemd linger for whoever UID 1000 ends up being at
# runtime. Pi Imager's first-boot wizard typically renames ``pi`` to a
# user-supplied name, orphaning the linger file the pipewire stage already
# created under /var/lib/systemd/linger/pi. Without linger, /run/user/1000
# (where PipeWire's PulseAudio socket lives) is session-scoped: the moment
# the user SSHs out, the tmpfs is torn down, and the LVA container's
# bind-mount of /run/user/1000 goes stale — audio capture starts failing
# with "Connection refused" and HA shows "voice assistant unable to
# connect".  Runs once at boot before picompose deploys.
install -v -D -m 755 files/lva-peripheral-linger-fix.sh \
    "${ROOTFS_DIR}/usr/local/sbin/lva-peripheral-linger-fix.sh"
install -v -D -m 644 files/lva-peripheral-linger-fix.service \
    "${ROOTFS_DIR}/etc/systemd/system/lva-peripheral-linger-fix.service"

# Group membership + SPI overlay + enable the helper units inside the chroot.
on_chroot << 'EOF'
getent group spi  >/dev/null && usermod -aG spi  pi || true
getent group gpio >/dev/null && usermod -aG gpio pi || true

CONFIG=/boot/config.txt
[ -f /boot/firmware/config.txt ] && CONFIG=/boot/firmware/config.txt
[ -f /boot/firmware/usercfg.txt ] && CONFIG=/boot/firmware/usercfg.txt

sed -i -e 's:#dtparam=spi=on:dtparam=spi=on:g' "$CONFIG" || true
grep -q "^dtparam=spi=on$" "$CONFIG" || echo "dtparam=spi=on" >> "$CONFIG"

systemctl daemon-reload
systemctl enable lva-peripheral-gpiochip-fix.service
systemctl enable lva-peripheral-linger-fix.service
EOF

rm -rf "$SRC"
