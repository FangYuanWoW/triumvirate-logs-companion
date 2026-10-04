-- UI/ProgressionTooltip.lua
-- Raid progression on the player unit tooltip.
--
-- Data comes from Data/Progression.lua, which the Logs Uploader rewrites with
-- the realm's snapshot (every player with a logged raid kill). Shape:
--
--   ALC_ProgressionData = {
--     v = 1, tenant = "triumvirate", generatedAt = <unix>, activePhase = 2,
--     phases  = { { n = 1, name = "Phase 1", raids = { 1, 2, 3, 4 } }, ... },
--     raids   = { [1] = { short = "OS", location = "Obsidian Sanctum", bosses = 1 }, ... },
--     players = { ["Fangyuan"] = "2.8.25.N.11.11;1.3.25.N.5.5", ... },
--   }
--
-- A player string is entries joined by ";", each
--   <phase>.<raidId>.<size>.<diff>.<killed>.<kills>
-- size: "10" | "25" | "F" (flex) | other number; diff: "N" | "H" | "0".."3"
-- (Obsidian Sanctum drakes). killed = distinct bosses down, kills = total kills.
--
-- Default view: the current phase, one line per raid, the highest difficulty
-- reached per raid size. Holding Shift (or the "always expanded" setting)
-- shows every size/difficulty, kill counts, older phases and the data age.

local ALC = _G.ALC
local P = {}
ALC.UI.ProgressionTooltip = P

local function cfg()
    return _G.ALC_Config or {}
end

local function on(key)
    -- Every toggle here defaults through C.DEFAULT_CONFIG; treat a missing
    -- key (pre-upgrade SavedVariables before Init merges) as the default.
    local v = cfg()[key]
    if v == nil then return ALC.Core.Constants.DEFAULT_CONFIG[key] and true or false end
    return v and true or false
end

-- ---------------------------------------------------------------------------
-- Data access
-- ---------------------------------------------------------------------------

function P.data()
    local d = _G.ALC_ProgressionData
    if type(d) ~= "table" or type(d.players) ~= "table" then return nil end
    return d
end

-- Data older than this means the Uploader has not been running.
local STALE_AFTER_S = 7 * 86400

-- What the player should be told about the data itself, or nil when it is
-- fine: "missing" (never synced) or "stale" (synced, but not for a week).
function P.ctaState()
    local d = P.data()
    if not d then return "missing" end
    if d.generatedAt and time() - d.generatedAt > STALE_AFTER_S then return "stale" end
    return nil
end

-- The call to action, as plain sentences (no link markup), for chat, the
-- settings tab and the tooltip.
function P.ctaText(state)
    local B = ALC.Core.Branding
    if state == "stale" then
        local d = P.data()
        local days = math.floor((time() - (d.generatedAt or time())) / 86400)
        return string.format("Raid progression data is %d days old. Open the %s to refresh it.",
            days, B.uploaderName())
    end
    return string.format("No raid progression data yet. Get the %s from %s to see what players have cleared.",
        B.uploaderName(), B.domain() .. "/download")
end

-- Parsed entry lists, per player name. Built on first hover; a /reload
-- (the only way new data arrives) discards it.
local parsed = {}

local DIFF_RANK = { ["0"] = 1, ["1"] = 2, ["2"] = 3, ["3"] = 4, N = 10, H = 20 }
local SIZE_ORDER = { ["25"] = 1, F = 2, ["10"] = 3 }

local function parseEntries(raw)
    local list = {}
    for entry in string.gmatch(raw or "", "[^;]+") do
        local ph, raid, size, diff, killed, kills =
            string.match(entry, "^(%d+)%.(%d+)%.([^%.]+)%.([^%.]+)%.(%d+)%.(%d+)$")
        if ph then
            list[#list + 1] = {
                phase  = tonumber(ph),
                raid   = tonumber(raid),
                size   = size,
                diff   = diff,
                killed = tonumber(killed),
                kills  = tonumber(kills),
            }
        end
    end
    return list
end

-- Look a player up by the name the client shows. Names are stored exactly as
-- the combat log wrote them, which is how UnitName returns them; the
-- case-insensitive scan is only for /tlc prog typed by hand.
function P.lookup(name, exactOnly)
    local d = P.data()
    if not d or not name or name == "" then return nil end
    if parsed[name] then return parsed[name], name end
    local raw = d.players[name]
    local key = name
    if not raw and not exactOnly then
        local lname = string.lower(name)
        for k, v in pairs(d.players) do
            if string.lower(k) == lname then raw, key = v, k; break end
        end
    end
    if not raw then return nil end
    parsed[key] = parseEntries(raw)
    return parsed[key], key
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

local function sizeLabel(size)
    if size == "F" then return "Flex" end
    return size
end

local function diffLabel(diff)
    if diff == "N" then return "N" end
    if diff == "H" then return "H" end
    if string.match(diff, "^%d$") then return " " .. diff .. "D" end
    return " " .. diff
end

local COLOR_FULL    = "1eff00"  -- full clear
local COLOR_PARTIAL = "ffd100"  -- some bosses down
local COLOR_LABEL   = "c8c8c8"
local COLOR_HEROIC  = "ff8000"
local COLOR_DIM     = "808080"

local function colorize(hex, s) return "|cff" .. hex .. s .. "|r" end

-- One tooltip row per (raid, size, difficulty): the raid and its size +
-- difficulty on the LEFT ("ICC 25H", "OS 10 1D"), the N/M on the right, so
-- every row lines up in the same two columns.
local function rowLeft(raidShort, e)
    local label = sizeLabel(e.size) .. diffLabel(e.diff)
    local labelColor = (e.diff == "H" or e.diff == "3") and COLOR_HEROIC or COLOR_LABEL
    return " " .. raidShort .. " " .. colorize(labelColor, label)
end

local function rowRight(e, total, showKills)
    local frac = e.killed .. "/" .. total
    local fracColor = (e.killed >= total) and COLOR_FULL or COLOR_PARTIAL
    local r = colorize(fracColor, frac)
    if showKills then
        r = r .. colorize(COLOR_DIM, string.format("  %d kill%s", e.kills, e.kills == 1 and "" or "s"))
    end
    return r
end

local function sortEntries(a, b)
    local sa, sb = SIZE_ORDER[a.size] or 9, SIZE_ORDER[b.size] or 9
    if sa ~= sb then return sa < sb end
    return (DIFF_RANK[a.diff] or 0) > (DIFF_RANK[b.diff] or 0)
end

-- Entries for one phase, grouped per raid in the phase's display order.
local function byRaid(entries, phase, raidOrder)
    local groups, any = {}, false
    for _, e in ipairs(entries) do
        if e.phase == phase.n then
            groups[e.raid] = groups[e.raid] or {}
            table.insert(groups[e.raid], e)
            any = true
        end
    end
    if not any then return nil end
    local out = {}
    for _, raidId in ipairs(raidOrder) do
        local g = groups[raidId]
        if g then
            table.sort(g, sortEntries)
            out[#out + 1] = { raid = raidId, entries = g }
        end
    end
    return out
end

-- Highest difficulty per size, for the compact one-line-per-raid view.
local function bestPerSize(entries)
    local best, order = {}, {}
    for _, e in ipairs(entries) do
        local cur = best[e.size]
        if not cur then
            best[e.size] = e
            order[#order + 1] = e.size
        elseif (DIFF_RANK[e.diff] or 0) > (DIFF_RANK[cur.diff] or 0) then
            best[e.size] = e
        end
    end
    local out = {}
    for _, s in ipairs(order) do out[#out + 1] = best[s] end
    table.sort(out, sortEntries)
    return out
end

local function phaseByNumber(d, n)
    for _, ph in ipairs(d.phases or {}) do
        if ph.n == n then return ph end
    end
    return nil
end

local function ago(ts)
    if not ts then return nil end
    local s = time() - ts
    if s < 0 then s = 0 end
    if s < 3600 then return math.max(1, math.floor(s / 60)) .. "m old" end
    if s < 86400 * 2 then return math.floor(s / 3600) .. "h old" end
    return math.floor(s / 86400) .. "d old"
end

-- Produce tooltip lines as { left, right } pairs (right may be nil), or nil
-- when there is nothing to show. Shared by the tooltip and /tlc prog.
function P.buildLines(name, expanded)
    local d = P.data()
    if not d then return nil end
    local entries = P.lookup(name, true)
    local brand = ALC.Core.Branding
    local header = colorize(brand.current().accent, brand.short())
    local lines = {}

    if not entries or #entries == 0 then
        if on("progression_show_unlogged") then
            lines[1] = { header, colorize(COLOR_DIM, "no logged raid kills") }
            return lines
        end
        return nil
    end

    -- Phases newest first; the current phase always leads.
    local phases = {}
    for _, ph in ipairs(d.phases or {}) do phases[#phases + 1] = ph end
    table.sort(phases, function(a, b) return a.n > b.n end)

    local showOlder = expanded or on("progression_all_phases")
    local showKills = expanded and on("progression_show_kills")
    local shownAny = false

    for _, ph in ipairs(phases) do
        if ph.n <= (d.activePhase or ph.n) then
            local groups = byRaid(entries, ph, ph.raids or {})
            if groups then
                local label = "Phase " .. ph.n
                local right = nil
                if not shownAny and expanded then right = colorize(COLOR_DIM, ago(d.generatedAt) or "") end
                if not shownAny then
                    lines[#lines + 1] = { header .. colorize(COLOR_DIM, " - " .. label), right }
                else
                    lines[#lines + 1] = { colorize(COLOR_DIM, label), nil }
                end
                for _, g in ipairs(groups) do
                    local raid = d.raids[g.raid] or {}
                    local total = raid.bosses or 0
                    local short = raid.short or "?"
                    -- Compact: the highest difficulty per raid size. Expanded:
                    -- every size and difficulty, with kill counts.
                    local rows = expanded and g.entries or bestPerSize(g.entries)
                    for _, e in ipairs(rows) do
                        lines[#lines + 1] = { rowLeft(short, e), rowRight(e, total, showKills) }
                    end
                end
                shownAny = true
                if not showOlder then break end
            end
        end
    end

    if not shownAny then return nil end
    return lines
end

-- ---------------------------------------------------------------------------
-- Tooltip hook
-- ---------------------------------------------------------------------------

local function expandedNow()
    return on("progression_always_expanded") or IsShiftKeyDown()
end

local function onSetUnit(tooltip)
    if not on("progression_tooltip") then return end
    if tooltip.alcProgressionAdded then return end
    if on("progression_hide_in_combat") and InCombatLockdown() then return end
    local _, unit = tooltip:GetUnit()
    if not unit or not UnitIsPlayer(unit) then return end
    local name, realm = UnitName(unit)
    -- Another realm's player of the same name is someone else entirely.
    if realm and realm ~= "" then return end
    if not P.data() then
        -- No snapshot installed at all: one quiet line pointing at the
        -- Uploader, instead of a feature that silently never shows anything.
        if on("progression_cta") then
            tooltip.alcProgressionAdded = true
            tooltip:AddLine("Raid progression: get the " .. ALC.Core.Branding.uploaderName()
                .. " at " .. ALC.Core.Branding.domain() .. "/download", 0.5, 0.5, 0.5, true)
            tooltip:Show()
        end
        return
    end
    local ok, lines = pcall(P.buildLines, name, expandedNow())
    if not ok or not lines then return end
    tooltip.alcProgressionAdded = true
    for _, l in ipairs(lines) do
        if l[2] then
            tooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 1, 1, 1)
        else
            tooltip:AddLine(l[1], 1, 1, 1)
        end
    end
    tooltip:Show()
end

function P.start()
    if P.installed then return end
    P.installed = true
    GameTooltip:HookScript("OnTooltipSetUnit", onSetUnit)
    -- Give the login chat burst a moment so the reminder is not buried.
    local delay, elapsed = CreateFrame("Frame"), 0
    delay:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < 8 then return end
        self:SetScript("OnUpdate", nil)
        pcall(P.chatCta)
    end)
    GameTooltip:HookScript("OnTooltipCleared", function(tooltip)
        tooltip.alcProgressionAdded = nil
    end)
    -- Shift toggles the expanded view on the tooltip already showing.
    ALC.RegisterEvent("MODIFIER_STATE_CHANGED", function(_, key)
        if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
        if not on("progression_tooltip") or on("progression_always_expanded") then return end
        if not GameTooltip:IsShown() then return end
        local _, unit = GameTooltip:GetUnit()
        if unit and UnitIsPlayer(unit) then
            GameTooltip:SetUnit(unit)
        end
    end)
end

-- Chat reminder at login when the data is missing or stale. At most once a
-- day (ALC_Config.progression_cta_at), and never when the tooltip or the
-- reminder is switched off.
local CTA_EVERY_S = 86400

function P.chatCta(force)
    local state = P.ctaState()
    if not state then return false end
    if not force then
        if not on("progression_tooltip") or not on("progression_cta") then return false end
        local last = tonumber(cfg().progression_cta_at) or 0
        if time() - last < CTA_EVERY_S then return false end
    end
    if _G.ALC_Config then ALC_Config.progression_cta_at = time() end
    local B = ALC.Core.Branding
    local V = ALC.Transport and ALC.Transport.VersionCheck
    local link = (V and V.urlLink) and V.urlLink(B.downloadUrl(), "Download the " .. B.uploaderName()) or B.downloadUrl()
    ALC.Core.Logger.info(P.ctaText(state) .. " " .. link)
    return true
end

-- One-line status for the settings tab and /tlc status.
function P.statusText()
    local d = P.data()
    if not d then return P.ctaText("missing") end
    local n = 0
    for _ in pairs(d.players) do n = n + 1 end
    return string.format("%d players, data %s", n, ago(d.generatedAt) or "of unknown age")
end

-- /tlc prog <name>: print a player's progression to chat.
function P.printFor(name)
    local log = ALC.Core.Logger
    if not P.data() then
        P.chatCta(true)
        return
    end
    if not name or name == "" then
        name = UnitName("target") or UnitName("player")
    end
    local _, key = P.lookup(name)
    local lines = key and P.buildLines(key, true)
    if not lines then
        log.info("No logged raid kills for " .. name .. ".")
        return
    end
    log.info(key .. ":")
    for _, l in ipairs(lines) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. l[1] .. (l[2] and ("  " .. l[2]) or ""))
    end
end
