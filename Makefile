SHELL := /bin/bash

# Optional local overrides (see .env.example). Values already set in the
# environment take precedence over the file.
-include .env
export

APP_DIR    := app
SERVER_DIR := server
WEB_DIST   := $(SERVER_DIR)/internal/web/dist
WEB_STAMP  := $(WEB_DIST)/.last_build_id
BIN        := $(SERVER_DIR)/bin/dusty
DUSTY_DATA_DIR ?= ./data
DUSTY_ADDR     ?= :8080

# Everything that changes the web bundle. The Go binary embeds these files at
# compile time, so a server rebuild without a fresh bundle serves the old app.
WEB_INPUTS := $(shell find $(APP_DIR)/lib $(APP_DIR)/web $(APP_DIR)/assets -type f 2>/dev/null) \
	$(APP_DIR)/pubspec.yaml $(APP_DIR)/pubspec.lock

.PHONY: all web server build dev env test test-server test-app analyze clean docker

all: build

## Rebuild the Flutter web bundle when app sources are newer than the embed.
$(WEB_STAMP): $(WEB_INPUTS)
	cd $(APP_DIR) && flutter build web --release
	mkdir -p $(WEB_DIST)
	find $(WEB_DIST) -mindepth 1 ! -name .gitkeep -delete
	cp -r $(APP_DIR)/build/web/. $(WEB_DIST)/
	# Flutter reuses main.dart.js and flutter_bootstrap.js on every build.
	# Browsers that cached the first response for a day would keep showing it,
	# so the fresh index.html points at a URL that includes this build's id.
	sh scripts/stamp-web.sh $(WEB_DIST)

web: $(WEB_STAMP)

## Go binary. Rebuilds the web bundle first when the app sources changed,
## because the bundle is embedded at compile time.
server: $(WEB_STAMP)
	mkdir -p $(SERVER_DIR)/bin
	cd $(SERVER_DIR) && CGO_ENABLED=0 go build -o bin/dusty ./cmd/dusty

## Full build: web bundle + Go binary that embeds it.
build: server

## Run the server locally (reads .env if present). Rebuilds the web bundle
## first when the app sources are newer than the embedded one.
dev: $(WEB_STAMP)
	mkdir -p $(DUSTY_DATA_DIR)
	cd $(SERVER_DIR) && DUSTY_DATA_DIR=$(abspath $(DUSTY_DATA_DIR)) go run ./cmd/dusty

## Create a local .env from the example if it does not exist yet.
env:
	@test -f .env && echo ".env already exists" || (cp .env.example .env && echo "created .env from .env.example")

test: test-server test-app

test-server:
	cd $(SERVER_DIR) && go test ./...

test-app: analyze
	cd $(APP_DIR) && flutter test

analyze:
	cd $(APP_DIR) && flutter analyze

docker:
	docker build -t dusty-library .

clean:
	rm -rf $(SERVER_DIR)/bin $(APP_DIR)/build
	find $(WEB_DIST) -mindepth 1 ! -name .gitkeep -delete
