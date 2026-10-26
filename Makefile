SHELL := /bin/bash
COMPOSE := docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml
IMAGE := vulcan/game-stream:local
CONTAINER := vulcan-game
VOLUME := vulcan_zzz-data

.DEFAULT_GOAL := help

.PHONY: help build up rebuild stop down restart logs ps config clean reset stats usage btop nvtop watch

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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

watch: ## Refresh container usage every 2 seconds
	@while true; do printf '\033[2J\033[H'; $(MAKE) --no-print-directory stats; sleep 2; done

config: ## Validate and print the resolved compose config
	$(COMPOSE) config

clean: ## Remove game session data; keep prefix and Apollo state
	$(COMPOSE) down
	docker run --rm -v $(VOLUME):/data --entrypoint sh $(IMAGE) -c 'rm -rf /data/overlay/zzz/upper/* /data/overlay/zzz/work/* /data/prefix/drive_c/users/*/AppData /data/log/*'
	$(COMPOSE) up -d

reset: ## Remove container and all data; requires CONFIRM=1
	@test "$(CONFIRM)" = "1" || { printf '%s\n' 'Refusing reset: run make reset CONFIRM=1'; exit 1; }
	$(COMPOSE) down -v
