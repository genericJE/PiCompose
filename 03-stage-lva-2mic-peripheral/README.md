# 03-stage-lva-2mic-peripheral

Pi-gen stage that bakes the Linux Voice Assistant **peripheral-led-light-entity** branch onto a PiCompose image alongside the ReSpeaker 2-Mic HAT peripheral container, for hardware-side smoke testing of an unmerged LVA branch.

The branch is unmerged upstream and depends on the in-flight upstream PR [OHF-Voice/linux-voice-assistant#266](https://github.com/OHF-Voice/linux-voice-assistant/pull/266) (`omaramin-2000:leds-and-buttons-events`). Until that lands, the LVA published image on GHCR does not expose the peripheral API needed by this peripheral, so the image is built from source at first boot rather than pulled.

## What's in the image

- PiCompose base (Docker, Pipewire, compose-manager) → from `01-stage-picompose`
- ReSpeaker 2-Mic HAT v2 audio driver (TLV320AIC3104 device-tree overlay + mixer tuning) → from `02-stage-audiodriver-2michat-v2`
- `/compose/lva-peripheral/` Docker Compose project containing two services:
  - `linux-voice-assistant` — built from cloned [genericJE/linux-voice-assistant `feat/peripheral-led-light-entity`](https://github.com/genericJE/linux-voice-assistant/tree/feat/peripheral-led-light-entity). Speaks the ESPHome API on `:6053` and the peripheral WebSocket API on `:6055`. Starts with `--peripheral-startup-wait 8` so HA only enumerates after the peripheral registers its Light entity.
  - `respeaker-peripheral` — built from the same branch's `examples/ReSpeaker 2mic HAT/` directory. Drives the 3 APA102 LEDs via SPI and the GPIO 17 button via gpiozero/lgpio. Registers `light.<satellite>_leds` with LVA on connect.
- `lva-peripheral-gpiochip-fix.service` — one-shot systemd unit that detects Pi 5 and rewrites the compose's `/dev/gpiochip0` mapping to `/dev/gpiochip4` before `picompose.service` runs.
- `pi` user added to `spi` and `gpio` groups; `dtparam=spi=on` added to `/boot/firmware/config.txt`.

The exact LVA commit baked into the image is recorded at `/compose/lva-peripheral/LVA_COMMIT`.

## How the image was built

```text
stage0 → stage1 → stage2                                  (pi-gen base)
01-stage-picompose                                        (base + Docker)
02-stage-audiodriver-2michat-v2                           (TLV320AIC3104 codec + mixer)
03-stage-lva-2mic-peripheral                              (THIS STAGE)
04-stage-finish                                           (user shell, cleanup)
```

`01-run.sh` clones `genericJE/linux-voice-assistant` at the branch above (override with `LVA_REPO_URL` / `LVA_BRANCH` env vars at build time), strips `.git`/tests/docs to keep the rootfs small, and copies:

```
${ROOTFS_DIR}/compose/lva-peripheral/
├── docker-compose.yml          (LVA + peripheral services)
├── picompose.conf              (BOOT_ENABLED=true, CRON_ENABLED=false)
├── .env                        (UID/GID, optional audio device overrides)
├── LVA_COMMIT                  (pinned commit SHA)
├── lva-src/                    (LVA branch source, build context for LVA)
│   ├── Dockerfile.local        (built locally — fixes upstream's COPY ../wakewords/ path)
│   ├── pyproject.toml
│   ├── linux_voice_assistant/
│   ├── script/
│   ├── sounds/
│   ├── wakewords/
│   └── docker-entrypoint.sh
└── peripheral/                 (peripheral build context, straight from examples/)
    ├── Dockerfile
    ├── requirements.txt
    ├── respeaker_2mic_hat.py
    └── compose.yml             (unused — replaced by ../docker-compose.yml)
```

## First boot

`picompose.service` runs `compose-manager.sh` which `docker compose up -d` the project. Both images build from cloned source — expect **~5–10 minutes on a Pi 5, ~15 minutes on a Pi 3** before the containers are running. After that, the LEDs come on, mDNS advertises the satellite, and Home Assistant should auto-discover.

Live progress:

```sh
ssh pi@<host>          # default password: raspberry — change with rpi-imager
sudo tail -F /var/log/picompose.log
docker compose -p lva-peripheral logs -f
```

## Post-flash verification

### 1. Containers are up

```sh
docker ps
```

Expect `linux-voice-assistant` and `respeaker-peripheral` both with `Up`. If either is restarting:

```sh
docker logs --tail=100 linux-voice-assistant
docker logs --tail=100 respeaker-peripheral
```

### 2. Audio in/out works

```sh
arecord -l         # should list the TLV320AIC3104 capture device
aplay -l           # should list the same device for playback
speaker-test -c 2 -t sine -f 440 -l 1   # one beep on the HAT speaker
```

If `arecord -l` shows nothing, the V2.0 device-tree overlay didn't load. Check `dmesg | grep -i tlv320`.

### 3. Peripheral API is up and the LED entity is registered

```sh
ss -tlnp | grep 6055           # LVA listening for peripheral
ss -tlnp | grep 6053           # LVA's ESPHome API for HA
docker logs respeaker-peripheral 2>&1 | grep -i 'connected\|register_light'
```

If you see "register_light" in the peripheral's logs, LVA's protocol additions are wired and the entity should appear in HA as `light.<hostname>_leds`.

### 4. HA discovery

LVA advertises itself via Avahi/mDNS in host network mode. After a Home Assistant restart or a few minutes, the satellite should show up in HA's "Discovered" section, no manual config needed. The `--peripheral-startup-wait 8` ensures HA enumerates entities **after** the Light entity is registered.

### 5. Smoke-test the manual exercises

From the LVA branch's `examples/ReSpeaker 2mic HAT/DOCS.md` plus the new Light entity work:

- Light entity appears (`light.<hostname>_leds`) — exposes on/off, brightness, RGB color, effects `Voice Assistant` / `Rainbow` / `None`.
- **Voice Assistant** effect — wake word triggers a flash; listening shows a chase; thinking pulses yellow; speaking breathes green. Wake/listening colors follow the HA color picker.
- **Rainbow** effect — three LEDs cycle through HSV offset by ⅓, ~5 s period.
- **None** effect — LEDs hold solid HA color, no pipeline animations.
- Brightness slider scales every animation linearly.
- Off in HA → LEDs go dark immediately; on resumes the current state.
- Voice timer ("set a timer for two minutes") — cyan brightness fades smoothly over countdown (the monotonic-brightness fix in this branch).

## Log paths

| What | Where |
|---|---|
| PiCompose boot deploy | `/var/log/picompose.log` |
| LVA container | `docker logs linux-voice-assistant` (or `journalctl -u docker.service`) |
| Peripheral container | `docker logs respeaker-peripheral` |
| Audio mixer tuning service | `journalctl -u configure_audio.service` |
| gpiochip fixup | `journalctl -u lva-peripheral-gpiochip-fix.service` |
| Pinned LVA commit | `/compose/lva-peripheral/LVA_COMMIT` |

## Tweaking the deployed config

Everything under `/compose/lva-peripheral/` is plain text on the boot partition — edit `.env` or `docker-compose.yml` on the SD card before flashing, or in-place on the Pi:

```sh
sudo nano /compose/lva-peripheral/.env
sudo docker compose -p lva-peripheral up -d
```

Common edits:

- Pin a specific ALSA/PulseAudio device (`.env`: `AUDIO_OUTPUT_DEVICE=...`, `AUDIO_INPUT_DEVICE=...`)
- Switch peripheral GPIO chip back to `/dev/gpiochip0` if running on a Pi 3/4 after the Pi 5 fixup auto-ran
- Set `ENABLE_DEBUG=1` in `.env` for verbose LVA logging
- Override `GPIO_GID` / `SPI_GID` in `.env` if the host's `gpio` / `spi` group IDs differ from the stock Raspberry Pi OS defaults (986 / 989). Check with `getent group gpio spi`. The peripheral container joins these numerically because the slim Python base has no `gpio` / `spi` groups to resolve by name.

## Flashing

The image and a matching `rpi-imager.json` are attached to the GitHub release for the `feature/lva-2mic-peripheral-image` branch on this fork. In Raspberry Pi Imager:

```sh
# Linux
rpi-imager --repo https://github.com/genericJE/PiCompose/releases/download/feature%2Flva-2mic-peripheral-image/rpi-imager.json
```

Or load the URL via *Settings → Image Repository → Use custom URL*. WiFi credentials and the SSH password are configured via Pi Imager's "advanced options" dialog at flash time — they are **not** baked into the image.
