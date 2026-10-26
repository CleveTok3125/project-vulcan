# syntax=docker/dockerfile:1

# Arch is used because Hyprland, gamescope and umu-launcher are current there.
# Pin the base image digest before publishing a reproducible build.
FROM archlinux:base

ARG GPU_VENDOR=nvidia
ARG INSTALL_CUDA=1
ARG APOLLO_PKG=apollo

RUN pacman -Syu --noconfirm --needed \
        base-devel \
        git \
        sudo \
        dbus \
        gettext \
        jq \
        python \
        tini \
        util-linux \
        seatd \
        hyprland \
        xorg-xwayland \
        mesa \
        vulkan-icd-loader \
        vulkan-tools \
        libva \
        libva-utils \
        ffmpeg \
        gamescope \
        umu-launcher \
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
    fi \
    && pacman -Scc --noconfirm

# AUR packages cannot be built by root.
RUN useradd -m -u 1001 builder \
    && printf 'builder ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/builder \
    && chmod 0440 /etc/sudoers.d/builder

USER builder
WORKDIR /home/builder
RUN git clone --depth 1 "https://aur.archlinux.org/${APOLLO_PKG}.git" "/home/builder/${APOLLO_PKG}" \
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

COPY config/hypr /config/hypr
COPY config/apollo /config/apollo
COPY scripts /usr/local/bin

RUN chmod 0755 /usr/local/bin/*.sh /usr/local/bin/input-broker.py \
    && chmod 0644 /config/hypr/hyprland.lua.in /config/apollo/*

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
