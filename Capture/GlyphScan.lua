-- Capture/GlyphScan.lua
-- Glyph capture for Triumvirate.
--
-- WHY THIS EXISTS
--   The stock 3.3.5a API cannot read another player's glyphs:
--   GetGlyphSocketInfo takes no unit token, and there is no inspect variant.
--   Triumvirate answers the question on the SERVER instead. Its own UI addon
--   (shipped in the client's patch MPQ) draws a talents + glyphs inspect card
--   and gets the glyphs over a whispered addon message to the player's own
--   name, which the server intercepts:
--
--     client -> server   prefix "TLO", "INSP <name>"
--     server -> client   prefix "TLO", "G <name> <level> <id1> ... <id6>"
--
--   The ids are glyph SPELL ids, indexed by socket 1..6 (majors 1/4/6, minors
--   2/3/5), 0 = empty socket. level -1 means the server would not answer
--   (seen when the player had moved away), and then no ids follow.
--   Measured: the reply lands ~180 ms after the request, inside the stock
--   inspect's own INSPECT_TALENT_READY + flip-delay window, so it is normally
--   in hand before InspectLoop finalizes the CI.
--
-- ONE HARD RULE
--   This module only ever sends "INSP". The same prefix carries ops that change
--   the PLAYER'S OWN loadout state (ACT swaps loadout, PREV loads a preview,
--   UNLOCK spends gold, NAME renames, UI toggles the server's talent UI). Never
--   send any of them.
--
-- CI SHAPE
--   ci.glyphs = { [1..6] = spellId }   (0 = empty socket)
--   No timestamp or level inside: the CI's durable hash covers this table, so
--   anything that changes on every read would force a keyframe every pull.
--
-- Inert on every profile except Triumvirate.

local ALC = _G.ALC
local G = {}
ALC.Capture.GlyphScan = G

local PREFIX = "TLO"
local NUM_SOCKETS = 6
local PENDING_TTL_S = 10

G.started = false
G.pending = {}   -- lowercased name -> { guid, at }
G.byGuid = {}    -- guid -> { glyphs = {6 ids}, at = GetTime() }

function G.isAvailable()
    return ALC.Core.Profile and ALC.Core.Profile.isTriumvirate
        and ALC.Core.Profile.isTriumvirate() or false
end

local function copyGlyphs(src)
    local out = {}
    for s = 1, NUM_SOCKETS do out[s] = tonumber(src[s]) or 0 end
    return out
end

local function sameGlyphs(a, b)
    if not a or not b then return false end
    for s = 1, NUM_SOCKETS do
        if (tonumber(a[s]) or 0) ~= (tonumber(b[s]) or 0) then return false end
    end
    return true
end

-- Own glyphs from the stock API, active talent group. The probe confirmed this
-- matches the server's reply for the same character on all six sockets.
function G.readLocal()
    if not G.isAvailable() or type(_G.GetGlyphSocketInfo) ~= "function" then return nil end
    local group = (type(_G.GetActiveTalentGroup) == "function" and GetActiveTalentGroup(false, false)) or 1
    local out = {}
    for s = 1, NUM_SOCKETS do
        local ok, _, _, spellId = pcall(GetGlyphSocketInfo, s, group)
        out[s] = (ok and tonumber(spellId)) or 0
    end
    return out
end

-- Fire the server request alongside NotifyInspect. Cheap and stateless on the
-- server side; the reply is matched back to the GUID by name.
function G.request(unit, guid)
    if not G.started or not unit or not guid then return end
    local name = UnitName(unit)
    local me = UnitName("player")
    if not name or not me or name == me then return end
    G.pending[name:lower()] = { guid = guid, at = GetTime() }
    SendAddonMessage(PREFIX, "INSP " .. name, "WHISPER", me)
    ALC.Core.Metrics.inc("glyph_requested")
end

-- Glyphs for a GUID if a reply landed at or after `since` (the inspect's
-- start), else nil. finalizeInspect falls back to the previously captured
-- glyphs on nil so a missed reply never blanks a known build.
function G.forGuid(guid, since)
    local rec = guid and G.byGuid[guid]
    if not rec then return nil end
    if since and rec.at < since then return nil end
    return copyGlyphs(rec.glyphs)
end

-- A reply that lands after finalizeInspect already ran is patched straight
-- onto the cached CI, so the next per-pull re-broadcast carries it.
local function patchCache(guid, glyphs)
    local cache = ALC.Capture.InspectCache
    local entry = cache and cache.get(guid)
    if not entry or not entry.ci then return end
    if sameGlyphs(entry.ci.glyphs, glyphs) then return end
    entry.ci.glyphs = copyGlyphs(glyphs)
    cache.set(guid, entry)
    ALC.Core.Metrics.inc("glyph_late_patch")
end

local function onReply(rest)
    local name, level, tail = rest:match("^(%S+)%s+(%-?%d+)%s?(.*)$")
    if not name then return end
    local key = name:lower()
    local p = G.pending[key]
    if not p then return end  -- not ours (the server's own UI asked)
    G.pending[key] = nil
    if (tonumber(level) or -1) < 0 then
        ALC.Core.Metrics.inc("glyph_unavailable")
        return
    end
    local glyphs, i = {}, 0
    for id in (tail or ""):gmatch("%d+") do
        i = i + 1
        if i > NUM_SOCKETS then break end
        glyphs[i] = tonumber(id) or 0
    end
    for s = i + 1, NUM_SOCKETS do glyphs[s] = 0 end
    G.byGuid[p.guid] = { glyphs = glyphs, at = GetTime() }
    ALC.Core.Metrics.inc("glyph_received")
    patchCache(p.guid, glyphs)
end

function G.onAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX or channel ~= "WHISPER" then return end
    if sender ~= UnitName("player") then return end
    local op, rest = (message or ""):match("^(%S+)%s?(.*)$")
    if op ~= "G" then return end
    local ok, err = pcall(onReply, rest or "")
    if not ok then ALC.Core.Logger.debug("GlyphScan reply error: " .. tostring(err)) end
    -- Drop requests the server never answered so the table cannot grow.
    local now = GetTime()
    for k, v in pairs(G.pending) do
        if now - v.at > PENDING_TTL_S then G.pending[k] = nil end
    end
end

function G.start()
    if G.started then return end
    if not G.isAvailable() then return end
    G.started = true
    ALC.RegisterEvent("CHAT_MSG_ADDON", function(_e, prefix, message, channel, sender)
        G.onAddonMessage(prefix, message, channel, sender)
    end)
    ALC.Core.Logger.debug("GlyphScan armed (server glyph inspect on " .. PREFIX .. ")")
end
