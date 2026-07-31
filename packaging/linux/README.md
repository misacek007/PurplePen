# PurplePen Linux AppImage Packaging

This directory contains everything needed to build a universal Linux AppImage
for PurplePen in a single command.

## Quick Start

From the repository root:

```bash
./packaging/linux/build-appimage.sh
```

This produces `PurplePen-<version>-x86_64.AppImage` in the repository root.

To run it:

```bash
chmod +x PurplePen-*.AppImage
./PurplePen-*.AppImage
```

## Prerequisites

| Requirement | Purpose |
|---|---|
| **.NET 10 SDK** | Builds and publishes the application |
| **wget** or **curl** | Downloads `appimagetool` on first run (cached afterward) |
| **FUSE** | Required by the Linux kernel to mount AppImages at runtime |

Optional (for icon generation):

| Tool | Purpose |
|---|---|
| **rsvg-convert** (librsvg) | Generates 256x256 PNG from the master SVG icon (preferred) |
| **ImageMagick** (`convert`) | Alternative icon resizer if librsvg is not available |

If neither is installed, the script copies the existing 1024x1024 PNG as a
fallback. The AppImage still works, but the icon is oversized.

### Installing prerequisites on Debian / Ubuntu

```bash
# .NET 10 SDK (see https://learn.microsoft.com/dotnet/core/install/linux-debian for latest instructions)
sudo apt update
sudo apt install -y dotnet-sdk-10.0

# Build essentials and FUSE
sudo apt install -y wget fuse libfuse2

# Optional: icon generation (pick one)
sudo apt install -y librsvg2-bin    # provides rsvg-convert (preferred)
# or
sudo apt install -y imagemagick     # provides convert
```

### Installing prerequisites on CentOS / RHEL / Fedora

```bash
# .NET 10 SDK (see https://learn.microsoft.com/dotnet/core/install/linux-centos for latest instructions)
sudo dnf install -y dotnet-sdk-10.0

# Build essentials and FUSE
sudo dnf install -y wget fuse fuse-libs

# Optional: icon generation (pick one)
sudo dnf install -y librsvg2-tools   # provides rsvg-convert (preferred)
# or
sudo dnf install -y ImageMagick      # provides convert
```

### RHEL 10+ / Fedora 41+ (crypto policy note)

These distributions restrict SHA-1 signatures by default via their system
crypto policy. .NET strong-name signing (used by the bundled PdfSharp library)
requires SHA-1, so the build script automatically sets
`OPENSSL_ENABLE_SHA1_SIGNATURES=1` when `/etc/redhat-release` is detected.
This only affects the build process — the resulting AppImage runs under normal
crypto policy.

### Building without FUSE

The `appimagetool` binary is itself an AppImage that needs FUSE to run. If
FUSE is unavailable (e.g., in containers or minimal installs), the build
script automatically falls back to extracting `appimagetool`, downloading the
AppImage type-2 runtime, and assembling the AppImage manually with
`mksquashfs`. No extra steps are needed.

## Build Options

```
./packaging/linux/build-appimage.sh [--arch x64|arm64] [--output-dir DIR]
```

| Flag | Default | Description |
|---|---|---|
| `--arch` | `x64` | Target CPU architecture. `x64` for standard PCs, `arm64` for Raspberry Pi / ARM servers |
| `--output-dir` | Repository root | Where to write the final `.AppImage` file |

Examples:

```bash
# Build for ARM64
./packaging/linux/build-appimage.sh --arch arm64

# Build and place output in a release directory
./packaging/linux/build-appimage.sh --output-dir ~/releases
```

## What the Script Does

1. **Publishes** the main app as a self-contained .NET application for the
   target Linux RID (`linux-x64` or `linux-arm64`).

2. **Overlays PdfConverter** — republishes the PDF conversion helper as
   self-contained for the same RID and overlays it onto the publish directory.
   This is required because the MSBuild `CopyPdfConverterToPublishOutput`
   target copies a framework-dependent build that cannot start next to a
   self-contained app (see upstream `INSTALLERS.md` §2.3). The overlay also
   flattens `libpdfium.so` to the output root.

3. **Strips the `runtimes/` directory** — a RID-specific publish flattens
   native libraries to the output root, making the multi-platform `runtimes/`
   tree orphaned (~400 MB of dead weight, verified 0 `runtimeTargets` in
   `deps.json`). Only safe to strip after step 2 puts `libpdfium.so` at the
   root.

4. **Detects the main binary name** — upstream renamed the assembly from
   `AvPurplePen` to `PurplePen`. The script auto-detects which binary exists
   in the publish output and wires AppRun and the `.desktop` file accordingly.

5. **Prepares the icon** by generating a 256x256 PNG from the master SVG, or
   falls back to the existing large PNG.

6. **Assembles the AppDir** — the standard AppImage directory layout:
   ```
   PurplePen.AppDir/
   ├── AppRun                              # Entry point script
   ├── org.purplepen.PurplePen.desktop     # Desktop integration
   ├── org.purplepen.PurplePen.png         # App icon
   └── usr/
       ├── bin/                            # Full published application
       │   ├── PurplePen (or AvPurplePen)  # Main binary
       │   ├── PdfConverter                # PDF conversion sidecar
       │   ├── fonts/                      # Bundled Roboto fonts
       │   ├── Samples/                    # Sample event files
       │   └── ...                         # .NET runtime, SkiaSharp, etc.
       └── share/
           ├── applications/               # .desktop file
           ├── icons/hicolor/              # Icons (256x256 + scalable SVG)
           ├── metainfo/                   # AppStream metadata
           └── mime/packages/              # .ppen MIME type definition
   ```

7. **Downloads `appimagetool`** (if not already cached in `packaging/linux/tools/`)
   from the official AppImage GitHub releases.

8. **Creates the AppImage** — a single executable file containing the entire
   application. The version number is read from `VersionNumber.cs`.

9. **Cleans up** the temporary AppDir.

## What's Included in the AppImage

The AppImage is fully self-contained. Users do not need .NET, SkiaSharp, or
any other dependency installed on their system. It bundles:

- PurplePen (Avalonia cross-platform UI)
- PdfConverter (PDF map template conversion)
- .NET 10 runtime
- SkiaSharp + HarfBuzz native libraries
- PDFium native library
- Roboto font family (18 variants + TeX Gyre Pagella)
- Sample orienteering event files
- All locale/translation satellite assemblies

## Desktop Integration

When run, the AppImage integrates with the Linux desktop:

- **Application menu**: appears as "Purple Pen" under Education/Graphics
- **File association**: `.ppen` files are associated with the MIME type
  `application/x-purplepen`
- **Icon**: installs into the hicolor icon theme

Some desktop environments (GNOME, KDE) pick up these automatically via
`libappimage` or the AppImage launcher daemon. Others may require manual
integration — users can extract the `.desktop` file from the AppImage with:

```bash
./PurplePen-*.AppImage --appimage-extract org.purplepen.PurplePen.desktop
```

## Files in This Directory

| File | Purpose |
|---|---|
| `build-appimage.sh` | The build script (one command to produce an AppImage) |
| `org.purplepen.PurplePen.desktop` | Freedesktop `.desktop` file for application menu integration |
| `org.purplepen.PurplePen.metainfo.xml` | AppStream metadata for software centers |
| `org.purplepen.PurplePen-ppen.xml` | MIME type definition for `.ppen` event files |
| `tools/` | Auto-populated cache for `appimagetool` (gitignored) |

## Source Patches for Linux Support

Several source code changes are required for Linux compatibility. These are
maintained as `.patch` files in the `patches/` directory at the repository
root and are applied automatically by the build script before compilation.

Current patches:
1. **PdfConverter path fix** — `FindPdfConverterExe()` selects the correct
   binary name per platform (`PdfConverter` on Linux vs `PdfConverter.exe`
   on Windows).
2. **HtmlPanel managed renderer** — Uses `Avalonia.HtmlRenderer` on Linux
   instead of `NativeWebView` (WebView2), which is Windows-only.
3. **Satellite assembly Culture metadata** — Adds explicit `<Culture>`
   elements to `.csproj` files so satellite assemblies build correctly
   without ICU (`DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`).

To update patches when upstream changes the patched files:
```bash
cd src
git apply --check ../patches/*.patch    # check if patches still apply
# If they fail, rebase manually and regenerate:
#   git format-patch --relative=src/ <old-base>..<new-base> -- src/
```

## Troubleshooting

**"AppImages require FUSE to run"**: Install FUSE (`sudo apt install fuse`
on Debian/Ubuntu, `sudo dnf install fuse` on Fedora), or extract and run
directly:

```bash
./PurplePen-*.AppImage --appimage-extract
./squashfs-root/AppRun
```

**PdfConverter not found at runtime**: The build script republishes
PdfConverter self-contained and overlays it onto the main publish output.
If the overlay step fails, verify that `PdfConverter` exists alongside the
main binary in the AppImage's `usr/bin/` directory.

**Icon not appearing**: If no icon resizing tool was available during the
build, the icon may be 1024x1024. Install `librsvg2-bin` (for `rsvg-convert`)
or `imagemagick` and rebuild to get a properly sized 256x256 icon.

## .gitignore

The repository `.gitignore` already excludes build artifacts
(`packaging/linux/tools/`, `*.AppImage`, `PurplePen.AppDir/`,
`packaging/linux/org.purplepen.PurplePen.png`).
