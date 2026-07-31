# PurplePen Linux Packaging

Tooling repo for building PurplePen as a Linux AppImage and Flatpak.
Upstream source is a git submodule at `src/` from https://github.com/petergolde/PurplePen.

## Structure

- `.github/workflows/` - CI for AppImage (Debian/CentOS) and Flatpak (GitHub Pages)
- `packaging/linux/` - AppImage build script, desktop metadata, and AppStream metainfo
- `packaging/flatpak/` - Flatpak manifest, NuGet sources, and GitHub Pages landing page
- `patches/` - Source patches applied at build time for Linux compatibility
- `src/` - Git submodule pointing to upstream PurplePen

## Build

### AppImage

```bash
git submodule update --init
bash packaging/linux/build-appimage.sh
```

### Flatpak

```bash
flatpak-builder --user --install build-dir packaging/flatpak/org.purplepen.PurplePen.yml
```

## Patches

Source patches in `patches/` are applied by the build script before compilation.
They are generated with `git format-patch --relative=src/` so paths are relative
to the submodule root. To check if patches still apply against current upstream:

```bash
git -C src apply --check --ignore-whitespace patches/*.patch
```

## Flatpak NuGet Sources

`packaging/flatpak/nuget-sources.json` contains offline NuGet package URLs for
the sandboxed Flatpak build. Regenerate with `./packaging/flatpak/generate-nuget-sources.sh`
when dependencies change (requires .NET 10 SDK, python3, and network access).
