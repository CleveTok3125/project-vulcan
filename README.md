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
   │  └─ wine + game
   ├─ Apollo (capture=wlr, NVENC)
   ├─ PipeWire null sink
   └─ input broker (event nodes -> private /dev/input)
```

The container receives the render node named by `RENDER_NODE`. On NVIDIA it
also receives the GPU's primary card node, which only the encoder opens, plus
the NVIDIA device nodes; the other cards are not passed.

Sway is the capture surface: gamescope does not expose
`zwlr_screencopy_manager_v1`, and Apollo on Linux does not currently provide a
PipeWire capture backend. gamescope therefore runs nested as a fullscreen
client and owns the game session inside the container.

Hyprland is not used because its Aquamarine backend requires an active seat/VT,
which is not available in this container.

## Host prerequisites

- Linux host with Docker Engine, rootful mode.
- NVIDIA driver, or AMD/Intel Mesa drivers; the image ships the NVIDIA
  userland libraries, so no NVIDIA Container Toolkit is needed.
- A host user with access to the Docker daemon.
- Game files available under a host directory that can be mounted read-only.
- Spritz-Wine-TkG, a Proton tree, or a distribution Wine tree available on
  the host under `SPRITZ_DIR`; it is mounted read-only at
  `/data/spritz-wine-tkg`.
- A writable Wine prefix under `/data/prefix`; the container creates it on
  the first game launch.
- `WINE_ROOT` points at a Wine tree with `bin/wine64` or, for Wine 11 and
  later, `bin/wine`.

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

### Shared base image

`make base` builds `vulcan/base:<hash>` from `docker/base.Dockerfile`: the
mirror setup, the runtime packages, the build tooling, and the game user. The
game image starts from it and adds only the vendor packages, Apollo, the native
and Rust artifacts, and the configuration.

The base tag hashes that file and `MIRROR_COUNTRY`; the game tag hashes the base
tag, `GPU_VENDOR`, `APOLLO_PKG`, and `APOLLO_COMMIT`. Editing scripts or config
rebuilds the last layers only, an Apollo bump rebuilds the Apollo stage only,
and a package change rebuilds the base and everything above it. `uninstall`
removes the game image.

Calling Compose without `make`, such as the AMD/Intel form above, needs the
base image first: run `make base` and pass `BASE_IMAGE` to the build, or build
through `make`.

`make images` lists the Vulcan images, and `make base-rebuild CONFIRM=1`
rebuilds the base image without cache for when the upstream packages moved.

## Reproducible builds

The build pins its external inputs:

- The CachyOS base image is pinned by digest.
- `APOLLO_PKG` and `APOLLO_COMMIT` pin the AUR package source to an exact
  Apollo commit.
- Rust crates are pinned by `rust/Cargo.lock` and built with `--locked`.

The image tag follows the build inputs: the base tag, `GPU_VENDOR`,
`APOLLO_PKG`, and `APOLLO_COMMIT` are hashed into
`vulcan/game-stream:local-<hash>`. Presets with the same inputs share one
image; a preset that changes them builds its own tag instead of overwriting
the image another preset runs on. `up` never pulls, so it stops with an error
when that variant has not been built.

CachyOS repositories do not expose an archive snapshot, so packages are
resolved from the CachyOS repos at build time. The pinned base digest is the
strongest available pin for those packages.

Update these together when intentionally upgrading the image.

## Configuration

The `.env.zzz.example` preset describes one game on one host, with the
host-specific lines marked.

```bash
cp .env.zzz.example .env.local
$EDITOR .env.local
```

The local file is ignored by git. Use it explicitly:

```bash
docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml up -d
```

Keep one file per game or host profile and select it with `PRESET`:

```bash
cp .env.zzz.example .env.zzz
$EDITOR .env.zzz
make up PRESET=.env.zzz
```

`PRESET` selects one preset for every target that acts on a single container,
including `build`, `logs`, `clean-*`, and `uninstall`. The value is a path
relative to the repository root; `.env.local` is the default. Each `GAME_ID`
gets its own container, compose project, and volume, so presets with different
`GAME_ID` values run side by side. Each target prints the selected file, for
example `[vulcan] PRESET=.env.zzz`. A target that acts on one container stops
when the preset file is missing or does not set `GAME_ID`; `help` and the
`*-all` targets keep working without one.

`GAME_ID`, `GAME_DIR`, `GAME_EXE`, `RENDER_NODE`, and `SPRITZ_DIR` are
required. `GAME_DIR` is mounted at `/games-ro/<GAME_ID>`; `GAME_EXE` is the
executable path inside the writable overlay view at `/games/<GAME_ID>`.

### Game identity

`GAME_ID` names everything derived from the game: the read-only mount point,
the overlay directories, the data volume `vulcan_<GAME_ID>-data`, the compose
project and container `vulcan-<GAME_ID>`, and the default Apollo host name
`Vulcan-<GAME_ID>`.

`GAME_APP_NAME` is the app label shown to clients. `GAME_APP_UUID` identifies
that app entry; leave it empty to derive a stable UUID from `GAME_ID`, or set
it explicitly, for example to keep the identity clients already stored.

To run a different game, keep its settings in a separate preset and select it
for every target. Presets with different `GAME_ID` values run side by side:

```bash
make up PRESET=.env.zzz
make up PRESET=.env.other
make logs PRESET=.env.other
make down PRESET=.env.zzz
```

Create the preset with `cp .env.zzz.example .env.demo` and set `GAME_ID`,
`GAME_DIR`, `GAME_EXE`, and `GAME_APP_NAME` as described above.

Each game gets its own container `vulcan-<GAME_ID>`, compose project, and
volume `vulcan_<GAME_ID>-data`. Volumes of games that are no longer configured
remain on the host; remove them with `docker volume rm`.

Start or stop several presets in one call. The list is colon-separated, and
every entry must exist before the first container starts:

```bash
make up-all PRESETS=".env.zzz:.env.other"
make stats-all PRESETS=".env.zzz:.env.other"
make build-all PRESETS=".env.zzz:.env.other"
make down-all PRESETS=".env.zzz:.env.other"
```

The group targets cover `up`, `down`, `stop`, `restart`, `ps`, `build`,
`stats`, and `uninstall` (which needs `CONFIRM=1`). Targets that act on one
container at a time, such as `logs`, `shell`, `btop`, `nvtop`, `watch`, and
`clean-*`, stay per preset.

Set a distinct `APOLLO_PORT` in every preset that runs at the same time,
because Apollo binds on the host network; the web UI listens on
`APOLLO_PORT + 1`. Both sessions share one GPU, so VRAM, memory bandwidth, and
the driver's NVENC session limit apply to the sum of the streams. The image and
the NVIDIA device configuration are shared: run `make down` for every preset
before `make uninstall`.

## Fresh deployment

These steps start from a checkout with no image, volume, or `.env.local`.
The `make` targets pass `compose.nvidia.yaml`; on AMD/Intel hosts use the raw
`docker compose --env-file .env.local` form without that file.

1. Read the host device group IDs. Use an input event node, not the
   `/dev/input` directory, which belongs to root and reports `0`:

   ```bash
   stat -c '%g %n' /dev/input/event* /dev/dri/renderD128
   ```

   The values are `GID_INPUT` and `GID_RENDER`. `GID_VIDEO` is the numeric
   video group from `getent group video`; compose requires it.
   When the host has no event node, `getent group input` gives `GID_INPUT`.
   A device owned by group `0` cannot be read by the game user.

2. Choose the render node of the encoder GPU. The node numbering does not
   follow the card numbering, and a node from the wrong vendor leaves Apollo
   without an encoder:

   ```bash
   for f in /sys/class/drm/renderD*/device/vendor; do echo "$f $(cat "$f")"; done
   ```

   `0x10de` is NVIDIA and `0x1002` is AMD. Use the resulting node as
   `RENDER_NODE`. A wrong node makes Apollo report
   `Couldn't initialize EGL display`, select no encoder, and disconnect the
   client right after the app starts.

3. Create the local configuration:

   ```bash
   cp .env.zzz.example .env.local
   $EDITOR .env.local
   make config
   ```

   `GAME_ID`, `GAME_DIR`, `GAME_EXE`, `SPRITZ_DIR`, `RENDER_NODE`, and the
   GIDs are required. `make config` prints the resolved compose configuration
   and stops at a missing or malformed value.

4. Build the image for the selected preset:

   ```bash
   make build
   ```

   The tag follows the build inputs, so one build serves every preset with the
   same base image, `GPU_VENDOR`, `APOLLO_PKG`, and `APOLLO_COMMIT`.

5. Start the container:

   ```bash
   make up
   make logs
   ```

   The first launch of the game creates the Wine prefix in the volume
   (about 340 MB). Follow it from the Apollo log:

   ```bash
   docker compose --env-file .env.local exec game \
     tail -f /data/apollo/sunshine.log
   ```

6. Open `https://<host>:47990` (`APOLLO_PORT + 1`), accept the self-signed
   certificate, create the web credentials, and pair the first client. The
   app entry is generated at startup from `config/apollo/apps.json` and runs
   `launch-game.sh`.

7. Verify the GPU nodes and the session logs:

   ```bash
   make stats
   docker compose --env-file .env.local exec game ls -l /dev/dri
   docker compose --env-file .env.local exec game tail -f /data/log/sway.log
   ```

To run a different game later, see [Game identity](#game-identity).

### NVIDIA devices

The image includes NVIDIA userland libraries, so the compose override passes
the host driver nodes directly. Keep the override in sync with the host node
names and rebuild the image after a major driver update.

NVENC needs the primary DRM node of the NVIDIA GPU. The CUDA path maps the
device PCI bus ID to the first `card*` entry in sysfs and opens it for the
GBM/EGL interop, so the override passes that node (for example
`/dev/dri/card0`) next to `RENDER_NODE`. AMD and Intel do not need it; see
[AMD and Intel](#amd-and-intel).

```bash
docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml up -d
```

```bash
docker compose --env-file .env.local exec game ls -l /dev/dri
docker compose --env-file .env.local exec game ls -l /dev/nvidia*
```

Expected: the primary card node, the render node, and the NVIDIA control and
device nodes. Apollo logs `Found DRM primary node` and `Found CUDA device`;
without the primary node NVENC fails and the session falls back to software
encoding.

### AMD and Intel

VAAPI opens the render node in `APOLLO_ADAPTER`, or `/dev/dri/renderD128` when
it is empty. It never opens a primary card node. Set `APOLLO_ADAPTER` when the
render node is not `renderD128`.

```dotenv
GPU_VENDOR=amd
APOLLO_ENCODER=vaapi
APOLLO_ADAPTER=/dev/dri/renderD128
```

## Display and game

Defaults:

- Sway: `HEADLESS-1`, `1920x1080@144`.
- gamescope: `--backend wayland`, fullscreen, 1920x1080@144.
- Game executable: `GAME_EXE` from the selected env file.
- Wine: `/data/spritz-wine-tkg/bin/wine64` or `/data/spritz-wine-tkg/bin/wine`,
  with `UMU_USE_STEAM=1`.

### Wine environment

`launch-game.sh` exports these before Wine starts; override them in the
selected env file:

- `WINEESYNC=1` and `WINEFSYNC=1` use eventfd and futex synchronisation
  instead of wineserver round trips. fsync requires `futex_waitv`, available
  since Linux 5.16.
- `XMODIFIERS=@im=none` keeps the host input method out of Wine. It is set by
  `launch-game.sh`, not by Compose, so a desktop `XMODIFIERS` value cannot
  leak into the container.
- `__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1` keeps the NVIDIA GL shader cache
  instead of letting the driver prune it.
- `DXVK_HUD` is empty by default; set it to e.g. `fps,frametimes` to show the
  DXVK overlay.

### GPU path

The container receives the render node named by `RENDER_NODE`. On NVIDIA,
`compose.nvidia.yaml` also passes the primary card node and the NVIDIA device
nodes; AMD/Intel need only the render node. A host iGPU is not passed through.
`RENDER_NODE` must be the render node of the GPU that runs gamescope and the
encoder; see [Fresh deployment](#fresh-deployment).

Every streamed frame goes through two composition steps:

1. gamescope composites the game into its own output.
2. Sway imports that output as a dmabuf, composites the cursor, and renders the
   headless output that Apollo captures.

The second step adds one full-screen read and write per frame: about 1.2 GB/s
in each direction at 1920x1080@144, a few percent of a discrete GPU's memory
bandwidth. It runs on the GPU, not the CPU, as long as Sway uses its GLES
renderer.

Keeping every step on one GPU matters more than the extra pass. Pointing
`RENDER_NODE` at a second GPU moves Sway's composite onto that GPU, forces a
cross-GPU dmabuf import for every frame, and drops Apollo out of the zero-copy
VRAM capture path into a GPU -> RAM -> GPU transfer.

Change resolution or FPS in the selected env file:

- `GAME_WIDTH`, `GAME_HEIGHT`, `GAME_FPS`
- `RENDER_NODE` if the encoder GPU moves to another render node

The Sway config is rendered from `config/sway/config.in` at startup, so the
template only needs editing for structural changes.

Disable gamescope for the lower-latency direct path:

```dotenv
GAMESCOPE_ENABLED=0
```

This is an A/B choice. Measure frame pacing and input latency with and without
gamescope.

The socket input transport requires gamescope: `vulcan-inputd` delivers input
through gamescope's EIS socket and gamescope composites the streamed cursor.
With `GAMESCOPE_ENABLED=0` the game renders directly under Sway, but the
container then has neither pointer/keyboard input nor a streamed cursor.

## Read-only game directory

The host directory is mounted at `/games-ro/<GAME_ID>:ro`. An overlay inside
the container presents a writable view at `/games/<GAME_ID>`:

- lower: `/games-ro/<GAME_ID>`
- upper/work: `/data/overlay/<GAME_ID>`
- host files are never modified
- game writes, `config.ini`, logs and launcher-generated files stay in the
  container volume

The host directory can also contain state written outside the container,
including stored logins under `ZenlessZoneZero_Data/Persistent/LocalStorage`
and `ZenlessZoneZero_Data/SDKCaches/HoYoPass`. Because it is the lower layer, a
fresh volume would still start signed in. `GAME_RESET_PATHS` lists
game-relative paths to remove once per prefix; removals land in the overlay
upper layer and the host files stay untouched. Setting it on an existing
prefix applies at the next launch.

Session cleanup targets remove parts of the volume and keep the Wine prefix
and Apollo state:

| Target | Removes |
| --- | --- |
| `make clean-logs` | `/data/log/*` |
| `make clean-overlay` | `/data/overlay/<GAME_ID>/{upper,work}/*` and `/data/prefix/.vulcan-reset-paths` |
| `make clean-appdata` | `/data/prefix/drive_c/users/*/AppData` |
| `make clean-all` | all of the above |

Each target stops the container, removes its paths, and starts the container
again. `clean-overlay` also drops the reset marker: the fresh overlay no longer
holds the whiteouts from the previous `GAME_RESET_PATHS` run, so the next
launch applies them again. Use it after the host changes files the container
had already written, since the overlay keeps the container's copy until it is
removed.

The overlay mount requires `CAP_SYS_ADMIN`, which is granted to the entrypoint.
The game runs as a non-root user without that capability.

To update the game, stop the container and run the updater/launcher outside
the streaming container, or start a separate maintenance container with a
read-write mount. Do not expose a read-write game directory while streaming.
Run `make clean-overlay` afterwards so the container stops using the copies it
wrote into its overlay and reads the updated tree.

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

### Cursor

The streamed cursor is the game's own cursor image, drawn by gamescope and
captured by Apollo with the rest of the frame. gamescope runs with
`--force-grab-cursor`, which makes it composite the cursor itself instead of
handing it to Sway.

- Visible over menus and any screen where the game provides a cursor.
- Hidden when the game hides its cursor, such as pointer-locked gameplay.
- No cursor outside gamescope: Sway has no pointer device here, so the desktop
  behind the game has no cursor of its own.
- `GAMESCOPE_GRAB_CURSOR=0` restores host-side cursor handling and drops the
  streamed cursor over the game.
- `GAMESCOPE_HIDE_CURSOR_DELAY` is the idle timeout in milliseconds before
  gamescope hides the cursor; the default `86400000` keeps it visible.

### Gamepad

```text
Apollo gamepad -> shim -> vulcan-inputd -> vulcan-gamepad.bin
              -> xinput1_4.dll (Wine prefix) -> game
```

The shim fakes the gamepad and `vulcan-inputd` writes the pad state to
`/data/prefix/drive_c/vulcan-gamepad.bin`, which Wine sees as
`C:\vulcan-gamepad.bin`. The file lives in the `vulcan_<GAME_ID>-data` volume.
The input socket is `/run/user/1000/vulcan-input.sock`; `/run` is a tmpfs, so
the socket exists only while the container runs.

`launch-game.sh` installs the native XInput DLL and sets `WINEDLLOVERRIDES`.
Set `INPUT_GAMEPAD=0` to skip both the pad state file and the DLL. Games that
use DirectInput or raw HID instead of XInput do not see a controller.

The input broker mirrors Apollo's remaining uinput nodes into the container's
private `/dev/input` and emits udev events so libinput can hotplug them. Sway
preloads `/usr/lib/libvulcan-input-grab.so`; the library calls `EVIOCGRAB` on
each event node so only Sway receives it. No host udev rule is installed.

Sway runs with `WLR_BACKENDS=headless,libinput` and libseat's `noop` backend.
`GAMESCOPE_TOUCH_MODE` controls gamescope's touch handling. Pointer and keyboard
input reaches the game through gamescope, so Sway itself has no pointer device
and does not draw the streamed cursor.

### Multi-touch

The shim forwards the `ABS_MT` sequence from Apollo's touch device and
`vulcan-inputd` maps each contact to a libei touch. Contacts do not reach the
game yet: gamescope 3.17 leaves `EIS_DEVICE_CAP_TOUCH` disabled in
`src/InputEmulation.cpp` and logs `No touch support yet` for touch events. The
forwarding path becomes active once gamescope advertises the capability; until
then keep the client in a mouse mode, where touch arrives as absolute mouse
events.

`INPUT_BACKEND=xtest` falls back to `vulcan-input-bridge`, which grabs the event
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

`vulcan-input-broker` watches for the fixed inputtino device names and creates
the corresponding event nodes in the container's private `/dev/input`. It
writes udev database records and emits udev netlink events so libinput can
hotplug them.

uinput devices live in the shared kernel and carry no marker that names their
creator, so the broker only takes devices that appeared after it started: the
nodes another running session created earlier stay in the baseline.

Virtual gamepads are not exposed as host devices; they are handled by the
XInput proxy in the Wine prefix.

### Known input limitation

The broker publishes event nodes into the container network namespace. With
`network_mode: host`, udev netlink events are shared with the host. If the
host libinput reacts to those events, use the broker's private udev database
or switch the container to a private network namespace.

## Security

This is a rootful container with `CAP_MKNOD` and the capabilities listed
below. It can create input nodes inside the container; it does not receive
`/dev/uinput` or `/dev/uhid` and does not install host udev rules. Run only
trusted game images, and treat the container as part of the host trust
boundary.

Additional hardening:

- keep `read_only: true`
- keep `cap_drop: ALL`
- add only what the entrypoint needs: `MKNOD` for the input broker,
  `NET_ADMIN` for the broker's synthetic udev event, `SYS_ADMIN` for the
  overlay mount and `ip netns add`, `CHOWN` for the overlayfs copy-up done
  with the mounter's credentials, `DAC_OVERRIDE` for the root writes into
  the game-owned volume (including the overlay upper directory), and
  `SETUID`/`SETGID` to drop to the game user
- keep the game process unprivileged: it receives no capabilities, and
  `CHOWN` only applies to the overlay mount created by the entrypoint
- after startup the entrypoint continues as the game user, and the broker
  drops to `MKNOD` and `NET_ADMIN`
- keep `no-new-privileges:true`
- pass only the DRM nodes the encoder needs: on NVIDIA the primary card node
  plus `RENDER_NODE`; on AMD/Intel only the render node
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
- Multi-touch does not reach the game: gamescope 3.17 has no EIS touch
  capability.

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
- `RENDER_NODE` and, on NVIDIA, the primary card node
- only expected input event nodes
- `swaymsg -t get_inputs` lists the passthrough devices while a client is
  connected
- Apollo logs show `Screencasting with Wayland's protocol`
- host session remains usable while streaming
