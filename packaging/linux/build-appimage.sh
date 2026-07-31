#!/usr/bin/env bash
#
# build-appimage.sh — Build a PurplePen AppImage in one command.
#
# Environment variables:
#   ARCH        Target architecture: x64 (default) or arm64
#   OUTPUT_DIR  Where to write the final .AppImage (default: repo root)
#   DEBUG       Set to 1 to enable shell tracing (set -x)
#
# Usage:
#   ./packaging/linux/build-appimage.sh
#   ARCH=arm64 OUTPUT_DIR=~/releases ./packaging/linux/build-appimage.sh
#   DEBUG=1 ./packaging/linux/build-appimage.sh
#
# Prerequisites:
#   - .NET 10 SDK (dotnet)
#   - wget or curl (to download appimagetool on first run)
#   - Optional: librsvg (rsvg-convert) or ImageMagick (convert) for icon resizing

set -euo pipefail
[[ "${DEBUG:-}" == "1" ]] && set -x

# ---------------------------------------------------------------------------
# Globals — populated by setup-env, used by all subsequent functions.
# ---------------------------------------------------------------------------
SCRIPT_DIR=""
REPO_ROOT=""
SUBMODULE_DIR=""
SRC_DIR=""
TOOLS_DIR=""
APPDIR=""
APPIMAGE_ARCH=""
RID=""
FULL_VERSION=""
SHORT_VERSION=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    printf ">>> %s\n" "$*"
}

info() {
    printf "    %s\n" "$*"
}

die() {
    printf "    ERROR: %s\n" "$*" >&2
    exit 1
}

download() {
    local url="$1"
    local dest="$2"

    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$dest" "$url"
    else
        die "Neither wget nor curl found. Cannot download: $url"
    fi
}

# ---------------------------------------------------------------------------
# Functions — bricks that main calls in sequence.
# ---------------------------------------------------------------------------

setup-env() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    SUBMODULE_DIR="$REPO_ROOT/src"
    SRC_DIR="$SUBMODULE_DIR/src"

    ARCH="${ARCH:-x64}"
    OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT}"

    case "$ARCH" in
        x64)   APPIMAGE_ARCH="x86_64" ;;
        arm64) APPIMAGE_ARCH="aarch64" ;;
        *)     die "Unsupported architecture: $ARCH (use x64 or arm64)" ;;
    esac

    RID="linux-$ARCH"
    TOOLS_DIR="$SCRIPT_DIR/tools"
    APPDIR="$REPO_ROOT/PurplePen.AppDir"

    # RHEL 10+ / Fedora 41+ block SHA-1 signatures via crypto policy, but
    # .NET strong-name signing requires SHA-1.
    if [[ -f /etc/redhat-release ]] && [[ -z "${OPENSSL_ENABLE_SHA1_SIGNATURES:-}" ]]; then
        export OPENSSL_ENABLE_SHA1_SIGNATURES=1
    fi
}

requirements() {
    log "Installing requirements..."

    if [[ -f /etc/debian_version ]]; then
        apt-get update
        apt-get install -y \
		ca-certificates \
		file \
		fuse \
		git \
		libfuse2 \
		librsvg2-bin \
		make \
		wget \
		;
    elif [[ -f /etc/redhat-release ]]; then
        dnf install -y \
		file \
		fuse \
		fuse-libs \
		git \
		libicu \
		librsvg2-tools \
		make \
		wget \
	       ;	
    else
        die "Unsupported distro. Install manually: git, wget, fuse, librsvg2, .NET 10 SDK"
    fi

    if ! command -v dotnet >/dev/null 2>&1; then
        info "Installing .NET 10 SDK..."
        local installer="/tmp/dotnet-install.sh"
        download "https://dot.net/v1/dotnet-install.sh" "$installer"
        chmod +x "$installer"
        "$installer" --channel 10.0
        export PATH="$HOME/.dotnet:$PATH"
    fi

    git config --global --add safe.directory "$REPO_ROOT"
    git config --global --add safe.directory "$SUBMODULE_DIR"

    info "dotnet $(dotnet --version)"
}

apply-patches() {
    local patches_dir="$REPO_ROOT/patches"

    [[ -d "$patches_dir" ]] || return 0

    local -a patch_files=("$patches_dir"/*.patch)
    [[ -e "${patch_files[0]}" ]] || return 0

    log "Applying source patches..."
    local patch_file patch_name
    for patch_file in "${patch_files[@]}"; do
        patch_name="$(basename "$patch_file")"
        if git -C "$SUBMODULE_DIR" apply --check --ignore-whitespace "$patch_file" >/dev/null 2>&1; then
            git -C "$SUBMODULE_DIR" apply --ignore-whitespace "$patch_file"
            info "Applied: $patch_name"
        else
            die "Patch failed to apply: $patch_name"
        fi
    done
    echo ""
}

extract-version() {
    local version_file="$SRC_DIR/PurplePenCore/VersionNumber.cs"

    [[ -f "$version_file" ]] || die "Version file not found: $version_file"

    FULL_VERSION="$(sed -n 's/.*Current[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' "$version_file")"
    SHORT_VERSION="$(printf "%s" "$FULL_VERSION" | cut -d. -f1-3)"

    [[ -n "$FULL_VERSION" ]] || die "Could not extract version from $version_file"
}

publish() {
    local publish_dir="$SRC_DIR/AvPurplePen/bin/Release/net10.0/publish/$RID"
    local pdfconv_tmp="$REPO_ROOT/_pdfconverter-tmp"

    log "Publishing AvPurplePen ($RID, self-contained)..."

    local -a dotnet_props=(
        -p:PublishReadyToRun=false
        -p:PublishTrimmed=false
    )

    dotnet restore "$SRC_DIR/AvPurplePen/AvPurplePen.csproj" -r "$RID"

    dotnet publish "$SRC_DIR/AvPurplePen/AvPurplePen.csproj" \
        -c Release \
        -r "$RID" \
        --self-contained true \
        "${dotnet_props[@]}" \
        -o "$publish_dir"

    info "Published to: $publish_dir"

    # Republish PdfConverter self-contained for the target RID (INSTALLERS.md §2.3).
    # The MSBuild CopyPdfConverterToPublishOutput target copies a framework-dependent
    # build which cannot start next to a self-contained app. Overlay the self-contained
    # version so libpdfium lands at the root and the helper's apphost works.
    # Use -p:BaseOutputPath to avoid poisoning the next build (§2.4).
    log "Overlaying self-contained PdfConverter ($RID)..."
    rm -rf "$pdfconv_tmp"
    dotnet publish "$SRC_DIR/PdfConverter/PdfConverter.csproj" \
        -c Release \
        -r "$RID" \
        --self-contained true \
        "${dotnet_props[@]}" \
        -p:BaseOutputPath="$pdfconv_tmp/obj/" \
        -o "$pdfconv_tmp/out"

    cp -a "$pdfconv_tmp/out"/. "$publish_dir/"
    rm -rf "$pdfconv_tmp"
    info "PdfConverter overlay applied"

    # Strip the orphaned runtimes/ directory (INSTALLERS.md §2.2).
    # RID-specific publish flattens native libs to the root; runtimes/ is ~400 MB
    # of unused multi-platform binaries (verified: 0 runtimeTargets in deps.json).
    if [[ -d "$publish_dir/runtimes" ]]; then
        local runtimes_size
        runtimes_size="$(du -sh "$publish_dir/runtimes" | cut -f1)"
        rm -rf "$publish_dir/runtimes"
        info "Stripped orphaned runtimes/ directory ($runtimes_size)"
    fi
}

prepare-icon() {
    local icon_svg="$SRC_DIR/PurplePen/Images/icon.svg"
    local icon_large_png="$SRC_DIR/PurplePen/Images/icon_large.png"
    local icon_256="$SCRIPT_DIR/org.purplepen.PurplePen.png"

    log "Preparing icon..."

    if [[ -f "$icon_256" ]]; then
        info "Using existing icon: $icon_256"
        return 0
    fi

    if command -v rsvg-convert >/dev/null 2>&1 && [[ -f "$icon_svg" ]]; then
        rsvg-convert -w 256 -h 256 "$icon_svg" -o "$icon_256"
        info "Generated 256x256 icon from SVG via rsvg-convert"
    elif command -v convert >/dev/null 2>&1 && [[ -f "$icon_large_png" ]]; then
        convert "$icon_large_png" -resize 256x256 "$icon_256"
        info "Generated 256x256 icon from icon_large.png via ImageMagick"
    elif [[ -f "$icon_large_png" ]]; then
        cp "$icon_large_png" "$icon_256"
        info "WARNING: No rsvg-convert or ImageMagick found. Using icon_large.png as-is (1024x1024)."
    else
        die "No icon source found."
    fi
}

build-appdir() {
    local publish_dir="$SRC_DIR/AvPurplePen/bin/Release/net10.0/publish/$RID"
    local icon_svg="$SRC_DIR/PurplePen/Images/icon.svg"
    local icon_256="$SCRIPT_DIR/org.purplepen.PurplePen.png"

    log "Building AppDir..."

    # Detect the main binary name. Upstream renamed AssemblyName from
    # AvPurplePen to PurplePen; handle both.
    local app_binary=""
    if [[ -f "$publish_dir/PurplePen" ]]; then
        app_binary="PurplePen"
    elif [[ -f "$publish_dir/AvPurplePen" ]]; then
        app_binary="AvPurplePen"
    else
        die "Cannot find main binary (PurplePen or AvPurplePen) in $publish_dir"
    fi
    info "Detected main binary: $app_binary"

    rm -rf "$APPDIR"
    mkdir -p \
        "$APPDIR/usr/bin" \
        "$APPDIR/usr/share/applications" \
        "$APPDIR/usr/share/icons/hicolor/256x256/apps" \
        "$APPDIR/usr/share/icons/hicolor/scalable/apps" \
        "$APPDIR/usr/share/metainfo" \
        "$APPDIR/usr/share/mime/packages"

    cp -a "$publish_dir"/. "$APPDIR/usr/bin/"

    # Install .desktop file with the correct Exec= for this build
    sed "s|^Exec=.*|Exec=$app_binary %f|" \
        "$SCRIPT_DIR/org.purplepen.PurplePen.desktop" > "$APPDIR/org.purplepen.PurplePen.desktop"
    cp "$APPDIR/org.purplepen.PurplePen.desktop" "$APPDIR/usr/share/applications/"

    cp "$icon_256" "$APPDIR/"
    cp "$icon_256" "$APPDIR/usr/share/icons/hicolor/256x256/apps/"
    if [[ -f "$icon_svg" ]]; then
        cp "$icon_svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.purplepen.PurplePen.svg"
    fi
    cp "$SCRIPT_DIR/org.purplepen.PurplePen.metainfo.xml" "$APPDIR/usr/share/metainfo/"
    cp "$SCRIPT_DIR/org.purplepen.PurplePen-ppen.xml" "$APPDIR/usr/share/mime/packages/"

    # AppRun uses the detected binary name
    cat > "$APPDIR/AppRun" <<APPRUN_EOF
#!/usr/bin/env bash
SELF_DIR="\$(dirname "\$(readlink -f "\$0")")"
export PATH="\$SELF_DIR/usr/bin:\$PATH"
exec "\$SELF_DIR/usr/bin/$app_binary" "\$@"
APPRUN_EOF
    chmod +x "$APPDIR/AppRun"

    chmod +x "$APPDIR/usr/bin/$app_binary"
    if [[ -f "$APPDIR/usr/bin/PdfConverter" ]]; then
        chmod +x "$APPDIR/usr/bin/PdfConverter"
    fi

    info "AppDir created at: $APPDIR"
}

fetch-appimagetool() {
    local appimagetool="$TOOLS_DIR/appimagetool"

    [[ -x "$appimagetool" ]] && return 0

    log "Downloading appimagetool..."
    mkdir -p "$TOOLS_DIR"

    local url="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    download "$url" "$appimagetool"
    chmod +x "$appimagetool"
    info "Downloaded appimagetool to: $appimagetool"
}

create-appimage() {
    local appimagetool="$TOOLS_DIR/appimagetool"
    local appimage_name="PurplePen-${SHORT_VERSION}-${APPIMAGE_ARCH}.AppImage"
    local appimage_path="$OUTPUT_DIR/$appimage_name"

    log "Creating AppImage..."
    mkdir -p "$OUTPUT_DIR"

    if ARCH="$APPIMAGE_ARCH" "$appimagetool" "$APPDIR" "$appimage_path" >/dev/null 2>&1; then
        info "Created AppImage via appimagetool"
    else
        info "appimagetool requires FUSE (not available). Building manually..."
        build-appimage-manual "$appimage_path"
    fi

    chmod +x "$appimage_path"
    rm -rf "$APPDIR"

    echo ""
    echo "=== Done ==="
    printf "  AppImage: %s\n" "$appimage_path"
    printf "  Size:     %s\n" "$(du -h "$appimage_path" | cut -f1)"
    echo ""
    printf "To run:  ./%s\n" "$appimage_name"
}

build-appimage-manual() {
    local appimage_path="$1"
    local extracted="$TOOLS_DIR/appimagetool-extracted"
    local appimagetool="$TOOLS_DIR/appimagetool"
    local runtime="$TOOLS_DIR/runtime-$APPIMAGE_ARCH"
    local squashfs_tmp="$TOOLS_DIR/PurplePen.squashfs"

    if [[ ! -d "$extracted" ]]; then
        (cd "$TOOLS_DIR" && "$appimagetool" --appimage-extract >/dev/null 2>&1)
        mv "$TOOLS_DIR/squashfs-root" "$extracted"
    fi

    if [[ ! -f "$runtime" ]]; then
        local runtime_url="https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-$APPIMAGE_ARCH"
        download "$runtime_url" "$runtime"
    fi

    "$extracted/usr/bin/mksquashfs" "$APPDIR" "$squashfs_tmp" \
        -root-owned -noappend -comp zstd -Xcompression-level 3 -quiet
    cat "$runtime" "$squashfs_tmp" > "$appimage_path"
    chmod +x "$appimage_path"
    rm -f "$squashfs_tmp"
    info "Created AppImage manually (runtime + squashfs)"
}

# ---------------------------------------------------------------------------
# Target registry — defines the public targets and their descriptions.
# ---------------------------------------------------------------------------

readonly -a TARGETS=(
    setup-env
    requirements
    apply-patches
    extract-version
    publish
    prepare-icon
    build-appdir
    fetch-appimagetool
    create-appimage
    build
)

declare -A TARGET_DESC=(
    [setup-env]="Resolve paths, map architecture, apply RHEL SHA-1 workaround"
    [requirements]="Install system dependencies, .NET SDK, and git safe directories"
    [apply-patches]="Apply patches/*.patch to the upstream submodule"
    [extract-version]="Read version from VersionNumber.cs"
    [publish]="dotnet restore + dotnet publish (self-contained)"
    [prepare-icon]="Generate or reuse 256x256 PNG icon"
    [build-appdir]="Assemble the AppDir tree from published output"
    [fetch-appimagetool]="Download appimagetool if not cached"
    [create-appimage]="Package AppDir into a portable .AppImage"
    [build]="Run the full build pipeline (patches through AppImage)"
)

show-usage() {
    cat <<'HEADER'
Usage: [ENV_VARS] ./packaging/linux/build-appimage.sh [TARGET...]

Run the full build pipeline (no arguments), or run individual targets.

HEADER
    printf "Targets:\n"
    local target
    for target in "${TARGETS[@]}"; do
        printf "  %-22s %s\n" "$target" "${TARGET_DESC[$target]}"
    done
    cat <<'FOOTER'

Environment variables:
  ARCH        Target architecture: x64 (default) or arm64
  OUTPUT_DIR  Where to write the final .AppImage (default: repo root)
  DEBUG       Set to 1 to enable shell tracing (set -x)

Examples:
  ./packaging/linux/build-appimage.sh
  ./packaging/linux/build-appimage.sh apply-patches extract-version
  ARCH=arm64 ./packaging/linux/build-appimage.sh publish build-appdir
  DEBUG=1 ./packaging/linux/build-appimage.sh
FOOTER
}

# ---------------------------------------------------------------------------
# build — the full pipeline as a callable target.
# ---------------------------------------------------------------------------

build() {
    apply-patches
    extract-version

    echo "=== PurplePen AppImage Builder ==="
    printf "  Version:      %s\n" "$FULL_VERSION"
    printf "  Architecture: %s (%s)\n" "$ARCH" "$APPIMAGE_ARCH"
    printf "  RID:          %s\n" "$RID"
    echo ""

    publish
    prepare-icon
    build-appdir
    fetch-appimagetool
    create-appimage
}

# ---------------------------------------------------------------------------
# main — dispatches targets or runs the full pipeline.
# ---------------------------------------------------------------------------

main() {
    if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        show-usage
        exit 0
    fi

    # Always run setup-env first.
    setup-env

    if [[ $# -eq 0 ]]; then
        build
    else
        # Run requested targets in order.
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
