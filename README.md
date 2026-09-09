<div align="center">

<img src="docs/logo.png" alt="Triumvirate Logs Companion" width="128" height="128" />

# Triumvirate Logs Companion

**Cross-player Combatant Information capture for WoW 3.3.5a**

Auto-inspects your raid in the background and embeds gear and talents into your `WoWCombatLog.txt`, so uploads to **[triumlogs.gg](https://triumlogs.gg)** can render WarcraftLogs-style combatant detail on every report.

[![Latest release](https://img.shields.io/github/v/release/FangYuanWoW/triumvirate-logs-companion?color=4ec3ff)](https://github.com/FangYuanWoW/triumvirate-logs-companion/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-e8e8e8)](LICENSE)
[![Client](https://img.shields.io/badge/client-3.3.5a-orange)](#install)

</div>

---

## Why this exists

Stock 3.3.5a does not emit `COMBATANT_INFO` events, so analytics tools that
rely on them - gear breakdown, talent specs per fight - have nothing to work
with. This addon fills that gap by:

1. Auto-inspecting the raid in the background. One logger covers every raider
   within inspect range, with no setup or coordination needed.
2. Reading your own character's state directly from the Lua API.
3. Serializing every captured Combatant Info struct, compressing it, and
   embedding it into `SPELL_CAST_FAILED` events so the server-side parser can
   demux it cleanly when the log is uploaded.

The result: dungeon and raid reports on triumlogs.gg can show the full build of
every player who was within ~28y of any logger during the fight.

## Install

1. Download the latest release zip and extract `TriumvirateLogsCompanion/`
   into your `Interface\AddOns\` folder.
2. Restart the game (or `/reload`).
3. Click the blue-flame **minimap button**, or type `/tlc`.

## Usage

| Action | What it does |
|---|---|
| `/tlc` | Open settings panel |
| `/tlc status` | Print current state and live capture stats |
| Minimap button (click) | Toggle settings panel |
| Minimap button (shift-drag) | Reposition around minimap |

`/alc` works as a universal alias for every command, and is kept because it is
in a lot of people's muscle memory and macros.

Default behavior: the addon runs continuously in raids and dungeons,
auto-starts `/combatlog` on entry to monitored zones, and prompts before
stopping when you leave. No further interaction is needed.

## Settings

- **Auto /combatlog on raid/dungeon zone entry** - toggle the auto-start. When
  off, you log manually with `/combatlog` and the addon stays out of the way.
- **Silent auto-logging** - skip the start/stop confirmation prompts. The addon
  starts logging silently on zone entry and never auto-stops; you control
  `/combatlog` yourself.
- **Log 5-man dungeons** - when off, entering a 5-man no longer auto-starts
  `/combatlog`. Raids and world bosses still log.
- **Log raids and world bosses** - when off, entering a raid instance or a
  world-boss zone no longer auto-starts `/combatlog`. Dungeons and Mythic+
  still log. If logging is already running when you enter, the addon stops it -
  but only if the addon started it; a `/combatlog` you turned on yourself is
  left alone.
- **Debug mode** - verbose chat output for diagnostics.
- **Monitored zones** - the list of zones where auto-`/combatlog` triggers. Add
  the current zone with one click; remove anything you don't want with the X
  next to its name. Removals are permanent: a zone you remove stays removed
  across logins, and **Restore Default Zones** (or `/tlc zone reset`) is the way
  back to the shipped list.

The shipped defaults cover the raid lineup, world bosses and their outdoor
subzones, and the 5-man dungeons. Customize the full list from the settings
panel.

## Coexistence with other addons

Plays nicely with `FangYuanWoW/CombatLogs`. If either addon has already enabled
`/combatlog`, this one skips its own toggle and says so in chat. Logging is
never inadvertently disabled.

No conflicts with WeakAuras, Skada, Recount, Details, DBM, or standard raid
frame addons.

## How the data flows

```
       inspect cycle
   +─────────────────────+
   |  raid party tokens  |  NotifyInspect cycle, gated by inspect range
   +──────────+──────────+
              |
              ▼
   +─────────────────────+
   |   Combatant Info    |  ← gear, talents, guild, arena teams
   |       struct        |
   +──────────+──────────+
              |  serialize → deflate → URL-safe base64
              ▼
   +─────────────────────+
   |  chunk into payloads|
   |  with sentinel      |  [[ALC_CI_v1_<session>_<guid>_<seq>/<total>]]
   |  header             |
   +──────────+──────────+
              |  embed in fail-reason field of SPELL_CAST_FAILED
              ▼
   +─────────────────────+
   |  WoWCombatLog.txt   |  ← uploaded to triumlogs.gg
   +─────────────────────+
```

The server-side demuxer reverses the pipeline: scans for the sentinel,
reassembles chunks per `(session, guid, snapshot)` tuple, decompresses, parses
the AceSerializer-3.0 stream, and lands a structured CI per encounter
participant in the database.

## Privacy & data scope

The addon only reads data that any other player in your raid can already see -
gear, equipped enchants, visible talents - plus your own client-side state
(active spec, guild). It embeds that data in the combat log so the parser at
triumlogs.gg can attribute it back to the right encounter. Nothing else is read
or sent.

Captured: gear itemstrings, talent ranks and spec, guild and rank, race, class,
level, gender. NOT captured: chat content, account info, UI state, anything from
other addons, anything outside the inspectable character profile.

Inspect itself is a public protocol - anyone in your raid can see the same data
by right-clicking and inspecting. This addon just turns thousands of one-off
manual inspects into structured, per-encounter capture.

## License

MIT - see `LICENSE`.

## Author

Made by **FangYuanWoW**. Issues and pull requests welcome on this repository.
