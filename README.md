# Vulcan Game Stream

Containerized headless game streaming for Apollo.

One container runs one game on a private headless Sway display. Apollo
captures that display with `capture=wlr`, and gamescope can host the game as a
fullscreen client. The host's graphical session is not used.

## Architecture

```text
Docker (rootful)
└─ game container
   ├─ Sway HEADLESS-1 1920x1080@144
   ├─ gamescope (nested Wayland client, optional)
   │  └─ wine64 + game
   ├─ Apollo (capture=wlr, NVENC)
   ├─ PipeWire null sink
   └─ input broker (uinput -> private /dev/input)
```

Only `/dev/dri/renderD128` is passed to the container. `/dev/dri/card*` is
never passed, so Sway cannot take DRM master from the host session.

Sway is the capture surface: gamescope does not expose
`zwlr_screencopy_manager_v1`, and Apollo on Linux does not currently provide a
PipeWire capture backend. gamescope therefore runs nested as a fullscreen
client and owns the game session inside the container.

Hyprland is not used because its Aquamarine backend requires an active seat/VT,
which is not available in this container.

## Host prerequisites

- Linux host with Docker Engine, rootful mode.
- NVIDIA driver and NVIDIA Container Toolkit, or AMD/Intel Mesa drivers.
- Kernel modules `uinput` and `uhid`.
- A host user with access to the Docker daemon.
- Game files available under a host directory that can be mounted read-only.
- Spritz-Wine-TkG or a Proton tree available on the host under `SPRITZ_DIR`;
  it is mounted read-only at `/data/spritz-wine-tkg`.
- A writable Wine prefix under `/data/prefix`. Seed it from an existing
  launcher prefix before first launch if the game needs DXVK/Wine settings.
- `WINE_ROOT` points at a Wine tree with `bin/wine64`.

### Groups and udev

```bash
sudo usermod -aG input,render,video "$USER"
sudo install -m 0644 host/99-vulcan-input.rules /etc/udev/rules.d/99-vulcan-input.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=input
```

Log out and back in after changing groups.

Get numeric GIDs for the local environment file:

```bash
getent group input render video
stat -c '%g' /dev/uinput
```

`GID_UINPUT` is the group that owns `/dev/uinput`, usually the same as
`GID_INPUT`.

## Build cache

The base image is pinned by digest and the package database/package cache are
BuildKit cache mounts. Changing only `scripts/` or `config/` reuses the
package and Apollo build layers.

The first build after a Dockerfile package-list change still downloads the new
packages once. Do not use `--no-cache` for normal rebuilds.

## Configuration

```bash
cp .env.example .env.local
$EDITOR .env.local
```

The local file is ignored by git. Use it explicitly:

```bash
docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml up -d
```

Example:

```dotenv
GAME_DIR=/srv/games/zzz
SPRITZ_DIR=/path/to/spritz-wine-tkg
GID_INPUT=993
GID_RENDER=992
GID_VIDEO=986
GID_UINPUT=993
APOLLO_ENCODER=nvenc
APOLLO_ADAPTER=
APOLLO_NAME=Vulcan-ZZZ
APOLLO_PORT=47989
GAMESCOPE_FORCE_WINDOWS_FULLSCREEN=1
RENDER_NODE=/dev/dri/renderD128
UMU_USE_STEAM=1
```

For AMD:

```dotenv
GPU_VENDOR=amd
INSTALL_CUDA=0
APOLLO_ENCODER=vaapi
APOLLO_ADAPTER=/dev/dri/renderD128
```

## Build and run

NVIDIA:

```bash
docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml build
docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml up -d
docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml logs -f
```

AMD/Intel:

```bash
docker compose --env-file .env.local build
docker compose --env-file .env.local up -d
docker compose --env-file .env.local logs -f
```

The Apollo web UI is available at `https://<host>:47990` by default
(`APOLLO_PORT + 1`). Pair the first client from the web UI. The default app
launches Zenless Zone Zero through `launch-zzz.sh`.

### First run

Build the image, then start the container:

```bash
docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml build
docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml up -d
docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml logs -f game
```

If the Wine prefix is empty and the game needs an existing DXVK/launcher
prefix, copy it into the container volume before the first launch:

```bash
docker run --rm \
  -v vulcan_zzz-data:/data \
  -v /path/to/existing/prefix:/src:ro \
  --entrypoint sh \
  vulcan/game-stream:local \
  -c 'mkdir -p /data/prefix && cp -a /src/. /data/prefix/'
```

Then restart the game container.

### NVIDIA devices

The image includes NVIDIA userland libraries, so the compose override passes
the host driver nodes directly. Keep the override in sync with the host GPU
node names and rebuild the image after a major driver update.

```bash
docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml up -d
```

Do not use `--gpus all` blindly: verify inside the container that
`/dev/dri/card0` was not mounted.

```bash
docker compose --env-file .env.local exec game ls -l /dev/dri
docker compose --env-file .env.local exec game ls -l /dev/nvidia*
```

Expected: `renderD128` and NVIDIA control/device nodes; no `card0`.

## Display and game

Defaults:

- Sway: `HEADLESS-1`, `1920x1080@144`.
- gamescope: `--backend wayland`, fullscreen, 1920x1080@144.
- Game executable: `/games/zzz/ZenlessZoneZero.exe`.
- Wine: `/data/spritz-wine-tkg/bin/wine64`, with `UMU_USE_STEAM=1`.

Change resolution or FPS in `.env.local`:

- `GAME_WIDTH`, `GAME_HEIGHT`, `GAME_FPS`
- `RENDER_NODE` if the host render node is not `/dev/dri/renderD128`

The Sway config is rendered from `config/sway/config.in` at startup, so the
template only needs editing for structural changes.

Disable gamescope for the lower-latency direct path:

```dotenv
GAMESCOPE_ENABLED=0
```

This is an A/B choice. Measure frame pacing and input latency with and without
gamescope.

## Read-only game directory

The host directory is mounted at `/games-ro/zzz:ro`. An overlay inside the
container presents a writable view at `/games/zzz`:

- lower: `/games-ro/zzz`
- upper/work: `/data/overlay/zzz`
- host files are never modified
- game writes, `config.ini`, logs and launcher-generated files stay in the
  container volume

The overlay mount requires `CAP_SYS_ADMIN`, which is granted to the entrypoint.
The game runs as a non-root user without that capability.

To update the game, stop the container and run the updater/launcher outside
the streaming container, or start a separate maintenance container with a
read-write mount. Do not expose a read-write game directory while streaming.

## Input

`input-broker.py` watches for the fixed inputtino device names:

- `Mouse passthrough`
- `Keyboard passthrough`
- `Touch passthrough`
- `Pen passthrough`

It creates the corresponding event nodes in the container's private
`/dev/input`, writes udev database records, and emits udev netlink events so
libinput can hotplug them.

The default input broker exposes Apollo virtual gamepads by name:
`Sunshine X-Box One (virtual) pad`, `Sunshine PS5 (virtual) pad`, and
`Sunshine Nintendo (virtual) pad`. Extra names can be added with
`INPUT_EXTRA_NAMES`.

The host udev rule moves `*passthrough*` devices to `seat-vulcan` and sets
`LIBINPUT_IGNORE_DEVICE`, preventing the host compositor from consuming
streamed keyboard and mouse input. The bridge additionally grabs the event
nodes with `EVIOCGRAB`.

Install and reload the rule after updating it:

```bash
sudo install -m 0644 host/99-vulcan-input.rules /etc/udev/rules.d/99-vulcan-input.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=input
```

Sway headless has no libinput seat, so `input-bridge.py` reads the keyboard,
relative mouse, absolute mouse, and touch event nodes directly and injects
them into the game's Xwayland display with XTest. With gamescope enabled, the
bridge targets `:2`; without gamescope it targets Sway's Xwayland at `:1`.
Override with `INPUT_DISPLAY`.

Absolute mouse is mapped to absolute XTest motion. Touch is mapped as a single
pointer; multi-touch is not supported by the XTest path.

Set `INPUT_BRIDGE=0` to disable the bridge.

Virtual gamepads are exposed as evdev nodes and are read directly by the game.

### Known input limitation

The broker publishes uinput devices into the container network namespace. With
`network_mode: host`, udev netlink events are shared with the host. If the host
libinput reacts to the broker events, switch the container to a private
network namespace (bridge or macvlan) and publish Apollo ports explicitly, or
run the input broker on a trusted host service.

## Security

This is a rootful container with `/dev/uinput` and `CAP_MKNOD`. That is enough
to inject input into the host kernel. Run only trusted game images, and treat
the container as part of the host trust boundary.

Additional hardening:

- keep `read_only: true`
- keep `cap_drop: ALL`
- keep only `MKNOD` and, when needed, `SYS_ADMIN`
- keep `no-new-privileges:true`
- do not pass `/dev/dri/card*`
- do not mount the host Wayland/X11 sockets
- separate `/dev/uinput` and `/dev/input` groups if games are untrusted

## Limitations

- One active game container at a time.
- Apollo Linux has no Windows-style virtual display; Sway provides it.
- HDR is not implemented in this scaffold.
- mDNS is not configured. Pair manually through the Apollo web UI, or add the
  host Avahi socket to the container.
- gamescope adds a second compositor. Disable it if latency or frame pacing is
  worse.
- Docker AppArmor may block `mknod`; test or install a custom profile.

## Validation checklist

```bash
# inside container
ls -l /dev/dri
ls -l /dev/input
swaymsg -t get_outputs
vulkaninfo --summary
ffmpeg -hide_banner -encoders | grep nvenc
```

Expected:

- `HEADLESS-1` at 1920x1080@144
- no `/dev/dri/card0`
- only expected input event nodes
- Apollo logs show `Screencasting with Wayland's protocol`
- host session remains usable while streaming
