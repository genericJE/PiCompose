#!/bin/bash
# Ensure linger is enabled for whoever ends up at UID 1000.
#
# The LVA peripheral compose runs the containers as the host's UID 1000
# (compose's ``user: "${LVA_USER_ID:-1000}:..."``) and bind-mounts the host's
# ``/run/user/1000`` so the container can reach PipeWire's PulseAudio socket
# for microphone capture.  Without linger, ``/run/user/1000`` is a tmpfs that
# only exists while a session is active — meaning audio capture breaks the
# moment the user SSHs out, and the next bind-mount inside the container goes
# stale.
#
# PiCompose's pipewire stage enables linger for the built-in ``pi`` user, but
# Pi Imager's first-boot wizard often renames ``pi`` → something else (e.g.
# ``je``), orphaning the linger file under the old name.  Do it again here at
# boot time using whatever username currently owns UID 1000.

set -e

RUNTIME_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
if [ -z "$RUNTIME_USER" ]; then
    echo "lva-peripheral-linger-fix: no user at UID 1000, skipping" >&2
    exit 0
fi

mkdir -p /var/lib/systemd/linger
touch "/var/lib/systemd/linger/$RUNTIME_USER"
chmod 644 "/var/lib/systemd/linger/$RUNTIME_USER"
echo "lva-peripheral-linger-fix: linger enabled for $RUNTIME_USER"
