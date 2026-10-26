# vencord-guard

A background macOS agent that notices when Vencord has been removed from Discord and puts it
back. It is event-driven: **zero timers, zero polling, 0.0% idle CPU.**

It works on every Discord branch — Stable, PTB, Canary and Development. By default it guards
each branch it finds installed in `/Applications` or `~/Applications`, and guards several at
once if several are installed. Examples below happen to show Canary; substitute
`Discord.app`, `Discord PTB.app` or `Discord Development.app` (and the matching
`discord` / `discordptb` / `discorddevelopment` support directory) as needed.

Verified on this machine: macOS 27.0 (Apple Silicon), Discord Canary 0.0.1280, Vencord `ef29bbe`.

---

## 1. Why Vencord disappears on macOS

Vencord does not live inside Discord. On macOS the installer does exactly two things:

```
/Applications/Discord Canary.app/Contents/Resources/     <- or Discord.app, Discord PTB.app, ...
    _app.asar    <- Discord's real 3.6 MB app.asar, renamed out of the way
    app.asar     <- a hand-built 221-byte asar containing one line:
                    require("/Users/you/Library/Application Support/Vencord/dist/patcher.js")
```

Electron loads `app.asar`, which loads Vencord's patcher, which loads the rest of Vencord from
`~/Library/Application Support/Vencord/dist/`. **The patch is two files in Discord's app bundle,
and nothing else.**

Discord's macOS updater is what removes it. Its log shows the mechanism plainly:

```
INFO [updater_client::install]: Host to be installed: HostTaskIdentifier { ...
     platform: OSX, arch: ARM64 }, version: HostVersionTriple(0, 0, 1280) },
     url: "https://canary.dl2.discordapp.net/distro/app/canary/osx/universal/0.0.1280/full.distro" }
INFO [updater_client::install]: Executing host install tasks.
```

A **host** update on macOS downloads `full.distro` and replaces the entire `.app` bundle. The
replacement contains a stock `app.asar` and no `_app.asar`, so the patch is gone — not damaged,
*absent*. This is why macOS loses Vencord more often than Windows or Linux do: those platforms
apply many updates as *module* updates under `Application Support`, which leave the patched
bundle alone. On macOS, host updates rewrite the exact directory the patch lives in.

A second macOS-only factor makes it worse. Patching breaks the bundle's code signature:

```
$ codesign -v --deep --strict "/Applications/Discord Canary.app"
/Applications/Discord Canary.app: a sealed resource is missing or invalid
```

A broken seal gives macOS and Discord more reasons to replace the bundle wholesale rather than
patch it in place.

### Does Vencord already solve this?

No, and it is worth being clear about it. Vencord's `dist/` files self-update from inside
Discord, but nothing re-applies the *patch* after the bundle is replaced. The official installer
has a `-repair` flag — but the shipped macOS artifact is the **GUI** build
(`//go:build !cli` in `gui.go`), which ignores command-line flags entirely and opens a window.
Upstream publishes `VencordInstallerCli` only for Linux and Windows; the macOS release is
`VencordInstaller.MacOS.zip` alone. There is no supported headless repair path on macOS today,
which is why this agent performs the patch itself.

It performs it *identically*, though. `AsarStub.swift` is a byte-for-byte port of upstream's
[`app_asar.go`](https://github.com/Vencord/Installer/blob/main/app_asar.go), and the self-test
proves it against your real install:

```
PASS  regenerated stub matches Discord Canary.app byte-for-byte
```

So VencordInstaller.app remains the tool of record for install / uninstall / OpenAsar. This
agent only restores what it already did.

---

## 2. The signals used to detect that Vencord is gone

Four independent signals, in order of how much they cost:

| # | Signal | Cost | What it tells us |
|---|--------|------|------------------|
| 1 | `NSWorkspace` launch/terminate notifications | zero when idle | Discord started, restarted, or quit |
| 2 | kqueue watch on `Contents/Resources` (one directory, one fd) | zero when idle | the bundle was rewritten |
| 3 | Incremental tail of `..._updater_rCURRENT.log`, only while Discord runs | ~0 | an update is *in progress* — **do not repair yet** |
| 4 | Incremental tail of `renderer_js.log`, only while Discord runs | ~0 | Vencord actually **loaded** |

Signal 4 is what makes this more than a file-existence check. Vencord prints its own banner
lines to Discord's renderer log:

```
[info] Vencord %c %c PluginManager ... Starting plugins (stage Init)
[info] Vencord %c %c WebpackPatcher ... Main WebpackInstance found in web.<hash>.js
```

Seeing any of those proves the patcher ran, the renderer bundle loaded, and plugins started.
If Discord has been running for 120 s and the renderer log has said nothing about Vencord, the
files may look right while the install is actually broken — and the agent re-checks knowing that.

When a signal fires, the health check itself is about six `stat()` calls plus one 221-byte read.
It classifies into five states, not two:

- **`patched`** — our stub is present, `_app.asar` backup is intact and >1 MB, and all four
  `dist/` files exist with plausible sizes and a `// Vencord <hash>` header.
- **`unpatched`** — a real `app.asar`, no backup. Stock Discord. Repair.
- **`brokenPatch(reason)`** — stub present but the backup is missing/truncated, or `dist/` is
  incomplete. A failed or half-finished install. Repair — after cleaning up first.
- **`foreignPatch(reason)`** — `app.asar` is a stub that requires *someone else's* patcher.
  Another client mod owns this install. **Never touched, never retried.**
- **`indeterminate(reason)`** — `Contents/Resources` is missing or `app.asar` is unreadable,
  i.e. the bundle is mid-swap. Never acted on; re-checked in 30 s.

---

## 3. Why this is cheaper than polling

A poll costs the same whether or not anything changed, and on a laptop the cost is not the CPU
cycles — it is the wakeup. A process that polls every 5 s wakes the CPU ~17,000 times a day,
each one defeating package C-states and appearing in `powermetrics` as a timer wakeup.

This agent arms **no timers at all** in its steady state:

- `NSWorkspace` notifications arrive over Mach ports from the window server.
- File watching uses `DispatchSource` vnode sources — kqueue, in the kernel. The kernel wakes the
  process only when *that specific inode* changes.
- The log tailers exist only while Discord is running, and are themselves vnode-driven, reading
  from a saved byte offset. The full log is never re-read.
- When Discord is not running, the agent holds two or three file descriptors and nothing else.

The only `DispatchQueue.asyncAfter` calls are one-shot debounce and re-check items that exist for
a few seconds after a real event and then vanish.

Measured on this machine while resident:

```
  PID  %CPU %MEM    RSS ELAPSED
23096   0.0  0.1  12064   00:07     # 11 open file descriptors
```

A vnode watch follows the *inode*, not the path, so when Discord replaces the whole bundle the
descriptor goes stale and the kernel reports `.delete`/`.revoke`. That is not a bug to work
around — it is precisely the event worth knowing about. The watcher re-arms on a bounded backoff
(1, 3, 8, 20, 60, 180, 600 s) and then stops, falling back to the next launch notification rather
than ticking forever.

**Network:** the only outbound request is fetching Vencord's `dist/` from GitHub, and only when
those files are missing or corrupt. A healthy machine never makes one.

---

## 4. Install

Requires macOS 14 (Sonoma) or newer, a Swift toolchain (Xcode or the Command Line Tools), and
Vencord already installed once via [VencordInstaller](https://vencord.dev/download).

```bash
git clone https://github.com/koels/vencord-guard.git
cd vencord-guard
./scripts/install.sh
```

This builds a release binary, runs the self-test against your real install, assembles
`~/Applications/VencordGuard.app`, ad-hoc signs it, and loads the LaunchAgent
(`RunAtLoad`, `KeepAlive`, `LimitLoadToSessionType: Aqua`, no `StartInterval`).

### The one manual step: App Management

**This is required, and nothing can do it for you.** Since macOS Sonoma, TCC blocks any process
from modifying another app's bundle unless the user allows it. Without it, the agent detects the
problem correctly but cannot fix it:

```
INFO  not repairing canary: cannot modify /Applications/Discord Canary.app/Contents/Resources:
      cannot create files in the bundle: You don't have permission to save the file
      ".vencordguard-probe" — grant App Management in System Settings > Privacy & Security
```

Fix it once:

> **System Settings → Privacy & Security → App Management → turn on `VencordGuard`**
>
> If it is not listed, drag in `~/Applications/VencordGuard.app`.

Then:

```bash
launchctl kickstart -k gui/$(id -u)/dev.vencordguard.agent
vencord-guard doctor
```

> `install.sh` puts the CLI in `~/.local/bin`, which is **not** on the default macOS `PATH`.
> It adds it to `~/.zprofile` for you — open a new terminal afterwards, or call the tools by
> full path: `~/.local/bin/vencord-guard doctor`.

This is also why the agent is a `.app` bundle rather than a bare binary: macOS attributes TCC
permissions to a signed bundle identity, and an unbundled launchd process can neither hold that
permission nor prompt for it.

> **After any rebuild, re-grant it.** Ad-hoc signatures change on every build, so macOS sees the
> rebuilt app as a new program. `vencord-guard doctor` will tell you if this has happened.

---

## 5. Uninstall

```bash
./scripts/uninstall.sh
```

Unloads the agent, deletes `~/Applications/VencordGuard.app`, the plist, and the `vencord-guard`
symlink; asks before deleting logs and state. **It never touches Discord or Vencord** — your
Vencord install is left exactly as it is. To remove Vencord itself, use VencordInstaller.app →
Uninstall.

---

## 6. Recovery behaviour

When a repair is warranted the agent:

1. **Confirms the state is appropriate.** It refuses if an update is in flight, if
   `Contents/Resources` changed within the last 15 s, if a cooldown or failure backoff is
   active, if another client mod owns `app.asar`, or if the bundle is not writable.
2. **Checks the Vencord `dist/` first** and downloads it only if missing or corrupt — patching
   against a missing `patcher.js` would produce a Discord that will not boot.
3. **Cleans up a broken patch** before re-patching, exactly as upstream's `patch()` does. If the
   stub is present but `_app.asar` is *gone*, it refuses and tells you to reinstall Discord:
   the original is not recoverable and writing another stub would not help.
4. **Patches** — rename `app.asar` → `_app.asar`, write the stub to a temp file, rename into
   place. If the stub write fails, the rename is undone, so Discord is never left unbootable.
5. **Verifies by re-reading from disk** rather than trusting the write.
6. **Does not kill Discord.** `rename()` is atomic and a running Discord keeps its old inode, so
   the patch simply takes effect at the next launch. You get a notification saying so.
   `autoRestartDiscord` exists in the config and is `false`.
7. **Records everything** in the log and in `state.json`.

Debouncing and cooldowns: bursts of filesystem events coalesce into one check (1.5 s, or 5 s for
bundle changes); repairs on the same install are at least 10 minutes apart; after 3 consecutive
failures it backs off for 6 hours and notifies once. Every "no" is logged with its reason and,
when the reason is transient, a re-check is scheduled so the finding is never silently dropped.

---

## 7. How to test each scenario

Assume `~/.local/bin` is on your `PATH` (install.sh arranges this; open a new terminal after
installing) and `L=~/Library/Logs/VencordGuard/vencord-guard.log`.
Watch with `tail -f $L` in one window.

**Before any destructive test, back up:**

```bash
R="/Applications/Discord Canary.app/Contents/Resources"
mkdir -p /tmp/asarbak && cp "$R/app.asar" "$R/_app.asar" /tmp/asarbak/
```

| Scenario | How | Expect in the log |
|---|---|---|
| **Normal launch** | Open Discord | `Discord Canary.app launched` → `check [Discord launched] canary: healthy, no action` (DEBUG) → `Vencord confirmed live in Discord Canary.app (ef29bbe)` |
| **Restart** | Quit and reopen Discord | `exited` → `check [Discord exited]` → `launched` → confirmed live again. No repair. |
| **Update** | Wait for a real host update, or replay one: `printf '%s\n' "INFO [updater_client::install]: Host to be installed: HostTaskIdentifier { }" >> "$HOME/Library/Application Support/discordcanary/logs/Discord Canary_updater_rCURRENT.log"` while Discord runs | `update in flight for canary: host update queued ... repairs suspended`, then no repair until `Update to latest complete` or the 5-minute expiry |
| **Vencord missing** | With Discord closed: `rm "$R/app.asar" && mv "$R/_app.asar" "$R/app.asar"` | `check [Contents/Resources changed] canary: unpatched` → `letting it settle` → `check [scheduled re-check]` → `repair START` → `repair OK` (~15 s total) |
| **Failed reinstall** | `chmod 500 "$R"` then remove the patch as above | `repair FAILED (1 in a row): ...`; three attempts → `retry budget` / backoff message + one notification. Restore with `chmod 755 "$R"`. |
| **Broken dist** | `mv ~/Library/Application\ Support/Vencord/dist/renderer.js /tmp/` then remove the patch | `brokenPatch(dist/renderer.js is missing)` → agent re-downloads dist → `repair OK` |
| **Foreign mod** | Point the stub elsewhere by hand | `foreignPatch(...)` → `refusing to overwrite it`, no repair, no retry |
| **Reboot / login** | Reboot, then `vencord-guard-bootcheck` | agent start timestamp within a minute of `kern.boottime`, uptime ≈ time since boot, `doctor` clean |

Restore at any time with `cp /tmp/asarbak/* "$R"/` or `$G repair`.

The `unpatched` case above is the one that matters most, and it is verified end-to-end on this
machine: the removed patch was detected via kqueue, deferred through the settle window,
re-checked on schedule, repaired, and the resulting `app.asar` and `_app.asar` hashed identical
to the pre-test backup.

---

## 8. Logging and debugging

```bash
tail -f ~/Library/Logs/VencordGuard/vencord-guard.log   # live
vencord-guard doctor                                    # why isn't it repairing?
vencord-guard status                                    # health + repair history
vencord-guard check                                     # one-shot; exit 0 = healthy
vencord-guard repair                                    # one-shot check + repair
vencord-guard selftest                                  # verify the asar generator
```

Every check logs its **trigger**, so the log answers "why did a repair happen" directly:

```
INFO  check [Contents/Resources changed] canary: unpatched
INFO  not repairing canary: Contents/Resources changed 5s ago; letting it settle
INFO  check [scheduled re-check] canary: unpatched
INFO  repair START canary at /Applications/Discord Canary.app — reason: unpatched
DEBUG renaming .../app.asar -> .../_app.asar
DEBUG wrote 221-byte stub -> .../app.asar
INFO  repair OK — Discord Canary.app is patched again
```

Triggers are one of: `agent start`, `Discord launched`, `Discord exited`,
`Contents/Resources changed`, `Discord update finished`, `update flag expired`,
`no Vencord activity in renderer log`, `new install detected`, `scheduled re-check`.

For verbose output, add `--debug` to the plist's `ProgramArguments` or set `"debug": true` in
`~/Library/Application Support/VencordGuard/config.json`, then
`launchctl kickstart -k gui/$(id -u)/dev.vencordguard.agent`.

Log files rotate at 1 MB, three kept. `launchd.out.log` / `launchd.err.log` in the same folder
capture anything that escapes the logger.

### Config

`~/Library/Application Support/VencordGuard/config.json` — all optional:

```json
{
  "branches": ["auto"],
  "notifications": true,
  "repairCooldownSeconds": 600,
  "maxConsecutiveFailures": 3,
  "failureBackoffSeconds": 21600,
  "confirmViaRendererLog": true,
  "rendererConfirmTimeoutSeconds": 120,
  "allowNetwork": true,
  "autoRestartDiscord": false,
  "debug": false
}
```

`branches` selects which Discord branches to guard. `["auto"]` (the default) means every branch
actually installed; otherwise list any of `"stable"`, `"ptb"`, `"canary"`, `"dev"` — for
example `{"branches": ["stable", "canary"]}` to guard those two and ignore the rest.

---

## 9. Layout

```
Package.swift
Sources/VencordGuard/
  Main.swift              @main, CLI (run/status/check/repair/doctor/selftest), single-instance lock
  Guard.swift             the event loop: workspace + fs + log signals, debounce, retry budget
  Watchers.swift          VnodeWatcher (kqueue) and LogTailer (incremental, offset-based)
  DiscordInstall.swift    branch discovery, the five-state health check, TCC probe
  Repair.swift            gating (cooldown/settle/update/backoff) and the patch/unpatch steps
  AsarStub.swift          byte-for-byte port of upstream app_asar.go
  VencordDownloader.swift dist download, only when dist is broken
  State.swift             persisted per-install history
  Support.swift           paths, rotating log, notifications, config
launchd/
  dev.vencordguard.agent.plist
  Info.plist
scripts/install.sh, scripts/uninstall.sh
```
