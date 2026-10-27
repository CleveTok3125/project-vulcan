# syntax=docker/dockerfile:1

# Arch is used because Sway and gamescope are current there.
# Pin the base image digest before publishing a reproducible build.
FROM cachyos/cachyos-v3@sha256:91d3b3f4db6016ca308765122d4c02049c39068ae37c509365047fa2c02d9af5 AS rust-builder
RUN pacman -Syu --noconfirm --needed --disable-download-timeout rust gcc libei
COPY rust /build
WORKDIR /build
RUN cargo build --release --locked

FROM cachyos/cachyos-v3@sha256:91d3b3f4db6016ca308765122d4c02049c39068ae37c509365047fa2c02d9af5

ARG GPU_VENDOR=nvidia
ARG INSTALL_CUDA=1
ARG APOLLO_PKG=apollo-git
ARG APOLLO_COMMIT=adc5c5a0bd80831ce495434bb16aee2cd4175fb8

RUN pacman -Syu --noconfirm --needed --disable-download-timeout \
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

RUN gcc -O2 -shared -fPIC -o /usr/lib/libglycin-nosandbox.so /tmp/native/glycin-nosandbox.c -ldl \
    && gcc -O2 -shared -fPIC -o /usr/lib/libvulcan-input-grab.so /tmp/native/input-grab.c -ldl \
    && rm -rf /tmp/native \
    && chmod 0755 /usr/lib/libvulcan-input-grab.so /usr/local/bin/*.sh /usr/local/bin/input-broker.py /usr/local/bin/input-bridge.py \
    && chmod 0644 /config/sway/config.in /config/apollo/* /usr/share/vulcan/wallpaper.png \
    && setcap -r /usr/bin/sway \
    && setcap -r /usr/bin/btop

ENTRYPOINT ["/usr/bin/catatonit", "--", "/usr/local/bin/entrypoint.sh"]
