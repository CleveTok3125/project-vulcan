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

# Show the selected preset once per invocation; `watch` calls make in a loop
# and the group targets report each preset from their own loop.
GROUP_TARGETS := up-all down-all stop-all restart-all ps-all build-all stats-all uninstall-all
ifeq ($(MAKELEVEL),0)
ifeq ($(filter base rm-base images volumes $(GROUP_TARGETS),$(MAKECMDGOALS)),)
$(info [vulcan] PRESET=$(PRESET))
endif
endif

.DEFAULT_GOAL := help

.PHONY: help base base-rebuild rm-base images volume volumes _volume-name build up rebuild stop down restart logs ps up-all down-all stop-all restart-all ps-all build-all stats-all uninstall-all _check-presets config clean-logs clean-overlay clean-appdata clean-all _clean-session uninstall stats usage btop nvtop shell watch

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nPRESET selects the configuration preset (default: .env.local).\n'
	@printf 'PRESETS lists several presets for the *-all targets, separated by colons.\n'

base: ## Build the shared environment image for this host
	@docker image inspect $(BASE_IMAGE) >/dev/null 2>&1 || \
		docker build -f $(BASE_DOCKERFILE) \
			--build-arg MIRROR_COUNTRY="$(MIRROR_COUNTRY)" \
			-t $(BASE_IMAGE) .

base-rebuild: ## Rebuild the shared base image without cache; requires CONFIRM=1
	@test "$(CONFIRM)" = "1" || { printf '%s\n' 'Refusing rebuild: run make base-rebuild CONFIRM=1'; exit 1; }
	docker build --no-cache \
		-f $(BASE_DOCKERFILE) \
		--build-arg MIRROR_COUNTRY="$(MIRROR_COUNTRY)" \
		-t $(BASE_IMAGE) .

rm-base: ## Remove the base image
	@images=$$(docker images --format '{{.Repository}}:{{.Tag}}' vulcan/base); \
	if [ -z "$$images" ]; then printf 'no base image\n'; exit 0; fi; \
	for image in $$images; do docker rmi "$$image" || exit 1; done

_volume-name:
	@printf '%s\n' '$(VOLUME)'

volume: ## Show the volume of the selected preset
	@name="$(VOLUME)"; \
	if ! docker volume inspect "$$name" >/dev/null 2>&1; then \
		printf '%s (missing)\n' "$$name"; exit 0; \
	fi; \
	docker volume inspect "$$name" --format 'name={{.Name}} mount={{.Mountpoint}}'; \
	docker volume inspect "$$name" --format 'created={{.CreatedAt}}'; \
	size=$$(docker system df -v | awk -v v="$$name" '$$1 == v {print $$3}'); \
	printf 'size=%s\n' "$${size:-unknown}"

volumes: ## List the Vulcan volumes
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

build: base ## Build the container image
	$(COMPOSE) build

images: ## List the Vulcan images
	@docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' \
		| awk 'NR == 1 || /^vulcan\//'

up: ## Start the container in the background
	$(COMPOSE) up -d

rebuild: build ## Rebuild the image and recreate the container
	$(COMPOSE) up -d --force-recreate

stop: ## Stop the running container
	$(COMPOSE) stop

down: ## Stop and remove the container; keep named volumes
	$(COMPOSE) down

restart: ## Restart the container
	$(COMPOSE) restart

logs: ## Follow container logs
	$(COMPOSE) logs -f --tail=200 game

ps: ## Show container status
	$(COMPOSE) ps

# Group targets take an explicit, colon-separated list:
#   make up-all PRESETS=".env.zzz:.env.broforce"
PRESETS ?=
PRESET_LIST = $(subst :, ,$(PRESETS))
CHECK_PRESETS = test -n "$(PRESETS)" || { printf '%s\n' 'set PRESETS, for example PRESETS=".env.zzz:.env.broforce"' >&2; exit 1; }; \
	case "$(PRESETS)" in *[[:space:]]*) printf '%s\n' 'PRESETS takes colon-separated paths without spaces' >&2; exit 1 ;; esac

up-all: _check-presets ## Start every preset listed in PRESETS
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory up PRESET="$$preset" || exit 1; \
	done

down-all: _check-presets ## Stop and remove every preset listed in PRESETS
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory down PRESET="$$preset" || exit 1; \
	done

stop-all: _check-presets ## Stop every preset listed in PRESETS
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory stop PRESET="$$preset" || exit 1; \
	done

restart-all: _check-presets ## Restart every preset listed in PRESETS
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory restart PRESET="$$preset" || exit 1; \
	done

ps-all: _check-presets ## Show the status of every preset listed in PRESETS
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory ps PRESET="$$preset" || exit 1; \
	done

build-all: _check-presets ## Build the image for every preset listed in PRESETS
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory build PRESET="$$preset" || exit 1; \
	done

uninstall-all: _check-presets ## Remove the container, volume, and image of every preset; requires CONFIRM=1
	@test "$(CONFIRM)" = "1" || { printf '%s\n' 'Refusing uninstall: run make uninstall-all CONFIRM=1'; exit 1; }
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory uninstall CONFIRM=1 PRESET="$$preset" || exit 1; \
	done

stats-all: _check-presets ## Show resource usage for every preset listed in PRESETS
	@for preset in $(PRESET_LIST); do \
		printf '[vulcan] PRESET=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory stats PRESET="$$preset" || exit 1; \
	done

_check-presets:
	@$(CHECK_PRESETS)
	@for preset in $(PRESET_LIST); do \
		test -f "$$preset" || { printf 'missing preset: %s\n' "$$preset" >&2; exit 1; }; \
	done

stats: ## Show container CPU, memory, and GPU usage
	@docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' $(CONTAINER)
	@docker exec $(CONTAINER) nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits | awk -F', ' '{printf "GPU: %s%%  VRAM: %s/%s MiB  Temp: %s C\n", $$1, $$2, $$3, $$4}'

usage: stats ## Alias for stats

btop: ## Open btop inside the container
	docker exec -it --user 1000 -e HOME=/data/home $(CONTAINER) btop

nvtop: ## Open nvtop inside the container
	docker exec -it --user 1000 -e HOME=/data/home $(CONTAINER) nvtop

shell: ## Open a shell with the running session environment
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

watch: ## Refresh container usage every 2 seconds
	@while true; do printf '\033[2J\033[H'; $(MAKE) --no-print-directory stats; sleep 2; done

config: ## Validate and print the resolved compose config
	$(COMPOSE) config

CLEAN_LOGS := /data/log/*
CLEAN_OVERLAY := /data/overlay/$(GAME_ID)/upper/* /data/overlay/$(GAME_ID)/work/* /data/prefix/.vulcan-reset-paths
CLEAN_APPDATA := /data/prefix/drive_c/users/*/AppData

clean-logs: ## Remove the session logs
clean-logs: CLEAN_PATHS := $(CLEAN_LOGS)
clean-logs: _clean-session

clean-overlay: ## Remove the game overlay and reset marker
clean-overlay: CLEAN_PATHS := $(CLEAN_OVERLAY)
clean-overlay: _clean-session

clean-appdata: ## Remove the prefix AppData
clean-appdata: CLEAN_PATHS := $(CLEAN_APPDATA)
clean-appdata: _clean-session

clean-all: ## Remove logs, overlay, reset marker, and prefix AppData
clean-all: CLEAN_PATHS := $(CLEAN_LOGS) $(CLEAN_OVERLAY) $(CLEAN_APPDATA)
clean-all: _clean-session

_clean-session:
	@set -f; printf '[vulcan] removing:\n'; printf '  %s\n' $(CLEAN_PATHS)
	$(COMPOSE) down
	docker run --rm -v $(VOLUME):/data --entrypoint sh $(IMAGE) -c 'set -e; rm -rf $(CLEAN_PATHS)'
	$(COMPOSE) up -d

uninstall: ## Remove the container, its data, and the image; requires CONFIRM=1
	@test "$(CONFIRM)" = "1" || { printf '%s\n' 'Refusing uninstall: run make uninstall CONFIRM=1'; exit 1; }
	$(COMPOSE) down -v
	docker rmi $(IMAGE)

# Targets that act on one container need a preset; `help` works without one and
# the group targets resolve a preset per entry.
KNOWN_TARGETS := $(shell grep -hoE '^[a-zA-Z0-9_-]+:' $(MAKEFILE_LIST) | tr -d ':')
CONFIG_GOALS := $(filter-out help base base-rebuild rm-base images volumes $(GROUP_TARGETS),$(filter $(KNOWN_TARGETS),$(MAKECMDGOALS)))
ifneq ($(CONFIG_GOALS),)
ifeq ($(wildcard $(PRESET)),)
$(error preset $(PRESET) does not exist: set PRESET=<path>)
endif
ifeq ($(strip $(GAME_ID)),)
$(error preset $(PRESET) does not define GAME_ID)
endif
endif
