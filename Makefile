SHELL := /bin/bash
# Select another configuration preset with `make <target> ENV_FILE=<path>`.
ENV_FILE ?= .env.local
-include $(ENV_FILE)
GAME_ID ?= zzz
COMPOSE = docker compose --env-file $(ENV_FILE) -f compose.yaml -f compose.nvidia.yaml
IMAGE := vulcan/game-stream:local
CONTAINER := vulcan-$(GAME_ID)
VOLUME := vulcan_$(GAME_ID)-data

# Show the selected preset once per invocation; `watch` calls make in a loop
# and the group targets report each preset from their own loop.
GROUP_TARGETS := up-all down-all ps-all
ifeq ($(MAKELEVEL),0)
ifeq ($(filter $(GROUP_TARGETS),$(MAKECMDGOALS)),)
$(info [vulcan] ENV_FILE=$(ENV_FILE)$(if $(wildcard $(ENV_FILE)),, (missing)))
endif
endif

.DEFAULT_GOAL := help

.PHONY: help build up rebuild stop down restart logs ps up-all down-all ps-all _check-presets config clean-logs clean-overlay clean-appdata clean-all _clean-session uninstall stats usage btop nvtop shell watch

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nENV_FILE selects the configuration preset (default: .env.local).\n'
	@printf 'PRESETS lists several presets for the *-all targets.\n'

build: ## Build the container image
	$(COMPOSE) build

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

# Group targets take an explicit list:
#   make up-all PRESETS=".env.zzz .env.broforce"
PRESETS ?=
CHECK_PRESETS = test -n "$(PRESETS)" || { printf '%s\n' 'set PRESETS, for example PRESETS=".env.zzz .env.broforce"' >&2; exit 1; }

up-all: _check-presets ## Start every preset listed in PRESETS
	@for preset in $(PRESETS); do \
		printf '[vulcan] ENV_FILE=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory up ENV_FILE="$$preset" || exit 1; \
	done

down-all: _check-presets ## Stop and remove every preset listed in PRESETS
	@for preset in $(PRESETS); do \
		printf '[vulcan] ENV_FILE=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory down ENV_FILE="$$preset" || exit 1; \
	done

ps-all: _check-presets ## Show the status of every preset listed in PRESETS
	@for preset in $(PRESETS); do \
		printf '[vulcan] ENV_FILE=%s\n' "$$preset"; \
		$(MAKE) --no-print-directory ps ENV_FILE="$$preset" || exit 1; \
	done

_check-presets:
	@$(CHECK_PRESETS)
	@for preset in $(PRESETS); do \
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
