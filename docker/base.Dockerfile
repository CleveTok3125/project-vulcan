# syntax=docker/dockerfile:1
# Shared environment image for every preset on the host.
#
# It carries the packages and the game user that do not depend on the game, the
# GPU vendor, or the Apollo revision, so those changes only rebuild the game
# image on top of this one.
#
# Pin the base image digest before publishing a reproducible build.
FROM cachyos/cachyos-v3@sha256:91d3b3f4db6016ca308765122d4c02049c39068ae37c509365047fa2c02d9af5

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

# Refresh the databases after the mirror change so package URLs match the
# rated mirror instead of the image's original one. The list also carries the
# Apollo runtime dependencies, so installing the built package needs no
# download.
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pacman -Syyu --noconfirm --needed --disable-download-timeout \
        base-devel \
        git \
        sudo \
        dbus \
        gettext \
        jq \
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
        libx11 \
        libxtst \
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
        adwaita-fonts \
        adwaita-icon-theme \
        adwaita-icon-theme-legacy \
        at-spi2-core \
        duktape \
        glib-networking \
        gsettings-desktop-schemas \
        gsettings-system-schemas \
        gtk-update-icon-cache \
        gtk3 \
        iso-codes \
        json-glib \
        libayatana-appindicator \
        libcloudproviders \
        libcolord \
        libcups \
        libdbusmenu-glib \
        libdbusmenu-gtk3 \
        libnotify \
        libproxy \
        libsoup3 \
        libstemmer \
        libxinerama \
        miniupnpc \
        numactl \
        tinysparql \
        xorg-xprop

# shared-mime-info is already present in the base image, so its install hook
# never ran and gio cannot name a single file type. Image loaders reject every
# file while that database is missing.
RUN update-mime-database /usr/share/mime \
    && test -f /usr/share/mime/magic

# aria2 fetches the large packages listed by the build stages into the pacman
# cache; pacman downloads everything else with its default downloader.
COPY docker/fetch-heavy /usr/local/bin/fetch-heavy

RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pacman -S --noconfirm --needed --disable-download-timeout aria2 \
    && chmod 0755 /usr/local/bin/fetch-heavy

# The game user and the groups it joins are identical for every preset.
RUN groupadd -f seat \
    && groupadd -f -g 1000 game \
    && useradd -m -u 1000 -g game \
        -G seat,video,render,input \
        -s /bin/bash game
