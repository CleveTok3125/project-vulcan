# syntax=docker/dockerfile:1
# Game image: the shared base image plus the vendor, Apollo, and session parts.
#
# The base image is built once per host from docker/base.Dockerfile, so a
# change here rebuilds only the stages it touches.
ARG BASE_IMAGE=vulcan/base:local

FROM ${BASE_IMAGE} AS game-base

ARG GPU_VENDOR=nvidia

RUN if [ "$GPU_VENDOR" = "nvidia" ]; then \
        /usr/local/bin/fetch-heavy nvidia-utils; \
        pacman -S --noconfirm --needed --disable-download-timeout nvidia-utils; \
    else \
        pacman -S --noconfirm --needed --disable-download-timeout vulkan-radeon libva-mesa-driver; \
    fi

FROM ${BASE_IMAGE} AS apollo-builder

ARG APOLLO_PKG=apollo-git
ARG APOLLO_COMMIT=adc5c5a0bd80831ce495434bb16aee2cd4175fb8

# AUR packages cannot be built by root.
RUN useradd -m -u 1001 builder \
    && printf 'builder ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/builder \
    && chmod 0440 /etc/sudoers.d/builder

USER builder
WORKDIR /home/builder

# apollo-git builds its CUDA frame conversion path only when the cuda package
# is installed. Without it nvenc initializes but the encoder test fails with
# "Couldn't scale frame: Invalid argument" and Apollo falls back to libx264.
# The toolkit stays in this stage; the game image only receives the package.
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    sudo pacman -Sy --noconfirm --needed \
    && sudo /usr/local/bin/fetch-heavy cuda \
    && sudo pacman -S --noconfirm --needed --disable-download-timeout cuda \
    && git clone --depth 1 "https://aur.archlinux.org/${APOLLO_PKG}.git" "/home/builder/${APOLLO_PKG}" \
    && cd "/home/builder/${APOLLO_PKG}" \
    && if [ "$APOLLO_PKG" = "apollo-git" ]; then \
         sed -i "s|^: \${_commit=}|: \${_commit=${APOLLO_COMMIT}}|" PKGBUILD; \
       fi \
    && makepkg -s --noconfirm

FROM ${BASE_IMAGE} AS native-builder

COPY native /src
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    /usr/local/bin/fetch-heavy mingw-w64-gcc \
    && pacman -S --noconfirm --needed --disable-download-timeout mingw-w64-gcc \
    && mkdir -p /out/x86_64 /out/i686 \
    && x86_64-w64-mingw32-gcc -shared -O2 -Wall -Wextra -Werror \
        -o /out/x86_64/xinput1_4.dll \
        /src/xinput1_4.c /src/xinput1_4.def \
        -Wl,--no-insert-timestamp \
    && i686-w64-mingw32-gcc -shared -O2 -Wall -Wextra -Werror \
        -o /out/i686/xinput1_4.dll \
        /src/xinput1_4.c /src/xinput1_4.def \
        -Wl,--no-insert-timestamp \
    && x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Werror \
        -o /out/x86_64/probe.exe /src/xinput_probe.c \
    && i686-w64-mingw32-gcc -O2 -Wall -Wextra -Werror \
        -o /out/i686/probe.exe /src/xinput_probe.c \
    && for arch in x86_64 i686; do \
        objdump="${arch}-w64-mingw32-objdump"; \
        "$objdump" -p "/out/${arch}/xinput1_4.dll" > "/tmp/${arch}-exports.txt"; \
        grep -q '[+]base' "/tmp/${arch}-exports.txt" \
            || { printf 'unexpected objdump export format for %s\n' "$arch" >&2; exit 1; }; \
        sed -n 's/.*[+]base\[ *[0-9]*\] *[0-9]* *//p' "/tmp/${arch}-exports.txt" \
            > "/tmp/${arch}-names.txt"; \
        for name in XInputGetState XInputSetState XInputGetCapabilities XInputEnable \
                    XInputGetBatteryInformation XInputGetKeystroke XInputGetAudioDeviceIds \
                    XInputGetStateEx XInputGetCapabilitiesEx; do \
            grep -qx "$name" "/tmp/${arch}-names.txt" \
                || { printf 'missing export %s for %s\n' "$name" "$arch" >&2; exit 1; }; \
        done; \
        sed -n 's/.*[+]base\[ *100\] *[0-9]* *//p' "/tmp/${arch}-exports.txt" \
            | grep -qx 'XInputGetStateEx' \
            || { printf 'ordinal 100 is not XInputGetStateEx for %s\n' "$arch" >&2; exit 1; }; \
        sed -n 's/.*[+]base\[ *108\] *[0-9]* *//p' "/tmp/${arch}-exports.txt" \
            | grep -qx 'XInputGetCapabilitiesEx' \
            || { printf 'ordinal 108 is not XInputGetCapabilitiesEx for %s\n' "$arch" >&2; exit 1; }; \
    done

# wbg draws the wallpaper without gdk-pixbuf, so no image loader is spawned
# through glycin and no bubblewrap sandbox is required at runtime.
FROM ${BASE_IMAGE} AS wbg-builder

ARG WBG_VERSION=1.3.0
ARG WBG_SHA256=5e23555c599e58f8fc76f2f8a697149c9fe96702a337a3e0457d503becb307a5

RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pacman -S --noconfirm --needed --disable-download-timeout \
        meson ninja tllist \
    && curl -fsSLo /tmp/wbg.tar.gz \
        "https://codeberg.org/dnkl/wbg/releases/download/${WBG_VERSION}/wbg-${WBG_VERSION}.tar.gz" \
    && printf '%s  %s\n' "$WBG_SHA256" /tmp/wbg.tar.gz | sha256sum -c - \
    && tar -xzf /tmp/wbg.tar.gz -C /tmp \
    && meson setup /tmp/wbg-build "/tmp/wbg-${WBG_VERSION}" \
        --buildtype=release \
        --prefix=/usr \
        -Dpng=enabled \
        -Djpeg=disabled \
        -Dwebp=disabled \
        -Djxl=disabled \
        -Dsvg=false \
    && ninja -C /tmp/wbg-build \
    && install -Dm0755 /tmp/wbg-build/wbg /out/wbg

FROM ${BASE_IMAGE} AS rust-builder

RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pacman -S --noconfirm --needed --disable-download-timeout rust

COPY rust /build
WORKDIR /build
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/root/.cargo/git,sharing=locked \
    cargo build --release --locked
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/root/.cargo/git,sharing=locked \
    cargo test --release --locked

# Runs the probe under the Wine already present in the base image. Only the
# native-builder stage and this stage are built; the game image never copies
# the probes. Enable it with XINPUT_RUNTIME_TEST=1.
FROM ${BASE_IMAGE} AS xinput-test

COPY --from=native-builder /out /out
ARG XINPUT_RUNTIME_TEST=0

RUN if [ "$XINPUT_RUNTIME_TEST" != "1" ]; then \
        printf '%s\n' 'xinput runtime tests skipped'; \
    else \
        command -v wine >/dev/null 2>&1 \
            || { printf '%s\n' 'wine is required for the xinput runtime tests' >&2; exit 1; }; \
        export WINEDEBUG=-all DISPLAY= XDG_RUNTIME_DIR=/tmp \
            WINEDLLOVERRIDES='xinput1_4,xinput1_3,xinput9_1_0=n'; \
        for arch in x86_64 i686; do \
            export WINEPREFIX="/tmp/wine-${arch}"; \
            wineboot --init; \
            wine "/out/${arch}/probe.exe" || exit 1; \
        done; \
    fi

FROM ${BASE_IMAGE} AS vkcapture-builder

# Build only the capture sender. The OBS plugin belongs to the host OBS
# process; pulling obs-studio into the game image would be unnecessary.
ARG OBS_VKCAPTURE_REF=v1.5.6

RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pacman -S --noconfirm --needed --disable-download-timeout cmake vulkan-headers \
    && git clone https://github.com/nowrep/obs-vkcapture /src/obs-vkcapture \
    && git -C /src/obs-vkcapture checkout "$OBS_VKCAPTURE_REF" \
    && cmake -S /src/obs-vkcapture -B /src/obs-vkcapture/build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_PLUGIN=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr \
    && cmake --build /src/obs-vkcapture/build -j"$(nproc)" \
    && DESTDIR=/out cmake --install /src/obs-vkcapture/build

FROM game-base

COPY --from=apollo-builder /home/builder/apollo-git/*.pkg.tar.zst /tmp/apollo/
RUN pacman -U --noconfirm /tmp/apollo/*.pkg.tar.zst && rm -rf /tmp/apollo

COPY --from=native-builder /out/x86_64/xinput1_4.dll /usr/lib/vulcan/xinput1_4.dll
COPY --from=native-builder /out/i686/xinput1_4.dll /usr/lib/vulcan/xinput1_4_32.dll
COPY --from=wbg-builder /out/wbg /usr/local/bin/wbg

COPY --from=rust-builder /build/target/release/libvulcan_uinput_shim.so /usr/lib/libvulcan_uinput_shim.so
COPY --from=rust-builder /build/target/release/vulcan-inputd /usr/local/bin/vulcan-inputd

COPY --from=vkcapture-builder /out/usr/ /usr/

RUN mkdir -p /config/apollo /data /games /games-ro \
    && chown -R 1000:1000 /data /games

COPY config/sway /config/sway
COPY config/apollo /config/apollo
COPY assets /usr/share/vulcan
COPY scripts /usr/local/bin

# setcap -r exits non-zero when the file carries no capability. A package built
# without file capabilities is already in the desired state.
RUN chmod 0755 \
        /usr/local/bin/*.sh \
        /usr/local/bin/vulcan-inputd \
    && chmod 0644 \
        /usr/lib/vulcan/xinput1_4.dll \
        /usr/lib/vulcan/xinput1_4_32.dll \
        /config/sway/config.in \
        /config/apollo/* \
        /usr/share/vulcan/wallpaper.png \
    && { setcap -r /usr/bin/sway || true; } \
    && { setcap -r /usr/bin/btop || true; }

# Tools run inside the container (btop, git, editors) need a UTF-8 charset;
# glibc provides C.UTF-8 without generated locale files.
ENV LANG=C.UTF-8

ENTRYPOINT ["/usr/bin/catatonit", "--", "/usr/local/bin/entrypoint.sh"]
