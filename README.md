# supertuxkart

Provisioning runtime for the **SuperTuxKart** one-click cloud-gaming launcher on
[cloudcompute.ru](https://cloudcompute.ru).

This repo holds a single `provision.sh` that the CloudCompute onstart wrapper
fetches and runs at instance boot:

```
https://raw.githubusercontent.com/cloudcompute-ru/supertuxkart/main/provision.sh
```

## What it does

Runs on top of the Selkies EGL desktop image
(`ghcr.io/selkies-project/nvidia-egl-desktop`), which streams a Linux desktop to
the browser over WebRTC with NVENC hardware encoding.

1. **`install_game`** — `apt-get install supertuxkart`.
2. **`start_game`** — drops a KDE autostart entry and launches the game
   fullscreen into the live session, so the browser lands directly in the game.

Each step is reported to the dashboard (`CC_PROVISION_URL`) so the launch
stepper advances; the final report (`start_game` at 100%) marks provisioning
complete.

## What it does NOT do

- **Auth password** — the Selkies basic-auth password
  (`SELKIES_BASIC_AUTH_PASSWORD`) is read by the image entrypoint at boot, so
  it is injected as per-instance Vast env at launch time, not by this script.
- **Streaming/TURN config** — encoder, resolution, and the internal TURN server
  live in the `gaming-desktop` Vast template's env/port options.

## Streaming / WebRTC note

WebRTC media needs UDP, which marketplace GPU hosts generally don't expose, so
the deployment uses the Selkies internal TURN server over **TCP**
(`SELKIES_TURN_PROTOCOL=tcp`). If the browser connects but the video stays
black, that's almost always TURN/UDP connectivity — not the container or the
game.

## Environment contract

| Variable | Provided by | Purpose |
| --- | --- | --- |
| `CC_PROVISION_URL` | onstart wrapper | POST target for stage reports |
| `CC_AGENT_TOKEN` | onstart wrapper | Bearer token for the report endpoint |
| `DISPLAY` | Selkies image | Virtual display to launch the game into (default `:0`) |
