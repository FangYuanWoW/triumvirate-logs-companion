<p align="center">
  <img src="docs/logo.png" alt="Triumvirate Logs Companion" width="128" height="128" />
</p>

# Triumvirate Logs Companion

In-game companion addon for **[triumviratelogs.gg](https://triumviratelogs.gg)** — the combat-log site for the Triumvirate (WotLK 3.3.5a) server.

It auto-inspects your raid in the background and embeds each player's gear and talents into your `WoWCombatLog.txt`, so uploads to triumviratelogs.gg can render WarcraftLogs-style combatant detail on every report.

## Install

1. Download the latest `TriumvirateLogsCompanion-vX.Y.Z.zip` from [**Releases**](https://github.com/FangYuanWoW/triumvirate-logs-companion/releases/latest).
2. Extract it into your WoW `Interface\AddOns` folder — you should end up with `Interface\AddOns\TriumvirateLogsCompanion`.
3. Restart the client (or `/reload`) and enable **Triumvirate Logs Companion** on the character-select **AddOns** screen.

## Usage

Click the flame **minimap button**, or type `/alc`.

| Command | Action |
| --- | --- |
| `/alc` | Open the settings panel |
| `/alc status` | Print current state and live capture stats |

It automatically starts `/combatlog` when you enter a monitored raid or dungeon and inspects raiders in the background, so every report has gear and talents attached.

## How it works

The addon reads party/raid inspect data and embeds it in the combat log so the parser at triumviratelogs.gg can attach full combatant information to each report. It does not modify any game files — it only reads inspect data and writes to your own combat log.
