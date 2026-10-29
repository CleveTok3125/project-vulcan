# syntax=docker/dockerfile:1
# Game image: the shared base image plus the vendor, Apollo, and session parts.
#
# The base image is built once per host from docker/base.Dockerfile, so a
# change here rebuilds only the stages it touches.
ARG BASE_IMAGE=vulcan/base:local

FROM ${BASE_IMAGE} AS game-base

ARG GPU_VENDOR=nvidia

RUN if [ "$GPU_VENDOR" = "nvidia" ]; then \
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
    sudo pacman -Sy --noconfirm --needed cuda \
    && git clone --depth 1 "https://aur.archlinux.org/${APOLLO_PKG}.git" "/home/builder/${APOLLO_PKG}" \
    && cd "/home/builder/${APOLLO_PKG}" \
    && if [ "$APOLLO_PKG" = "apollo-git" ]; then \
         sed -i "s|^: \${_commit=}|: \${_commit=${APOLLO_COMMIT}}|" PKGBUILD; \
       fi \
    && makepkg -s --noconfirm

FROM ${BASE_IMAGE} AS native-builder

COPY native /src
RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pacman -S --noconfirm --needed --disable-download-timeout mingw-w64-gcc \
    && mkdir -p /out \
    && x86_64-w64-mingw32-gcc -shared -O2 \
        -o /out/xinput1_4.dll \
        /src/xinput1_4.c /src/xinput1_4.def \
        -Wl,--no-insert-timestamp \
    && gcc -O2 -shared -fPIC -o /out/libglycin-nosandbox.so /src/glycin-nosandbox.c -ldl \
    && gcc -O2 -shared -fPIC -o /out/libvulcan-input-grab.so /src/input-grab.c -ldl

FROM ${BASE_IMAGE} AS rust-builder

RUN --mount=type=cache,target=/var/cache/pacman/pkg,sharing=locked \
    pacman -S --noconfirm --needed --disable-download-timeout rust

COPY rust /build
WORKDIR /build
RUN --mount=type=cache,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,target=/root/.cargo/git,sharing=locked \
    cargo build --release --locked

FROM game-base

COPY --from=apollo-builder /home/builder/apollo-git/*.pkg.tar.zst /tmp/apollo/
RUN pacman -U --noconfirm /tmp/apollo/*.pkg.tar.zst && rm -rf /tmp/apollo

COPY --from=native-builder /out/xinput1_4.dll /usr/lib/vulcan/xinput1_4.dll
COPY --from=native-builder /out/libglycin-nosandbox.so /usr/lib/libglycin-nosandbox.so
COPY --from=native-builder /out/libvulcan-input-grab.so /usr/lib/libvulcan-input-grab.so

COPY --from=rust-builder /build/target/release/libvulcan_uinput_shim.so /usr/lib/libvulcan_uinput_shim.so
COPY --from=rust-builder /build/target/release/vulcan-inputd /usr/local/bin/vulcan-inputd
COPY --from=rust-builder /build/target/release/vulcan-input-broker /usr/local/bin/vulcan-input-broker
COPY --from=rust-builder /build/target/release/vulcan-input-bridge /usr/local/bin/vulcan-input-bridge

RUN mkdir -p /config/apollo /data /games /games-ro \
    && chown -R 1000:1000 /data /games

COPY config/sway /config/sway
COPY config/apollo /config/apollo
COPY assets /usr/share/vulcan
COPY scripts /usr/local/bin

# setcap -r exits non-zero when the file carries no capability. A package built
# without file capabilities is already in the desired state.
RUN chmod 0755 \
        /usr/lib/libvulcan-input-grab.so \
        /usr/local/bin/*.sh \
        /usr/local/bin/vulcan-inputd \
        /usr/local/bin/vulcan-input-broker \
        /usr/local/bin/vulcan-input-bridge \
    && chmod 0644 \
        /usr/lib/vulcan/xinput1_4.dll \
        /config/sway/config.in \
        /config/apollo/* \
        /usr/share/vulcan/wallpaper.png \
    && { setcap -r /usr/bin/sway || true; } \
    && { setcap -r /usr/bin/btop || true; }

# Tools run inside the container (btop, git, editors) need a UTF-8 charset;
# glibc provides C.UTF-8 without generated locale files.
ENV LANG=C.UTF-8

ENTRYPOINT ["/usr/bin/catatonit", "--", "/usr/local/bin/entrypoint.sh"]
