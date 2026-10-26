SHELL := /bin/bash
COMPOSE := docker compose --env-file .env.local -f compose.yaml -f compose.nvidia.yaml
IMAGE := vulcan/game-stream:local
CONTAINER := vulcan-game
VOLUME := vulcan_zzz-data

.DEFAULT_GOAL := help

.PHONY: help build up rebuild stop down restart logs ps config clean reset

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

config: ## Validate and print the resolved compose config
	$(COMPOSE) config

clean: ## Remove game session data; keep prefix and Apollo state
	$(COMPOSE) down
	docker run --rm -v $(VOLUME):/data --entrypoint sh $(IMAGE) -c 'rm -rf /data/overlay/zzz/upper/* /data/overlay/zzz/work/* /data/prefix/drive_c/users/*/AppData /data/log/*'
	$(COMPOSE) up -d

reset: ## Remove container and all data; requires CONFIRM=1
	@test "$(CONFIRM)" = "1" || { printf '%s\n' 'Refusing reset: run make reset CONFIRM=1'; exit 1; }
	$(COMPOSE) down -v
