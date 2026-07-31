#!/usr/bin/env bash
#
# build-packages.sh — Build .deb and .rpm packages for PurplePen using fpm.
#
# Reuses the publish output from build-appimage.sh (dotnet publish +
# PdfConverter overlay + runtimes/ stripping). If no publish output exists,
# runs the publish step automatically.
#
# Environment variables:
#   ARCH        Target architecture: x64 (default) or arm64
#   OUTPUT_DIR  Where to write the packages (default: repo root)
#   DEBUG       Set to 1 to enable shell tracing (set -x)
#
# Usage:
#   ./packaging/linux/build-packages.sh              # build both .deb and .rpm
#   ./packaging/linux/build-packages.sh build-deb    # .deb only
#   ./packaging/linux/build-packages.sh build-rpm    # .rpm only
#
# Prerequisites:
#   - .NET 10 SDK (dotnet)
#   - fpm (gem install fpm)
#   - rpm-build (for .rpm output)

set -euo pipefail
[[ "${DEBUG:-}" == "1" ]] && set -x

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SCRIPT_DIR=""
REPO_ROOT=""
SUBMODULE_DIR=""
SRC_DIR=""
STAGING_DIR=""
APPIMAGE_SCRIPT=""
FULL_VERSION=""
SHORT_VERSION=""
APP_BINARY=""
RID=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf ">>> %s\n" "$*"; }
info() { printf "    %s\n" "$*"; }
die() { printf "    ERROR: %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

setup-env() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    SUBMODULE_DIR="$REPO_ROOT/src"
    SRC_DIR="$SUBMODULE_DIR/src"
    APPIMAGE_SCRIPT="$SCRIPT_DIR/build-appimage.sh"

    ARCH="${ARCH:-x64}"
    OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT}"

    case "$ARCH" in
        x64)   RID="linux-x64";  DEB_ARCH="amd64";  RPM_ARCH="x86_64" ;;
        arm64) RID="linux-arm64"; DEB_ARCH="arm64";   RPM_ARCH="aarch64" ;;
        *)     die "Unsupported architecture: $ARCH (use x64 or arm64)" ;;
    esac

    STAGING_DIR="$REPO_ROOT/_staging"

    if [[ -f /etc/redhat-release ]] && [[ -z "${OPENSSL_ENABLE_SHA1_SIGNATURES:-}" ]]; then
        export OPENSSL_ENABLE_SHA1_SIGNATURES=1
    fi
}

requirements() {
    log "Installing requirements..."

    # .NET SDK + base tools (delegates to build-appimage.sh)
    ARCH="$ARCH" OUTPUT_DIR="$OUTPUT_DIR" bash "$APPIMAGE_SCRIPT" requirements

    # build-appimage.sh installs dotnet in a subprocess, so PATH doesn't propagate.
    if [[ -d "$HOME/.dotnet" ]] && ! command -v dotnet >/dev/null 2>&1; then
        export PATH="$HOME/.dotnet:$PATH"
    fi

    # fpm and its dependencies
    if ! command -v fpm >/dev/null 2>&1; then
        info "Installing fpm..."
        if [[ -f /etc/debian_version ]]; then
            apt-get update
            apt-get install -y ruby ruby-dev gcc make
        elif [[ -f /etc/redhat-release ]]; then
            dnf install -y ruby ruby-devel gcc make rpm-build
        fi
        gem install fpm
    fi

    info "fpm $(fpm --version)"
}

ensure-published() {
    local publish_dir="$SRC_DIR/AvPurplePen/bin/Release/net10.0/publish/$RID"

    # Ensure dotnet is on PATH (may have been installed by requirements() subprocess)
    if [[ -d "$HOME/.dotnet" ]] && ! command -v dotnet >/dev/null 2>&1; then
        export PATH="$HOME/.dotnet:$PATH"
    fi

    if [[ ! -d "$publish_dir" ]] || [[ -z "$(ls -A "$publish_dir" 2>/dev/null)" ]]; then
        log "No publish output found. Running publish via build-appimage.sh..."
        ARCH="$ARCH" OUTPUT_DIR="$OUTPUT_DIR" bash "$APPIMAGE_SCRIPT" \
            apply-patches extract-version publish prepare-icon
    fi

    # Detect binary name
    if [[ -f "$publish_dir/PurplePen" ]]; then
        APP_BINARY="PurplePen"
    elif [[ -f "$publish_dir/AvPurplePen" ]]; then
        APP_BINARY="AvPurplePen"
    else
        die "Cannot find main binary in $publish_dir"
    fi
    info "Detected main binary: $APP_BINARY"
}

extract-version() {
    local version_file="$SRC_DIR/PurplePenCore/VersionNumber.cs"
    [[ -f "$version_file" ]] || die "Version file not found: $version_file"
    FULL_VERSION="$(sed -n 's/.*Current[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' "$version_file")"
    SHORT_VERSION="$(printf "%s" "$FULL_VERSION" | cut -d. -f1-3)"
    [[ -n "$FULL_VERSION" ]] || die "Could not extract version from $version_file"
}

stage() {
    local publish_dir="$SRC_DIR/AvPurplePen/bin/Release/net10.0/publish/$RID"
    local icon_svg="$SRC_DIR/PurplePen/Images/icon.svg"
    local icon_256="$SCRIPT_DIR/org.purplepen.PurplePen.png"

    log "Staging package tree..."

    rm -rf "$STAGING_DIR"
    mkdir -p \
        "$STAGING_DIR/opt/purplepen" \
        "$STAGING_DIR/usr/bin" \
        "$STAGING_DIR/usr/share/applications" \
        "$STAGING_DIR/usr/share/icons/hicolor/256x256/apps" \
        "$STAGING_DIR/usr/share/icons/hicolor/scalable/apps" \
        "$STAGING_DIR/usr/share/metainfo" \
        "$STAGING_DIR/usr/share/mime/packages"

    # Application files
    cp -a "$publish_dir"/. "$STAGING_DIR/opt/purplepen/"
    chmod +x "$STAGING_DIR/opt/purplepen/$APP_BINARY"
    if [[ -f "$STAGING_DIR/opt/purplepen/PdfConverter" ]]; then
        chmod +x "$STAGING_DIR/opt/purplepen/PdfConverter"
    fi

    # Launcher symlink
    ln -sf "/opt/purplepen/$APP_BINARY" "$STAGING_DIR/usr/bin/purplepen"

    # Desktop file with correct Exec path
    sed "s|^Exec=.*|Exec=/usr/bin/purplepen %f|" \
        "$SCRIPT_DIR/org.purplepen.PurplePen.desktop" \
        > "$STAGING_DIR/usr/share/applications/org.purplepen.PurplePen.desktop"

    # Icons
    if [[ -f "$icon_256" ]]; then
        cp "$icon_256" "$STAGING_DIR/usr/share/icons/hicolor/256x256/apps/org.purplepen.PurplePen.png"
    fi
    if [[ -f "$icon_svg" ]]; then
        cp "$icon_svg" "$STAGING_DIR/usr/share/icons/hicolor/scalable/apps/org.purplepen.PurplePen.svg"
    fi

    # Metadata
    cp "$SCRIPT_DIR/org.purplepen.PurplePen.metainfo.xml" \
        "$STAGING_DIR/usr/share/metainfo/"
    cp "$SCRIPT_DIR/org.purplepen.PurplePen-ppen.xml" \
        "$STAGING_DIR/usr/share/mime/packages/"

    info "Staged to: $STAGING_DIR"
}

run-fpm() {
    local pkg_type="$1"
    local iteration="${ITERATION:-1}"

    if ! command -v fpm >/dev/null 2>&1; then
        die "fpm not found. Install with: gem install fpm"
    fi

    log "Building .$pkg_type package..."

    # Dependencies differ between deb and rpm
    local -a deps=()
    case "$pkg_type" in
        deb)
            deps=(
                --depends "libfontconfig1"
                --depends "libfreetype6"
                --depends "libx11-6"
                --depends "libice6"
                --depends "libsm6"
                --depends "zlib1g"
            )
            ;;
        rpm)
            deps=(
                --depends "fontconfig"
                --depends "freetype"
                --depends "libX11"
                --depends "libICE"
                --depends "libSM"
                --depends "zlib"
            )
            ;;
    esac

    # Architecture flag
    local fpm_arch=""
    case "$pkg_type" in
        deb) fpm_arch="$DEB_ARCH" ;;
        rpm) fpm_arch="$RPM_ARCH" ;;
    esac

    mkdir -p "$OUTPUT_DIR"

    fpm -s dir -t "$pkg_type" \
        -n purplepen \
        -v "$FULL_VERSION" \
        --iteration "$iteration" \
        --architecture "$fpm_arch" \
        --license "MIT" \
        --vendor "Purple Pen Software" \
        --maintainer "Purple Pen Software" \
        --url "https://purple-pen.org" \
        --description "Course setting software for orienteering" \
        --category "Education" \
        "${deps[@]}" \
        --after-install "$SCRIPT_DIR/postinst.sh" \
        --after-remove "$SCRIPT_DIR/postrm.sh" \
        --force \
        -C "$STAGING_DIR" \
        -p "$OUTPUT_DIR/" \
        .

    local pkg_file
    pkg_file="$(ls -t "$OUTPUT_DIR"/purplepen*."$pkg_type" 2>/dev/null | head -1)"
    if [[ -n "$pkg_file" ]]; then
        info "Created: $pkg_file ($(du -h "$pkg_file" | cut -f1))"
    fi
}

build-deb() {
    ensure-published
    extract-version
    stage
    run-fpm deb
    rm -rf "$STAGING_DIR"
}

build-rpm() {
    ensure-published
    extract-version
    stage
    run-fpm rpm
    rm -rf "$STAGING_DIR"
}

build() {
    ensure-published
    extract-version

    echo "=== PurplePen Package Builder (fpm) ==="
    printf "  Version:      %s\n" "$FULL_VERSION"
    printf "  Architecture: %s\n" "$ARCH"
    printf "  Binary:       %s\n" "$APP_BINARY"
    echo ""

    stage
    run-fpm deb
    run-fpm rpm
    rm -rf "$STAGING_DIR"

    echo ""
    echo "=== Done ==="
    ls -lh "$OUTPUT_DIR"/purplepen*.deb "$OUTPUT_DIR"/purplepen*.rpm 2>/dev/null
}

# ---------------------------------------------------------------------------
# Target registry
# ---------------------------------------------------------------------------

readonly -a TARGETS=(
    setup-env
    requirements
    ensure-published
    extract-version
    stage
    build-deb
    build-rpm
    build
)

declare -A TARGET_DESC=(
    [setup-env]="Resolve paths and architecture"
    [requirements]="Install system dependencies, .NET SDK, and fpm"
    [ensure-published]="Run dotnet publish if no output exists"
    [extract-version]="Read version from VersionNumber.cs"
    [stage]="Create FHS staging tree from publish output"
    [build-deb]="Build .deb package"
    [build-rpm]="Build .rpm package"
    [build]="Build both .deb and .rpm packages"
)

show-usage() {
    cat <<'HEADER'
Usage: [ENV_VARS] ./packaging/linux/build-packages.sh [TARGET...]

Build .deb and .rpm packages using fpm. Requires a prior dotnet publish
(runs it automatically if missing).

HEADER
    printf "Targets:\n"
    local target
    for target in "${TARGETS[@]}"; do
        printf "  %-22s %s\n" "$target" "${TARGET_DESC[$target]}"
    done
    cat <<'FOOTER'

Environment variables:
  ARCH        Target architecture: x64 (default) or arm64
  OUTPUT_DIR  Where to write the packages (default: repo root)
  ITERATION   Package iteration/release number (default: 1)
  DEBUG       Set to 1 to enable shell tracing (set -x)

Examples:
  ./packaging/linux/build-packages.sh               # build both
  ./packaging/linux/build-packages.sh build-deb      # .deb only
  ./packaging/linux/build-packages.sh build-rpm      # .rpm only
  ARCH=arm64 ./packaging/linux/build-packages.sh
FOOTER
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
    if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        show-usage
        exit 0
    fi

    setup-env

    if [[ $# -eq 0 ]]; then
        build
    else
        local target
        for target in "$@"; do
            if [[ "$(type -t "$target" 2>/dev/null)" == "function" ]] \
                && [[ -n "${TARGET_DESC[$target]+x}" ]]; then
                "$target"
            else
                printf "Unknown target: %s\n\n" "$target" >&2
                show-usage >&2
                exit 1
            fi
        done
    fi
}

main "$@"
