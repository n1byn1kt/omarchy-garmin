# Garmin for Omarchy

Today's Garmin health at a glance: **Body Battery** in the bar, and sleep score,
steps and resting heart rate in a click-away panel.

![Garmin panel and bar chip](preview.png)

---

## What it shows

**In the bar** — a bolt glyph and your current Body Battery:

![Garmin bar chip](docs/bar-chip.png)

The number is coloured by the reading, not by the plumbing: accent when you have
battery left (≥ 60), urgent when you are nearly empty (< 30), plain in between.
Anything degraded — stale data, an unreachable API, a session that needs a new
login — goes plain and dim, so a broken helper never looks like a health alarm.
A trailing `·` marks data that is no longer fresh. Hover for a tooltip with the
state, the last error (if any), and the timestamp.

**In the panel** — Body Battery with its daily low–high range, sleep score and
duration, steps against your Garmin step goal (with a progress bar), and resting
heart rate, plus a footer timestamp and a Refresh button.

**Interactions**

| Action | Result |
|---|---|
| Left click the chip | Open / close the panel |
| Middle click the chip | Force a refresh |
| `Escape` (panel focused) | Close the panel |
| `r` (panel focused) | Refresh |
| `c` (panel focused) | Copy the suggested command to the clipboard |
| `qs ipc call garmin refresh\|open\|close\|toggle` | Same, from a script or a keybind |

---

## Requirements

- **Omarchy** with the Quickshell-based bar (plugin schema v1).
- **Python 3** — the helper itself is stdlib-only, but the
  [`garminconnect`](https://github.com/cyberjunky/python-garminconnect) library
  it talks to requires **Python 3.12+**. Omarchy's system Python is newer than
  that, so this is normally already satisfied.
- **A Garmin Connect account.** No Garmin developer key is needed.

### External dependency: `garminconnect`

This plugin has one external dependency, and it is not installed for you.

Arch (and every other PEP 668 distro) refuses `pip install` into the system
Python, so the helper uses a **dedicated virtualenv** it knows how to find:

```bash
python3 -m venv ~/.local/share/garmin-widget/venv
~/.local/share/garmin-widget/venv/bin/pip install garminconnect
```

Verified against `garminconnect` **0.3.11**. Newer releases normally work — the
four calls this plugin makes (`Garmin()`, `login()`, `get_user_summary()`,
`get_sleep_data()`) have been stable for a long time — but 0.3.11 is the
version the widget was tested on.

Nothing is installed system-wide, and nothing outside your home directory is
touched. The helper re-execs itself into that venv automatically when
`garminconnect` is not importable from the interpreter it started under — you
never have to activate anything.

Until the venv exists the bar chip shows `⚡—` dimmed and the panel says
**HELPER DEPENDENCY MISSING**, with the two commands above in a copyable box.

---

## Install

```bash
omarchy plugin add https://github.com/n1byn1kt/omarchy-garmin.git --enable
```

Then install the dependency (see above) and connect your account (below).

Updating later: `omarchy plugin update io.github.n1byn1kt.garmin`.

---

## Connect your Garmin account

![Not signed in](docs/panel-no-tokens.png)

Run the helper's `login` subcommand in a terminal:

```bash
~/.config/omarchy/plugins/io.github.n1byn1kt.garmin/bin/garmin-widget login
```

It prompts for your Garmin Connect email and password (the password is not
echoed), and for an **MFA code** if your account has multi-factor auth enabled —
MFA is fully supported, you just type the code when asked.

Two things worth knowing about the first login:

- **Garmin often rate-limits the first attempts.** You may see one or two lines
  like `mobile+cffi returned 429: GarminConnectTooManyRequestsError`. This is
  harmless — the library retries with a different login strategy internally, and
  the MFA path usually goes through right after. Let it finish.
- On success it prints one line of JSON:
  `{"ok": true, "tokens": "/home/you/.config/garmin-widget/tokens.json"}`.
  Give the bar up to `pollMinutes` to notice, or middle-click the chip to
  refresh immediately.

Only OAuth tokens are stored. Your password is never written to disk.

---

## Settings

Configured per bar-widget instance in Omarchy's bar settings (or in
`~/.config/omarchy/shell.json`):

| Setting | Type | Default | What it does |
|---|---|---|---|
| `pollMinutes` | number | `30` | How often the helper asks Garmin for new data. **Floored at 5 minutes** — anything lower (including `0`, which a typo makes easy) is clamped, since Garmin's numbers move slowly and polling harder mostly buys you rate limits. |
| `showSteps` | boolean | `false` | Also show today's steps next to Body Battery in the bar (e.g. `⚡61  8.0k`). |
| `stepsGoalFallback` | number | `10000` | Step goal used in the panel when Garmin does not return one for the day. |

On a multi-monitor setup the widget appears on every bar, and it is designed so
that only **one** instance polls, fanning the result out to the others — one
Garmin session regardless of bar count. (Developed and verified on a
single-monitor setup; multi-monitor reports welcome.)

---

## Privacy

Your credentials go to Garmin only. Tokens are stored locally in
`~/.config/garmin-widget/` with 0600 permissions. The widget makes one outbound
connection — to Garmin Connect — and contains no telemetry.

Everything this plugin writes lives under your home directory:

| Path | Contents |
|---|---|
| `~/.config/garmin-widget/tokens.json` | Garmin OAuth tokens, mode `0600`. No password. |
| `~/.cache/garmin-widget/last.json` | Last successful reading, so the bar can show yesterday's numbers while offline. |
| `~/.local/share/garmin-widget/venv/` | The dedicated virtualenv holding `garminconnect`. |

---

## Troubleshooting

The widget has five failure states, and each one asks you for exactly one thing.
Open the panel to see which you are in.

| Panel says | What happened | What to do |
|---|---|---|
| **HELPER DEPENDENCY MISSING** | `garminconnect` is not importable and no venv was found. | Run the two venv commands under [External dependency](#external-dependency-garminconnect). |
| **NOT SIGNED IN** | No `~/.config/garmin-widget/tokens.json` yet. | Run `garmin-widget login` (path in the panel, copyable). |
| **SESSION EXPIRED** | Garmin rejected the stored tokens. | Run `garmin-widget login` again. Tokens do expire; this is normal every so often. |
| **OFFLINE** / **GARMIN API ERROR** | The network or Garmin Connect is unavailable. The specific error is shown. | Wait and hit Refresh. If a cached reading exists, the panel keeps showing it and marks the footer `· stale`. |
| Rows shown, footer `· stale` | Last fetch failed but a previous reading is cached. | Nothing — the numbers are real, just old. Refresh when you are back online. |

**Nothing appears in the bar at all.** Check the widget is enabled and placed:
`omarchy plugin list`. After enabling, `omarchy restart shell`.

**The chip shows `⚡—` and never updates.** Run the helper by hand — it always
prints one JSON object and always exits 0, so the error is in the output:

```bash
~/.config/omarchy/plugins/io.github.n1byn1kt.garmin/bin/garmin-widget fetch
~/.config/omarchy/plugins/io.github.n1byn1kt.garmin/bin/garmin-widget status
```

**The shell dies right after you add or update the plugin.** Known upstream
issue, not fixed here: Quickshell 0.3.0 can segfault in
`IpcHandler::updateRegistration` when plugin files change underneath a shell
that is already restarting — which is exactly what `omarchy plugin add` and
`omarchy plugin update` do. We saw it in roughly 30% of rapid redeploy cycles
during development. It is always the **outgoing** process that dies; the
incoming one comes up clean, and the shell normally restarts itself. If it does
not:

```bash
omarchy restart shell
```

Your data is unaffected — nothing is lost but a few seconds of bar.

---

## Removal

```bash
omarchy plugin remove io.github.n1byn1kt.garmin
```

That removes the plugin only. Your tokens, cache and venv are deliberately left
behind, so removing and re-adding the plugin (or moving to a newer version) does
not make you log in again. To clear them out as well:

```bash
rm -rf ~/.config/garmin-widget ~/.cache/garmin-widget ~/.local/share/garmin-widget
```

---

## Development

```bash
python3 -m pytest tests/ -v          # helper unit tests, no network
omarchy plugin validate .            # manifest schema check
```

The plugin is five files: `manifest.json`, `Service.qml` (poller and state
machine), `BarWidget.qml` (the chip), `Panel.qml` (the detail panel), and the
Python helper in `bin/garmin-widget`. The helper's contract is that every
subcommand prints exactly one JSON object to stdout and exits 0 — errors are
data, never a non-zero exit, so a failed fetch can never blank the bar.

Design notes and the implementation plan are in [`docs/`](docs/).

## License

MIT — see [LICENSE](LICENSE).
