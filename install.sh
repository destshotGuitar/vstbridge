#!/usr/bin/env bash
# vstbridge destshot stable — one-line installer.
#
# From the internet:
#   curl -fsSL https://raw.githubusercontent.com/destshotGuitar/vstbridge/master/install.sh | bash
#
# From a release tarball (install.sh sits next to the binaries):
#   ./install.sh
#
# Missing dependencies are installed automatically through the system package
# manager (dnf/apt-get/pacman/zypper) when possible: curl and tar for the
# download, python3 for the directory watcher, wine (Staging 10+ or 11) to
# run the plugins.
#
# Environment:
#   VSTBRIDGE_VERSION   install a specific release instead of the latest
#   VSTBRIDGE_SYSTEMD=0 skip the auto-sync systemd user services
#   VSTBRIDGE_SETUP=0   skip the first-run plugin directory setup and sync
#   VSTBRIDGE_DXVK=1    install winetricks and DXVK into the Wine prefix
#                       (many plugin GUIs need DXVK; default: skip)
set -euo pipefail

REPO="destshotGuitar/vstbridge"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/vstbridge"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

# --- Architecture check ------------------------------------------------------

[ "$(uname -m)" = "x86_64" ] || die "This build is for x86_64 only. Your architecture: $(uname -m)"

# --- Dependencies -------------------------------------------------------------

PM=""
detect_pm() {
    if   command -v dnf     >/dev/null 2>&1; then PM="dnf"
    elif command -v apt-get >/dev/null 2>&1; then PM="apt"
    elif command -v pacman  >/dev/null 2>&1; then PM="pacman"
    elif command -v zypper  >/dev/null 2>&1; then PM="zypper"
    fi
}

pm_pkg() {
    # Translate a command name into a package name for the detected PM.
    case "$PM:$1" in
        pacman:wine) printf 'wine-staging' ;;
        *)           printf '%s' "$1" ;;
    esac
}

install_pkgs() {
    # Install packages with the detected package manager. Returns non-zero
    # (after warning) when installation is impossible without the user.
    local pkgs=("$@") sudo=""
    case "$PM" in
        apt|dnf|pacman|zypper) ;;
        *)  warn "No supported package manager found (dnf/apt/pacman/zypper)."
            warn "Install manually: ${pkgs[*]}"
            return 1 ;;
    esac
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            warn "sudo not found; install manually: ${pkgs[*]}"
            return 1
        fi
        sudo -v 2>/dev/null || {
            warn "sudo needs a password; install manually: ${pkgs[*]}"
            return 1
        }
        sudo="sudo"
    fi
    log "Installing missing dependencies: ${pkgs[*]}"
    case "$PM" in
        apt)    $sudo apt-get update -qq && $sudo apt-get install -y "${pkgs[@]}" ;;
        dnf)    $sudo dnf install -y "${pkgs[@]}" ;;
        pacman) $sudo pacman -Sy --needed --noconfirm "${pkgs[@]}" ;;
        zypper) $sudo zypper --non-interactive install "${pkgs[@]}" ;;
    esac
}

ensure_cmds() {
    # Install the given commands if they are missing. Returns 0 once all of
    # them are available, 1 otherwise.
    local missing=() still=() cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0
    detect_pm
    local pkgs=() m
    for m in "${missing[@]}"; do
        pkgs+=("$(pm_pkg "$m")")
    done
    install_pkgs "${pkgs[@]}" || return 1
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || still+=("$cmd")
    done
    if [ "${#still[@]}" -gt 0 ]; then
        warn "Still missing after install attempt: ${still[*]}"
        return 1
    fi
}

# python3 drives the vstbridge-watch directory watcher. Without it the sync
# timer still works, so a failed install is a warning, not a fatal error.
HAVE_WATCHER=1
if ! command -v python3 >/dev/null 2>&1; then
    if ensure_cmds python3; then
        log "Installed python3"
    else
        warn "python3 is unavailable; the plugin directory watcher will be skipped."
        HAVE_WATCHER=0
    fi
fi

# Wine is the actual plugin runtime; a missing Wine must not stop the file
# installation, but plugins won't load without it.
if ! command -v wine >/dev/null 2>&1; then
    if ensure_cmds wine; then
        log "Installed $(wine --version 2>/dev/null || echo wine)"
    else
        warn "Wine was not found and could not be installed automatically."
        warn "vstbridge needs Wine Staging 10+ or 11: https://wiki.winehq.org/Download"
    fi
fi
if command -v wine >/dev/null 2>&1; then
    WINE_MAJOR="$(wine --version 2>/dev/null | grep -oE '[0-9]+' | head -n 1 || true)"
    if [ -n "$WINE_MAJOR" ] && [ "$WINE_MAJOR" -lt 10 ]; then
        warn "$(wine --version) detected, but vstbridge is tested with Wine Staging 10+ or 11."
        warn "Upgrade Wine if plugins misbehave."
    fi
fi

# --- Optional DXVK (many plugin GUIs need it) ---------------------------------

if [ "${VSTBRIDGE_DXVK:-0}" = "1" ]; then
    if command -v winetricks >/dev/null 2>&1 || ensure_cmds winetricks; then
        DXVK_PREFIX="${WINEPREFIX:-$HOME/.wine}"
        log "Installing DXVK into $DXVK_PREFIX"
        if WINEPREFIX="$DXVK_PREFIX" winetricks -q dxvk; then
            log "DXVK installed"
        else
            warn "winetricks dxvk failed in $DXVK_PREFIX."
            warn "Try manually: WINEPREFIX='$DXVK_PREFIX' winetricks dxvk"
        fi
    else
        warn "winetricks is unavailable; skipping DXVK."
        warn "Many plugin GUIs need it: https://github.com/doitsujin/dxvk"
    fi
fi

# --- Locate the binaries -----------------------------------------------------

SRC_DIR=""
TMP_DIR=""

if [ -f "$SCRIPT_DIR/libvstbridge-vst3.so" ]; then
    # Running from inside an extracted release tarball.
    SRC_DIR="$SCRIPT_DIR"
else
    ensure_cmds curl tar || die "curl and tar are required to download vstbridge. Install them manually and re-run this script."

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
    vstbridgectl vstbridgectl-gtk vstbridge-watch.py
do
    [ -f "$SRC_DIR/$f" ] && cp "$SRC_DIR/$f" "$INSTALL_DIR/$f"
done
chmod +x "$INSTALL_DIR/vstbridgectl" "$INSTALL_DIR/vstbridge-watch.py" 2>/dev/null || true

# --- Put the tools on PATH (via ~/.local/bin, no exports needed) -------------

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
for tool in vstbridgectl vstbridgectl-gtk; do
    [ -f "$INSTALL_DIR/$tool" ] && ln -sf "$INSTALL_DIR/$tool" "$BIN_DIR/$tool"
done
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        if ! grep -qs 'local/share/vstbridge' "$HOME/.bashrc" 2>/dev/null; then
            printf '\n# vstbridge destshot stable\nexport PATH="$HOME/.local/share/vstbridge:$PATH"\n' >> "$HOME/.bashrc"
            warn "$BIN_DIR is not on your PATH. Added a line to ~/.bashrc;"
            warn "open a new terminal or run: export PATH=\"$BIN_DIR:\$PATH\""
        fi
        ;;
esac

# --- systemd user units: sync on login + live watcher ------------------------

if [ "${VSTBRIDGE_SYSTEMD:-1}" != "0" ] && command -v systemctl >/dev/null 2>&1 \
    && systemctl --user >/dev/null 2>&1; then
    UNIT_DIR="$CONFIG_HOME/systemd/user"
    mkdir -p "$UNIT_DIR"

    cat > "$UNIT_DIR/vstbridge-sync.service" <<EOF
[Unit]
Description=Sync vstbridge plugin bridges

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/vstbridgectl sync
EOF

    cat > "$UNIT_DIR/vstbridge-sync.timer" <<EOF
[Unit]
Description=Sync vstbridge plugin bridges once after login

[Timer]
OnBootSec=45s
Unit=vstbridge-sync.service

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    if [ "$HAVE_WATCHER" = "1" ]; then
        cat > "$UNIT_DIR/vstbridge-watch.service" <<EOF
[Unit]
Description=Watch plugin directories and auto-sync vstbridge

[Service]
ExecStart=/usr/bin/env python3 $INSTALL_DIR/vstbridge-watch.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
        systemctl --user enable --now vstbridge-watch.service 2>/dev/null \
            && log "Enabled the plugin directory watcher (vstbridge-watch.service)" \
            || warn "Could not start vstbridge-watch.service"
    else
        rm -f "$UNIT_DIR/vstbridge-watch.service"
        systemctl --user daemon-reload
        warn "Skipping vstbridge-watch.service (python3 unavailable)."
        warn "Run 'vstbridgectl sync' manually after installing new plugins."
    fi
    systemctl --user enable --now vstbridge-sync.timer 2>/dev/null \
        && log "Enabled the login-time sync timer (vstbridge-sync.timer)" \
        || warn "Could not start vstbridge-sync.timer"
elif [ "${VSTBRIDGE_SYSTEMD:-1}" != "0" ]; then
    warn "systemd user session not available; skipping auto-sync services."
    warn "Run 'vstbridgectl sync' manually after installing new plugins."
fi

# --- First-run setup: default Wine prefix plugin dirs + sync -----------------

VSTBRIDGECTL="$INSTALL_DIR/vstbridgectl"
if [ "${VSTBRIDGE_SETUP:-1}" != "0" ]; then
    CTL_CONFIG="$CONFIG_HOME/vstbridgectl/config.toml"
    if [ ! -f "$CTL_CONFIG" ]; then
        log "First run: registering the standard plugin folders of ~/.wine"
        WINEPREFIX_PATH="${WINEPREFIX:-$HOME/.wine}"
        for sub in \
            "Program Files/Common Files/VST3" \
            "Program Files/Common Files/VST2" \
            "Program Files/Common Files/CLAP" \
            "Program Files/Common Files/Kontakt/Kontakt 8/x64/VST3" \
            "Program Files/Steinberg/VSTPlugins" \
            "Program Files/VSTPlugins"
        do
            dir="$WINEPREFIX_PATH/drive_c/$sub"
            if [ -d "$dir" ]; then
                "$VSTBRIDGECTL" add "$dir" >/dev/null 2>&1 || true
            fi
        done
    fi
    log "Syncing plugins"
    "$VSTBRIDGECTL" sync || warn "Sync reported errors; run '$BIN_DIR/vstbridgectl status' for details."
fi

# --- Sanity checks -----------------------------------------------------------

if ! command -v wine >/dev/null 2>&1; then
    warn "Wine was not found in PATH. vstbridge needs Wine Staging 10+ or 11."
fi

cat <<EOF

$(log "Done. Almost everything is automatic now:")

  - New plugins installed into the watched folders are bridged by
    vstbridge-watch within ~10 seconds; open (or restart) your DAW and
    rescan to see them. Logs: journalctl --user -u vstbridge-watch -f

  - Add the bridged folders to your DAW if it asks:
       VST3: ~/.vst3/vstbridge/    VST2: ~/.vst/vstbridge/    CLAP: ~/.clap/vstbridge/

  - JUCE plugins whose menus close instantly (Toontrack, Hofa, ...): enable
    "Fix popup menus" in vstbridgectl-gtk (Plugins tab), or set
    editor_popup_fix = true for the plugin in ~/.vst3/vstbridge/vstbridge.toml.
    No Wine virtual desktop needed.

  - If you also have yabridge installed, remove its bridged copies
    (~/.vst3/yabridge and friends) so each plugin only shows up once.

EOF
