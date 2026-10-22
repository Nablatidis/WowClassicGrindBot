local Load = select(2, ...)
local DataToColor = unpack(Load)

--------------------------------------------------------------------------------
-- MODERN-ENGINE COMPAT (WoW Forever): restore classic globals the addon expects
-- from the C_ namespaces. Only fills in functions that are missing (nil).
--------------------------------------------------------------------------------
-- The shims below are kept in a private table instead of being written into
-- _G: Blizzard UI code calling addon-created globals (UnitBuff, GetSpellInfo,
-- ...) becomes tainted, and the client then blocks protected actions and
-- blames this addon ("has been blocked from an action only available to the
-- Blizzard UI"). Addon files read globals through DataToColor.Env, which looks
-- in the shims first and then in _G; global writes still go to _G.
local compat = {}
local function lookup(_, k)
  local v = compat[k]
  if v ~= nil then return v end
  return _G[k]
end
DataToColor.Env = setmetatable({}, { __index = lookup, __newindex = _G })

do
  local G = setmetatable({}, { __index = lookup, __newindex = compat })
  local C_Spell, C_SpellBook, C_UnitAuras = G.C_Spell, G.C_SpellBook, G.C_UnitAuras

  local function alias(name, ns, fname)
    local t = G[ns]
    if G[name] == nil and type(t) == "table" and t[fname or name] ~= nil then
      G[name] = t[fname or name]
    end
  end

  alias("IsAutoRepeatSpell", "C_Spell")
  alias("IsCurrentSpell", "C_Spell")
  alias("GetSpellPowerCost", "C_Spell")
  alias("GetItemInfo", "C_Item")
  alias("GetCoinTextureString", "C_CurrencyInfo")

  if G.GetCoinTextureString == nil then
    G.GetCoinTextureString = function(copper) return tostring(copper or 0) end
  end

  if G.GetSpellInfo == nil and C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo
    G.GetSpellInfo = function(spell)
      local i = info(spell)
      if type(i) ~= "table" then return nil end
      return i.name, nil, i.iconID, i.castTime, i.minRange, i.maxRange, i.spellID, i.originalIconID
    end
  end

  -- classic returns 1 / 0 / nil, modern returns true / false / nil
  if G.IsSpellInRange == nil and C_Spell and C_Spell.IsSpellInRange then
    local inRange = C_Spell.IsSpellInRange
    G.IsSpellInRange = function(spell, unit)
      local r = inRange(spell, unit)
      if DataToColor.IsSecret(r) then return nil end -- hidden by the game
      if r == true then return 1 elseif r == false then return 0 end
      return nil
    end
  end

  -- spellbook: classic (index, "spell") -> modern (index, bank)
  local function bank(bookType)
    local e = G.Enum and G.Enum.SpellBookSpellBank
    if bookType == "pet" then return e and e.Pet or 1 end
    return e and e.Player or 0
  end
  if C_SpellBook then
    if G.GetSpellBookItemName == nil and C_SpellBook.GetSpellBookItemName then
      local f = C_SpellBook.GetSpellBookItemName
      G.GetSpellBookItemName = function(index, bookType)
        local ok, a, b, c = pcall(f, index, bank(bookType))
        if ok then return a, b, c end
        return nil
      end
    end
    if G.GetSpellBookItemTexture == nil and C_SpellBook.GetSpellBookItemTexture then
      local f = C_SpellBook.GetSpellBookItemTexture
      G.GetSpellBookItemTexture = function(index, bookType)
        local ok, a = pcall(f, index, bank(bookType))
        if ok then return a end
        return nil
      end
    end
  end

  -- auras: UnitBuff / UnitDebuff via C_UnitAuras
  if C_UnitAuras then
    local function unpackAura(a)
      if type(a) ~= "table" then return nil end
      return a.name, a.icon, a.applications, a.dispelName, a.duration, a.expirationTime,
        a.sourceUnit, a.isStealable, a.nameplateShowPersonal, a.spellId
    end
    local function make(byIndex, filterName)
      return function(unit, index, filter)
        local a
        if byIndex then
          if filter then a = byIndex(unit, index, filter) else a = byIndex(unit, index) end
        elseif C_UnitAuras.GetAuraDataByIndex then
          a = C_UnitAuras.GetAuraDataByIndex(unit, index, filter and (filterName .. "|" .. filter) or filterName)
        end
        return unpackAura(a)
      end
    end
    if G.UnitBuff == nil then G.UnitBuff = make(C_UnitAuras.GetBuffDataByIndex, "HELPFUL") end
    if G.UnitDebuff == nil then G.UnitDebuff = make(C_UnitAuras.GetDebuffDataByIndex, "HARMFUL") end
  end

  -- spells / items moved into C_ namespaces
  alias("IsUsableSpell", "C_Spell", "IsSpellUsable")
  alias("IsUsableItem", "C_Item", "IsUsableItem")
  alias("IsSpellKnown", "C_SpellBook", "IsSpellKnown")
  alias("GetSpellBaseCooldown", "C_Spell", "GetSpellBaseCooldown")

  -- action bar functions moved into C_ActionBar
  alias("GetActionTexture", "C_ActionBar")
  alias("GetActionInfo", "C_ActionBar")
  alias("HasAction", "C_ActionBar")
  alias("IsUsableAction", "C_ActionBar")
  alias("IsCurrentAction", "C_ActionBar")
  alias("IsAutoRepeatAction", "C_ActionBar")
  if G.GetActionCooldown == nil and G.C_ActionBar and G.C_ActionBar.GetActionCooldown then
    local f = G.C_ActionBar.GetActionCooldown
    G.GetActionCooldown = function(slot)
      local a, b, c, d = f(slot)
      if type(a) == "table" then
        return a.startTime, a.duration, a.isEnabled, a.modRate
      end
      return a, b, c, d
    end
  end

  -- combo points: modern clients read them through UnitPower
  if G.GetComboPoints == nil then
    G.GetComboPoints = function(unit, target)
      local e = G.Enum and G.Enum.PowerType
      return G.UnitPower(unit or "player", e and e.ComboPoints or 4)
    end
  end

  -- no equivalent in this client: safe empty answers so the addon keeps running
  local function stub(name, fn) if G[name] == nil then G[name] = fn end end
  stub("GetNumTalentTabs", function() return 0 end)
  stub("GetNumTalents", function() return 0 end)
  stub("GetTalentInfo", function() return nil end)
  stub("GetNumSkillLines", function() return 0 end)
  stub("GetSkillLineInfo", function() return nil end)
  stub("GetPetHappiness", function() return nil end)
  stub("GetRuneType", function() return nil end)
  stub("GetSpellBaseCooldown", function() return nil end)
end

setfenv(1, DataToColor.Env)

--------------------------------------------------------------------------------
-- /dcapi : list game functions the addon uses that this client doesn't have
--------------------------------------------------------------------------------
local REQUIRED_API = {
  "AcceptGroup",
  "CanMerchantRepair",
  "CheckInteractDistance",
  "ClearSendMail",
  "ClickSendMailItemButton",
  "DeclineGroup",
  "DeleteCursorItem",
  "GetActionCooldown",
  "GetActionInfo",
  "GetActionTexture",
  "GetAddOnCPUUsage",
  "GetBindingKey",
  "GetBuildInfo",
  "GetCVarBool",
  "GetCoinTextureString",
  "GetComboPoints",
  "GetCorpseRecoveryDelay",
  "GetCurrentBindingSet",
  "GetInventoryItemBroken",
  "GetInventoryItemCount",
  "GetInventoryItemDurability",
  "GetInventoryItemID",
  "GetInventoryItemLink",
  "GetInventorySlotInfo",
  "GetItemInfo",
  "GetMacroInfo",
  "GetMacroItem",
  "GetMacroSpell",
  "GetMerchantItemLink",
  "GetMirrorTimerInfo",
  "GetMoney",
  "GetNetStats",
  "GetNumLootItems",
  "GetNumSkillLines",
  "GetNumTalentTabs",
  "GetNumTalents",
  "GetPetActionInfo",
  "GetPetHappiness",
  "GetPlayerFacing",
  "GetRepairAllCost",
  "GetRuneCooldown",
  "GetRuneType",
  "GetSendMailItem",
  "GetShapeshiftForm",
  "GetShapeshiftFormInfo",
  "GetSkillLineInfo",
  "GetSpellBaseCooldown",
  "GetSpellBookItemName",
  "GetSpellBookItemTexture",
  "GetSpellInfo",
  "GetSpellPowerCost",
  "GetTalentInfo",
  "GetTime",
  "GetUnitName",
  "GetUnitSpeed",
  "GetWeaponEnchantInfo",
  "HasAction",
  "HasPetUI",
  "InCombatLockdown",
  "IsAutoRepeatAction",
  "IsAutoRepeatSpell",
  "IsBagOpen",
  "IsCurrentAction",
  "IsCurrentSpell",
  "IsFalling",
  "IsFlying",
  "IsInGroup",
  "IsIndoors",
  "IsMounted",
  "IsSpellInRange",
  "IsSpellKnown",
  "IsStealthed",
  "IsSwimming",
  "IsUsableAction",
  "IsUsableItem",
  "IsUsableSpell",
  "RepairAllItems",
  "RepopMe",
  "ResetCPUUsage",
  "RetrieveCorpse",
  "SaveBindings",
  "SendMail",
  "SetBinding",
  "SetSendMailMoney",
  "UnitAffectingCombat",
  "UnitAttackSpeed",
  "UnitBuff",
  "UnitCastingInfo",
  "UnitChannelInfo",
  "UnitClass",
  "UnitClassification",
  "UnitDebuff",
  "UnitExists",
  "UnitGUID",
  "UnitHealth",
  "UnitHealthMax",
  "UnitIsDead",
  "UnitIsDeadOrGhost",
  "UnitIsFriend",
  "UnitIsGhost",
  "UnitIsPlayer",
  "UnitIsTapDenied",
  "UnitIsTrivial",
  "UnitIsUnit",
  "UnitIsVisible",
  "UnitLevel",
  "UnitName",
  "UnitOnTaxi",
  "UnitPlayerControlled",
  "UnitPower",
  "UnitPowerMax",
  "UnitRace",
  "UnitRangedDamage",
  "UnitReaction",
  "UnitXP",
  "UnitXPMax",
  "UpdateAddOnCPUUsage",
}

function DataToColor:ReportMissingApi()
  local missing = 0
  for i = 1, #REQUIRED_API do
    local name = REQUIRED_API[i]
    if DataToColor.Env[name] == nil then
      missing = missing + 1
      DataToColor:Print("missing: " .. name)
    end
  end
  DataToColor:Print("API check done, " .. missing .. " missing (of " .. #REQUIRED_API .. ")")
end

local GetBuildInfo = GetBuildInfo

local UnitIsUnit = UnitIsUnit
local UnitLevel = UnitLevel

-- Unspent talent points, safe when the client lacks both UnitCharacterPoints and GetUnspentTalentPoints (e.g. WoW Forever)
local NativeUnitCharacterPoints = UnitCharacterPoints
function DataToColor.UnitCharacterPoints(unit)
  if NativeUnitCharacterPoints then
    return NativeUnitCharacterPoints(unit)
  end
  if GetUnspentTalentPoints and UnitExists(unit) then
    if UnitIsUnit(unit, "pet") then
      return GetUnspentTalentPoints(false, true) or 0
    elseif UnitIsUnit(unit, "player") then
      return GetUnspentTalentPoints(false) or 0
    end
  end
  return 0
end

local UnitChannelInfo = UnitChannelInfo
local UnitCastingInfo = UnitCastingInfo

local WOW_PROJECT_ID = WOW_PROJECT_ID or -1 -- -1 = Legacy client (old retail)
local WOW_PROJECT_CLASSIC = WOW_PROJECT_CLASSIC
local WOW_PROJECT_BURNING_CRUSADE_CLASSIC = WOW_PROJECT_BURNING_CRUSADE_CLASSIC
local WOW_PROJECT_WRATH_CLASSIC = WOW_PROJECT_WRATH_CLASSIC
local WOW_PROJECT_CATACLYSM_CLASSIC = WOW_PROJECT_CATACLYSM_CLASSIC
local WOW_PROJECT_MAINLINE = WOW_PROJECT_MAINLINE

local buildVersion = select(4, GetBuildInfo())
local isVanilla = buildVersion < 20000

-- Is this a Legacy client (old retail, e.g., Cataclysm 4.3.4)?
function DataToColor.IsLegacy()
  return WOW_PROJECT_ID == -1
end

function DataToColor.IsVanilla()
  return isVanilla
end

-- Is this a Classic-era client (any of the Classic versions)?
function DataToColor.IsClassicEra()
  return WOW_PROJECT_ID ~= -1
end

function DataToColor.IsClassic()
  return WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
end

function DataToColor.IsClassic_BCC()
  return WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC
end

function DataToColor.IsClassic_Wrath()
  return WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC
end

function DataToColor.IsClassic_Cata()
  return WOW_PROJECT_ID == WOW_PROJECT_CATACLYSM_CLASSIC
end

function DataToColor.IsRetail()
  return WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
end

function DataToColor.IsClassicPreCata()
  return DataToColor.IsClassic() or DataToColor.IsClassic_BCC() or DataToColor.IsClassic_Wrath()
end

local LibClassicCasterino
if DataToColor.IsClassic() then
  LibClassicCasterino = _G.LibStub("LibClassicCasterino")
  LibClassicCasterino.callbacks:OnUsed()
end

local Som140 = DataToColor.IsClassic() and buildVersion == 11400 or buildVersion == 11401 or buildVersion == 11402
local TBC253 = DataToColor.IsClassic_BCC() and buildVersion >= 20503
local TBC252 = DataToColor.IsClassic_BCC() and buildVersion >= 20502
local Wrath340 = DataToColor.IsClassic_Wrath() and buildVersion >= 30400
local Cata440 = DataToColor.IsClassic_Cata() and buildVersion >= 40400

--------------------------------------------------------------------------------
-- CLIENT VERSION ASSIGNMENT
--------------------------------------------------------------------------------

-- Project ids the bot understands (SharedLib/ClientVersion.cs)
local KNOWN_PROJECT_IDS = { [1] = true, [2] = true, [5] = true, [11] = true, [14] = true, [19] = true }

-- Fallback for custom clients that report an unknown WOW_PROJECT_ID
-- (e.g. WoW Forever reports 18): pick the matching Classic flavour by build
local PROJECT_ID_BY_EXPANSION = { [1] = 2, [2] = 5, [3] = 11, [4] = 14, [5] = 19 }

if DataToColor.IsLegacy() then
  DataToColor.ClientVersion = 90 + math.floor(buildVersion / 10000)
elseif KNOWN_PROJECT_IDS[WOW_PROJECT_ID] then
  DataToColor.ClientVersion = WOW_PROJECT_ID
else
  DataToColor.ClientVersion = PROJECT_ID_BY_EXPANSION[math.floor(buildVersion / 10000)] or 2
end

--------------------------------------------------------------------------------
-- API COMPATIBILITY WRAPPERS
--------------------------------------------------------------------------------

------------------------------------------------------------
-- UnitCastingInfo (no allocations, cross-version safe)
------------------------------------------------------------
if DataToColor.IsLegacy() then
    local S = DataToColor.S
    -- Fast path: built-in function exists
    function DataToColor.UnitCastingInfo(unit)
        local n1, n2, n3, n4, n5, n6, n7, n8, n9 = UnitCastingInfo(unit)
        -- Legacy (e.g., 4.3.4) may not return spellId (n9)
        if not n9 and n4 and S and S.playerSpellBookIconToId then
          n4 = DataToColor:NormalizeTexture(n4)
          n9 = S.playerSpellBookIconToId[n4] or 0
        end
        return n1, n2, n3, n4, n5, n6, n7, n8, n9
    end
else
  function DataToColor.UnitCastingInfo(unit)
    local n1, n2, n3, n4, n5, n6, n7, n8, n9
    if LibClassicCasterino then
      n1, n2, n3, n4, n5, n6, n7, n8, n9 = LibClassicCasterino:UnitCastingInfo(unit)
    else
      n1, n2, n3, n4, n5, n6, n7, n8, n9 = UnitCastingInfo(unit)
    end

    if not n9 then
      return n1, n2, n3, n4, n5, n6, n7, nil, n8
    end
    return n1, n2, n3, n4, n5, n6, n7, n8, n9
  end
end


------------------------------------------------------------
-- UnitChannelInfo (no allocations, cross-version safe)
------------------------------------------------------------

local S = DataToColor.S
if DataToColor.IsLegacy() then
    function DataToColor.UnitChannelInfo(unit)
        local n1, n2, n3, n4, n5, n6, n7, n8 = UnitChannelInfo(unit)
        -- Legacy (e.g., 4.3.4) may not return spellId (n8)
        if not n8 and n4 and S and S.playerSpellBookIconToId then
          n4 = DataToColor:NormalizeTexture(n4)
          n8 = S.playerSpellBookIconToId[n4] or 0
        end

        return n1, n2, n3, n4, n5, n6, n7, n8
    end
else
  function DataToColor.UnitChannelInfo(unit)
    local n1, n2, n3, n4, n5, n6, n7, n8
    if LibClassicCasterino then
      n1, n2, n3, n4, n5, n6, n7, n8 =  LibClassicCasterino:UnitChannelInfo(unit)
    else
      n1, n2, n3, n4, n5, n6, n7, n8 = UnitChannelInfo(unit)
    end

    if not n8 then
      return n1, n2, n3, n4, n5, n6, nil, n7
    end
    return n1, n2, n3, n4, n5, n6, n7, n8
  end
end

-- define your safe version under a different name
local function UnitIsTapDenied_Fallback(unit)
  if not UnitExists(unit) then
    return false
  end
  if UnitIsUnit(unit, "pet") then
    return false
  end
  if UnitIsTapped(unit) and not UnitIsTappedByPlayer(unit) then
    return true
  end
  return false
end

-- if Blizzard’s version exists and works, use it; otherwise use the fallback
local UnitIsTapDeniedExists = type(UnitIsTapDenied) == "function"
local function SafeUnitIsTapDenied(self, unit)
  if UnitIsTapDeniedExists then
    return UnitIsTapDenied(unit)
  else
    return UnitIsTapDenied_Fallback(unit)
  end
end

DataToColor.UnitIsTapDenied = SafeUnitIsTapDenied

--------------------------------------------------------
-- NormalizeTexture: convert path or numeric into a fileID
--------------------------------------------------------
function DataToColor:NormalizeTexture(texture)
    if not texture then return nil end

    -- modern numeric ID
    if type(texture) == "number" then
        return texture
    end

    return DataToColor.LegacyTextureToFileID[texture] or -1
end


function DataToColor:GetAuraInfo(func, unit, index)
    -- one call only; positions differ by era:
    -- modern: name(1), icon(2), count(3), dispel(4), duration(5), expiration(6), source(7), ...
    -- legacy: name(1), rank(2), icon(3),  count(4), dispel(5), duration(6),   expiration(7), source(8)
    local a1, a2, a3, a4, a5, a6, a7 = func(unit, index)
    if not a1 then return nil end

    -- decide which slot is the texture:
    --  - modern: a2 is a file path like "Interface\\Icons\\..."
    --  - legacy: a2 is rank ("" or "Rank X"), a3 is the texture path
    local texture = a2
    if not texture
       or texture == ""
       or type(texture) ~= "string"
       or (not texture:find("\\") and not texture:find("/"))  -- not a path-looking string
    then
        texture = a3
    end

    -- ✅ normalize texture cross-version (ALWAYS do it here)
    texture = DataToColor:NormalizeTexture(texture)

    -- duration/expiration are at a6/a7 in both eras
    local duration       = tonumber(a6) or 0
    local expirationTime = tonumber(a7) or 0

    return a1, texture, duration, expirationTime
end

-- Cached version of GetAuraInfo that reads from AuraCache instead of calling WoW API
-- This avoids string allocations from UnitBuff/UnitDebuff every frame
function DataToColor:GetCachedAuraInfo(isBuff, unit, index)
    local name, texture, count, _, duration, expirationTime
    if isBuff then
        name, texture, count, _, duration, expirationTime = DataToColor:GetCachedBuff(unit, index)
    else
        name, texture, count, _, duration, expirationTime = DataToColor:GetCachedDebuff(unit, index)
    end

    if not name then return nil end

    -- Normalize texture (same as GetAuraInfo)
    texture = DataToColor:NormalizeTexture(texture)

    return name, texture, duration or 0, expirationTime or 0
end


--------------------------------------------------------------------------------
-- CONTAINER API COMPATIBILITY (Bag changes from 10.0)
-- Legacy clients use old API, newer clients may use C_Container
--------------------------------------------------------------------------------

DataToColor.GetContainerNumSlots = GetContainerNumSlots or C_Container.GetContainerNumSlots
DataToColor.GetContainerItemInfo = GetContainerItemInfo or
    function(bagID, slot)
      local o = C_Container.GetContainerItemInfo(bagID, slot)
      if o == nil then return nil end
      return o.iconFileID, o.stackCount, o.isLocked, o.quality, o.isReadable, o.hasLoot, o.hyperlink, o.isFiltered,
          o.hasNoValue, o.itemID, o.isBound
    end

DataToColor.GetContainerNumFreeSlots = GetContainerNumFreeSlots or C_Container.GetContainerNumFreeSlots
DataToColor.GetContainerItemLink = GetContainerItemLink or C_Container.GetContainerItemLink
DataToColor.PickupContainerItem = PickupContainerItem or C_Container.PickupContainerItem
DataToColor.UseContainerItem = UseContainerItem or C_Container.UseContainerItem
DataToColor.ContainerIDToInventoryID = ContainerIDToInventoryID or C_Container.ContainerIDToInventoryID

DataToColor.GetGossipOptions = GetGossipOptions or C_GossipInfo.GetOptions

--------------------------------------------------------------------------------
-- FRIEND LIST API COMPATIBILITY
-- Legacy/older clients use GetNumFriends/GetFriendInfo
-- Newer clients use C_FriendList namespace
--------------------------------------------------------------------------------

DataToColor.GetNumFriends = GetNumFriends or C_FriendList.GetNumFriends

-- GetFriendInfo returns: name, level, class, area, connected, status, notes (old API)
-- C_FriendList.GetFriendInfoByIndex returns a table with: name, level, className, area, connected, etc.
DataToColor.GetFriendInfo = GetFriendInfo or
    function(index)
        local info = C_FriendList.GetFriendInfoByIndex(index)
        if not info then return nil end
        return info.name, info.level, info.className, info.area, info.connected, info.status, info.notes
    end

--------------------------------------------------------------------------------
-- MAP API COMPATIBILITY
-- Legacy clients and older Classic-era versions don't have C_Map
--------------------------------------------------------------------------------

-- C_Map compatibility
if not C_Map or not C_Map.GetBestMapForUnit then

--------------------------------------------------------
-- Case-insensitive, slash-tolerant lookup for legacy table
--------------------------------------------------------
  setmetatable(DataToColor.LegacyTextureToFileID, {
      __index = function(t, k)
          if type(k) ~= "string" then
              return nil
          end
          local key = k:lower()
          return rawget(t, key)
      end
  })

    C_Map = C_Map or {}

    function C_Map.GetBestMapForUnit(unit)
        unit = unit or "player"
        SetMapToCurrentZone()
        local id = GetCurrentMapAreaID and GetCurrentMapAreaID() or 0
        return DataToColor.WorldMapAreaIDToUiMapID[id]
    end

    function C_Map.GetPlayerMapPosition(mapID, unit)
        local x, y = GetPlayerMapPosition(unit or "player")
        local pos = {}
        function pos:GetXY() return x, y end
        return pos
    end
end

DataToColor.GetBestMapForUnit    = C_Map.GetBestMapForUnit
DataToColor.GetPlayerMapPosition = C_Map.GetPlayerMapPosition

-- GetCVar compatibility wrapper
local originalGetCVar = GetCVar
DataToColor.SafeGetCVar = function(cvar, default)
  local success, value = pcall(originalGetCVar, cvar)
  if success and value then
    return value
  end
  return default or "0"
end

-- SetCVar compatibility wrapper
-- Safely sets a CVar value, silently failing if the CVar doesn't exist
local originalSetCVar = SetCVar
DataToColor.SafeSetCVar = function(cvar, value, eventType)
  local success = pcall(originalSetCVar, cvar, value, eventType)
  return success
end

DataToColor.UnitLevelSafe = function(unit, playerLevel)
  local level = UnitLevel(unit)

  if not level then
    return 0
  end

  if level == -1 then
    return playerLevel + 10
  end

  return level
end

local IS_LEGACY_GOSSIP = type(_G.GetNumGossipOptions) == "function" and type(DataToColor.GetGossipOptions) == "function"

DataToColor.OnGossipShow = function(event)
  if IS_LEGACY_GOSSIP then
    local options = { DataToColor:GetGossipOptions() }
    local count = #options / 2
    if count == 0 then
      return
    end

    DataToColor.gossipQueue:push(DataToColor.GOSSIP_START)
    -- returns variable string - format of one entry
    -- [1] localized name
    -- [2] gossip_type
    for k, v in pairs(options) do
      if k % 2 == 0 then
        DataToColor.gossipQueue:push(10000 * count + 100 * (k / 2) + DataToColor.C.Gossip[v])
      end
    end
  else
    local options = DataToColor:GetGossipOptions()
    if not options then
      return
    end

    table.sort(options, function(a, b)
      return (a.orderIndex or 0) < (b.orderIndex or 0)
    end)

    DataToColor.gossipQueue:push(DataToColor.GOSSIP_START)

    local count = #options
    for i, v in pairs(options) do
      local hash = 10000 * count + 100 * i + DataToColor.C.GossipIcon[v.icon]
      --DataToColor:Print(i .. " " .. v.icon .. " " .. DataToColor.C.GossipIcon[v.icon] .. " " .. v.name .. " " .. hash)
      DataToColor.gossipQueue:push(hash)
    end
  end

  DataToColor.gossipQueue:push(DataToColor.GOSSIP_END)
end

--------------------------------------------------------------------------------
-- GUID HANDLING FUNCTIONS - Version-specific implementations
-- Legacy 4.3.4: Uses simpler Cataclysm-era GUID format
-- Modern Classic: Uses newer GUID format with uniqueGuid hash calculation
--------------------------------------------------------------------------------

-- Compatibility layer for older WoW versions

if not IsInGroup then
    function IsInGroup()
        return (GetNumPartyMembers() > 0) or (GetNumRaidMembers() > 0)
    end
end

if not bit then
	bit = {
		band = function(a, b)
			a = tonumber(a) or 0
			b = tonumber(b) or 0
			local result = 0
			local p = 1
			while a > 0 and b > 0 do
				result = result + (p * ((a % 2) * (b % 2)))
				a = math.floor(a / 2)
				b = math.floor(b / 2)
				p = p * 2
			end
			return result
		end,
		rshift = function(a, bits)
			a = tonumber(a) or 0
			return math.floor(a / (2 ^ bits))
		end
	}
end

local bit = bit
local band = bit.band
local sub = string.sub
local strsplit = strsplit

if DataToColor.IsLegacy() then
  -- ========================================
  -- LEGACY CATACLYSM 4.3.4 IMPLEMENTATIONS
  -- ========================================

  function DataToColor:GetActionTexture(slot)
    if not slot then return nil end
    return DataToColor:NormalizeTexture(GetActionTexture(slot))
  end

  -- Extract NPC ID from GUID
  -- Legacy Cataclysm format: Creature-0-X-Y-Z-NpcId-UniqueSpawnId
  function DataToColor:NpcId(unit)
    local guid = UnitGUID(unit) or ""

    -- Legacy format (hex)
    -- pattern: 0xF13000C5000034D7 → extract 00C5
    local npc_hex = guid:match("^0xF[0-9A-F]+00(%x%x%x%x)")
    if npc_hex then
        return tonumber(npc_hex, 16)
    end

    return 0
  end

  -- Get unique GUID from unit
  -- Legacy: Uses uniqueGuid with NPC ID for bit-packed encoding
  function DataToColor:getGuidFromUnit(unit)
    if not UnitExists(unit) then
      return 0
    end

    local guid = UnitGUID(unit)
    if not guid then return 0 end

    -- Legacy creature guid example: 0xF130C2CF0000355D
    -- NPC ID is at position 5-8 (after 0xF130): C2CF = 49871
    local npc_hex = guid:match("^0xF130(%x%x%x%x)")
    local npcId = npc_hex and tonumber(npc_hex, 16) or 0

    -- Spawn data is last 8 characters
    local hex = guid:match("^0x(%x+)$")
    local spawn = hex and hex:sub(-8) or nil

    return DataToColor:uniqueGuid(npcId, spawn)
  end

  -- /dump DataToColor:getGuidFromUUID("0xF130C2CF0000355D")
  -- returns: 63532
  -- Get unique GUID from UUID
  -- Legacy: Direct extraction without hash calculation
  function DataToColor:getGuidFromUUID(uuid)
    if not uuid then
      return 0
    end

    -- Legacy creature guid example: 0xF130C2CF0000355D
    -- NPC/Entry is always right after 0xF130
    local npc_hex = uuid:match("^0xF130(%x%x%x%x)")
    local hex = uuid:match("^0x(%x+)$")
    local npcId = tonumber(npc_hex, 16)
    local spawn = hex:sub(-8)  -- "0000355D"
    return DataToColor:uniqueGuid(npcId, spawn)
  end

  -- Extract NPC ID from UUID
  -- Legacy: Same extraction pattern as modern
  function DataToColor:getNpcIdFromUUID(uuid)
    if not uuid then
      return 0
    end

    local npc_hex = uuid:match("^0xF[0-9A-F]+00(%x%x%x%x)")
    if npc_hex then return tonumber(npc_hex, 16) end

    return 0
  end

  -- Get unit type from UUID
  -- Same for all versions - extract first segment
  function DataToColor:getTypeFromUUID(uuid)
    if not uuid then
      return 0
    end

    --local type = uuid:match("^(.-)-")
    --return DataToColor.C.GuidType[type] or 0

    -- Legacy hex GUID: first byte identifies type
    local high = uuid:sub(3,4)
    local firstByte = tonumber(high, 16)
    local typeID = bit.rshift(firstByte, 4)
    -- Map typeID → your GuidType table if you maintain one
    return typeID

  end

else
  -- ========================================
  -- MODERN CLASSIC IMPLEMENTATIONS
  -- ========================================

  function DataToColor:GetActionTexture(slot)
    return GetActionTexture(slot)
  end

  -- Extract NPC ID from GUID
  -- Modern format: Uses standard extraction
  function DataToColor:NpcId(unit)
    local guid = UnitGUID(unit) or ""
    local id = guid:match("-(%d+)-[^-]+$")

    if id and not guid:find("^Player") then
      return tonumber(id, 10)
    end
    return 0
  end

  -- Get unique GUID from unit
  -- Modern: Uses uniqueGuid calculation with spawn data
  function DataToColor:getGuidFromUnit(unit)
    if not UnitExists(unit) then
      return 0
    end

    -- Modern Classic: Uses uniqueGuid calculation
    -- Player-4731-02AAD4FF
    -- Creature-0-4488-530-222-19350-000005C0D70
    -- Pet-0-4448-530-222-22123-15004E200E
    return DataToColor:uniqueGuid(select(-2, strsplit('-', UnitGUID(unit))))
  end

  -- Get unique GUID from UUID
  -- Modern: Uses uniqueGuid calculation
  function DataToColor:getGuidFromUUID(uuid)
    if not uuid then
      return 0
    end
    return DataToColor:uniqueGuid(select(-2, strsplit('-', uuid)))
  end

  -- Extract NPC ID from UUID
  -- Modern: Standard extraction
  function DataToColor:getNpcIdFromUUID(uuid)
    if not uuid then
      return 0
    end

    local id = uuid:match("-(%d+)-[^-]+$")

    if id and not uuid:find("^Player") then
      return tonumber(id, 10)
    end
    return 0
  end

  -- Get unit type from UUID
  -- Same for all versions - extract first segment
  function DataToColor:getTypeFromUUID(uuid)
    if not uuid then
      return 0
    end

    local type = uuid:match("^(.-)-")
    return DataToColor.C.GuidType[type] or 0
  end

end

-- Unique GUID calculation - bit-packed encoding
-- High 18 bits: NPC ID (max 262,143), Low 6 bits: spawn uniqueness hash (64 values)
-- This allows C# to extract the NPC ID via: npcId = guid >> 6
function DataToColor:uniqueGuid(npcId, spawn)
  npcId = tonumber(npcId, 10) or tonumber(npcId, 16) or 0
  if not spawn then
    return 0
  end

  -- Extract spawn uniqueness from spawn string
  local spawnEpochOffset = band(tonumber(sub(spawn, 5), 16) or 0, 0x7fffff)
  local spawnIndex = band(tonumber(sub(spawn, 1, 5), 16) or 0, 0xffff8)
  local spawnHash = band(spawnEpochOffset + spawnIndex, 0x3F)  -- 6 bits (0-63)

  -- Pack: NPC ID (18 bits) | spawn hash (6 bits)
  -- bit.lshift(npcId, 6) puts NPC ID in high bits
  -- bit.bor combines with spawn hash in low bits
  return bit.bor(bit.lshift(band(npcId, 0x3FFFF), 6), spawnHash)
end


---

if DataToColor:IsLegacy() then
  function DataToColor:PlayerIsMoving()
      return GetUnitSpeed(DataToColor.C.unitPlayer) > 0
  end
else
  function DataToColor:PlayerIsMoving()
    return DataToColor.moving
  end
end

--------------------------------------------------------------------------------
-- SAFE EVENT REGISTRATION
-- Pre-validates event existence before AceEvent registration to avoid errors
--------------------------------------------------------------------------------

local eventTestFrame = CreateFrame("Frame")
local validatedEvents = {}

-- Check if an event exists in this WoW version
-- Uses raw frame registration which returns silently for unknown events
function DataToColor.IsEventSupported(eventName)
    if validatedEvents[eventName] ~= nil then
        return validatedEvents[eventName]
    end

    -- Try to register on raw frame - this doesn't error for unknown events
    local success = pcall(function()
        eventTestFrame:RegisterEvent(eventName)
    end)

    if success then
        -- Check if it was actually registered (some versions silently fail)
        local isRegistered = eventTestFrame:IsEventRegistered(eventName)
        eventTestFrame:UnregisterEvent(eventName)
        validatedEvents[eventName] = isRegistered
        return isRegistered
    end

    validatedEvents[eventName] = false
    return false
end

-- Safe wrapper for AceEvent registration
-- Only registers if the event exists in this WoW version
function DataToColor:SafeRegisterEvent(eventName, handler)
    if DataToColor.IsEventSupported(eventName) then
        DataToColor:RegisterEvent(eventName, handler)
        return true
    end
    return false
end