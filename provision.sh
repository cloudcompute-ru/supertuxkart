#!/usr/bin/env bash
# SuperTuxKart cloud-gaming provisioner (cloudcompute.ru).
#
# Runs on the Selkies nvidia-glx-desktop image at instance boot, fetched and
# launched by the CloudCompute onstart wrapper. It:
#   1. Starts the Selkies desktop/stream stack (supervisord) — see below.
#   2. Installs SuperTuxKart.
#   3. Launches the game into the live X session.
#   4. Reports stage transitions (and, on failure, diagnostics) to
#      CC_PROVISION_URL so the dashboard advances / surfaces the cause.
#
# Why we start supervisord ourselves
# ----------------------------------
# The image's ENTRYPOINT is `/usr/bin/supervisord` (it brings up Xorg :20, KDE,
# the Selkies WebRTC server on :8080, internal coTURN, audio). But CloudCompute
# launches with Vast's SSH/Jupyter runtype so this onstart script (agent token,
# billing, provision reports) runs at all — and that runtype REBUILDS the image
# and REPLACES the entrypoint with Vast's own /.launch. So supervisord never
# runs unless we start it here. This is Vast's documented pattern: "call the
# image's entrypoint command at the end of the on-start section."
#
# Contract (provided by the onstart wrapper):
#   CC_PROVISION_URL  POST target for stage reports (/api/agent/provision)
#   CC_AGENT_TOKEN    Bearer token for the report endpoint
# Plus, injected as per-instance Vast env at launch:
#   SELKIES_BASIC_AUTH_PASSWORD  basic-auth password for the :8080 web UI
set -uo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"
GAME_USER="ubuntu"
# The Selkies image runs Xorg on :20 (Dockerfile `ENV DISPLAY=":20"`).
GAME_DISPLAY=":20"
RUNTIME_DIR="/tmp/runtime-ubuntu"
SELKIES_LOG="/var/log/cc-selkies.log"
DIAG_LOG="/tmp/cc-diag.log"

# Vast applies our per-instance `-e` vars to the container's PID 1 (its
# /.launch), but does NOT cascade them into the onstart shell that runs this
# script. So SELKIES_BASIC_AUTH_PASSWORD (the password the dashboard shows the
# user) is empty here, and the Selkies entrypoint silently falls back to the
# image default PASSWD=mypasswd — i.e. the shown password wouldn't work.
# Recover the vars straight from PID 1's environment so the htpasswd the
# container builds matches what the user sees.
pid1_env() { tr '\0' '\n' < /proc/1/environ 2>/dev/null | sed -n "s/^$1=//p" | head -n1; }
: "${SELKIES_BASIC_AUTH_PASSWORD:=$(pid1_env SELKIES_BASIC_AUTH_PASSWORD)}"
: "${SELKIES_ENCODER:=$(pid1_env SELKIES_ENCODER)}"
: "${SELKIES_ENABLE_BASIC_AUTH:=$(pid1_env SELKIES_ENABLE_BASIC_AUTH)}"
: "${SELKIES_TURN_PROTOCOL:=$(pid1_env SELKIES_TURN_PROTOCOL)}"
: "${SELKIES_TURN_PORT:=$(pid1_env SELKIES_TURN_PORT)}"
: "${TURN_MIN_PORT:=$(pid1_env TURN_MIN_PORT)}"
: "${TURN_MAX_PORT:=$(pid1_env TURN_MAX_PORT)}"
# coTURN must advertise an address the browser can reach. On Vast the container's
# private IP is useless externally, so pin the TURN host to the instance's public
# IP (Vast injects PUBLIC_IPADDR on PID 1). Even on static_ip hosts Vast often
# remaps container ports to random externals — map_vast_turn_ports() below sets
# SELKIES_TURN_PORT from VAST_TCP_PORT_70000 so the browser dials the right one.
: "${SELKIES_TURN_HOST:=$(pid1_env SELKIES_TURN_HOST)}"
: "${SELKIES_TURN_HOST:=$(pid1_env PUBLIC_IPADDR)}"
: "${DISPLAY_SIZEW:=$(pid1_env DISPLAY_SIZEW)}"
: "${DISPLAY_SIZEH:=$(pid1_env DISPLAY_SIZEH)}"

# Host paths Selkies entrypoint expects but cannot create as the unprivileged
# desktop user (supervisord runs via runuser ubuntu). Without these, X fails with
# "_XSERVTransmkdir: euid != 0", /dev/input setup errors out, and :20 never
# comes up — "desktop session did not start in time".
bootstrap_selkies_host() {
  install -d -m 1777 /tmp/.X11-unix /tmp/.ICE-unix
  install -d -m 1777 /dev/input
  touch /dev/input/js0 /dev/input/js1 /dev/input/js2 /dev/input/js3 2>/dev/null || true
  chmod a+rw /dev/input/js* 2>/dev/null || true
  # GLX desktop (nvidia-glx-desktop) starts Xorg on vt7 with -sharevts
  ln -snf /dev/ptmx /dev/tty7 2>/dev/null || true
}

# Vast DNATs external PUBLIC_IP:VAST_TCP_PORT_70000 -> container :70000 where
# coTURN listens. Selkies' rtc.json must expose the *external* port to the
# browser; advertising :70000 when Vast mapped it to :21489 breaks ICE.
map_vast_turn_ports() {
  local ext_tcp
  ext_tcp=$(pid1_env VAST_TCP_PORT_70000)
  [ -n "$ext_tcp" ] && SELKIES_TURN_PORT="$ext_tcp"
}
map_vast_turn_ports

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

# Gather on-box diagnostics into DIAG_LOG so a failed boot is debuggable from
# the dashboard instead of blind.
collect_diag() {
  {
    echo "===== date ====="; date
    echo "===== nvidia-smi ====="; nvidia-smi 2>&1 | head -n 40
    echo "===== encoder ====="
    echo "SELKIES_ENCODER=${SELKIES_ENCODER:-}"
    ls -l /usr/lib/x86_64-linux-gnu/libnvidia-encode.so* 2>&1
    gst-inspect-1.0 nvh264enc >/dev/null 2>&1 && echo "nvh264enc: usable" || echo "nvh264enc: NOT usable"
    echo "===== turn / ports ====="
    echo "advertised: SELKIES_TURN_HOST=${SELKIES_TURN_HOST:-} SELKIES_TURN_PORT=${SELKIES_TURN_PORT:-} SELKIES_TURN_PROTOCOL=${SELKIES_TURN_PROTOCOL:-}"
    echo "relay range: TURN_MIN_PORT=${TURN_MIN_PORT:-} TURN_MAX_PORT=${TURN_MAX_PORT:-}"
    echo "-- Vast external port map + public IP (PID1) --"
    tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -E '^(VAST_(TCP|UDP)_PORT_|PUBLIC_IPADDR=)' | sort
    echo "-- coturn process --"
    ps aux 2>/dev/null | grep -i '[t]urnserver'
    echo "-- coturn config --"
    cat /etc/coturn/turnserver.conf 2>/dev/null \
      || cat /etc/turnserver.conf 2>/dev/null \
      || echo "(no turnserver.conf found)"
    echo "-- listening sockets (70000-70004) --"
    { ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null; } | grep -E ':7000[0-4]\b' || echo "(none bound)"
    echo "===== /tmp/.X11-unix ====="; ls -la /tmp/.X11-unix 2>&1
    echo "===== supervisorctl status ====="; supervisorctl -c /etc/supervisord.conf status 2>&1
    echo "===== /tmp/supervisord.log (tail) ====="; tail -n 100 /tmp/supervisord.log 2>&1
    echo "===== /tmp/entrypoint.log (tail) ====="; tail -n 160 /tmp/entrypoint.log 2>&1
    echo "===== $SELKIES_LOG (tail) ====="; tail -n 80 "$SELKIES_LOG" 2>&1
    echo "===== /tmp/selkies-gstreamer-entrypoint.log (tail) ====="; tail -n 80 /tmp/selkies-gstreamer-entrypoint.log 2>&1
    echo "===== basic-auth ====="
    echo "recovered SELKIES_BASIC_AUTH_PASSWORD length: ${#SELKIES_BASIC_AUTH_PASSWORD}"
    echo "PID1 SELKIES_/PASSWD/USER env (name + value length, values masked):"
    tr '\0' '\n' < /proc/1/environ 2>/dev/null \
      | awk -F= '/^(SELKIES_|PASSWD=|USER=)/ {v=$0; sub(/^[^=]+=/,"",v); print $1" len="length(v)}'
    echo "htpasswd file first field ($RUNTIME_DIR/.htpasswd):"
    cut -d: -f1 "$RUNTIME_DIR/.htpasswd" 2>&1
    echo "verify recovered password against htpasswd:"
    htpasswd -vb "$RUNTIME_DIR/.htpasswd" "$GAME_USER" "${SELKIES_BASIC_AUTH_PASSWORD:-}" 2>&1
  } > "$DIAG_LOG" 2>&1 || true
}

# Post a stage update carrying the diagnostics as app_log_tail (no `message`, so
# it is NOT treated as a fatal failure) — used to surface the auth state even
# when the boot succeeds.
report_diag() {
  local stage="$1"
  collect_diag
  [ -z "$CC_PROVISION_URL" ] && return 0
  python3 - "$CC_PROVISION_URL" "$CC_AGENT_TOKEN" "$stage" "$DIAG_LOG" <<'PY' || true
import sys, json, urllib.request
url, token, stage, logfile = sys.argv[1:5]
body = {"stage": stage}
try:
    with open(logfile, "r", errors="replace") as f:
        body["app_log_tail"] = f.read()[-60000:]
except Exception:
    pass
req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
)
try:
    urllib.request.urlopen(req, timeout=15).read()
except Exception:
    pass
PY
}

# fail <stage> <message> — collect diagnostics and POST them as app_log_tail so
# the dashboard's provision-log shows exactly why the boot stalled, then exit.
fail() {
  local stage="$1" message="$2"
  collect_diag
  if [ -n "$CC_PROVISION_URL" ]; then
    python3 - "$CC_PROVISION_URL" "$CC_AGENT_TOKEN" "$stage" "$message" "$DIAG_LOG" <<'PY' || true
import sys, json, urllib.request
url, token, stage, message, logfile = sys.argv[1:6]
body = {"stage": stage, "message": message[:255]}
try:
    with open(logfile, "r", errors="replace") as f:
        body["app_log_tail"] = f.read()[-60000:]
except Exception:
    pass
req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
)
try:
    urllib.request.urlopen(req, timeout=15).read()
except Exception:
    pass
PY
  fi
  exit 1
}

# Pick a video encoder that actually works on THIS host.
#
# nvh264enc (NVENC) is preferred — hardware encode, low latency — but it only
# works when the host's encode userspace (libnvidia-encode.so, mounted by the
# nvidia container runtime when NVIDIA_DRIVER_CAPABILITIES includes `video`) is
# present AND the GPU exposes a usable NVENC session. That varies host-to-host
# on Vast; when it's missing, selkies-gstreamer fails to build its pipeline and
# dies on the first client connect — the browser then sees the signalling socket
# drop ("Server closed connection", retry loop) and never gets a stream.
#
# gst-inspect succeeds for nvh264enc only if the nvcodec plugin could open a
# probe session, so it's an accurate "is NVENC usable" test. We give the encode
# lib a brief window to appear (it's mounted at container create, but be safe),
# then fall back to software x264enc so a stream ALWAYS comes up.
pick_encoder() {
  case "${SELKIES_ENCODER:-}" in
    x264enc | vp8enc | vp9enc) return 0 ;;  # explicit non-NVENC override, honour it
  esac
  local i
  for i in $(seq 1 15); do
    ls /usr/lib/x86_64-linux-gnu/libnvidia-encode.so* >/dev/null 2>&1 && break
    sleep 2
  done
  if gst-inspect-1.0 nvh264enc >/dev/null 2>&1; then
    SELKIES_ENCODER="nvh264enc"
  else
    SELKIES_ENCODER="x264enc"
  fi
}
pick_encoder

# Clean, explicit environment for the desktop user. Using `runuser`
# (root->ubuntu, no password) + `env -i` + this fixed list removes all ambiguity
# about whether the container env survived Vast's image rebuild — we set every
# var the Selkies supervisord/entrypoint needs from the known image defaults.
#
# This is a plain array (not a function): it's expanded inline into the
# `nohup runuser ... env -i "${SELKIES_ENV[@]}" <cmd>` calls below, because
# `nohup` can only launch a real executable, not a shell function.
SELKIES_ENV=(
  "HOME=/home/$GAME_USER"
  "USER=$GAME_USER"
  "LOGNAME=$GAME_USER"
  "SHELL=/bin/bash"
  "PATH=/usr/local/nvidia/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  "DISPLAY=$GAME_DISPLAY"
  "XDG_RUNTIME_DIR=$RUNTIME_DIR"
  "DBUS_SYSTEM_BUS_ADDRESS=unix:path=$RUNTIME_DIR/dbus-system-bus"
  "PULSE_RUNTIME_PATH=$RUNTIME_DIR/pulse"
  "PULSE_SERVER=unix:$RUNTIME_DIR/pulse/native"
  "PIPEWIRE_RUNTIME_DIR=$RUNTIME_DIR"
  "LANG=en_US.UTF-8"
  "NVIDIA_VISIBLE_DEVICES=all"
  "NVIDIA_DRIVER_CAPABILITIES=all"
  "DISPLAY_SIZEW=${DISPLAY_SIZEW:-1920}"
  "DISPLAY_SIZEH=${DISPLAY_SIZEH:-1080}"
  "DISPLAY_REFRESH=60"
  "DISPLAY_DPI=96"
  "DISPLAY_CDEPTH=24"
  "KASMVNC_ENABLE=false"
  "SELKIES_ENCODER=${SELKIES_ENCODER:-nvh264enc}"
  "SELKIES_ENABLE_BASIC_AUTH=${SELKIES_ENABLE_BASIC_AUTH:-true}"
  "SELKIES_BASIC_AUTH_PASSWORD=${SELKIES_BASIC_AUTH_PASSWORD:-}"
  "SELKIES_TURN_HOST=${SELKIES_TURN_HOST:-}"
  "SELKIES_TURN_PROTOCOL=${SELKIES_TURN_PROTOCOL:-tcp}"
  "SELKIES_TURN_PORT=${SELKIES_TURN_PORT:-70000}"
  "TURN_MIN_PORT=${TURN_MIN_PORT:-70001}"
  "TURN_MAX_PORT=${TURN_MAX_PORT:-70004}"
)

# --- Stage 1: bring up the desktop/stream + install the game ---------------
report "install_game" 10

if [ ! -f /etc/supervisord.conf ] || [ ! -x /usr/bin/supervisord ]; then
  fail "install_game" "Selkies image entrypoint (/usr/bin/supervisord) not found on this image"
fi

bootstrap_selkies_host
install -d -o "$GAME_USER" -g "$GAME_USER" -m 700 "$RUNTIME_DIR"
nohup runuser -u "$GAME_USER" -- env -i "${SELKIES_ENV[@]}" \
  /usr/bin/supervisord -c /etc/supervisord.conf > "$SELKIES_LOG" 2>&1 &

# Fail fast if supervisord didn't even come up (e.g. it can't write its socket),
# instead of waiting out the full X timeout below.
sleep 15
if [ ! -S /tmp/supervisor.sock ] && ! pgrep -x supervisord >/dev/null 2>&1; then
  fail "install_game" "supervisord did not start"
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

# Wait for Xorg to come up on :20 (first boot also downloads the matching NVIDIA
# userspace driver, so allow several minutes).
for _ in $(seq 1 150); do
  [ -S "/tmp/.X11-unix/X20" ] && break
  sleep 2
done
if [ ! -S "/tmp/.X11-unix/X20" ]; then
  fail "start_game" "desktop session (:20) did not start in time"
fi

nohup runuser -u "$GAME_USER" -- env -i "${SELKIES_ENV[@]}" \
  supertuxkart --fullscreen > /var/log/cc-supertuxkart.log 2>&1 &

# Don't stamp completion until the Selkies web server actually accepts
# connections on :8080 — the "Играть" button is provision-marker gated (a plain
# HTTP target can't be browser-polled from the https dashboard), so a premature
# 100% would hand the user an ERR_CONNECTION_REFUSED.
for _ in $(seq 1 150); do
  nc -z localhost 8080 >/dev/null 2>&1 && break
  sleep 2
done
if ! nc -z localhost 8080 >/dev/null 2>&1; then
  fail "start_game" "stream server (:8080) did not come up in time"
fi

# Surface the basic-auth state (recovered-password length, htpasswd user, and a
# real htpasswd -vb verification) in the app log even on success, so a
# credentials mismatch is diagnosable without another blind round-trip.
report_diag "start_game"

# Final stage + progress 100 => the dashboard stamps completed_at.
report "start_game" 100
