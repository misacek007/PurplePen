# PurplePen Linux Packaging

Linux packaging tooling for [PurplePen](https://github.com/petergolde/PurplePen),
a desktop course-setting program for orienteering races.
Builds both AppImage and Flatpak formats.
Flatpak install instructions: [misacek007.github.io/PurplePen](https://misacek007.github.io/PurplePen/)

The upstream PurplePen source is included as a git submodule at `src/`.
Source patches for Linux compatibility are maintained in `patches/` and
applied automatically at build time.

## Quick Start

### AppImage

```bash
git clone --recurse-submodules https://github.com/misacek007/PurplePen.git
cd PurplePen
make build
```

### Flatpak

```bash
make flatpak-install
make flatpak-run
```

This installs all dependencies (flatpak, flatpak-builder, SDK, runtime,
dotnet10 extension), builds the Flatpak, and installs it locally.

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init
```

## Build from a Specific Upstream Tag

```bash
make build TAG=master           # upstream master (AppImage)
make build TAG=3.5.4            # specific tag (patches must be compatible)
make check-patches TAG=master   # verify patches apply without building
```

**Note:** The patches target the Avalonia codebase (post-3.5.4 development
on master). Older tags like 3.5.4 use a different project structure and
are not compatible with the current patches or build script.

## Makefile Targets

### AppImage

| Target | Description |
|---|---|
| `make build` | Build AppImage from current submodule commit |
| `make build TAG=<ref>` | Checkout upstream ref and build |
| `make check-patches` | Verify patches apply cleanly (dry-run) |
| `make update TAG=<ref>` | Checkout upstream ref without building |

Options: `ARCH=x64|arm64` (default: x64), `OUTPUT_DIR=<path>` (default: repo root).

### Flatpak

| Target | Description |
|---|---|
| `make flatpak-deps` | Install flatpak, flatpak-builder, SDK, runtime, and dotnet10 extension |
| `make flatpak` | Build Flatpak (installs deps first) |
| `make flatpak-install` | Build and install Flatpak locally (`--user`) |
| `make flatpak-run` | Run the installed Flatpak |
| `make flatpak-nuget-sources` | Regenerate `nuget-sources.json` |

### Container builds (podman)

| Target | Description |
|---|---|
| `make cont-build-ubuntu` | Build AppImage in Ubuntu 24.04 container |
| `make cont-build-centos` | Build AppImage in CentOS Stream 9 container |
| `make cont-enter` | Interactive shell in Ubuntu container (`CONT=centos` for CentOS) |

### Utilities

| Target | Description |
|---|---|
| `make clean` | Remove build artifacts and reset submodule |

## Flatpak

A Flatpak repository is published to GitHub Pages on every push to `master`.

### Install from the repository

```bash
flatpak remote-add --user --if-not-exists purplepen \
  https://misacek007.github.io/PurplePen/index.flatpakrepo
flatpak install --user purplepen org.purplepen.PurplePen
```

### Update

```bash
flatpak update
```

### Inspect installed files

```bash
# List all files installed by the Flatpak
flatpak info -l org.purplepen.PurplePen       # show install path
ls $(flatpak info -l org.purplepen.PurplePen)/files/

# Browse the full install tree
flatpak run --command=ls org.purplepen.PurplePen /app/bin/
flatpak run --command=ls org.purplepen.PurplePen /app/share/

# Show app metadata (permissions, runtime, SDK extensions)
flatpak info org.purplepen.PurplePen
flatpak info -m org.purplepen.PurplePen       # raw metadata
```

### Regenerate NuGet sources

When NuGet dependencies change, regenerate the offline package list:

```bash
make flatpak-nuget-sources
```

This requires the .NET 10 SDK, python3, and network access. Commit the
updated `nuget-sources.json` afterwards.

## Repository Structure

```
Makefile               Build entry point
.github/workflows/     CI workflows (AppImage + Flatpak)
packaging/linux/       AppImage build script, desktop metadata, AppStream info
packaging/flatpak/     Flatpak manifest, NuGet sources, and landing page
patches/               Source patches applied before building (Linux fixes)
src/                   Git submodule -> petergolde/PurplePen
```

## Updating Upstream

```bash
make update TAG=master
make check-patches
git add src
git commit -m "chore: update upstream submodule"
```

If patches fail to apply against the new upstream, rebase them manually
and regenerate the `.patch` files.

## Prerequisites

See [packaging/linux/README.md](packaging/linux/README.md) for full
AppImage build prerequisites and options. For Flatpak, `make flatpak-deps`
handles all dependencies automatically.
