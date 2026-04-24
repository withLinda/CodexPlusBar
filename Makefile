APP_NAME := CodexPlusBar
APP_PROJECT := CodexPlusBar.xcodeproj
APP_WORKSPACE := CodexPlusBar.xcworkspace
APP_SCHEME ?= CodexPlusBar
APP_PLATFORM := macos
APP_GENERATOR := xcodegen
CONFIGURATION ?= Debug
SIM_NAME ?= 
TARGET_PREFIX := 
SCRIPTS_DIR := ./scripts
TRACE_PRIVATE_API ?= 0

WORKSPACE ?= $(firstword $(wildcard *.xcworkspace))
PROJECT ?= $(firstword $(wildcard *.xcodeproj))
ifeq ($(strip $(PROJECT)),)
PROJECT := $(APP_PROJECT)
endif

ifeq ($(strip $(WORKSPACE)),)
BUILD_FILE_FLAG := -project $(PROJECT)
else
BUILD_FILE_FLAG := -workspace $(WORKSPACE)
endif

ifeq ($(TARGET_PREFIX),)
.DEFAULT_GOAL := build-and-run
endif

XCBUILD := $(SCRIPTS_DIR)/xcbuild.sh

ifeq ($(origin AGENT_NAME), undefined)
AGENT_NAME := $(shell $(SCRIPTS_DIR)/resolve_agent_name.sh)
endif

DERIVED_BASE := build/DerivedData
DERIVED := $(DERIVED_BASE)/$(AGENT_NAME)
LOG_DIR := build/logs/$(AGENT_NAME)
TRACE_LOG_FILE := $(LOG_DIR)/app-trace.log
CACHE_ROOT := $(CURDIR)/build/cache/$(AGENT_NAME)
TMPDIR_PATH := $(CURDIR)/build/tmp/$(AGENT_NAME)

ifeq ($(APP_PLATFORM),ios)
PLATFORM_SUFFIX := -iphonesimulator
else
PLATFORM_SUFFIX :=
DESTINATION := platform=macOS,arch=arm64
endif

BUILD_PRODUCTS := $(DERIVED)/Build/Products/$(CONFIGURATION)$(PLATFORM_SUFFIX)
APP_PATH := $(BUILD_PRODUCTS)/$(APP_SCHEME).app
ARCHIVE_DERIVED := $(DERIVED_BASE)/$(AGENT_NAME)-archive
ARCHIVE_PATH := $(CURDIR)/build/archive/$(APP_SCHEME).xcarchive
ARCHIVED_APP_PATH := $(ARCHIVE_PATH)/Products/Applications/$(APP_SCHEME).app
DIST_DIR := $(CURDIR)/build/dist
DMG_NAME ?= $(APP_SCHEME)
DMG_VOLUME_NAME ?= $(APP_NAME)
DMG_PATH := $(DIST_DIR)/$(DMG_NAME).dmg

PHONY_TARGETS := $(TARGET_PREFIX)help $(TARGET_PREFIX)diagnose $(TARGET_PREFIX)build \
	$(TARGET_PREFIX)test $(TARGET_PREFIX)run $(TARGET_PREFIX)build-and-run \
	$(TARGET_PREFIX)build-and-run-background $(TARGET_PREFIX)archive $(TARGET_PREFIX)dmg \
	$(TARGET_PREFIX)clean $(TARGET_PREFIX)agent-verify
.PHONY: $(PHONY_TARGETS)

$(TARGET_PREFIX)help:
	@printf "%s\n" \
		"Targets:" \
		"  make $(TARGET_PREFIX)build                    Build with strict flags + logs" \
		"  make $(TARGET_PREFIX)diagnose                 Print toolchain + config info" \
		"  make $(TARGET_PREFIX)test                     Run unit tests" \
		"  make $(TARGET_PREFIX)run                      Run app (assumes prior build)" \
		"  make $(TARGET_PREFIX)build-and-run            Build then run" \
		"  make $(TARGET_PREFIX)build-and-run-background Build then run in background" \
		"  make $(TARGET_PREFIX)archive                  Build a Release .xcarchive for packaging" \
		"  make $(TARGET_PREFIX)dmg                      Build a local drag-to-Applications DMG" \
		"  make $(TARGET_PREFIX)clean                    Clean derived data + logs" \
		"  TRACE_PRIVATE_API=1 make $(TARGET_PREFIX)build-and-run Capture private API trace in $(TRACE_LOG_FILE)" \
		"  make $(TARGET_PREFIX)agent-verify             Build and test"

$(TARGET_PREFIX)diagnose:
ifeq ($(APP_PLATFORM),ios)
	@APP_PROJECT="$(PROJECT)" \
		APP_WORKSPACE="$(WORKSPACE)" \
		APP_BUILD_FILE="$$( [ -n "$(WORKSPACE)" ] && printf "%s" "$(WORKSPACE)" || printf "%s" "$(PROJECT)" )" \
		APP_SCHEME="$(APP_SCHEME)" \
		APP_PLATFORM="$(APP_PLATFORM)" \
		APP_GENERATOR="$(APP_GENERATOR)" \
		APP_DESTINATION="$$( $(SCRIPTS_DIR)/resolve_sim_destination.sh --sim-name "$(SIM_NAME)" 2>/dev/null || true)" \
		AGENT_NAME="$(AGENT_NAME)" \
		CACHE_ROOT="$(CACHE_ROOT)" \
		TMPDIR="$(TMPDIR_PATH)" \
		$(SCRIPTS_DIR)/diagnose.sh
else
	@APP_PROJECT="$(PROJECT)" \
		APP_WORKSPACE="$(WORKSPACE)" \
		APP_BUILD_FILE="$$( [ -n "$(WORKSPACE)" ] && printf "%s" "$(WORKSPACE)" || printf "%s" "$(PROJECT)" )" \
		APP_SCHEME="$(APP_SCHEME)" \
		APP_PLATFORM="$(APP_PLATFORM)" \
		APP_GENERATOR="$(APP_GENERATOR)" \
		APP_DESTINATION="$(DESTINATION)" \
		AGENT_NAME="$(AGENT_NAME)" \
		CACHE_ROOT="$(CACHE_ROOT)" \
		TMPDIR="$(TMPDIR_PATH)" \
		$(SCRIPTS_DIR)/diagnose.sh
endif

$(TARGET_PREFIX)build:
ifeq ($(APP_PLATFORM),ios)
	@DESTINATION="$$( $(SCRIPTS_DIR)/resolve_sim_destination.sh --sim-name "$(SIM_NAME)")"; \
	if [ -z "$$DESTINATION" ]; then echo "No iOS Simulator found."; exit 1; fi; \
	LOG_DIR="$(LOG_DIR)" CACHE_ROOT="$(CACHE_ROOT)" TMPDIR="$(TMPDIR_PATH)" $(XCBUILD) --label "$(AGENT_NAME)" --action build -- \
		$(BUILD_FILE_FLAG) \
		-scheme $(APP_SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination "$$DESTINATION" \
		-derivedDataPath $(DERIVED) \
		GCC_TREAT_WARNINGS_AS_ERRORS=YES \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		SWIFT_STRICT_CONCURRENCY=complete \
		build
else
	@LOG_DIR="$(LOG_DIR)" CACHE_ROOT="$(CACHE_ROOT)" TMPDIR="$(TMPDIR_PATH)" $(XCBUILD) --label "$(AGENT_NAME)" --action build -- \
		$(BUILD_FILE_FLAG) \
		-scheme $(APP_SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) \
		GCC_TREAT_WARNINGS_AS_ERRORS=YES \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		SWIFT_STRICT_CONCURRENCY=complete \
		build
endif

$(TARGET_PREFIX)test:
ifeq ($(APP_PLATFORM),ios)
	@DESTINATION="$$( $(SCRIPTS_DIR)/resolve_sim_destination.sh --sim-name "$(SIM_NAME)")"; \
	if [ -z "$$DESTINATION" ]; then echo "No iOS Simulator found."; exit 1; fi; \
	LOG_DIR="$(LOG_DIR)" CACHE_ROOT="$(CACHE_ROOT)" TMPDIR="$(TMPDIR_PATH)" $(XCBUILD) --label "$(AGENT_NAME)" --action test -- \
		$(BUILD_FILE_FLAG) \
		-scheme $(APP_SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination "$$DESTINATION" \
		-derivedDataPath $(DERIVED) \
		GCC_TREAT_WARNINGS_AS_ERRORS=YES \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		SWIFT_STRICT_CONCURRENCY=complete \
		test
else
	@LOG_DIR="$(LOG_DIR)" CACHE_ROOT="$(CACHE_ROOT)" TMPDIR="$(TMPDIR_PATH)" $(XCBUILD) --label "$(AGENT_NAME)" --action test -- \
		$(BUILD_FILE_FLAG) \
		-scheme $(APP_SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) \
		GCC_TREAT_WARNINGS_AS_ERRORS=YES \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		SWIFT_STRICT_CONCURRENCY=complete \
		test
endif

$(TARGET_PREFIX)run:
ifeq ($(APP_PLATFORM),ios)
	@$(SCRIPTS_DIR)/run_app_ios_sim.sh --app-path "$(APP_PATH)" --sim-name "$(SIM_NAME)"
else
	@mkdir -p "$(LOG_DIR)"
	@TRACE_PRIVATE_API="$(TRACE_PRIVATE_API)" APP_TRACE_LOG="$(TRACE_LOG_FILE)" $(SCRIPTS_DIR)/run_app_macos.sh --app-path "$(APP_PATH)" --replace-bundle-id
endif

$(TARGET_PREFIX)build-and-run: $(TARGET_PREFIX)build $(TARGET_PREFIX)run

$(TARGET_PREFIX)build-and-run-background: $(TARGET_PREFIX)build
ifeq ($(APP_PLATFORM),ios)
	@$(SCRIPTS_DIR)/run_app_ios_sim.sh --app-path "$(APP_PATH)" --sim-name "$(SIM_NAME)" --background
else
	@mkdir -p "$(LOG_DIR)"
	@TRACE_PRIVATE_API="$(TRACE_PRIVATE_API)" APP_TRACE_LOG="$(TRACE_LOG_FILE)" $(SCRIPTS_DIR)/run_app_macos.sh --app-path "$(APP_PATH)" --background --replace-bundle-id
endif

$(TARGET_PREFIX)archive:
	@mkdir -p "$(dir $(ARCHIVE_PATH))"
	@LOG_DIR="$(LOG_DIR)" CACHE_ROOT="$(CACHE_ROOT)" TMPDIR="$(TMPDIR_PATH)" $(XCBUILD) --label "$(AGENT_NAME)" --action archive -- \
		$(BUILD_FILE_FLAG) \
		-scheme $(APP_SCHEME) \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-derivedDataPath $(ARCHIVE_DERIVED) \
		-archivePath $(ARCHIVE_PATH) \
		GCC_TREAT_WARNINGS_AS_ERRORS=YES \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		SWIFT_STRICT_CONCURRENCY=complete \
		SKIP_INSTALL=NO \
		archive
	@printf "Archive: %s\n" "$(ARCHIVE_PATH)"

$(TARGET_PREFIX)dmg: $(TARGET_PREFIX)archive
	@$(SCRIPTS_DIR)/create_dmg.sh \
		--app "$(ARCHIVED_APP_PATH)" \
		--output "$(DMG_PATH)" \
		--volume-name "$(DMG_VOLUME_NAME)"

$(TARGET_PREFIX)clean:
	@$(SCRIPTS_DIR)/clean.sh

$(TARGET_PREFIX)agent-verify:
	@$(MAKE) --no-print-directory $(TARGET_PREFIX)build
	@$(MAKE) --no-print-directory $(TARGET_PREFIX)test
