# PurplePen Linux Packaging (AppImage + Flatpak + deb/rpm)
#
# All build-script targets are available as Make targets.
# TAG= checks out an upstream ref before running.

SHELL := /bin/bash
SUBMODULE_DIR := src
PATCHES_DIR := patches
BUILD_SCRIPT := packaging/linux/build-appimage.sh
PKG_SCRIPT   := packaging/linux/build-packages.sh
FLATPAK_MANIFEST := packaging/flatpak/org.purplepen.PurplePen.yml

ARCH ?= x64
OUTPUT_DIR ?= $(CURDIR)

# Container images
CONT_UBUNTU := ubuntu:24.04
CONT_CENTOS := quay.io/centos/centos:stream9
CONT_MOUNT  := -v $(CURDIR):/src:Z -w /src

# Build-script targets exposed as Make targets.
SCRIPT_TARGETS := setup-env requirements apply-patches extract-version publish \
                  prepare-icon build-appdir fetch-appimagetool create-appimage

.PHONY: help build check-patches update clean submodule-init \
       cont-build-ubuntu cont-build-centos cont-enter \
       cont-appimage cont-deb cont-rpm cont-flatpak cont-all \
       flatpak flatpak-deps flatpak-install flatpak-run flatpak-nuget-sources \
       deb rpm packages \
       $(SCRIPT_TARGETS)
.DEFAULT_GOAL := help

# --- Help (default) ---

help:
	@echo "PurplePen Linux AppImage Builder"
	@echo ""
	@echo "Usage: make <target> [TAG=<ref>] [ARCH=x64|arm64] [OUTPUT_DIR=<path>]"
	@echo ""
	@echo "Pipeline:"
	@echo "  build               Run the full AppImage build pipeline (depends: update)"
	@echo ""
	@echo "Build steps (from build-appimage.sh, each depends: update):"
	@echo "  setup-env           Resolve paths, map architecture, apply RHEL SHA-1 workaround"
	@echo "  requirements        Install system dependencies and .NET SDK"
	@echo "  apply-patches       Apply patches/*.patch to the upstream submodule"
	@echo "  extract-version     Read version from VersionNumber.cs"
	@echo "  publish             dotnet restore + dotnet publish (self-contained)"
	@echo "  prepare-icon        Generate or reuse 256x256 PNG icon"
	@echo "  build-appdir        Assemble the AppDir tree from published output"
	@echo "  fetch-appimagetool  Download appimagetool if not cached"
	@echo "  create-appimage     Package AppDir into a portable .AppImage"
	@echo ""
	@echo "Native packages (fpm, each depends: update):"
	@echo "  deb                 Build .deb package (Debian/Ubuntu)"
	@echo "  rpm                 Build .rpm package (CentOS/RHEL/Fedora)"
	@echo "  packages            Build both .deb and .rpm"
	@echo ""
	@echo "Container builds (podman):"
	@echo "  cont-appimage       Build AppImage in Ubuntu container"
	@echo "  cont-deb            Build .deb in Ubuntu container"
	@echo "  cont-rpm            Build .rpm in CentOS Stream container"
	@echo "  cont-flatpak        Build Flatpak in Ubuntu container (depends: flatpak-deps)"
	@echo "  cont-all            Build all packages in containers (AppImage + deb + rpm + Flatpak)"
	@echo "  cont-build-ubuntu   Build AppImage in Ubuntu container (alias for cont-appimage)"
	@echo "  cont-build-centos   Build AppImage in CentOS Stream container"
	@echo "  cont-enter          Interactive shell in Ubuntu container (CONT=centos for CentOS)"
	@echo ""
	@echo "Flatpak:"
	@echo "  flatpak-deps        Install Flatpak SDK, runtime, and dotnet10 extension"
	@echo "  flatpak             Build Flatpak with flatpak-builder (depends: flatpak-deps)"
	@echo "  flatpak-install     Build and install Flatpak locally (depends: flatpak-deps)"
	@echo "  flatpak-run         Run the installed Flatpak"
	@echo "  flatpak-nuget-sources  Regenerate nuget-sources.json"
	@echo ""
	@echo "Utilities:"
	@echo "  check-patches       Verify patches apply cleanly (depends: update)"
	@echo "  update              Checkout upstream ref (depends: submodule-init; requires TAG=)"
	@echo "  clean               Remove build artifacts and reset submodule"
	@echo ""
	@echo "Examples:"
	@echo "  make build                        Build from current submodule commit"
	@echo "  make build TAG=master             Build from upstream master"
	@echo "  make apply-patches                Run a single build step"
	@echo "  make check-patches TAG=master     Verify patches against a ref"
	@echo "  make cont-build-ubuntu            Build in Ubuntu container"
	@echo "  make cont-enter CONT=centos       Enter CentOS container"
	@echo "  DEBUG=1 make build                Build with shell tracing"

# --- Submodule management ---

submodule-init:
	@if [ ! -f $(SUBMODULE_DIR)/.git ] && [ ! -d $(SUBMODULE_DIR)/.git ]; then \
		echo ">>> Initializing submodule..."; \
		git submodule update --init; \
	fi

update: submodule-init
ifdef TAG
	@echo ">>> Checking out upstream ref: $(TAG)"
	git -C $(SUBMODULE_DIR) fetch --tags origin
	git -C $(SUBMODULE_DIR) checkout $(TAG)
else
	@echo ">>> Using current submodule commit: $$(git -C $(SUBMODULE_DIR) rev-parse --short HEAD)"
endif

# --- Full pipeline ---

build: update
	@echo ">>> Building AppImage from $$(git -C $(SUBMODULE_DIR) describe --tags --always)..."
	ARCH=$(ARCH) OUTPUT_DIR=$(OUTPUT_DIR) bash $(BUILD_SCRIPT)

# --- Individual build-script targets ---

$(SCRIPT_TARGETS): update
	ARCH=$(ARCH) OUTPUT_DIR=$(OUTPUT_DIR) bash $(BUILD_SCRIPT) $@

# --- Utilities ---

check-patches: update
	@echo ">>> Checking patches against $$(git -C $(SUBMODULE_DIR) describe --tags --always)..."
	@if git -C $(SUBMODULE_DIR) am --check $(PATCHES_DIR)/*.patch 2>/dev/null; then \
		echo "All patches apply cleanly."; \
	else \
		echo ""; \
		echo "ERROR: Patches do not apply to this ref."; \
		echo "       Patches target the Avalonia codebase (post-3.5.4)."; \
		exit 1; \
	fi

# --- Native packages (fpm) ---

deb: update
	ARCH=$(ARCH) OUTPUT_DIR=$(OUTPUT_DIR) bash $(PKG_SCRIPT) build-deb

rpm: update
	ARCH=$(ARCH) OUTPUT_DIR=$(OUTPUT_DIR) bash $(PKG_SCRIPT) build-rpm

packages: update
	ARCH=$(ARCH) OUTPUT_DIR=$(OUTPUT_DIR) bash $(PKG_SCRIPT) build

# --- Flatpak ---

FLATPAK_RUNTIME_VER := 25.08
FLATPAK_APP_ID := org.purplepen.PurplePen

flatpak-deps:
	@echo ">>> Installing Flatpak tooling, SDK, runtime, and .NET 10 extension..."
	@if ! command -v flatpak >/dev/null 2>&1 || ! command -v flatpak-builder >/dev/null 2>&1; then \
		echo "    Installing flatpak and flatpak-builder..."; \
		if [ -f /etc/debian_version ]; then \
			DEBIAN_FRONTEND=noninteractive apt-get update && \
			DEBIAN_FRONTEND=noninteractive apt-get install -y flatpak flatpak-builder; \
		elif [ -f /etc/redhat-release ]; then \
			dnf install -y flatpak flatpak-builder; \
		else \
			echo "ERROR: Install flatpak and flatpak-builder manually." >&2; exit 1; \
		fi; \
	fi
	flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
	flatpak install --user -y flathub org.freedesktop.Platform//$(FLATPAK_RUNTIME_VER)
	flatpak install --user -y flathub org.freedesktop.Sdk//$(FLATPAK_RUNTIME_VER)
	flatpak install --user -y flathub org.freedesktop.Sdk.Extension.dotnet10//$(FLATPAK_RUNTIME_VER)

flatpak: flatpak-deps
	flatpak-builder --disable-rofiles-fuse --force-clean _build $(FLATPAK_MANIFEST)

flatpak-install: flatpak-deps
	flatpak-builder --disable-rofiles-fuse --user --install --force-clean _build $(FLATPAK_MANIFEST)

flatpak-run:
	flatpak run $(FLATPAK_APP_ID)

flatpak-nuget-sources:
	bash packaging/flatpak/generate-nuget-sources.sh

# --- Utilities ---

clean:
	rm -rf PurplePen.AppDir _build .flatpak-builder _staging _pdfconverter-tmp
	rm -f *.AppImage *.deb *.rpm
	@if [ -d $(SUBMODULE_DIR) ]; then \
		git -C $(SUBMODULE_DIR) checkout -- . 2>/dev/null || true; \
		git -C $(SUBMODULE_DIR) clean -fd 2>/dev/null || true; \
	fi
	@echo "Cleaned build artifacts and reset submodule working tree."

# --- Container builds (podman) ---

CONT_ENV := --env ARCH=$(ARCH) --env OUTPUT_DIR=/src --env DEBUG=$(DEBUG)

cont-appimage:
	podman run --rm $(CONT_MOUNT) $(CONT_ENV) $(CONT_UBUNTU) \
		bash /src/$(BUILD_SCRIPT) requirements build

cont-build-ubuntu: cont-appimage

cont-build-centos:
	podman run --rm $(CONT_MOUNT) $(CONT_ENV) $(CONT_CENTOS) \
		bash /src/$(BUILD_SCRIPT) requirements build

cont-deb:
	podman run --rm $(CONT_MOUNT) $(CONT_ENV) $(CONT_UBUNTU) \
		bash /src/$(PKG_SCRIPT) requirements build-deb

cont-rpm:
	podman run --rm $(CONT_MOUNT) $(CONT_ENV) $(CONT_CENTOS) \
		bash /src/$(PKG_SCRIPT) requirements build-rpm

cont-flatpak:
	podman run --rm --privileged $(CONT_MOUNT) $(CONT_ENV) $(CONT_UBUNTU) \
		bash -c 'apt-get update && apt-get install -y flatpak flatpak-builder git && \
		flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo && \
		flatpak install -y flathub org.freedesktop.Platform//$(FLATPAK_RUNTIME_VER) \
			org.freedesktop.Sdk//$(FLATPAK_RUNTIME_VER) \
			org.freedesktop.Sdk.Extension.dotnet10//$(FLATPAK_RUNTIME_VER) && \
		flatpak-builder --disable-rofiles-fuse --force-clean /src/_build /src/$(FLATPAK_MANIFEST)'

cont-all: cont-appimage cont-deb cont-rpm cont-flatpak

cont-enter:
ifeq ($(CONT),centos)
	podman run --rm -it $(CONT_MOUNT) $(CONT_ENV) $(CONT_CENTOS) \
		bash -c '/src/$(BUILD_SCRIPT) requirements && exec bash'
else
	podman run --rm -it $(CONT_MOUNT) $(CONT_ENV) $(CONT_UBUNTU) \
		bash -c '/src/$(BUILD_SCRIPT) requirements && exec bash'
endif
