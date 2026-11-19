# Caffeine Plus

Caffeine Plus is a fork of [Caffeine](https://github.com/domzilla/Caffeine) (MIT) for macOS. It keeps everything Caffeine does (menu bar cup, timers, preferences, activity simulation) and adds **schedule windows**: time spans in which the Mac must be awake, registered by Claude through a local MCP server when it creates or changes scheduled tasks.

## What it adds

- **Schedules window** (right-click the cup → *Schedules…*): upcoming windows, state (pending, in progress, finished, skipped, interrupted), skip/disable/delete, and wake-scheduling warnings.
- **Local MCP server**: `http://127.0.0.1:47821/mcp` (loopback only, bearer token in `~/Library/Application Support/Caffeine Plus/mcp-token`). Tools: `list_windows`, `upsert_window` (idempotent by `id`), `delete_window`, `get_status`.
- **Wake and sleep control**: wakes the Mac `lead_minutes` before a window (`pmset schedule wake`), holds a sleep assertion until it ends and then releases it, handling overlapping windows, sleeps, clock changes and relaunches.
- **Open at login** (Preferences): registers the app as a login item. It starts the app at login only; it does not reopen it when the Mac wakes from sleep, so keep Caffeine Plus open for scheduled wakes.
- Coexists with Caffeine: different bundle id (`net.rubenguior.caffeineplus`), name and preferences; no auto-update.

## Register the MCP server in Claude Code

```bash
claude mcp add --transport http caffeine-plus http://127.0.0.1:47821/mcp \
  --header "Authorization: Bearer $(cat ~/Library/Application\ Support/Caffeine\ Plus/mcp-token)"
```

## macOS limitations

- Scheduling a wake needs root. Caffeine Plus does not run privileged code itself: the Schedules window offers an opt-in, narrow sudoers rule (`/etc/sudoers.d/caffeineplus`, only `pmset schedule wake|cancel wake`) installed after an administrator prompt. Without it, windows still hold the assertion if the Mac is awake, and the app says so.
- A scheduled wake is a short "dark wake"; the app takes the assertion at the wake time, not at the window start.
- With the lid closed on battery (or without power/external display) macOS may sleep regardless. A powered-off Mac cannot wake.
- The app is not sandboxed (needed for `sudo` and the local server) and is unsigned for now.

## Build and test

```bash
xcodebuild -project src/Caffeine.xcodeproj -scheme Caffeine -destination "platform=macOS" build
swift test   # pure-logic tests (schedules, power, wake, MCP)
```

## Credits and license

MIT. Caffeine © 2006–2018 Tomas Franzén (Lighthead Software), © 2018 Michael Jones (IntelliScape Computer Solutions), © 2022 Dominic Rodemer; Caffeine Plus additions © 2026 Rubén Guijarro. See [LICENSE](LICENSE).
