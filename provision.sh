#!/usr/bin/env bash
# SuperTuxKart cloud-gaming provisioner (cloudcompute.ru).
#
# Runs on the Selkies nvidia-egl-desktop image at instance boot, fetched by the
# CloudCompute onstart wrapper. It installs the game, autostarts it into the
# live KDE session, and reports stage transitions to CC_PROVISION_URL so the
# dashboard stepper advances.
#
# It deliberately does NOT set the Selkies basic-auth password: the image
# entrypoint starts the streaming server (reading SELKIES_BASIC_AUTH_PASSWORD
# from the container env) before this script runs, so the password is injected
# as per-instance Vast env at launch time, not here.
#
# Contract (provided by the onstart wrapper):
#   CC_PROVISION_URL  POST target for stage reports (/api/agent/provision)
#   CC_AGENT_TOKEN    Bearer token for the report endpoint
set -uo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"
GAME_USER="ubuntu"
# Selkies' virtual display. ":0" is the image default; override via DISPLAY env.
GAME_DISPLAY="${DISPLAY:-:0}"

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

# --- Stage 1: install the game --------------------------------------------
report "install_game" 10
export DEBIAN_FRONTEND=noninteractive
apt-get update -y                || fail "install_game" "apt update failed"
apt-get install -y supertuxkart  || fail "install_game" "supertuxkart install failed"
report "install_game" 100

# --- Stage 2: autostart + launch into the running session -----------------
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

# The session is already up by the time the user connects, so also launch the
# game directly into the live display. Wait for X to be ready first.
for _ in $(seq 1 60); do
  sudo -u "$GAME_USER" env DISPLAY="$GAME_DISPLAY" xset q >/dev/null 2>&1 && break
  sleep 2
done

nohup sudo -u "$GAME_USER" env DISPLAY="$GAME_DISPLAY" supertuxkart --fullscreen \
  > /var/log/cc-supertuxkart.log 2>&1 &

# Final stage + progress 100 => the dashboard stamps completed_at.
report "start_game" 100
