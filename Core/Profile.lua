-- Core/Profile.lua
-- Detects which 3.3.5 server family this client is connected to so the rest
-- of the addon can route per-server behavior at runtime. Sets ALC.Profile to
-- one of "triumvirate" | "frostmourne" | "unknown". Result is cached to
-- ALC_Config.server_profile so /reload doesn't re-probe.
--
-- Triumvirate is stock WotLK 3.3.5a (private server triumvirate-wow.com).
-- Standard talent-group (dual-spec) reader, no custom-client API surface.
--
-- ONE EXCEPTION, and it is easy to get wrong: Triumvirate DOES have a full
-- Mythic+ system. It simply has no C_MythicPlus to read it with - the whole M+
-- UI is a server-pushed AIO addon, so the data is on the addon-message wire
-- instead of behind an API. Capture/MythicAioScan.lua reads it there. Do not
-- infer "no M+" from isStockClient().
--
-- Frostmourne (Whitemane "Frostmourne Rebuffed") is stock 3.3.5a build 12340
-- with a large custom content patch injected via rebuffed.dll. Same capture
-- path as Triumvirate, plus a native transmog API - see P.hasNativeTransmog().
--
-- HISTORY, because the shape here looks over-general for two tenants: this
-- addon used to support several custom-client realms whose Lua exposed extra
-- character-advancement and enchant namespaces, and the detection below is what
-- is left after those were removed. The negative checks in the client probe are
-- deliberately kept - they are what stops a custom client being mistaken for a
-- stock one, which would enable a capture path its API cannot serve.
--
-- Detection order:
--   1. ALC_Config.server_profile_override (manual escape hatch for forks /
--      rebrands where auto-detect is wrong).
--   2. Realm-name match via GetRealmName().
--   3. Global probe fallback.
--   4. "unknown" (snapshot still ships, backend treats as bare-vanilla 3.3.5).

local ALC = _G.ALC
local P = {}
ALC.Core.Profile = P

P.TRIUMVIRATE = "triumvirate"
P.FROSTMOURNE = "frostmourne"   -- Whitemane "Frostmourne Rebuffed", stock 3.3.5a build 12340
P.UNKNOWN     = "unknown"

-- Exact-match realm names. Update when new shards launch.
local REALMS = {
    -- Triumvirate: stock WotLK 3.3.5a private server (triumvirate-wow.com).
    -- Realm string confirmed 2026-06-15 via clean probe (WTF account realm
    -- folder = "Triumvirate"; single word, no GetRealmName() sanitization).
    ["Triumvirate"]                   = P.TRIUMVIRATE,
    -- Frostmourne (Whitemane / "Frostmourne Rebuffed"). Realm string VERIFIED
    -- in-game 2026-08-23: the PTR realm reports "Frostmourne PTR" (WTF account
    -- folder matches). The live realm is expected to report plain
    -- "Frostmourne"; both are listed, and P.detect's ^Frostmourne prefix
    -- fallback covers any other suffix they add.
    ["Frostmourne"]                   = P.FROSTMOURNE,
    ["Frostmourne PTR"]               = P.FROSTMOURNE,
}

-- Frostmourne global probe. Belt-and-braces behind the realm-name match, for
-- shards/renames that report an unmatched realm string.
--
-- MEASURED in-game 2026-08-23 (FLC_Probe), not inferred from the client binary:
-- these are real Lua exports of the injected client extension.
--
-- The two negative checks are NOT redundant. C_CharacterAdvancement and
-- C_MysticEnchant are markers of a different, heavily customised client family
-- that this addon no longer supports. If such a client ever loaded this build,
-- matching it as Frostmourne would enable a transmog/inspect path its API does
-- not actually serve, and the failure would look like a capture bug rather than
-- a misdetection. Cheap check, keep it.
--
-- NOTE: an earlier design keyed this on a "Cache_Frostmourne" global. That
-- string exists inside rebuffed.dll but is NOT exported to Lua - probing it
-- would have silently never matched. Use only verified exports.
local function probeFrostmourneGlobals()
    if type(_G.GetInventoryItemTransmog) ~= "function" then return false end
    if type(_G.UnitTokenFromGUID) ~= "function" then return false end
    -- Must NOT look like a custom-client build.
    if type(_G.C_CharacterAdvancement) == "table" then return false end
    if type(_G.C_MysticEnchant) == "table" then return false end
    return true
end

-- Public: run detection and stamp ALC.Profile. Idempotent.
--
-- Note detect() does NOT read the cached ALC_Config.server_profile back as
-- input - it re-derives and overwrites it every boot. A player carrying a
-- cached value for a profile this build no longer knows about is therefore
-- re-detected normally rather than being stuck on a dead one.
function P.detect()
    _G.ALC_Config = _G.ALC_Config or {}

    -- 1. Manual override
    local override = ALC_Config.server_profile_override
    if override == P.TRIUMVIRATE or override == P.FROSTMOURNE
       or override == P.UNKNOWN then
        ALC.Profile = override
        ALC_Config.server_profile = override
        return override
    end

    -- 2. Realm-name match. Exact table first, then a prefix fallback, so a
    --    realm that grows a suffix in the realm list still resolves.
    local realm = (type(GetRealmName) == "function") and GetRealmName() or nil
    if type(realm) == "string" then
        local matched = REALMS[realm]
        if not matched then
            if realm:find("^Frostmourne") then matched = P.FROSTMOURNE end
        end
        if matched then
            ALC.Profile = matched
            ALC_Config.server_profile = matched
            return matched
        end
    end

    -- 3. Global probe.
    if probeFrostmourneGlobals() then
        ALC.Profile = P.FROSTMOURNE
        ALC_Config.server_profile = P.FROSTMOURNE
        return P.FROSTMOURNE
    end

    -- 4. Unknown
    ALC.Profile = P.UNKNOWN
    ALC_Config.server_profile = P.UNKNOWN
    return P.UNKNOWN
end

-- Convenience predicates so callers don't repeat the literal strings.
function P.isTriumvirate() return ALC.Profile == P.TRIUMVIRATE end
function P.isFrostmourne() return ALC.Profile == P.FROSTMOURNE end

-- Stock-client family = the standard talent-group (dual-spec) reader and no
-- custom character-advancement / enchant API surface. Both supported tenants
-- qualify; they differ only in the `server` tag they stamp for backend tenant
-- routing, and in Frostmourne's native transmog. Capture-side branches should
-- gate on THIS rather than on a bare isTriumvirate(), so a new stock tenant
-- routes correctly without touching every call site.
--
-- Renamed from a previous tenant-specific name when the tenant it was named
-- after was retired; the predicate itself is unchanged.
function P.isStockClient()
    return ALC.Profile == P.TRIUMVIRATE
        or ALC.Profile == P.FROSTMOURNE
end

-- Frostmourne shares the stock capture path (dual-spec talent reader, no
-- Mythic+ API) but - unlike Triumvirate - it DOES have a transmog system,
-- exposed as a first-class API rather than inferred from link-vs-id
-- divergence. Measured 2026-08-23:
--
--   GetInventoryItemTransmog(unit, slot) -> 2 values, first is 0 when the slot
--   has no transmog. Works on INSPECTED units, not just "player". The
--   slot-only call form returns nil and is wrong.
--
-- Anything that wants the authoritative overlay should gate on THIS, not on
-- isStockClient() (which assumes no transmog at all).
function P.hasNativeTransmog()
    return ALC.Profile == P.FROSTMOURNE
       and type(_G.GetInventoryItemTransmog) == "function"
end

-- Returns the per-server inspect throttle floor with a safe fallback.
function P.inspectIntervalSeconds()
    local C = ALC.Core.Constants
    local byProfile = C and C.INSPECT_MIN_INTERVAL_S_BY_PROFILE
    local val = byProfile and byProfile[ALC.Profile or P.TRIUMVIRATE]
    return val or (C and C.INSPECT_MIN_INTERVAL_S) or 1.0
end
