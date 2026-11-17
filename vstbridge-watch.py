#!/usr/bin/env python3
"""Watch the plugin directories registered in vstbridgectl's config and run
`vstbridgectl sync` shortly after they change.

Stdlib only (ctypes + inotify). Installed next to vstbridgectl by install.sh
and started as a systemd user service.

Environment:
    VSTBRIDGECTL        path to vstbridgectl (default: next to this script)
    VSTBRIDGE_WATCH_EXCLUDES  comma-separated directory names to skip
    VSTBRIDGE_WATCH_DEBOUNCE  seconds of quiet time before syncing (default 8)
    VSTBRIDGE_WATCH_MAX_DEPTH  recursion depth for watches (default 3)
"""

import ctypes
import os
import select
import struct
import subprocess
import sys
import time
from pathlib import Path

LIBC = ctypes.CDLL(None, use_errno=True)

IN_CLOSE_WRITE = 0x00000008
IN_MOVED_FROM = 0x00000040
IN_MOVED_TO = 0x00000080
IN_CREATE = 0x00000100
IN_DELETE = 0x00000200
IN_DELETE_SELF = 0x00000400
IN_MOVE_SELF = 0x00000800
IN_ONLYDIR = 0x01000000
IN_ISDIR = 0x40000000
IN_Q_OVERFLOW = 0x00004000

MASK = (
    IN_CLOSE_WRITE
    | IN_MOVED_FROM
    | IN_MOVED_TO
    | IN_CREATE
    | IN_DELETE
    | IN_DELETE_SELF
    | IN_MOVE_SELF
)

PLUGIN_SUFFIXES = (".vst3", ".dll", ".clap")

WATCHER_DIR = Path(__file__).resolve().parent
VSTBRIDGECTL = Path(
    os.environ.get("VSTBRIDGECTL", WATCHER_DIR / "vstbridgectl")
)
CONFIG = Path.home() / ".config/vstbridgectl/config.toml"
DEBOUNCE = float(os.environ.get("VSTBRIDGE_WATCH_DEBOUNCE", "8"))
MAX_DEPTH = int(os.environ.get("VSTBRIDGE_WATCH_MAX_DEPTH", "3"))
EXCLUDES = set(
    name.strip()
    for name in os.environ.get(
        "VSTBRIDGE_WATCH_EXCLUDES", "demucs-env,node_modules,.git,__pycache__"
    ).split(",")
    if name.strip()
)


def log(message):
    print(f"vstbridge-watch: {message}", flush=True)


def read_plugin_dirs():
    """Parse `plugin_dirs` from vstbridgectl's config.toml (best effort)."""
    dirs = []
    try:
        in_list = False
        for line in CONFIG.read_text().splitlines():
            stripped = line.strip()
            if stripped.startswith("plugin_dirs"):
                in_list = "[" in stripped
                rest = stripped.split("[", 1)[1] if in_list else ""
                dirs.extend(parse_entries(rest))
                if "]" in rest:
                    in_list = False
            elif in_list:
                dirs.extend(parse_entries(stripped))
                if "]" in stripped:
                    in_list = False
    except OSError:
        pass
    return [Path(d) for d in dirs]


def parse_entries(text):
    entries = []
    for item in text.split(","):
        item = item.strip()
        if item.endswith("]"):
            item = item[:-1].strip()
        item = item.strip().strip("'\"")
        if item:
            entries.append(item)
    return entries


def inotify_init():
    fd = LIBC.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
    if fd < 0:
        raise OSError(ctypes.get_errno(), "inotify_init1 failed")
    return fd


def add_watch(fd, path):
    name = os.fsencode(path)
    return LIBC.inotify_add_watch(fd, name, MASK | IN_ONLYDIR)


class Watcher:
    def __init__(self):
        self.fd = inotify_init()
        self.wd_to_dir = {}
        self.pending = False
        self.last_event = 0.0

    def close(self):
        os.close(self.fd)

    def rebuild(self, roots):
        for wd in self.wd_to_dir:
            LIBC.inotify_rm_watch(self.fd, wd)
        self.wd_to_dir.clear()
        for root in roots:
            self._add_recursive(root, 0)
        log(f"watching {len(self.wd_to_dir)} directories")

    def _add_recursive(self, path, depth):
        if path.name in EXCLUDES or not path.is_dir():
            return
        wd = add_watch(self.fd, path)
        if wd < 0:
            return
        self.wd_to_dir[wd] = path
        if depth >= MAX_DEPTH:
            return
        try:
            children = sorted(path.iterdir())
        except OSError:
            return
        for child in children:
            if child.is_dir() and not child.is_symlink():
                self._add_recursive(child, depth + 1)

    def collect_events(self, timeout_ms):
        readable, _, _ = select.select([self.fd], [], [], timeout_ms / 1000.0)
        if not readable:
            return
        buf = os.read(self.fd, 65536)
        offset = 0
        while offset + 16 <= len(buf):
            wd, mask, _cookie, length = struct.unpack_from("iIII", buf, offset)
            offset += 16
            name = buf[offset : offset + length].split(b"\0", 1)[0].decode(
                "utf-8", "replace"
            )
            offset += length
            yield wd, mask, name

    def note_event(self):
        self.pending = True
        self.last_event = time.monotonic()


def looks_like_plugin(name):
    return name.lower().endswith(PLUGIN_SUFFIXES)


def run_sync():
    log("running vstbridgectl sync")
    try:
        subprocess.run(
            [str(VSTBRIDGECTL), "sync"], check=False, timeout=600,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception as error:  # noqa: BLE001 - keep watching no matter what
        log(f"sync failed: {error}")
    log("sync finished")


def main():
    if not VSTBRIDGECTL.exists():
        log(f"vstbridgectl not found at {VSTBRIDGECTL}, exiting")
        return 1

    watcher = Watcher()
    config_mtime = 0.0
    try:
        while True:
            # (Re)build watches when the config changes.
            try:
                mtime = CONFIG.stat().st_mtime
            except OSError:
                mtime = 0.0
            if mtime != config_mtime:
                config_mtime = mtime
                roots = read_plugin_dirs()
                if not roots:
                    log(f"no plugin dirs in {CONFIG}, waiting for config")
                watcher.rebuild(roots)

            for wd, mask, name in watcher.collect_events(1000):
                if mask & IN_Q_OVERFLOW:
                    watcher.rebuild(read_plugin_dirs())
                    watcher.note_event()
                    continue
                directory = watcher.wd_to_dir.get(wd)
                if directory is None:
                    continue
                # Only react to plugin files and to directory structure changes
                # inside the watched trees; ignore everything else to avoid
                # syncing on irrelevant writes (presets, caches, ...).
                if name and looks_like_plugin(name):
                    watcher.note_event()
                elif mask & (IN_DELETE_SELF | IN_MOVE_SELF):
                    watcher.note_event()
                elif (mask & IN_ISDIR) and name:
                    watcher.note_event()

            if watcher.pending and time.monotonic() - watcher.last_event >= DEBOUNCE:
                watcher.pending = False
                run_sync()
                # New plugin may have added directories; rebuild on next loop.
                config_mtime = 0.0
    except KeyboardInterrupt:
        pass
    finally:
        watcher.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
