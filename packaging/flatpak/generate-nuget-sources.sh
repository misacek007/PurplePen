#!/usr/bin/env bash
#
# generate-nuget-sources.sh — Generate nuget-sources.json for offline Flatpak builds.
#
# Requires: python3, .NET 10 SDK (dotnet), network access.
#
# Usage:
#   ./packaging/flatpak/generate-nuget-sources.sh
#
# The generated nuget-sources.json is referenced by the Flatpak manifest
# and must be committed to the repository. Re-run this script whenever
# NuGet dependencies change (new packages, version bumps).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$REPO_ROOT/src/src"
OUTPUT="$SCRIPT_DIR/nuget-sources.json"
GENERATOR="/tmp/flatpak-dotnet-generator.py"

if ! command -v dotnet >/dev/null 2>&1; then
    echo "ERROR: dotnet CLI not found. Install .NET 10 SDK first." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found." >&2
    exit 1
fi

echo ">>> Downloading flatpak-dotnet-generator.py..."
curl -fsSL -o "$GENERATOR" \
    "https://raw.githubusercontent.com/flatpak/flatpak-builder-tools/master/dotnet/flatpak-dotnet-generator.py"

echo ">>> Generating NuGet sources for AvPurplePen..."
python3 "$GENERATOR" \
    --dotnet 10 \
    --freedesktop 25.08 \
    "$OUTPUT" \
    "$SRC_DIR/AvPurplePen/AvPurplePen.csproj" \
    "$SRC_DIR/PdfConverter/PdfConverter.csproj"

echo ">>> Generated: $OUTPUT"
echo "    Commit this file to the repository."
