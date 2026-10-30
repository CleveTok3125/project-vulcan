SHELL := /bin/bash
# Select another configuration preset with `make <target> PRESET=<path>`.
PRESET ?= .env.local
-include $(PRESET)

# Build inputs; keep the defaults in sync with the build args in compose.yaml.
GPU_VENDOR ?= nvidia
APOLLO_PKG ?= apollo-git
APOLLO_COMMIT ?= adc5c5a0bd80831ce495434bb16aee2cd4175fb8
MIRROR_COUNTRY ?=

# The shared environment image is built once per host; the game image adds the
# vendor packages, Apollo, and the session parts on top of it.
BASE_DOCKERFILE := docker/base.Dockerfile
BASE_HASH := $(shell sha256sum $(BASE_DOCKERFILE) | cut -c1-12)
BASE_TAG := local-$(shell printf '%s|%s' "$(MIRROR_COUNTRY)" "$(BASE_HASH)" | sha256sum | cut -c1-12)
BASE_IMAGE := vulcan/base:$(BASE_TAG)
export BASE_IMAGE

# One image per build variant, so a preset never overwrites the image another
# preset runs on.
IMAGE_TAG := local-$(shell printf '%s' '$(BASE_TAG)|$(GPU_VENDOR)|$(APOLLO_PKG)|$(APOLLO_COMMIT)' | sha256sum | cut -c1-12)
IMAGE := vulcan/game-stream:$(IMAGE_TAG)
export IMAGE_TAG

COMPOSE = docker compose --env-file $(PRESET) -f compose.yaml -f compose.nvidia.yaml
CONTAINER := vulcan-$(GAME_ID)
VOLUME := vulcan_$(GAME_ID)-data

# The help tag on a target is the single source of truth for its preset scope:
#   [global]  needs no preset
#   [preset]  acts on the preset in PRESET
#   [presets] acts on the colon-separated list in PRESETS
#
# A [presets] target still declares `_check-presets` itself; deriving that
# prerequisite from the tag would let a mistyped tag turn a group target into a
# loop over an empty list, which exits successfully without doing anything.
#
# The description marker is held in a variable because make ends a line at an
# unescaped `#`, even inside a $(shell) argument.
HELP_MARK := \#\#
HELP_TARGETS := $(shell grep -hE "^[a-zA-Z0-9_-]+:.*$(HELP_MARK) " $(MAKEFILE_LIST) | cut -d: -f1)
PRESET_TARGETS := $(shell grep -hoE "^[a-zA-Z0-9_-]+:.*$(HELP_MARK) \[preset\] " $(MAKEFILE_LIST) | cut -d: -f1)
NO_PRESET_TARGETS := $(shell grep -hoE "^[a-zA-Z0-9_-]+:.*$(HELP_MARK) \[(global|presets)\] " $(MAKEFILE_LIST) | cut -d: -f1)
UNTAGGED_TARGETS := $(filter-out $(PRESET_TARGETS) $(NO_PRESET_TARGETS),$(HELP_TARGETS))
ifneq ($(UNTAGGED_TARGETS),)
$(error help targets need a [global], [preset], or [presets] tag: $(UNTAGGED_TARGETS))
endif

# Show the selected preset once per invocation; `watch` calls make in a loop
# and the group targets report each preset from their own loop.
ifeq ($(MAKELEVEL),0)
ifeq ($(filter $(NO_PRESET_TARGETS),$(MAKECMDGOALS)),)
$(info [vulcan] PRESET=$(PRESET))
endif
endif

.DEFAULT_GOAL := help

.PHONY: help base base-rebuild rm-base images volume volumes _volume-name build up rebuild stop down restart logs ps up-all down-all stop-all restart-all ps-all build-all stats-all uninstall-all check-ports _check-presets _check-ports config clean-logs clean-overlay clean-appdata clean-all _clean-session uninstall stats usage btop nvtop shell watch

# The table keeps the file order of the targets inside each section. A `# ---`
# line between blocks starts a new group, which the table separates with a blank
# line.
help: ## [global] Show available targets
	@printf 'PRESET=%s\n' '$(PRESET)'
	@printf 'PRESETS=%s\n' '$(if $(strip $(PRESETS)),$(PRESETS),(unset))'
	@printf '\n'
	@awk 'BEGIN { FS = ":.*## " ; split("global preset presets", scope_order, " ") ; \
		title["global"] = "Shared (no preset)" ; \
		title["preset"] = "One preset (PRESET=<path>)" ; \
		title["presets"] = "Several presets (PRESETS=<a>:<b>)" } \
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
	@printf '\nPRESET defaults to .env.local.\n'
	@printf 'PRESETS takes colon-separated paths without spaces.\n'
	@printf 'Destructive targets (base-rebuild, uninstall, uninstall-all) require CONFIRM=1.\n'

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
	if [ -n "$(strip $(PRESETS))" ]; then \
		for preset in $(PRESET_LIST); do \
			names="$$names $$($(MAKE) -s --no-print-directory _volume-name PRESET="$$preset")"; \
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
build: base ## [preset] Build the container image
	$(COMPOSE) build

rebuild: build ## [preset] Rebuild the image and recreate the container
	$(COMPOSE) up -d --force-recreate

up: ## [preset] Start the container in the background
	$(COMPOSE) up -d

restart: ## [preset] Restart the container
	$(COMPOSE) restart

stop: ## [preset] Stop the running container
	$(COMPOSE) stop

down: ## [preset] Stop and remove the container; keep named volumes
	$(COMPOSE) down

# ---
logs: ## [preset] Follow container logs
	$(COMPOSE) logs -f --tail=200 game

ps: ## [preset] Show container status
	$(COMPOSE) ps

stats: ## [preset] Show container CPU, memory, and GPU usage
	@docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' $(CONTAINER)
	@docker exec $(CONTAINER) nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits | awk -F', ' '{printf "GPU: %s%%  VRAM: %s/%s MiB  Temp: %s C\n", $$1, $$2, $$3, $$4}'

usage: stats ## [preset] Alias for stats

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

config: ## [preset] Validate and print the resolved compose config
	$(COMPOSE) config

# ---
CLEAN_LOGS := /data/log/*
CLEAN_OVERLAY := /data/overlay/$(GAME_ID)/upper/* /data/overlay/$(GAME_ID)/work/* /data/prefix/.vulcan-reset-paths
CLEAN_APPDATA := /data/prefix/drive_c/users/*/AppData

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

_clean-session:
	@set -f; printf '[vulcan] removing:\n'; printf '  %s\n' $(CLEAN_PATHS)
	$(COMPOSE) down
	docker run --rm -v $(VOLUME):/data --entrypoint sh $(IMAGE) -c 'set -e; rm -rf $(CLEAN_PATHS)'
	$(COMPOSE) up -d

# ---
uninstall: ## [preset] Remove the container, its data, and the image
	@test "$(CONFIRM)" = "1" || { printf '%s\n' 'Refusing uninstall: run make uninstall CONFIRM=1'; exit 1; }
	$(COMPOSE) down -v
	@if docker image inspect $(IMAGE) >/dev/null 2>&1; then \
		docker rmi $(IMAGE) 2>/dev/null || \
			printf '[vulcan] image %s is still used by another container; leaving it\n' '$(IMAGE)' >&2; \
	else \
		printf 'image %s is already absent\n' '$(IMAGE)'; \
	fi

# Group targets take an explicit, colon-separated list:
#   make up-all PRESETS=".env.zzz:.env.broforce"
PRESETS ?=
PRESET_LIST = $(subst :, ,$(PRESETS))
CHECK_PRESETS = test -n "$(PRESETS)" || { printf '%s\n' 'set PRESETS, for example PRESETS=".env.zzz:.env.broforce"' >&2; exit 1; }; \
	case "$(PRESETS)" in *[[:space:]]*) printf '%s\n' 'PRESETS takes colon-separated paths without spaces' >&2; exit 1 ;; esac

build-all: _check-presets ## [presets] Build the image for every listed preset
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory build PRESET="$$preset" || exit 1; \
	done

up-all: _check-presets _check-ports ## [presets] Start every listed preset
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory up PRESET="$$preset" || exit 1; \
	done

restart-all: _check-presets _check-ports ## [presets] Restart every listed preset
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory restart PRESET="$$preset" || exit 1; \
	done

stop-all: _check-presets ## [presets] Stop every listed preset
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory stop PRESET="$$preset" || exit 1; \
	done

down-all: _check-presets ## [presets] Stop and remove every listed preset
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory down PRESET="$$preset" || exit 1; \
	done

# ---
ps-all: _check-presets ## [presets] Show the status of every listed preset
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory ps PRESET="$$preset" || exit 1; \
	done

stats-all: _check-presets ## [presets] Show resource usage for every listed preset
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory stats PRESET="$$preset" || exit 1; \
	done

check-ports: _check-ports ## [presets] Check that Apollo port ranges do not overlap

# ---
uninstall-all: _check-presets ## [presets] Remove the container, volume, and image of every listed preset
	@test "$(CONFIRM)" = "1" || { printf '%s\n' 'Refusing uninstall: run make uninstall-all CONFIRM=1'; exit 1; }
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory uninstall CONFIRM=1 PRESET="$$preset" || exit 1; \
	done

_check-presets:
	@$(CHECK_PRESETS)
	@for preset in $(PRESET_LIST); do \
		test -f "$$preset" || { printf 'missing preset: %s\n' "$$preset" >&2; exit 1; }; \
	done

_check-ports: _check-presets
	@scripts/check-ports.sh $(PRESET_LIST)

# Targets tagged [preset] need an existing preset with a GAME_ID; the [global]
# and [presets] targets resolve their own configuration.
KNOWN_TARGETS := $(shell grep -hoE '^[a-zA-Z0-9_-]+:' $(MAKEFILE_LIST) | tr -d ':')
CONFIG_GOALS := $(filter-out $(NO_PRESET_TARGETS),$(filter $(KNOWN_TARGETS),$(MAKECMDGOALS)))
ifneq ($(CONFIG_GOALS),)
ifeq ($(wildcard $(PRESET)),)
$(error preset $(PRESET) does not exist: set PRESET=<path>)
endif
ifeq ($(strip $(GAME_ID)),)
$(error preset $(PRESET) does not define GAME_ID)
endif
endif
