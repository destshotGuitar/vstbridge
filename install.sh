#!/usr/bin/env bash
# vstbridge destshot stable — one-line installer.
#
# From the internet:
#   curl -fsSL https://raw.githubusercontent.com/destshotGuitar/vstbridge/master/install.sh | bash
#
# From a release tarball (install.sh sits next to the binaries):
#   ./install.sh
#
# Environment:
#   VSTBRIDGE_VERSION   install a specific release instead of the latest
set -euo pipefail

REPO="destshotGuitar/vstbridge"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/vstbridge"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# --- Architecture check ------------------------------------------------------

[ "$(uname -m)" = "x86_64" ] || die "This build is for x86_64 only. Your architecture: $(uname -m)"

# --- Locate the binaries -----------------------------------------------------

SRC_DIR=""
TMP_DIR=""

if [ -f "$SCRIPT_DIR/libvstbridge-vst3.so" ]; then
    # Running from inside an extracted release tarball.
    SRC_DIR="$SCRIPT_DIR"
else
    command -v curl >/dev/null 2>&1 || die "curl is required for the download"
    command -v tar  >/dev/null 2>&1 || die "tar is required for the download"

    VERSION="${VSTBRIDGE_VERSION:-}"
    if [ -z "$VERSION" ]; then
        log "Looking up the latest release of $REPO"
        JSON="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")" \
            || die "Could not reach GitHub. Check your connection, or set VSTBRIDGE_VERSION."
        VERSION="$(printf '%s' "$JSON" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)"
        [ -n "$VERSION" ] || die "No releases found in $REPO"
    fi
    VERSION="${VERSION#v}"
    log "Downloading vstbridge $VERSION"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    URL="https://github.com/$REPO/releases/download/v$VERSION/vstbridge-$VERSION-x86_64.tar.gz"
    curl -fsSL "$URL" -o "$TMP_DIR/vstbridge.tar.gz" \
        || die "Download failed: $URL"
    tar -xzf "$TMP_DIR/vstbridge.tar.gz" -C "$TMP_DIR"
    SRC_DIR="$TMP_DIR/vstbridge"
fi

[ -f "$SRC_DIR/libvstbridge-vst3.so" ] || die "vstbridge libraries not found in $SRC_DIR"

# --- Backup the previous installation ----------------------------------------

if [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    BACKUP="$INSTALL_DIR.bak-$(date +%Y%m%d-%H%M%S)"
    log "Backing up the existing installation to $BACKUP"
    mv "$INSTALL_DIR" "$BACKUP"
fi

# --- Install -----------------------------------------------------------------

log "Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
for f in \
    libvstbridge-vst2.so libvstbridge-vst3.so libvstbridge-clap.so \
    libvstbridge-chainloader-vst2.so libvstbridge-chainloader-vst3.so \
    libvstbridge-chainloader-clap.so \
    vstbridge-host.exe vstbridge-host.exe.so \
    vstbridge-host-32.exe vstbridge-host-32.exe.so \
    vstbridge-host-32-unixlib.so vstbridge-host-32-unixlib-i386.so \
    vstbridgectl vstbridgectl-gtk
do
    [ -f "$SRC_DIR/$f" ] && cp "$SRC_DIR/$f" "$INSTALL_DIR/$f"
done
chmod +x "$INSTALL_DIR/vstbridgectl" 2>/dev/null || true

# --- Sanity checks -----------------------------------------------------------

if ! command -v wine >/dev/null 2>&1; then
    warn "Wine was not found in PATH. vstbridge needs Wine Staging 10+ or 11."
fi

cat <<EOF

$(log "Done.")

Next steps:

  1. Add the tools to your PATH for this shell:
       export PATH="\$HOME/.local/share/vstbridge:\$PATH"

  2. Point vstbridgectl at your Windows plugin folders (inside your Wine
     prefix), then sync:
       vstbridgectl add "\$HOME/.wine/drive_c/Program Files/Common Files/VST3"
       vstbridgectl add "\$HOME/.wine/drive_c/Program Files/VSTPlugins"
       vstbridgectl sync

  3. Add the bridged plugin folders to your DAW:
       VST3: ~/.vst3/vstbridge/
       VST2: ~/.vst/vstbridge/
       CLAP: ~/.clap/vstbridge/

  4. If you also have yabridge installed, either remove its bridged copies
     (usually ~/.vst3/yabridge and friends) or remove those folders from your
     DAW's plugin paths, so each plugin only shows up once.

  5. JUCE plugins whose menus close instantly (Toontrack, Hofa, ...): enable
     "Fix popup menus" in vstbridgectl-gtk (Plugins tab), or set
     editor_popup_fix = true for the plugin in ~/.vst3/vstbridge/vstbridge.toml.
     No Wine virtual desktop needed.

Restart your DAW so it reloads the plugin libraries.
EOF
