-- UI/ProgressionTooltip.lua
-- Raid progression, All-Stars rankings and parses on the player unit tooltip.
--
-- The data is NOT part of this addon. The Logs Uploader writes it as a
-- standalone data addon (TriumvirateLogsData / FrostmourneLogsData, see
-- Branding.dataAddon) with a public Lua API that any addon can use; this file
-- is one consumer of that API:
--
--   local L = _G[<data addon>]; L.IsLoaded(); L.GetMeta(); L.GetProfile(who)
--
-- (the .toc lists the data addon under OptionalDeps so it loads first).
--
-- Default view: the current phase, one row per raid and size at the highest
-- difficulty reached, then the main raid's All-Stars rank and Best Perf Avg.
-- Holding Shift (or "always expanded") shows every size and difficulty, kill
-- counts, every ranked raid with per-boss parses, and earlier phases.

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
-- Data access (through the data addon's public API)
-- ---------------------------------------------------------------------------

-- The data addon's API table when it is installed AND has data, else nil.
function P.lib()
    local L = _G[ALC.Core.Branding.dataAddon()]
    if type(L) == "table" and type(L.IsLoaded) == "function" and L.IsLoaded() then
        return L
    end
    return nil
end

-- Data older than this means the Uploader has not been running.
local STALE_AFTER_S = 7 * 86400

-- What the player should be told about the data itself, or nil when it is
-- fine: "missing" (never synced) or "stale" (synced, but not for a week).
function P.ctaState()
    local L = P.lib()
    if not L then return "missing" end
    local meta = L.GetMeta()
    if meta and meta.generatedAt and time() - meta.generatedAt > STALE_AFTER_S then return "stale" end
    return nil
end

-- The call to action, as plain sentences (no link markup), for chat, the
-- settings tab and the tooltip.
function P.ctaText(state)
    local B = ALC.Core.Branding
    if state == "stale" then
        local meta = P.lib().GetMeta()
        local days = math.floor((time() - (meta.generatedAt or time())) / 86400)
        return string.format("Raid progression data is %d days old. Open the %s to refresh it.",
            days, B.uploaderName())
    end
    return string.format("No raid progression data yet. Get the %s from %s to see what players have cleared.",
        B.uploaderName(), B.downloadPage())
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

local COLOR_FULL    = "1eff00"  -- full clear
local COLOR_PARTIAL = "ffd100"  -- some bosses down
local COLOR_LABEL   = "c8c8c8"
local COLOR_HEROIC  = "ff8000"
local COLOR_DIM     = "808080"
local SEPARATOR     = "- - - - - - - - - - - - - - - - - - - - - -"

local function colorize(hex, s) return "|cff" .. hex .. s .. "|r" end

local DIFF_RANK  = { ["0d"] = 1, ["1d"] = 2, ["2d"] = 3, ["3d"] = 4, normal = 10, heroic = 20 }
local SIZE_ORDER = { [25] = 1, flex = 2, [10] = 3 }

local function sizeLabel(size)
    if size == "flex" then return "Flex" end
    return tostring(size)
end

-- "Nm"/"Hc" after the size ("25Hc", "10Nm") - the spelling other WotLK log
-- addons use, so it reads at a glance. Obsidian Sanctum keeps its drakes
-- count ("10 1D").
local function diffLabel(diff)
    if diff == "normal" then return "Nm" end
    if diff == "heroic" then return "Hc" end
    local drakes = string.match(diff or "", "^(%d)d$")
    if drakes then return " " .. drakes .. "D" end
    return " " .. tostring(diff)
end

local function isHard(diff) return diff == "heroic" or diff == "3d" end

local function diffColored(diff, prefix)
    local text = (prefix or "") .. diffLabel(diff)
    return colorize(isHard(diff) and COLOR_HEROIC or COLOR_LABEL, (string.gsub(text, "^ ", "")))
end

-- Parse colours, the scale every log site uses.
local function parseColor(p)
    if p >= 100 then return "e5cc80" end
    if p >= 99 then return "e268a8" end
    if p >= 95 then return "ff8000" end
    if p >= 75 then return "a335ee" end
    if p >= 50 then return "0070ff" end
    if p >= 25 then return "1eff00" end
    return "9d9d9d"
end

local function parseText(p)
    if not p then return colorize(COLOR_DIM, "-") end
    local s = (p == math.floor(p)) and tostring(p) or string.format("%.1f", p)
    return colorize(parseColor(p), s)
end

-- One row per (raid, size, difficulty): the raid and its size + difficulty
-- on the LEFT ("ICC 25Hc", "OS 10 1D"), the N/M on the right.
local function rowLeft(e)
    local d = diffLabel(e.difficulty)
    -- "Flex Hc", not "FlexHc"; numeric sizes stay glued ("25Hc").
    if e.size == "flex" and string.sub(d, 1, 1) ~= " " then d = " " .. d end
    local labelColor = isHard(e.difficulty) and COLOR_HEROIC or COLOR_LABEL
    return " " .. (e.raid or "?") .. " " .. colorize(labelColor, sizeLabel(e.size) .. d)
end

local function rowRight(e, showKills)
    local frac = e.killed .. "/" .. (e.total or 0)
    local fracColor = (e.killed >= (e.total or 0)) and COLOR_FULL or COLOR_PARTIAL
    local r = colorize(fracColor, frac)
    if showKills then
        r = r .. colorize(COLOR_DIM, string.format("  %d kill%s", e.kills, e.kills == 1 and "" or "s"))
    end
    return r
end

local function sortEntries(a, b)
    local sa, sb = SIZE_ORDER[a.size] or 9, SIZE_ORDER[b.size] or 9
    if sa ~= sb then return sa < sb end
    return (DIFF_RANK[a.difficulty] or 0) > (DIFF_RANK[b.difficulty] or 0)
end

-- Progression entries for one phase, grouped per raid in the phase's order.
local function byRaid(entries, phase)
    local groups, any = {}, false
    for _, e in ipairs(entries) do
        if e.phase == phase.n then
            groups[e.raidId] = groups[e.raidId] or {}
            table.insert(groups[e.raidId], e)
            any = true
        end
    end
    if not any then return nil end
    local out = {}
    for _, raidId in ipairs(phase.raids or {}) do
        local g = groups[raidId]
        if g then
            table.sort(g, sortEntries)
            out[#out + 1] = g
        end
    end
    return out
end

-- Highest difficulty per size, for the compact one-row-per-size view.
local function bestPerSize(entries)
    local best, order = {}, {}
    for _, e in ipairs(entries) do
        local cur = best[e.size]
        if not cur then
            best[e.size] = e
            order[#order + 1] = e.size
        elseif (DIFF_RANK[e.difficulty] or 0) > (DIFF_RANK[cur.difficulty] or 0) then
            best[e.size] = e
        end
    end
    local out = {}
    for _, s in ipairs(order) do out[#out + 1] = best[s] end
    table.sort(out, sortEntries)
    return out
end

local function ago(ts)
    if not ts then return nil end
    local s = time() - ts
    if s < 0 then s = 0 end
    if s < 3600 then return math.max(1, math.floor(s / 60)) .. "m old" end
    if s < 86400 * 2 then return math.floor(s / 3600) .. "h old" end
    return math.floor(s / 86400) .. "d old"
end

local ROLE_SUFFIX = { healer = " (Healing)", tank = " (Tank)" }

local function rankText(r)
    if not r or not r.rank then return nil end
    return "#" .. r.rank .. (r.of and ("/" .. r.of) or "")
end

-- All-Stars + parse rows for one ranked raid.
-- Rank in gold, points in cyan, spec in the player's class colour: the
-- colours other WotLK log addons use for the same facts.
local COLOR_RANK   = "ffd100"
local COLOR_POINTS = "4ecdf0"

local function rankingRows(lines, rk, expanded, showRaid, classHex)
    if on("progression_show_rankings") then
        -- The raid name is already on the progression row above; it is only
        -- repeated when several ranked raids are listed (Shift).
        local raidPart = showRaid and ((rk.raid or "?") .. " ") or ""
        local left = " All-Stars " .. raidPart .. diffColored(rk.difficulty)
            .. (ROLE_SUFFIX[rk.role] and colorize(COLOR_DIM, ROLE_SUFFIX[rk.role]) or "")
        local right = {}
        if rk.points then right[#right + 1] = colorize(COLOR_POINTS, string.format("%d pts", math.floor(rk.points + 0.5))) end
        if rankText(rk.overall) then right[#right + 1] = colorize(COLOR_RANK, rankText(rk.overall)) end
        lines[#lines + 1] = { left, table.concat(right, "  ") }
        local parts = {}
        if rk.spec and rk.spec.rank then parts[#parts + 1] = colorize(COLOR_RANK, rankText(rk.spec)) .. colorize(COLOR_LABEL, " spec") end
        if rk.class and rk.class.rank then parts[#parts + 1] = colorize(COLOR_RANK, rankText(rk.class)) .. colorize(COLOR_LABEL, " class") end
        if #parts > 0 then
            local specName = (rk.spec and rk.spec.name) or ""
            lines[#lines + 1] = { "   " .. colorize(classHex or COLOR_DIM, specName), table.concat(parts, "  ") }
        end
    end
    if on("progression_show_parses") and rk.bestPerfAvg then
        lines[#lines + 1] = { " Best Perf Avg", parseText(rk.bestPerfAvg) }
        if expanded then
            for _, b in ipairs(rk.bosses or {}) do
                -- "*" = provisional: a fresh best not weekly-locked yet (the
                -- site marks it the same way).
                local mark = (b.parse and b.provisional) and colorize(COLOR_DIM, "*") or ""
                lines[#lines + 1] = { "   " .. colorize(COLOR_DIM, b.name), parseText(b.parse) .. mark }
            end
        end
    end
end

-- Produce tooltip lines as { left, right } pairs (right may be nil), or nil
-- when there is nothing to show. Shared by the tooltip and /tlc prog.
function P.buildLines(who, expanded)
    local L = P.lib()
    if not L then return nil end
    local meta = L.GetMeta()
    local profile = L.GetProfile(who)
    local brand = ALC.Core.Branding
    local header = colorize(brand.current().accent, brand.short())
    local lines = {}

    -- Class colour for the spec name, when `who` is a unit we can ask.
    local classHex
    if UnitExists and UnitExists(who) and UnitClass then
        local _, token = UnitClass(who)
        local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        if c then
            classHex = string.format("%02x%02x%02x", math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255))
        end
    end

    if not profile or #profile.progression == 0 then
        if on("progression_show_unlogged") then
            lines[1] = { header, colorize(COLOR_DIM, "no logged raid kills") }
            return lines
        end
        return nil
    end

    local phases = {}
    for _, ph in ipairs(meta.phases or {}) do phases[#phases + 1] = ph end
    table.sort(phases, function(a, b) return a.n > b.n end)

    local showOlder = expanded or on("progression_all_phases")
    local showKills = expanded and on("progression_show_kills")
    local shownAny = false

    for _, ph in ipairs(phases) do
        if ph.n <= (meta.activePhase or ph.n) then
            local groups = byRaid(profile.progression, ph)
            if groups then
                -- Brand + data age is its own header line, then a dashed rule
                -- (tooltip only; /tlc prog skips it); every phase gets a row.
                if not shownAny then
                    lines[#lines + 1] = { header, colorize(COLOR_DIM, ago(meta.generatedAt) or "") }
                    lines[#lines + 1] = { colorize(COLOR_DIM, SEPARATOR), nil, sep = true }
                end
                lines[#lines + 1] = { colorize(COLOR_DIM, "Phase " .. ph.n), nil }
                for _, g in ipairs(groups) do
                    local rows = expanded and g or bestPerSize(g)
                    for _, e in ipairs(rows) do
                        lines[#lines + 1] = { rowLeft(e), rowRight(e, showKills) }
                    end
                end
                -- Rankings exist for the current phase only: the main raid
                -- compact, every ranked raid expanded, in the phase's order.
                if ph.n == meta.activePhase and #profile.rankings > 0 then
                    local byId = {}
                    for _, rk in ipairs(profile.rankings) do byId[rk.raidId] = rk end
                    for _, raidId in ipairs(ph.raids or {}) do
                        if byId[raidId] then
                            rankingRows(lines, byId[raidId], expanded,
                                expanded and #profile.rankings > 1, classHex)
                            if not expanded then break end
                        end
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
    local _, realm = UnitName(unit)
    -- Another realm's player of the same name is someone else entirely.
    if realm and realm ~= "" then return end
    if not P.lib() then
        -- No data installed at all: one quiet line pointing at the Uploader,
        -- instead of a feature that silently never shows anything.
        if on("progression_cta") then
            tooltip.alcProgressionAdded = true
            tooltip:AddLine("Raid progression: get the " .. ALC.Core.Branding.uploaderName()
                .. " at " .. ALC.Core.Branding.downloadPage(), 0.5, 0.5, 0.5, true)
            tooltip:Show()
        end
        return
    end
    local ok, lines = pcall(P.buildLines, unit, expandedNow())
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
    GameTooltip:HookScript("OnTooltipCleared", function(tooltip)
        tooltip.alcProgressionAdded = nil
    end)
    -- Give the login chat burst a moment so the reminder is not buried.
    local delay, elapsed = CreateFrame("Frame"), 0
    delay:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < 8 then return end
        self:SetScript("OnUpdate", nil)
        pcall(P.chatCta)
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
    local L = P.lib()
    if not L then return P.ctaText("missing") end
    local meta = L.GetMeta()
    return string.format("%d players, data %s", meta.players or 0, ago(meta.generatedAt) or "of unknown age")
end

-- /tlc prog <name>: print a player's progression and rankings to chat.
function P.printFor(name)
    local log = ALC.Core.Logger
    local L = P.lib()
    if not L then
        P.chatCta(true)
        return
    end
    if not name or name == "" then
        name = UnitName("target") or UnitName("player")
    end
    local profile = L.GetProfile(name)
    local lines = profile and P.buildLines(profile.name, true)
    if not lines then
        log.info("No logged raid kills for " .. name .. ".")
        return
    end
    log.info(profile.name .. ":")
    for _, l in ipairs(lines) do
        if not l.sep then
            DEFAULT_CHAT_FRAME:AddMessage("  " .. l[1] .. (l[2] and ("  " .. l[2]) or ""))
        end
    end
end
