SHELL := /bin/bash
# Select another configuration preset with `make <target> ENV_FILE=<path>`.
ENV_FILE ?= .env.local
-include $(ENV_FILE)
GAME_ID ?= zzz
COMPOSE = docker compose --env-file $(ENV_FILE) -f compose.yaml -f compose.nvidia.yaml
IMAGE := vulcan/game-stream:local
CONTAINER := vulcan-game
VOLUME := vulcan_$(GAME_ID)-data

.DEFAULT_GOAL := help

.PHONY: help build up rebuild stop down restart logs ps config clean uninstall stats usage btop nvtop shell watch

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nENV_FILE selects the configuration preset (default: .env.local).\n'

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

clean: ## Reset the game overlay, AppData, logs, and reset marker
	$(COMPOSE) down
	docker run --rm -v $(VOLUME):/data --entrypoint sh $(IMAGE) -c 'rm -rf /data/overlay/$(GAME_ID)/upper/* /data/overlay/$(GAME_ID)/work/* /data/prefix/drive_c/users/*/AppData /data/prefix/.vulcan-reset-paths /data/log/*'
	$(COMPOSE) up -d

uninstall: ## Remove the container, its data, and the image; requires CONFIRM=1
	@test "$(CONFIRM)" = "1" || { printf '%s\n' 'Refusing uninstall: run make uninstall CONFIRM=1'; exit 1; }
	$(COMPOSE) down -v
	docker rmi $(IMAGE)
