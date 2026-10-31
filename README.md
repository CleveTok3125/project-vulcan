# Vulcan Game Stream

Containerized headless game streaming for Apollo.

One container runs a session with one or more games on a private headless Sway
display. Apollo lists every catalog game as an app and starts the selected one.
gamescope hosts the game as a fullscreen client. The host's graphical session
is not used.

## Architecture

```text
Docker (rootful)
└─ game container
   ├─ Sway HEADLESS-1 1920x1080@144
   ├─ Apollo (capture=wlr, NVENC)
   │  └─ app per catalog game
   ├─ gamescope (nested Wayland client, optional)
   │  └─ wine + selected game
   ├─ PipeWire null sink
   └─ vulcan-inputd (socket -> gamescope EIS)
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
- Game files available under host directories that can be mounted read-only.
- `jq` and `yq` (`go-yq`) on the host to validate and convert the game
  catalog: `sudo pacman -S jq go-yq`.
- Optional OBS capture: native OBS on Wayland plus `obs-vkcapture` matching
  `OBS_VKCAPTURE_REF`. The container does not ship OBS or the OBS plugin.
- Spritz-Wine-TkG, a Proton tree, or a distribution Wine tree available on
  the host under `SPRITZ_DIR`; it is mounted read-only at
  `/data/spritz-wine-tkg`.
- A writable Wine prefix per game under `/data/prefix/<game>`; the container
  creates it on the first game launch.
- `WINE_ROOT` points at a Wine tree with `bin/wine64` or, for Wine 11 and
  later, `bin/wine`.

### Groups

`GID_RENDER` and `GID_VIDEO` are the render/video GIDs. `GID_STORAGE` is
optional. Input devices are not passed to the container, so no input GID is
needed.

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

The base tag hashes `docker/base.Dockerfile`, `docker/fetch-heavy`, and
`MIRROR_COUNTRY`; the game tag hashes the base tag, `GPU_VENDOR`, `APOLLO_PKG`,
and `APOLLO_COMMIT`. Editing scripts or config rebuilds the last layers only,
an Apollo bump rebuilds the Apollo stage only, and a package change rebuilds
the base and everything above it. `uninstall` removes the game image once no
container uses it.

`docker/fetch-heavy` prefetches the large build packages into the pacman cache
with aria2c. Everything else, including repository databases and parallel
downloads, uses pacman's default downloader.

Calling Compose without `make` needs the base image first and the generated
catalog files: run `make base`, `make config`, then pass
`-f .generated/compose.games.yaml` explicitly.

`make rm-base` removes the base image; the next build recreates it.
`make images` lists the Vulcan images, and `make base-rebuild CONFIRM=1`
rebuilds the base image without cache for when the upstream packages moved.

## Reproducible builds

The build pins its external inputs:

- The CachyOS base image is pinned by digest.
- `APOLLO_PKG` and `APOLLO_COMMIT` pin the AUR package source to an exact
  Apollo commit.
- Rust crates are pinned by `rust/Cargo.lock` and built with `--locked`.

The image tag follows the build inputs: the base tag, `GPU_VENDOR`,
`APOLLO_PKG`, `APOLLO_COMMIT`, and `OBS_VKCAPTURE_REF` are hashed into
`vulcan/game-stream:local-<hash>`. Presets with the same inputs share one
image; a preset that changes them builds its own tag instead of overwriting
the image another preset runs on. `up` never pulls, so it stops with an error
when that variant has not been built.

CachyOS repositories do not expose an archive snapshot, so packages are
resolved from the CachyOS repos at build time. The pinned base digest is the
strongest available pin for those packages.

Update these together when intentionally upgrading the image.

## Configuration

The `.env.multi.example` preset describes one session on one host, with the
host-specific lines marked. `games.example.yaml` is the game catalog template.

```bash
cp .env.multi.example .env.local
cp games.example.yaml games.yaml
$EDITOR .env.local games.yaml
make config
```

Both local files are ignored by git. `make` converts `games.yaml` to
`.generated/games.json` and `.generated/compose.games.yaml`; Compose mounts the
generated JSON and one read-only bind for every catalog game.

`SESSION_ID`, `GAMES_CATALOG`, `RENDER_NODE`, and `SPRITZ_DIR` are required.
`SESSION_ID` names the compose project, container `vulcan-<SESSION_ID>`, volume
`vulcan_<SESSION_ID>-data`, and the default Apollo host name
`Vulcan-<SESSION_ID>`.

### Game catalog

`games.yaml` is the source of truth:

```yaml
games:
  - id: demo
    name: Demo Game
    source: /srv/games/demo
    exe: Demo.exe

  - id: other
    name: Other Game
    source: /srv/games/other
    exe: Other.exe
    wine_source: /srv/wine/other
    reset_paths:
      - Data/Login
      - Data/Cache
```

- `id` is unique, safe as a path segment, and identifies the overlay, prefix,
  Apollo app, and log lines.
- `name` is the app label shown to clients.
- `source` is an absolute host directory. Only catalog directories are
  mounted, read-only, at `/games-ro/<id>`.
- `exe` is relative to `source`; the writable overlay path is
  `/games/<id>/<exe>`.
- `reset_paths` are relative to the game directory and are removed once per
  Wine prefix, never on the host.
- `wine_source` is optional. Set it to an absolute host Wine tree when games
  need different Wine builds; it is mounted at `/wine/<id>` and overrides the
  session `SPRITZ_DIR`. Without it, every game uses the session Wine tree.
- `uuid` is optional. Empty derives a stable UUID from `id`; set it to keep an
  existing client app identity.

Apollo reads one app per catalog entry from `/data/apollo/apps.json`. Selecting
an app starts `launch-game.sh <id>`, which resolves that game's overlay, Wine
prefix, and reset paths. The container runs one game at a time; a second app
start exits while the first holds the session lock.

### Sessions

`P` selects one preset or a colon-separated list. The value is a path relative
to the repository root; `.env.local` is the default. Each `SESSION_ID` gets its
own container, compose project, and volume, so different sessions run side by
side:

```bash
make up P=.env.multi
make up P=.env.other
make logs P=.env.other
make down P=.env.multi
```

Every target prints the selection, for example `[vulcan] P=.env.multi`. A
target that acts on one container stops when the preset file is missing or
does not set `SESSION_ID`; `help` and the global targets keep working without
one.

Start, stop, or inspect several presets in one call. The list is
colon-separated and every entry must exist before the first container starts:

```bash
make up P=".env.multi:.env.other"
make stats P=".env.multi:.env.other"
make build P=".env.multi:.env.other"
make down P=".env.multi:.env.other"
```

Targets that can act on several presets are `build`, `rebuild`, `up`, `stop`,
`restart`, `down`, `ps`, `stats`, and `uninstall` (which needs `CONFIRM=1`).
The old `*-all` names still work as aliases. Targets that act on one container
at a time, such as `logs`, `shell`, `btop`, `nvtop`, `watch`, `volume`,
`config`, and `clean-*`, stop when `P` lists more than one preset.

`make volumes` lists every Vulcan volume; add `P=".env.multi:.env.other"` to
list only those presets. Volumes of sessions that are no longer configured
remain on the host; remove them with `docker volume rm`.

### Migrating from per-game presets

Per-game presets are not read by this version. Create `.env.multi` and
`games.yaml` instead. Old volumes remain on the host; the new session uses
`vulcan_<SESSION_ID>-data`.

To keep an old Wine prefix, copy it into the new volume before the first
launch:

```bash
docker run --rm -v vulcan_<old_game>-data:/old \
  -v vulcan_<SESSION_ID>-data:/new \
  alpine sh -c 'mkdir -p /new/prefix/<id> && cp -a /old/prefix/. /new/prefix/<id>/'
```

The overlay can be rebuilt from the host game directory; copy it only if the
container had local writes that must survive.

### Ports

Every preset that runs at the same time needs a non-overlapping
`APOLLO_PORT`, because Apollo binds on the host network and derives all of its
ports from that value:

| Protocol | Ports |
| --- | --- |
| TCP | `base - 5`, `base`, `base + 1`, `base + 21` |
| UDP | `base + 9` through `base + 13` |

Pick bases whose ranges do not intersect on the same protocol. The tracked
example uses `48006`; a second session on `47989` does not overlap it. Run
`make check-ports P=".env.multi:.env.other"` before starting a set; `up` and
`restart` run the same check. `make ports P=".env.multi:.env.other"` prints the
derived table for those presets. Clients that only use the default port cannot
reach a preset with a custom base port.

Both sessions share one GPU, so VRAM, memory bandwidth, and the driver's NVENC
session limit apply to the sum of the streams. The image and the NVIDIA device
configuration are shared. `make uninstall` removes the container and volume of
one preset and leaves the image while another preset still uses it;
`make uninstall P="a:b"` removes the image once the last container is gone.

## Fresh deployment

These steps start from a checkout with no image, volume, or local preset.
The `make` targets pass `compose.nvidia.yaml`; on AMD/Intel hosts open a shell
that does not use that file and pass the generated override explicitly.

1. Read the render node group:

   ```bash
   stat -c '%g %n' /dev/dri/renderD128
   ```

   The value is `GID_RENDER`. `GID_VIDEO` is the numeric video group from
   `getent group video`; compose requires it. A node owned by group `0`
   cannot be read by the game user.

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

3. Create the local configuration and catalog:

   ```bash
   cp .env.multi.example .env.local
   cp games.example.yaml games.yaml
   $EDITOR .env.local games.yaml
   make config
   ```

   `SESSION_ID`, `GAMES_CATALOG`, `SPRITZ_DIR`, `RENDER_NODE`, and the GIDs are
   required. The catalog needs at least one game with a valid `source` and
   `exe`. `make config` prints the resolved Compose configuration and stops at
   a missing or malformed value.

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

   The first launch of a game creates its per-game Wine prefix in the volume
   (about 340 MB). Follow it from the Apollo log:

   ```bash
   docker compose --env-file .env.local exec game \
     tail -f /data/apollo/sunshine.log
   ```

6. Open `https://<host>:47990` (`APOLLO_PORT + 1`), accept the self-signed
   certificate, create the web credentials, and pair the first client. Apollo
   reads one app per catalog game and runs `launch-game.sh <id>` for the
   selected app.

7. Verify the GPU nodes and the session logs:

   ```bash
   make stats
   docker compose --env-file .env.local exec game ls -l /dev/dri
   docker compose --env-file .env.local exec game tail -f /data/log/sway.log
   ```

To add or remove games, edit `games.yaml` and restart the session; see
[Game catalog](#game-catalog).

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
# make config has already generated .generated/compose.games.yaml
docker compose --env-file .env.local \
  -f compose.yaml -f compose.nvidia.yaml \
  -f .generated/compose.games.yaml up -d
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
- Game executable: the catalog `exe` for the selected Apollo app, under
  `/games/<id>`.
- Wine: `/data/spritz-wine-tkg/bin/wine64` or `/data/spritz-wine-tkg/bin/wine`,
  with `UMU_USE_STEAM=1`.

### OBS capture

The image contains only the `obs-vkcapture` capture sender. Host OBS runs the
receiver plugin:

```text
container: Wine/game -> obs-vkcapture layer -> abstract socket
host:      OBS -> linux-vkcapture plugin -> DMA-BUF
```

The container uses `network_mode: host`, so both sides share the abstract
socket. This does not change the Sway/Apollo path.

`OBS_VKCAPTURE=1` is the default. It wraps only the Wine command, inside
gamescope, matching a Lutris `prefix_command = obs-gamecapture` setup:

```text
gamescope ... -- obs-gamecapture wine game
```

Set `OBS_VKCAPTURE=0` to disable capture. A missing host OBS or plugin does not
stop the game.

Host requirements:

- Native OBS on Wayland, not Flatpak.
- `obs-vkcapture` plugin, version matching `OBS_VKCAPTURE_REF` (source tag; host package `1.5.6` uses tag `v1.5.6`).
- NVIDIA driver with `nvidia-drm.modeset=1`.

The container builds only the capture layer (`-DBUILD_PLUGIN=OFF`) and pins the
source with `OBS_VKCAPTURE_REF`; there is no automatic host-version detection.
Change the reference and rebuild when the host plugin changes.

Capture is limited to the game process: it does not include gamescope cursor,
FSR/NIS, HDR tone mapping, or gamescope/Steam overlays. Audio is not captured
by `obs-vkcapture`.

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

## Read-only game directories

Each catalog game is mounted read-only at `/games-ro/<id>`. An overlay inside
the container presents a writable view at `/games/<id>`:

- lower: `/games-ro/<id>`
- upper/work: `/data/overlay/<id>`
- host files are never modified
- game writes, `config.ini`, logs and launcher-generated files stay in the
  container volume

Only the directories listed in `games.yaml` are mounted. The generated Compose
override adds one bind mount per game; there is no shared game root.

A host game directory can also contain state written outside the container,
including stored logins under `Data/Login` and cached credentials under
`Data/Cache`. Because it is the lower layer, a
fresh volume still starts signed in. The catalog `reset_paths` field lists
game-relative paths to remove once per Wine prefix; removals land in the
overlay upper layer and the host files stay untouched. Changing the field on
an existing prefix applies at the next launch.

The session data volume contains one prefix and one overlay per game:

```text
/data/prefix/<id>
/data/overlay/<id>
```

Session cleanup targets remove parts of the volume and keep Apollo state:

| Target | Removes |
| --- | --- |
| `make clean-logs` | `/data/log/*` |
| `make clean-overlay` | `/data/overlay/*/{upper,work}/*` and `/data/prefix/*/.vulcan-reset-paths` |
| `make clean-appdata` | `/data/prefix/*/drive_c/users/*/AppData` |
| `make clean-all` | all of the above |

Each target stops the container, removes its paths, and starts the container
again. `clean-overlay` also drops the reset markers: the fresh overlays no
longer hold the whiteouts from the previous reset, so the next launch applies
the catalog `reset_paths` again. Use it after the host changes files the
container had already written, since the overlay keeps the container's copy
until it is removed.

The overlay mount requires `CAP_SYS_ADMIN`, which is granted to the entrypoint.
The game runs as a non-root user without that capability.

To update a game, stop the container and run the updater/launcher outside the
streaming container, or start a separate maintenance container with a
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
`/data/vulcan-gamepad.bin`, which Wine sees as `C:\vulcan-gamepad.bin`
through a per-prefix symlink. The file lives in the
`vulcan_<SESSION_ID>-data` volume and is shared by the catalog games because
only one game runs at a time.

The input socket is `/run/user/1000/vulcan-input.sock`; `/run` is a tmpfs, so
the socket exists only while the container runs.

`launch-game.sh` installs the native XInput DLL and sets `WINEDLLOVERRIDES`.
Set `INPUT_GAMEPAD=0` to skip both the pad state file and the DLL. Games that
use DirectInput or raw HID instead of XInput do not see a controller.

Sway runs with `WLR_BACKENDS=headless`. `GAMESCOPE_TOUCH_MODE` controls
gamescope's touch handling. Pointer and keyboard input reaches the game
through gamescope EIS, so Sway has no input device and does not draw the
streamed cursor.

Sway does not start Xwayland while gamescope is enabled: gamescope runs its
own X server for Wine, and Sway's instance would only compete for the abstract
X11 socket names that the host already owns, because the container uses the
host network namespace. `GAMESCOPE_ENABLED=0` re-enables Xwayland for the
direct Sway path.

### Multi-touch

The shim forwards the `ABS_MT` sequence from Apollo's touch device and
`vulcan-inputd` maps each contact to a libei touch. Contacts do not reach the
game yet: gamescope 3.17 leaves `EIS_DEVICE_CAP_TOUCH` disabled in
`src/InputEmulation.cpp` and logs `No touch support yet` for touch events. The
forwarding path becomes active once gamescope advertises the capability; until
then keep the client in a mouse mode, where touch arrives as absolute mouse
events.

Logs:

```bash
docker compose exec game tail -f /data/log/sway.log
docker compose exec game tail -f /data/log/vulcan-inputd.log
```

### Session isolation

Each container owns its input socket, runtime directory, and gamescope
instance, so two presets can stream at the same time without sharing input.
The shim sends events to `VULCAN_INPUT_SOCKET` and `vulcan-inputd` connects to
the EIS socket of its own gamescope. Set `VULCAN_EIS_SOCKET` to override the
discovered path.

No input device is created in the host kernel, so neither session can see or
grab the other's devices.

## Security

This is a rootful container with the capabilities listed below. It does not
receive `/dev/uinput`, `/dev/uhid`, or host input devices, and does not install
host udev rules. Run only trusted game images, and treat the container as part
of the host trust boundary.

Additional hardening:

- keep `read_only: true`
- keep `cap_drop: ALL`
- add only what the entrypoint needs: `SYS_ADMIN` for the overlay mount,
  `CHOWN` for the overlayfs copy-up done with the mounter's credentials,
  `DAC_OVERRIDE` for the root writes into the game-owned volume (including
  the overlay upper directory), and `SETUID`/`SETGID` to drop to the game user
- keep the game process unprivileged: it receives no capabilities, and
  `CHOWN` only applies to the overlay mount created by the entrypoint
- after startup the entrypoint continues as the game user
- keep `no-new-privileges:true`
- pass only the DRM nodes the encoder needs: on NVIDIA the primary card node
  plus `RENDER_NODE`; on AMD/Intel only the render node
- do not mount the host Wayland/X11 sockets
- keep `/dev/uinput` out of the container

## Limitations

- One active game per session at a time; separate sessions can run in parallel.
- Apollo Linux has no Windows-style virtual display; Sway provides it.
- HDR is not implemented in this scaffold.
- mDNS is not configured. Pair manually through the Apollo web UI, or add the
  host Avahi socket to the container.
- gamescope adds a second compositor. Disable it if latency or frame pacing is
  worse.
- Docker AppArmor may block the overlay mount; test or install a custom
  profile.
- Multi-touch does not reach the game: gamescope 3.17 has no EIS touch
  capability.

## Validation checklist

```bash
# inside container
ls -l /dev/dri
swaymsg -t get_outputs
vulkaninfo --summary
ffmpeg -hide_banner -encoders | grep nvenc
```

Expected:

- `HEADLESS-1` at 1920x1080@144
- `RENDER_NODE` and, on NVIDIA, the primary card node
- Apollo logs show `Screencasting with Wayland's protocol`
- host session remains usable while streaming
