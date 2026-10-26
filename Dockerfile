# syntax=docker/dockerfile:1

# Arch is used because Sway and gamescope are current there.
# Pin the base image digest before publishing a reproducible build.
FROM archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

ARG GPU_VENDOR=nvidia
ARG INSTALL_CUDA=1
ARG APOLLO_PKG=apollo

RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    --mount=type=cache,target=/var/lib/pacman/sync,sharing=locked \
    pacman -Syu --noconfirm --needed \
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
        libcap \
        xorg-xwayland \
        mesa \
        vulkan-icd-loader \
        vulkan-tools \
        libva \
        libva-utils \
        ffmpeg \
        gamescope \
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
    && if [ "$GPU_VENDOR" = "nvidia" ]; then \
        pacman -S --noconfirm --needed nvidia-utils; \
        if [ "$INSTALL_CUDA" = "1" ]; then pacman -S --noconfirm --needed cuda; fi; \
    else \
        pacman -S --noconfirm --needed vulkan-radeon libva-mesa-driver; \
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
    && makepkg -si --noconfirm

USER root
WORKDIR /

RUN groupadd -f uinput \
    && groupadd -f seat \
    && groupadd -f -g 1000 game \
    && useradd -m -u 1000 -g game \
        -G seat,video,render,input,uinput \
        -s /bin/bash game

RUN mkdir -p /config/apollo /data /games/zzz /games-ro/zzz \
    && chown -R 1000:1000 /data /games

COPY config/sway /config/sway
COPY config/apollo /config/apollo
COPY assets /usr/share/vulcan
COPY scripts /usr/local/bin
COPY scripts/glycin-nosandbox.c /tmp/glycin-nosandbox.c

RUN gcc -O2 -shared -fPIC -o /usr/lib/libglycin-nosandbox.so /tmp/glycin-nosandbox.c -ldl \
    && rm -f /tmp/glycin-nosandbox.c \
    && chmod 0755 /usr/local/bin/*.sh /usr/local/bin/input-broker.py /usr/local/bin/input-bridge.py \
    && chmod 0644 /config/sway/config.in /config/apollo/* /usr/share/vulcan/wallpaper.png \
    && setcap -r /usr/bin/sway \
    && setcap -r /usr/bin/btop

ENTRYPOINT ["/usr/bin/catatonit", "--", "/usr/local/bin/entrypoint.sh"]
