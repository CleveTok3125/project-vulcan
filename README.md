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
   └─ input broker (event nodes -> private /dev/input)
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
- A host user with access to the Docker daemon.
- Game files available under a host directory that can be mounted read-only.
- Spritz-Wine-TkG or a Proton tree available on the host under `SPRITZ_DIR`;
  it is mounted read-only at `/data/spritz-wine-tkg`.
- A writable Wine prefix under `/data/prefix`. Seed it from an existing
  launcher prefix before first launch if the game needs DXVK/Wine settings.
- `WINE_ROOT` points at a Wine tree with `bin/wine64`.

### Groups

Set `GID_INPUT` to the numeric GID of `/dev/input`. `GID_RENDER` and
`GID_VIDEO` are the render/video GIDs. `GID_UINPUT` and host udev rules are
no longer used.

## Build cache

The base image is pinned by digest and the package database/package cache are
BuildKit cache mounts. Changing only `scripts/` or `config/` reuses the
package and Apollo build layers.

The first build after a Dockerfile package-list change still downloads the new
packages once. Do not use `--no-cache` for normal rebuilds.

## Reproducible builds

The build pins its external inputs:

- The CachyOS base image is pinned by digest.
- `APOLLO_PKG` and `APOLLO_COMMIT` pin the AUR package source to an exact
  Apollo commit.
- Rust crates are pinned by `rust/Cargo.lock` and built with `--locked`.

CachyOS repositories do not expose an archive snapshot, so packages are
resolved from the CachyOS repos at build time. The pinned base digest is the
strongest available pin for those packages.

Update these together when intentionally upgrading the image.

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
APOLLO_PKG=apollo-git
APOLLO_COMMIT=adc5c5a0bd80831ce495434bb16aee2cd4175fb8
APOLLO_ENCODER=nvenc
APOLLO_ADAPTER=
APOLLO_NAME=Vulcan-ZZZ
APOLLO_PORT=47989
GAMESCOPE_FORCE_WINDOWS_FULLSCREEN=1
GAMESCOPE_TOUCH_MODE=4
INPUT_GAMEPAD=1
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

`INPUT_TRANSPORT=socket` is the only supported path. Apollo's libevdev
uinput calls are intercepted by a Rust shim and sent over a Unix socket to
`vulcan-inputd`. No host uinput device and no host udev rule are used.

Pointer and keyboard path:

```text
Apollo -> libvulcan_uinput_shim.so -> /run/user/1000/vulcan-input.sock
       -> vulcan-inputd -> gamescope EIS -> Xwayland -> Wine
```

`vulcan-inputd` starts emulating as soon as gamescope creates the EIS device
and reads `device.resumed` before it sends input; libei rejects events for a
device that is not emulating.

Cursor: gamescope runs nested under Sway and cannot hand a client cursor to the
host reliably, so the image starts it with `--force-grab-cursor` and a long
`--hide-cursor-delay`. gamescope then paints the game's cursor into its own
frames and Apollo captures it with the rest of the image. `GAMESCOPE_GRAB_CURSOR=0`
restores host-side cursor handling, which leaves the stream without a cursor
while the pointer is over gamescope.

Gamepad path:

```text
Apollo gamepad -> shim -> vulcan-inputd -> vulcan-gamepad.bin
              -> xinput1_4.dll (Wine prefix) -> game
```

The shim fakes the gamepad and `vulcan-inputd` writes the pad state to
`/data/prefix/drive_c/vulcan-gamepad.bin`. `launch-zzz.sh` installs the
native XInput DLL and sets `WINEDLLOVERRIDES`. Set `INPUT_GAMEPAD=0` to
disable the gamepad.

The input broker mirrors Apollo's remaining uinput nodes into the container's
private `/dev/input` and emits udev events so libinput can hotplug them. Sway
preloads `/usr/lib/libvulcan-input-grab.so`; the library calls `EVIOCGRAB` on
each event node so only Sway receives it. No host udev rule is installed.

Sway runs with `WLR_BACKENDS=headless,libinput` and libseat's `noop` backend.
`GAMESCOPE_TOUCH_MODE` controls gamescope's touch handling. Pointer and keyboard
input reaches the game through gamescope, so Sway itself has no pointer device
and does not draw the streamed cursor.

`INPUT_BACKEND=xtest` falls back to `input-bridge.py`, which grabs the event
nodes with `EVIOCGRAB` and injects them into gamescope's Xwayland display with
XTest. With gamescope enabled the bridge targets `:2`; without gamescope it
targets Sway's Xwayland at `:1`. Override with `INPUT_DISPLAY`. That path
supports one pointer only and provides no Sway cursor.

Logs:

```bash
docker compose exec game tail -f /data/log/sway.log
docker compose exec game tail -f /data/log/vulcan-inputd.log
```

### Input broker

`input-broker.py` watches for the fixed inputtino device names and creates
the corresponding event nodes in the container's private `/dev/input`. It
writes udev database records and emits udev netlink events so libinput can
hotplug them.

Virtual gamepads are not exposed as host devices; they are handled by the
XInput proxy described above.

### Known input limitation

The broker publishes event nodes into the container network namespace. With
`network_mode: host`, udev netlink events are shared with the host. If the
host libinput reacts to those events, use the broker's private udev database
or switch the container to a private network namespace.

## Security

This is a rootful container with `CAP_MKNOD` and a private udev database. It
can create input nodes inside the container; it does not receive
`/dev/uinput` or `/dev/uhid` and does not install host udev rules. Run only
trusted game images, and treat the container as part of the host trust
boundary.

Additional hardening:

- keep `read_only: true`
- keep `cap_drop: ALL`
- keep only `MKNOD` and, when needed, `SYS_ADMIN`
- keep `no-new-privileges:true`
- do not pass `/dev/dri/card*`
- do not mount the host Wayland/X11 sockets
- keep `/dev/uinput` out of the container

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
swaymsg -t get_inputs
vulkaninfo --summary
ffmpeg -hide_banner -encoders | grep nvenc
```

Expected:

- `HEADLESS-1` at 1920x1080@144
- no `/dev/dri/card0`
- only expected input event nodes
- `swaymsg -t get_inputs` lists the passthrough devices while a client is
  connected
- Apollo logs show `Screencasting with Wayland's protocol`
- host session remains usable while streaming
