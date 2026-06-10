#!/usr/bin/env bash
# SuperTuxKart cloud-gaming provisioner (cloudcompute.ru).
#
# Runs on the Selkies nvidia-egl-desktop image at instance boot, fetched and
# launched by the CloudCompute onstart wrapper. It:
#   1. Starts the Selkies desktop/stream stack (supervisord) — see below.
#   2. Installs SuperTuxKart.
#   3. Launches the game into the live X session.
#   4. Reports stage transitions to CC_PROVISION_URL so the dashboard advances.
#
# Why we start supervisord ourselves
# ----------------------------------
# The image's ENTRYPOINT is `/usr/bin/supervisord` (it brings up Xorg :20, KDE,
# the Selkies WebRTC server on :8080, internal coTURN, audio). But CloudCompute
# launches the instance with Vast's SSH/Jupyter runtype so this onstart script
# (agent token, billing, provision reports) can run at all — and Vast's SSH/
# Jupyter runtypes REPLACE the image entrypoint. So supervisord never runs
# unless we start it here. This is exactly Vast's documented pattern: "call the
# image's entrypoint command at the end of the on-start section."
#
# The basic-auth password is injected as per-instance Vast env
# (-e SELKIES_BASIC_AUTH_PASSWORD=…) at launch, so it's already in this script's
# environment and is preserved into supervisord via `sudo -E`.
#
# Contract (provided by the onstart wrapper):
#   CC_PROVISION_URL  POST target for stage reports (/api/agent/provision)
#   CC_AGENT_TOKEN    Bearer token for the report endpoint
set -uo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"
GAME_USER="ubuntu"
# The Selkies image runs Xorg on :20 (Dockerfile `ENV DISPLAY=":20"`); honour an
# override but default to :20, NOT :0.
GAME_DISPLAY="${DISPLAY:-:20}"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-ubuntu}"

# report <stage> [progress_pct] [message]
report() {
  [ -z "$CC_PROVISION_URL" ] && return 0
  local body="{\"stage\":\"$1\""
  [ -n "${2:-}" ] && body="$body,\"progress_pct\":$2"
  [ -n "${3:-}" ] && body="$body,\"message\":\"$3\""
  body="$body}"
  curl -fsS -X POST "$CC_PROVISION_URL" \
    -H "Authorization: Bearer $CC_AGENT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$body" >/dev/null 2>&1 || true
}

fail() { report "$1" "" "$2"; exit 1; }

# Run a command as the desktop user, preserving the container env (DISPLAY,
# SELKIES_*, DBUS_*, PULSE_*) but pinning the per-user paths that root's
# environment would otherwise carry over wrong (HOME=/root, etc.).
as_user() {
  sudo -u "$GAME_USER" -E env \
    HOME="/home/$GAME_USER" \
    USER="$GAME_USER" \
    LOGNAME="$GAME_USER" \
    DISPLAY="$GAME_DISPLAY" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    "$@"
}

# --- Stage 1: bring up the desktop/stream + install the game ---------------
report "install_game" 10

# Start the Selkies stack (the suppressed image entrypoint). Guarded so a wrong
# base image can't hard-fail the script before the game install.
if [ -f /etc/supervisord.conf ] && [ -x /usr/bin/supervisord ]; then
  install -d -o "$GAME_USER" -g "$GAME_USER" -m 700 "$XDG_RUNTIME_DIR"
  nohup as_user /usr/bin/supervisord -c /etc/supervisord.conf \
    > /var/log/cc-selkies.log 2>&1 &
else
  report "install_game" "" "Selkies image entrypoint not found; streaming may be unavailable"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y                || fail "install_game" "apt update failed"
apt-get install -y supertuxkart  || fail "install_game" "supertuxkart install failed"
report "install_game" 100

# --- Stage 2: launch the game into the live session ------------------------
report "start_game" 20

# KDE autostart entry so the game relaunches if the desktop session restarts.
install -d -o "$GAME_USER" -g "$GAME_USER" "/home/$GAME_USER/.config/autostart"
cat > "/home/$GAME_USER/.config/autostart/supertuxkart.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=SuperTuxKart
Exec=supertuxkart --fullscreen
X-GNOME-Autostart-enabled=true
EOF
chown "$GAME_USER:$GAME_USER" "/home/$GAME_USER/.config/autostart/supertuxkart.desktop"

# Wait for Xorg to come up on the Selkies display (first boot also downloads the
# matching NVIDIA userspace driver, so allow several minutes).
x_socket="/tmp/.X11-unix/X${GAME_DISPLAY#*:}"
for _ in $(seq 1 180); do
  [ -S "$x_socket" ] && break
  sleep 2
done
if [ ! -S "$x_socket" ]; then
  fail "start_game" "desktop session ($GAME_DISPLAY) did not start in time"
fi

# Launch the game directly into the live display (in addition to the autostart
# entry above, which only fires on a fresh session).
nohup as_user supertuxkart --fullscreen > /var/log/cc-supertuxkart.log 2>&1 &

# Don't stamp completion until the Selkies web server actually accepts
# connections on :8080 — the dashboard's "Играть" button is provision-marker
# gated (plain HTTP can't be browser-polled from the https dashboard), so a
# premature 100% would hand the user an ERR_CONNECTION_REFUSED.
for _ in $(seq 1 180); do
  nc -z localhost 8080 >/dev/null 2>&1 && break
  sleep 2
done
if ! nc -z localhost 8080 >/dev/null 2>&1; then
  fail "start_game" "stream server (:8080) did not come up in time"
fi

# Final stage + progress 100 => the dashboard stamps completed_at.
report "start_game" 100
