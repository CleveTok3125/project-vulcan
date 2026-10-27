# syntax=docker/dockerfile:1

# Arch is used because Sway and gamescope are current there.
# Pin the base image digest before publishing a reproducible build.
FROM cachyos/cachyos-v3@sha256:91d3b3f4db6016ca308765122d4c02049c39068ae37c509365047fa2c02d9af5 AS base

# The image ships a fixed mirror list; rate the reachable mirrors once per
# build so package downloads do not stall on a slow or blocked server.
#
# cachyos-rate-mirrors prepends its own CDN to the rated Arch list. Move that
# entry to the end so the fastest rated mirror is tried first and the CDN stays
# as a fallback. MIRROR_COUNTRY skips geo detection when set.
#
# The default 1s speed sample ranks bursts over sustained throughput, so each
# mirror is sampled longer before it is sorted.
ARG MIRROR_COUNTRY=
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pacman -Sy --noconfirm --needed cachyos-rate-mirrors \
    && (RATE_MIRRORS_ENTRY_COUNTRY="${MIRROR_COUNTRY}" \
        RATE_MIRRORS_MIN_PER_MIRROR=1000 \
        RATE_MIRRORS_MAX_PER_MIRROR=3000 \
        RATE_MIRRORS_PER_MIRROR_TIMEOUT=15000 \
        cachyos-rate-mirrors \
        || printf '%s\n' 'Mirror rating failed; keeping the image mirror list.' >&2) \
    && sed -i '/^Server = https:\/\/archlinux\.cachyos\.org\/repo/d' /etc/pacman.d/mirrorlist \
    && printf 'Server = https://archlinux.cachyos.org/repo/$repo/os/$arch\n' >> /etc/pacman.d/mirrorlist

FROM base AS rust-builder
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pacman -Syu --noconfirm --needed --disable-download-timeout rust gcc libei
COPY rust /build
WORKDIR /build
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/root/.cargo/git,sharing=locked \
    cargo build --release --locked

FROM base

ARG GPU_VENDOR=nvidia
ARG INSTALL_CUDA=1
ARG APOLLO_PKG=apollo-git
ARG APOLLO_COMMIT=adc5c5a0bd80831ce495434bb16aee2cd4175fb8

# Refresh the databases after the mirror change so package URLs match the
# rated mirror instead of the image's original one.
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pacman -Syyu --noconfirm --needed --disable-download-timeout \
        base-devel \
        git \
        sudo \
        dbus \
        gettext \
        jq \
        python \
        catatonit \
        util-linux \
        sway \
        adwaita-cursors \
        libcap \
        xorg-xwayland \
        mesa \
        vulkan-icd-loader \
        vulkan-tools \
        libva \
        libva-utils \
        ffmpeg \
        gamescope \
        libei \
        wine-mono \
        swaybg \
        grim \
        btop \
        nvtop \
        pipewire \
        pipewire-pulse \
        wireplumber \
        libinput \
        ffnvcodec-headers \
        mingw-w64-gcc \
    && if [ "$GPU_VENDOR" = "nvidia" ]; then \
        pacman -S --noconfirm --needed --disable-download-timeout nvidia-utils; \
        if [ "$INSTALL_CUDA" = "1" ]; then pacman -S --noconfirm --needed --disable-download-timeout cuda; fi; \
    else \
        pacman -S --noconfirm --needed --disable-download-timeout vulkan-radeon libva-mesa-driver; \
    fi

# AUR packages cannot be built by root.
RUN useradd -m -u 1001 builder \
    && printf 'builder ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/builder \
    && chmod 0440 /etc/sudoers.d/builder

USER builder
WORKDIR /home/builder
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=cache,target=/var/lib/pacman/sync,sharing=locked \
    git clone --depth 1 "https://aur.archlinux.org/${APOLLO_PKG}.git" "/home/builder/${APOLLO_PKG}" \
    && cd "/home/builder/${APOLLO_PKG}" \
    && if [ "$APOLLO_PKG" = "apollo-git" ]; then \
         sed -i "s|^: \${_commit=}|: \${_commit=${APOLLO_COMMIT}}|" PKGBUILD; \
       fi \
    && makepkg -si --noconfirm

USER root
WORKDIR /

RUN groupadd -f seat \
    && groupadd -f -g 1000 game \
    && useradd -m -u 1000 -g game \
        -G seat,video,render,input \
        -s /bin/bash game

RUN mkdir -p /config/apollo /data /games/zzz /games-ro/zzz \
    && chown -R 1000:1000 /data /games

COPY config/sway /config/sway
COPY config/apollo /config/apollo
COPY assets /usr/share/vulcan
COPY scripts /usr/local/bin
COPY native /tmp/native
RUN mkdir -p /usr/lib/vulcan \
    && x86_64-w64-mingw32-gcc -shared -O2 \
        -o /usr/lib/vulcan/xinput1_4.dll \
        /tmp/native/xinput1_4.c /tmp/native/xinput1_4.def \
        -Wl,--no-insert-timestamp \
    && chmod 0644 /usr/lib/vulcan/xinput1_4.dll
COPY --from=rust-builder /build/target/release/libvulcan_uinput_shim.so /usr/lib/libvulcan_uinput_shim.so
COPY --from=rust-builder /build/target/release/vulcan-inputd /usr/local/bin/vulcan-inputd

# setcap -r exits non-zero when the file carries no capability. A package built
# without file capabilities is already in the desired state.
RUN gcc -O2 -shared -fPIC -o /usr/lib/libglycin-nosandbox.so /tmp/native/glycin-nosandbox.c -ldl \
    && gcc -O2 -shared -fPIC -o /usr/lib/libvulcan-input-grab.so /tmp/native/input-grab.c -ldl \
    && rm -rf /tmp/native \
    && chmod 0755 /usr/lib/libvulcan-input-grab.so /usr/local/bin/*.sh /usr/local/bin/input-broker.py /usr/local/bin/input-bridge.py \
    && chmod 0644 /config/sway/config.in /config/apollo/* /usr/share/vulcan/wallpaper.png \
    && { setcap -r /usr/bin/sway || true; } \
    && { setcap -r /usr/bin/btop || true; }

ENTRYPOINT ["/usr/bin/catatonit", "--", "/usr/local/bin/entrypoint.sh"]
