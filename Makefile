SHELL := /bin/bash
# Select one preset or a colon-separated list of presets:
#   make up P=.env.multi
#   make up P=".env.multi:.env.other"
# PRESET and PRESETS still work for existing scripts.
space := $(subst ,, )
P_EXPLICIT :=
ifeq ($(origin P),undefined)
  ifneq ($(strip $(PRESETS)),)
    $(warning PRESETS is deprecated; use P="a:b")
    P_EXPLICIT := 1
    P := $(PRESETS)
  else ifneq ($(strip $(PRESET)),)
    $(warning PRESET is deprecated; use P=<path>)
    P_EXPLICIT := 1
    P := $(PRESET)
  endif
endif
P ?= .env.local
P_LIST = $(subst :, ,$(P))
P_COUNT = $(words $(P_LIST))
P_SINGLE = $(firstword $(P_LIST))
VOLUMES_P := $(if $(or $(P_EXPLICIT),$(filter command line environment,$(origin P))),$(P_LIST),)
# P is only a selector; do not leak it into every recipe environment.
unexport P

ifneq ($(findstring $(space),$(strip $(P))),)
$(error P takes colon-separated paths without spaces)
endif

ifeq ($(P_COUNT),1)
-include $(P_SINGLE)
endif

# Build inputs; keep the defaults in sync with the build args in compose.yaml.
GPU_VENDOR ?= nvidia
APOLLO_PKG ?= apollo-git
APOLLO_COMMIT ?= adc5c5a0bd80831ce495434bb16aee2cd4175fb8
MIRROR_COUNTRY ?=
OBS_VKCAPTURE_REF ?= v1.5.6
GAMES_CATALOG ?= games.yaml
AUDIO_RUNTIME_DIR ?= $(if $(XDG_RUNTIME_DIR),$(XDG_RUNTIME_DIR),/run/user/$(shell id -u))/vulcan/$(SESSION_ID)
AUDIO_LATENCY_MSEC ?= 60
YQ ?= yq
GAMES_OUTPUT_DIR := .generated
GAMES_COMPOSE := $(GAMES_OUTPUT_DIR)/compose.games.yaml

# The shared environment image is built once per host; the game image adds the
# vendor packages, Apollo, and the session parts on top of it.
BASE_DOCKERFILE := docker/base.Dockerfile
# The base tag follows everything copied into the base image, so a change to
# the downloader or its package list rebuilds the base.
BASE_INPUTS := $(BASE_DOCKERFILE) docker/fetch-heavy
BASE_HASH := $(shell cat $(BASE_INPUTS) | sha256sum | cut -c1-12)
BASE_TAG := local-$(shell printf '%s|%s' "$(MIRROR_COUNTRY)" "$(BASE_HASH)" | sha256sum | cut -c1-12)
BASE_IMAGE := vulcan/base:$(BASE_TAG)
export BASE_IMAGE

# One image per build variant, so a preset never overwrites the image another
# preset runs on.
IMAGE_TAG := local-$(shell printf '%s' '$(BASE_TAG)|$(GPU_VENDOR)|$(APOLLO_PKG)|$(APOLLO_COMMIT)|$(OBS_VKCAPTURE_REF)' | sha256sum | cut -c1-12)
IMAGE := vulcan/game-stream:$(IMAGE_TAG)
export IMAGE_TAG

# The NVIDIA override exposes host driver nodes that do not exist on AMD/Intel.
COMPOSE_NVIDIA := $(if $(filter nvidia,$(GPU_VENDOR)),-f compose.nvidia.yaml,)
COMPOSE = AUDIO_RUNTIME_DIR="$(AUDIO_RUNTIME_DIR)" docker compose --env-file $(P_SINGLE) -f compose.yaml $(COMPOSE_NVIDIA) -f $(GAMES_COMPOSE)
CONTAINER := vulcan-$(SESSION_ID)
VOLUME := vulcan_$(SESSION_ID)-data

# The help tag on a target is the single source of truth for its preset scope:
#   [global]  needs no preset
#   [preset]  needs exactly one preset
#   [presets] accepts one or more presets
#
# A [presets] target still declares `_check-presets` itself; deriving that
# prerequisite from the tag would let a mistyped tag turn a group target into a
# loop over an empty list, which exits successfully without doing anything.
#
# The description marker is held in a variable because make ends a line at an
# unescaped `#`, even inside a $(shell) argument.
HELP_MARK := \#\#
HELP_TARGETS := $(shell grep -hE "^[a-zA-Z0-9_-]+:.*$(HELP_MARK) " $(MAKEFILE_LIST) | cut -d: -f1)
SINGLE_TARGETS := $(shell grep -hoE "^[a-zA-Z0-9_-]+:.*$(HELP_MARK) \[preset\] " $(MAKEFILE_LIST) | cut -d: -f1)
LIST_TARGETS := $(shell grep -hoE "^[a-zA-Z0-9_-]+:.*$(HELP_MARK) \[presets\] " $(MAKEFILE_LIST) | cut -d: -f1)
GLOBAL_TARGETS := $(shell grep -hoE "^[a-zA-Z0-9_-]+:.*$(HELP_MARK) \[global\] " $(MAKEFILE_LIST) | cut -d: -f1)
ALIAS_TARGETS := build-all up-all restart-all stop-all down-all ps-all stats-all uninstall-all
SESSION_TARGETS := $(SINGLE_TARGETS) $(LIST_TARGETS) $(ALIAS_TARGETS)
UNTAGGED_TARGETS := $(filter-out $(SINGLE_TARGETS) $(LIST_TARGETS) $(GLOBAL_TARGETS),$(HELP_TARGETS))
ifneq ($(UNTAGGED_TARGETS),)
$(error help targets need a [global], [preset], or [presets] tag: $(UNTAGGED_TARGETS))
endif

# Show the selection once per invocation; the group recipe reports each preset
# from its own loop.
ifeq ($(MAKELEVEL),0)
ifneq ($(filter $(SESSION_TARGETS),$(MAKECMDGOALS)),)
$(info [vulcan] P=$(P))
endif
endif

.DEFAULT_GOAL := help

.PHONY: help base base-rebuild rm-base images volume volumes _volume-name build up rebuild _recreate stop down restart logs ps up-all down-all stop-all restart-all ps-all build-all stats-all uninstall-all check-ports ports _check-presets _check-ports _games-config _audio-runtime audio-up audio-down audio-status config clean-logs clean-overlay clean-appdata clean-all _clean-session uninstall stats usage btop nvtop shell watch

# The table keeps the file order of the targets inside each section. A `# ---`
# line between blocks starts a new group, which the table separates with a blank
# line.
help: ## [global] Show available targets
	@printf 'P=%s\n' '$(P)'
	@printf '\n'
	@awk 'BEGIN { FS = ":.*## " ; split("global preset presets", scope_order, " ") ; \
		title["global"] = "Shared (no preset)" ; \
		title["preset"] = "Exactly one preset (P=<path>)" ; \
		title["presets"] = "One or more presets (P=<a>[:<b>])" } \
	/^# ---$$/ { pending_break = 1 ; next } \
	/^[a-zA-Z0-9_-]+:.*## \[[a-z]+\] / { \
		scope = $$2 ; sub(/^\[/, "", scope) ; sub(/\].*/, "", scope) ; \
		description = $$2 ; sub(/^\[[a-z]+\] /, "", description) ; \
		if (pending_break && (scope in rows)) rows[scope] = rows[scope] "\n" ; \
		pending_break = 0 ; \
		rows[scope] = rows[scope] sprintf("  %-14s %s\n", $$1, description) } \
	END { first = 1 ; \
		for (i = 1; i <= 3; i++) { scope = scope_order[i] ; \
			if (!(scope in rows)) continue ; \
			if (!first) printf "\n" ; \
			first = 0 ; \
			printf "%s:\n%s", title[scope], rows[scope] } }' $(MAKEFILE_LIST)
	@printf '\nP defaults to .env.local.\n'
	@printf 'P takes colon-separated paths without spaces: P=".env.multi:.env.other".\n'
	@printf 'Destructive targets (base-rebuild, uninstall) require CONFIRM=1.\n'

# ---
base: ## [global] Build the shared environment image for this host
	@docker image inspect $(BASE_IMAGE) >/dev/null 2>&1 || \
		docker build -f $(BASE_DOCKERFILE) \
			--build-arg MIRROR_COUNTRY="$(MIRROR_COUNTRY)" \
			-t $(BASE_IMAGE) .

base-rebuild: ## [global] Rebuild the shared base image without cache
	@test "$(CONFIRM)" = "1" || { printf '%s\n' 'Refusing rebuild: run make base-rebuild CONFIRM=1'; exit 1; }
	docker build --no-cache \
		-f $(BASE_DOCKERFILE) \
		--build-arg MIRROR_COUNTRY="$(MIRROR_COUNTRY)" \
		-t $(BASE_IMAGE) .

rm-base: ## [global] Remove the base image
	@images=$$(docker images --format '{{.Repository}}:{{.Tag}}' vulcan/base); \
	if [ -z "$$images" ]; then printf 'no base image\n'; exit 0; fi; \
	for image in $$images; do docker rmi "$$image" || exit 1; done

# ---
images: ## [global] List the Vulcan images
	@docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' \
		| awk 'NR == 1 || /^vulcan\//'

volumes: ## [global] List the Vulcan volumes
	@names=""; \
	if [ -n "$(VOLUMES_P)" ]; then \
		for preset in $(VOLUMES_P); do \
			names="$$names $$($(MAKE) -s --no-print-directory _volume-name P="$$preset")"; \
		done; \
	else \
		names=$$(docker volume ls --format '{{.Name}}' --filter name=vulcan_); \
	fi; \
	sizes=$$(docker system df -v | awk '$$1 ~ /^vulcan_/ {print $$1" "$$3}'); \
	printf '%-28s %s\n' VOLUME SIZE; \
	for name in $$names; do \
		size=$$(printf '%s\n' "$$sizes" | awk -v n="$$name" '$$1 == n {print $$2}'); \
		[ -n "$$size" ] || size='(missing)'; \
		printf '%-28s %s\n' "$$name" "$$size"; \
	done

# ---
build: _check-presets _games-config _audio-runtime base ## [presets] Build the container image
ifeq ($(P_COUNT),1)
	$(COMPOSE) build
else
	@for preset in $(P_LIST); do \
		printf '[vulcan] P=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory build P="$$preset" || exit 1; \
	done
endif

rebuild: build _recreate ## [presets] Rebuild the image and recreate the container

_recreate: _check-presets _games-config _audio-runtime
ifeq ($(P_COUNT),1)
	$(COMPOSE) up -d --force-recreate
else
	@for preset in $(P_LIST); do \
		printf '[vulcan] P=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory _recreate P="$$preset" || exit 1; \
	done
endif

up: _check-presets _check-ports _games-config _audio-runtime ## [presets] Start the container in the background
ifeq ($(P_COUNT),1)
	$(COMPOSE) up -d
else
	@for preset in $(P_LIST); do \
		printf '[vulcan] P=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory up P="$$preset" || exit 1; \
	done
endif

restart: _check-presets _check-ports _games-config ## [presets] Restart the container
ifeq ($(P_COUNT),1)
	$(COMPOSE) restart
else
	@for preset in $(P_LIST); do \
		printf '[vulcan] P=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory restart P="$$preset" || exit 1; \
	done
endif

stop: _check-presets _games-config _audio-teardown ## [presets] Stop the running container
ifeq ($(P_COUNT),1)
	$(COMPOSE) stop
else
	@for preset in $(P_LIST); do \
		printf '[vulcan] P=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory stop P="$$preset" || exit 1; \
	done
endif

down: _check-presets _games-config _audio-teardown ## [presets] Stop and remove the container; keep named volumes
ifeq ($(P_COUNT),1)
	$(COMPOSE) down
else
	@for preset in $(P_LIST); do \
		printf '[vulcan] P=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory down P="$$preset" || exit 1; \
	done
endif

# ---
logs: _check-presets _games-config ## [preset] Follow container logs
	$(COMPOSE) logs -f --tail=200 game

ps: _check-presets _games-config ## [presets] Show container status
ifeq ($(P_COUNT),1)
	$(COMPOSE) ps
else
	@for preset in $(P_LIST); do \
		printf '[vulcan] P=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory ps P="$$preset" || exit 1; \
	done
endif

stats: _check-presets ## [presets] Show container CPU/memory and NVIDIA GPU usage
ifeq ($(P_COUNT),1)
	@docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' $(CONTAINER)
	@docker exec $(CONTAINER) nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits | awk -F', ' '{printf "GPU: %s%%  VRAM: %s/%s MiB  Temp: %s C\n", $$1, $$2, $$3, $$4}'
else
	@for preset in $(P_LIST); do \
		printf '[vulcan] P=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory stats P="$$preset" || exit 1; \
	done
endif

usage: stats ## [presets] Alias for stats

watch: ## [preset] Refresh container usage every 2 seconds
	@while true; do printf '\033[2J\033[H'; $(MAKE) --no-print-directory stats; sleep 2; done

volume: ## [preset] Show the volume of the selected preset
	@name="$(VOLUME)"; \
	if ! docker volume inspect "$$name" >/dev/null 2>&1; then \
		printf '%s (missing)\n' "$$name"; exit 0; \
	fi; \
	docker volume inspect "$$name" --format 'name={{.Name}} mount={{.Mountpoint}}'; \
	docker volume inspect "$$name" --format 'created={{.CreatedAt}}'; \
	size=$$(docker system df -v | awk -v v="$$name" '$$1 == v {print $$3}'); \
	printf 'size=%s\n' "$${size:-unknown}"

_volume-name:
	@printf '%s\n' '$(VOLUME)'

# ---
btop: ## [preset] Open btop inside the container
	docker exec -it --user 1000 -e HOME=/data/home $(CONTAINER) btop

nvtop: ## [preset] Open nvtop inside the container
	docker exec -it --user 1000 -e HOME=/data/home $(CONTAINER) nvtop

shell: ## [preset] Open a shell with the running session environment
	WAYLAND_SOCKET=$$(docker exec $(CONTAINER) sh -c 'ls /run/user/1000/wayland-? 2>/dev/null | head -n 1'); \
	docker exec -it --user 1000 \
		-e HOME=/data/home \
		-e XDG_RUNTIME_DIR=/run/user/1000 \
		-e XDG_CONFIG_HOME=/data/home/.config \
		-e XDG_CACHE_HOME=/data/home/.cache \
		-e XDG_DATA_HOME=/data/home/.local/share \
		-e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
		-e PULSE_SERVER=unix:/run/user/1000/pulse/native \
		-e WAYLAND_DISPLAY="$${WAYLAND_SOCKET##*/}" \
		$(CONTAINER) bash

config: _check-presets _games-config _audio-runtime ## [preset] Validate and print the resolved compose config
	$(COMPOSE) config

# ---
CLEAN_LOGS := /data/log/*
CLEAN_OVERLAY := /data/overlay/*/upper/* /data/overlay/*/work/* /data/prefix/*/.vulcan-reset-paths
CLEAN_APPDATA := /data/prefix/*/drive_c/users/*/AppData

clean-logs: ## [preset] Remove the session logs
clean-logs: CLEAN_PATHS := $(CLEAN_LOGS)
clean-logs: _clean-session

clean-overlay: ## [preset] Remove the game overlay and reset marker
clean-overlay: CLEAN_PATHS := $(CLEAN_OVERLAY)
clean-overlay: _clean-session

clean-appdata: ## [preset] Remove the prefix AppData
clean-appdata: CLEAN_PATHS := $(CLEAN_APPDATA)
clean-appdata: _clean-session

clean-all: ## [preset] Remove logs, overlay, reset marker, and prefix AppData
clean-all: CLEAN_PATHS := $(CLEAN_LOGS) $(CLEAN_OVERLAY) $(CLEAN_APPDATA)
clean-all: _clean-session

_clean-session: _check-presets _games-config
	@set -f; printf '[vulcan] removing:\n'; printf '  %s\n' $(CLEAN_PATHS)
	$(COMPOSE) down
	docker run --rm -v $(VOLUME):/data --entrypoint sh $(IMAGE) -c 'set -e; rm -rf $(CLEAN_PATHS)'
	$(COMPOSE) up -d

# ---
uninstall: _check-presets _games-config _audio-teardown ## [presets] Remove the container, its data, and the image
	@test "$(CONFIRM)" = "1" || { printf '%s\n' 'Refusing uninstall: run make uninstall CONFIRM=1'; exit 1; }
ifeq ($(P_COUNT),1)
	$(COMPOSE) down -v
	@rm -rf "$(AUDIO_RUNTIME_DIR)/pulse" "$(AUDIO_RUNTIME_DIR)/obs-audio.err"
	@rmdir "$(AUDIO_RUNTIME_DIR)" 2>/dev/null || true
	@if docker image inspect $(IMAGE) >/dev/null 2>&1; then \
		docker rmi $(IMAGE) 2>/dev/null || \
			printf '[vulcan] image %s is still used by another container; leaving it\n' '$(IMAGE)' >&2; \
	else \
		printf 'image %s is already absent\n' '$(IMAGE)'; \
	fi
else
	@for preset in $(P_LIST); do \
		printf '[vulcan] P=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory uninstall CONFIRM=1 P="$$preset" || exit 1; \
	done
endif

# Deprecated aliases: the base targets accept one or more presets.
build-all: build
up-all: up
restart-all: restart
stop-all: stop
down-all: down
ps-all: ps
stats-all: stats
uninstall-all: uninstall

check-ports: _check-ports ## [presets] Check that Apollo port ranges do not overlap

ports: _check-presets ## [presets] Show the Apollo ports for every listed preset
	@scripts/show-ports.sh $(P_LIST)

_check-presets:
	@test -n "$(strip $(P))" || { printf '%s\n' 'set P to a preset or a colon-separated list' >&2; exit 1; }
	@for preset in $(P_LIST); do \
		test -f "$$preset" || { printf 'missing preset: %s\n' "$$preset" >&2; exit 1; }; \
	done
	@if [ "$(P_COUNT)" -eq 1 ]; then \
		test -f "$(GAMES_CATALOG)" || { printf 'missing game catalog: %s\n' "$(GAMES_CATALOG)" >&2; exit 1; }; \
	fi

_games-config:
ifeq ($(P_COUNT),1)
	@YQ="$(YQ)" scripts/generate-games-config.sh "$(GAMES_CATALOG)" "$(GAMES_OUTPUT_DIR)"
else
	@:
endif

_audio-runtime:
ifeq ($(P_COUNT),1)
	@if [ -d "$(AUDIO_RUNTIME_DIR)" ]; then 		test -w "$(AUDIO_RUNTIME_DIR)" || { 			printf 'audio runtime is not writable: %s\n' "$(AUDIO_RUNTIME_DIR)" >&2; 			exit 1; 		}; 	else 		install -d -m 0700 "$(AUDIO_RUNTIME_DIR)"; 	fi
else
	@:
endif

audio-up: _check-presets _audio-runtime ## [preset] Expose the session audio to host OBS
	@AUDIO_SOURCE="$(AUDIO_SOURCE)" AUDIO_LATENCY_MSEC="$(AUDIO_LATENCY_MSEC)" scripts/obs-audio.sh up "$(AUDIO_RUNTIME_DIR)" "$(SESSION_ID)"

audio-down: _check-presets ## [preset] Remove the session audio tunnel
	@scripts/obs-audio.sh down "$(AUDIO_RUNTIME_DIR)" "$(SESSION_ID)"

audio-status: _check-presets ## [preset] Show the session audio tunnel
	@scripts/obs-audio.sh status "$(AUDIO_RUNTIME_DIR)" "$(SESSION_ID)"

_audio-teardown:
ifeq ($(P_COUNT),1)
	@scripts/obs-audio.sh down "$(AUDIO_RUNTIME_DIR)" "$(SESSION_ID)" || true
else
	@:
endif

_check-ports: _check-presets
	@scripts/check-ports.sh $(P_LIST)

# Targets tagged [preset] need exactly one preset; [presets] targets accept a
# list and validate each entry themselves.
KNOWN_TARGETS := $(shell grep -hoE '^[a-zA-Z0-9_-]+:' $(MAKEFILE_LIST) | tr -d ':')
CONFIG_GOALS := $(filter $(SESSION_TARGETS),$(filter $(KNOWN_TARGETS),$(MAKECMDGOALS)))
ifneq ($(CONFIG_GOALS),)
ifeq ($(P_COUNT),0)
$(error set P to a preset path or a colon-separated list)
endif
ifneq ($(filter $(SINGLE_TARGETS),$(MAKECMDGOALS)),)
ifneq ($(P_COUNT),1)
$(error $(filter $(SINGLE_TARGETS),$(MAKECMDGOALS)) needs exactly one preset in P)
endif
endif
P_MISSING := $(strip $(filter-out $(wildcard $(P_LIST)),$(P_LIST)))
ifneq ($(P_MISSING),)
$(error preset $(P_MISSING) does not exist: set P=<path>)
endif
ifeq ($(P_COUNT),1)
ifeq ($(strip $(SESSION_ID)),)
$(error preset $(P_SINGLE) does not define SESSION_ID)
endif
endif
endif
