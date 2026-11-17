# vstbridge destshot stable

**vstbridge** — это форк [yabridge](https://github.com/robbert-vdh/yabridge) от [rations](https://github.com/rations/vstbridge), а этот репозиторий — стабильная сборка 2026 года: все исправления vstbridge 0.0.5 плюс вручную перенесённые PR-ы из yabridge, которые так и не были влиты в апстрим. Позволяет запускать Windows VST2, VST3 и CLAP плагины в Linux DAW (REAPER, Ardour, Bitwig и др.) через Wine.

Репозиторий: <https://github.com/destshotGuitar/vstbridge> · [English below](#english)

---

## Почему этот форк

Оригинальный yabridge давно без релизов, а Wine 10+ сломал в нём ряд вещей. vstbridge исправил ввод мыши и добавил фикс меню, но тоже развивается медленно. Здесь собрано всё, что сообщество сделало к ноябрю 2026-го, в одну проверенную на REAPER + GNOME (Wayland) сборку:

| Проблема | Источник фикса |
|---|---|
| Меню JUCE-плагинов (Superior Drummer 3, EZdrummer 3, Hofa) открываются и сразу закрываются на Wine 10+; нужна была эмуляция виртуального стола в winecfg | Патч singularity098 (yabridge#521), в vstbridge — опция `editor_popup_fix` |
| GUI плагина не реагирует на мышь с Wine ≥ 9.21 (координаты уезжают из-за `wm_state_serial`) | Фикс rations (XEmbed + `SetWindowPos`), включён по умолчанию |
| REAPER подвисает, пока открыто меню или диалог плагина (модальный цикл) | yabridge#538 (zx2c4) |
| Падение Wine-хоста уносит за собой весь DAW | Серия yabridge#534 (Yagafgaf, 21 коммит): `with_live_host`, pidfd, try/catch на всех C-входах |
| Краш `BadWindow` при закрытии окна плагина | yabridge#531 (zx2c4) |
| Чёрная/непрорисованная область GUI у FabFilter и подобных | yabridge#533 (repaint после show/resize) |
| Дедлок `beginEdit` в Bitwig, прочие дедлоки и падения | yabridge#505, y#513, y#537-класс |
| Мышь «протухает» после переноса окна плагина | rations/vstbridge#26 |
| Дропауты от per-block gain reduction query в REAPER | yabridge#527 |
| Мелочь: SIGCHLD, STDIN Wine-хоста, приоритет SCHED_FIFO, коалесцинг мыши | yabridge#528, #529, #509, #532 |

Полный список — в истории коммитов ветки `master` (32 коммита поверх vstbridge 0.0.5).

## Требования

- **Wine Staging 10+ или 11** (проверено на 11.20)
- 64-битный Linux DAW (REAPER, Ardour, Bitwig, Renoise…)
- GNOME / KDE / X11 / Wayland (XWayland)
- Для GUI многих плагинов нужен DXVK: `winetricks dxvk` в нужном префиксе

## Быстрая установка

Одна команда — скачает последний релиз, установит в `~/.local/share/vstbridge` (старая установка будет сохранена как бэкап):

```bash
curl -fsSL https://raw.githubusercontent.com/destshotGuitar/vstbridge/master/install.sh | bash
```

Затем добавьте папки с Windows-плагинами и синхронизируйте:

```bash
export PATH="$HOME/.local/share/vstbridge:$PATH"
vstbridgectl add "$HOME/.wine/drive_c/Program Files/Common Files/VST3"
vstbridgectl sync
```

и укажите DAW на выходные папки:

- VST3: `~/.vst3/vstbridge/`
- VST2: `~/.vst/vstbridge/`
- CLAP: `~/.clap/vstbridge/`

### Фикс «пропадающих» меню

Для JUCE-плагинов с меню (Toontrack, Hofa и др.) включите опцию — либо через GUI (`vstbridgectl-gtk`, вкладка Plugins → «Fix popup menus»), либо вручную в `~/.vst3/vstbridge/vstbridge.toml` (и аналогах для VST2/CLAP):

```toml
["EZdrummer 3.vst3"]
editor_popup_fix = true
```

После этого меню работают **без эмуляции виртуального стола в winecfg**.

## Автоматическая синхронизация плагинов

`install.sh` ставит два systemd user-сервиса (отключить: `VSTBRIDGE_SYSTEMD=0 ./install.sh`):

- **vstbridge-watch.service** — watcher (inotify) на директории из конфигурации vstbridgectl. Установили плагин через wine-инсталлятор — через ~8 секунд после окончания копирования `vstbridgectl sync` запустится сам. Новые директории в конфиге подхватываются без перезапуска.
- **vstbridge-sync.timer** — разово при входе в сессию на случай, если watcher пропустил изменения.

DAW при этом сама должна пересканировать плагины — watcher может только создать/обновить мосты в `~/.vst3/vstbridge/` и остальных выходных папках, а заставить DAW перечитать их изнутри нельзя. REAPER пересканирует сам при старте (либо кнопка «Re-scan» в Preferences → Plug-ins). Практический вывод: поставили плагин → дождитесь записи «sync finished» в логе (≈10 секунд) → откройте/перезапустите DAW. Логи: `journalctl --user -u vstbridge-watch -f`.

## Лимиты памяти и realtime (предупреждение «Low memory locking limit»)

Если при открытии плагинов вылезает уведомление про низкий лимит памяти (memlock), у пользователя не настроены audio-лимиты — общие аудиобуферы моста не могут быть запинены в ОЗУ (работает чуть медленнее). Лечится одной командой и перелогином:

```bash
sudo tee /etc/security/limits.d/99-audio-rt.conf >/dev/null <<EOF
$USER - memlock unlimited
$USER - rtprio 95
EOF
```

Проверка после перелогина: `ulimit -l` должен вывести `unlimited`. Начиная с v5.2.2 это предупреждение показывается один раз за сессию, а не по уведомлению на каждый плагин.

## Сборка из исходников

```bash
git clone https://github.com/destshotGuitar/vstbridge.git
cd vstbridge
sudo dnf install wine-devel libxcb-devel   # Fedora; в README vstbridge есть список для Debian/Ubuntu
sudo ln -sf /usr/bin/winegcc /usr/local/bin/winegcc-stable
sudo ln -sf /usr/bin/wineg++ /usr/local/bin/wineg++-stable
meson setup vstbridge/build --buildtype=release --cross-file=vstbridge/cross-wine.conf
ninja -C vstbridge/build
make -C vstbridge/tools/vstbridgectl
```

## Откат

```bash
rm -rf ~/.local/share/vstbridge
mv ~/.local/share/vstbridge.bak-* ~/.local/share/vstbridge
vstbridgectl sync --force
```

## Благодарности

- [Robbert van der Helm](https://github.com/robbert-vdh) — автор yabridge
- [rations](https://github.com/rations) — автор vstbridge
- [singularity098](https://github.com/robbert-vdh/yabridge/issues/521) — анализ и патч от JUCE-меню
- [zx2c4](https://github.com/zx2c4), [Yagafgaf](https://github.com/Yagafgaf) и другие авторы перенесённых PR

Лицензия: GPL-3.0 (как у yabridge).

---

# <a name="english"></a>English

**vstbridge destshot stable** is a community stable build for 2026: everything from vstbridge 0.0.5 plus stability and bug-fix pull requests from yabridge that were never merged upstream. It runs Windows VST2, VST3 and CLAP plugins in Linux DAWs through Wine.

## Why this fork

Upstream yabridge has had no releases for a long time, and Wine 10+ broke several things in it. vstbridge fixed mouse input and added a menu fix but also moves slowly. This repo combines everything the community had produced by November 2026 into one build, tested on REAPER + GNOME (Wayland):

- JUCE popup menus (Superior Drummer 3, EZdrummer 3, Hofa) closing instantly on Wine 10+ — fixed by singularity098's patch (yabridge#521), exposed as vstbridge's `editor_popup_fix` option; **no virtual desktop emulation in winecfg needed**
- Dead mouse input with Wine ≥ 9.21 — rations' XEmbed + `SetWindowPos` fix, on by default
- REAPER stalls while a plugin menu/dialog is open — yabridge#538 (zx2c4)
- A crashed Wine host taking the whole DAW down — the 21-commit yabridge#534 series (Yagafgaf)
- `BadWindow` crash when closing plugin editors — yabridge#531
- Black/unpainted GUI areas in FabFilter-style plugins — yabridge#533
- `beginEdit` deadlock (Bitwig) and assorted crashes — yabridge#505, #513
- Stale mouse coordinates after moving the editor — rations/vstbridge#26
- REAPER per-block gain reduction query dropouts — yabridge#527

Full list in the `master` commit history (32 commits on top of vstbridge 0.0.5).

## Requirements

- Wine Staging 10+ or 11 (tested on 11.20)
- A 64-bit Linux DAW (REAPER, Ardour, Bitwig, Renoise…)
- GNOME / KDE / X11 / Wayland (XWayland)
- Many plugin GUIs need DXVK: `winetricks dxvk` in the prefix

## Quick install

One command — downloads the latest release into `~/.local/share/vstbridge` (your previous install is kept as a backup):

```bash
curl -fsSL https://raw.githubusercontent.com/destshotGuitar/vstbridge/master/install.sh | bash
```

Then point vstbridgectl at your Windows plugin folders and sync:

```bash
export PATH="$HOME/.local/share/vstbridge:$PATH"
vstbridgectl add "$HOME/.wine/drive_c/Program Files/Common Files/VST3"
vstbridgectl sync
```

and add the output folders to your DAW: VST3 `~/.vst3/vstbridge/`, VST2 `~/.vst/vstbridge/`, CLAP `~/.clap/vstbridge/`.

### The disappearing-menus fix

For JUCE plugins with menus (Toontrack, Hofa, …) enable the option either in `vstbridgectl-gtk` (Plugins tab → "Fix popup menus") or manually in `~/.vst3/vstbridge/vstbridge.toml`:

```toml
["EZdrummer 3.vst3"]
editor_popup_fix = true
```

## Auto-syncing plugins

`install.sh` also installs two systemd user services (skip with `VSTBRIDGE_SYSTEMD=0 ./install.sh`):

- **vstbridge-watch.service** — an inotify watcher on the directories registered in vstbridgectl's config. Install a plugin through a Wine installer, and `vstbridgectl sync` runs by itself about 8 seconds after the copying settles. Directories added to the config later are picked up without a restart.
- **vstbridge-sync.timer** — once at login, in case the watcher missed anything.

Your DAW still needs to rescan its plugin paths for new plugins to show up — the watcher can only create/update the bridges in `~/.vst3/vstbridge/` and the other output folders; it cannot make the DAW reload them from the inside. REAPER rescans on startup (or via Preferences → Plug-ins → «Re-scan»). So the practical flow is: install the plugin, wait for the «sync finished» log entry (about 10 seconds), then open or restart your DAW. Logs: `journalctl --user -u vstbridge-watch -f`.

## Memory locking and realtime limits (the "Low memory locking limit" warning)

If you get a notification about a low memory locking limit when opening plugins, your user is missing the standard audio limits, and the bridge's shared audio buffers cannot be pinned in RAM (slightly worse performance). Fix it with one command and a re-login:

```bash
sudo tee /etc/security/limits.d/99-audio-rt.conf >/dev/null <<EOF
$USER - memlock unlimited
$USER - rtprio 95
EOF
```

After re-logging in, `ulimit -l` should print `unlimited`. Since v5.2.2 the warning itself is shown once per session instead of one notification per plugin.

## Building from source

```bash
git clone https://github.com/destshotGuitar/vstbridge.git
cd vstbridge
meson setup vstbridge/build --buildtype=release --cross-file=vstbridge/cross-wine.conf
ninja -C vstbridge/build
make -C vstbridge/tools/vstbridgectl
```

See the "Prerequisites" section of the original vstbridge README (kept in the git history) for the exact distro package list.

## Credits

yabridge by Robbert van der Helm, vstbridge fork by rations, popup-menu analysis and patch by singularity098, modal-loop fixes by zx2c4, host-death hardening by Yagafgaf. Licensed under GPL-3.0, same as yabridge.
