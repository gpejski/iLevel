-- ============================================================================
-- iLevel: Dynamic Character Item Level Tooltip Addon for World of Warcraft (Retail)
-- Compatible with The War Within (11.x)
-- ============================================================================

local ADDON_NAME, ns = ...

-- Default Configuration & Database
local defaults = {
    cacheTTL = 900, -- Cache item level for 15 minutes (in seconds)
    showLoading = true,
}

-- In-memory cache: [guid] = { ilvl = number, timestamp = number }
local cache = {}
local inspectQueue = {}
local isInspecting = false
local currentInspectGUID = nil
local currentInspectUnit = nil
local lastInspectTime = 0
local INSPECT_COOLDOWN = 0.6  -- Cooldown between inspect requests to avoid server throttling
local INSPECT_TIMEOUT = 2.5   -- Watchdog timeout in seconds

-- Equipment slots to inspect in modern WoW (16 gear slots)
-- Slot 4 (Shirt) and Slot 19 (Tabard) have no stats or item level and are excluded.
local GEAR_SLOTS = {
    1,  -- INVSLOT_HEAD
    2,  -- INVSLOT_NECK
    3,  -- INVSLOT_SHOULDER
    5,  -- INVSLOT_CHEST
    6,  -- INVSLOT_WAIST
    7,  -- INVSLOT_LEGS
    8,  -- INVSLOT_FEET
    9,  -- INVSLOT_WRIST
    10, -- INVSLOT_HAND
    11, -- INVSLOT_FINGER1
    12, -- INVSLOT_FINGER2
    13, -- INVSLOT_TRINKET1
    14, -- INVSLOT_TRINKET2
    15, -- INVSLOT_BACK
    16, -- INVSLOT_MAINHAND
    17, -- INVSLOT_OFFHAND
}

-- ============================================================================
-- Color Gradient & Bracket Configuration
-- Current The War Within progression brackets with smooth color interpolation
-- ============================================================================
local COLOR_TIERS = {
    { ilvl = 0,   r = 0.65, g = 0.65, b = 0.65 }, -- Gray (Poor/Under-geared)
    { ilvl = 554, r = 0.12, g = 1.00, b = 0.00 }, -- Green (Explorer Tier)
    { ilvl = 580, r = 0.00, g = 0.44, b = 0.87 }, -- Blue (Adventurer Tier)
    { ilvl = 593, r = 0.64, g = 0.21, b = 0.93 }, -- Purple (Veteran Tier)
    { ilvl = 606, r = 0.78, g = 0.25, b = 0.98 }, -- Rich Purple (Champion Tier)
    { ilvl = 619, r = 0.95, g = 0.25, b = 0.95 }, -- Magenta (Hero Tier)
    { ilvl = 639, r = 1.00, g = 0.50, b = 0.00 }, -- Orange (Mythic Tier)
    { ilvl = 650, r = 0.90, g = 0.80, b = 0.50 }, -- Gold/Artifact
}

-- Interpolate between brackets for smooth gradient coloring
local function GetItemLevelColor(ilvl)
    if not ilvl or ilvl <= 0 then
        return 0.65, 0.65, 0.65
    end
    if ilvl <= COLOR_TIERS[1].ilvl then
        return COLOR_TIERS[1].r, COLOR_TIERS[1].g, COLOR_TIERS[1].b
    end
    for i = 1, #COLOR_TIERS - 1 do
        local low = COLOR_TIERS[i]
        local high = COLOR_TIERS[i + 1]
        if ilvl >= low.ilvl and ilvl <= high.ilvl then
            local pct = (ilvl - low.ilvl) / (high.ilvl - low.ilvl)
            local r = low.r + (high.r - low.r) * pct
            local g = low.g + (high.g - low.g) * pct
            local b = low.b + (high.b - low.b) * pct
            return r, g, b
        end
    end
    local last = COLOR_TIERS[#COLOR_TIERS]
    return last.r, last.g, last.b
end

local function FormatItemLevel(ilvl)
    local r, g, b = GetItemLevelColor(ilvl)
    local hex = string.format("%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
    return string.format("|cff%s%.1f|r", hex, ilvl)
end

-- ============================================================================
-- Unit Token Resolution Helper
-- Resolves an active unit token for a given GUID if mouseover or target shifted
-- ============================================================================
local function ResolveUnitByGUID(guid, preferredUnit)
    if preferredUnit and UnitExists(preferredUnit) and UnitGUID(preferredUnit) == guid then
        return preferredUnit
    end
    if UnitExists("mouseover") and UnitGUID("mouseover") == guid then
        return "mouseover"
    end
    if UnitExists("target") and UnitGUID("target") == guid then
        return "target"
    end
    if UnitExists("focus") and UnitGUID("focus") == guid then
        return "focus"
    end
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do
            local u = "raid" .. i
            if UnitExists(u) and UnitGUID(u) == guid then
                return u
            end
        end
    elseif IsInGroup and IsInGroup() then
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) and UnitGUID(u) == guid then
                return u
            end
        end
    end
    return nil
end

-- ============================================================================
-- Item Level Calculation Engine
-- ============================================================================
local function CalculateUnitItemLevel(unit)
    if not unit or not UnitExists(unit) then
        return nil, false
    end

    -- For the local player, Blizzard provides GetAverageItemLevel directly
    if UnitIsUnit(unit, "player") then
        local _, equipped = GetAverageItemLevel()
        return equipped, false
    end

    local totalILvl = 0
    local hasPendingItems = false

    local mainHandLink = GetInventoryItemLink(unit, 16)
    local offHandLink = GetInventoryItemLink(unit, 17)

    -- Check if Main Hand is a Two-Handed Weapon (Bows, Crossbows, Guns, 2H Weapons)
    local isTwoHand = false
    if mainHandLink then
        local equipLoc = select(4, C_Item.GetItemInfoInstant(mainHandLink))
        if equipLoc == "INVTYPE_2HWEAPON" or equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT" then
            isTwoHand = true
        end
    end

    -- In modern WoW, a 2H weapon with an empty off-hand counts twice toward the 16-slot average
    local doubleCountMainHand = isTwoHand and (not offHandLink)

    for _, slotId in ipairs(GEAR_SLOTS) do
        local link = GetInventoryItemLink(unit, slotId)
        if link then
            local ilvl = C_Item.GetDetailedItemLevelInfo(link)
            if not ilvl or ilvl == 0 then
                -- Item data is not yet cached locally by the client, request it
                C_Item.RequestLoadItemDataByID(link)
                hasPendingItems = true
            else
                if slotId == 16 and doubleCountMainHand then
                    totalILvl = totalILvl + (ilvl * 2)
                else
                    totalILvl = totalILvl + ilvl
                end
            end
        end
    end

    if hasPendingItems then
        return nil, true -- Calculation incomplete, waiting on server item info
    end

    -- Modern WoW average item level is always divided across 16 gear slots
    local avgILvl = totalILvl / 16
    return avgILvl, false
end

-- ============================================================================
-- Tooltip Helper Functions
-- ============================================================================
local function FindItemLevelLine(tooltip)
    local tooltipName = tooltip:GetName()
    if not tooltipName then return nil end

    for i = 2, tooltip:NumLines() do
        local leftText = _G[tooltipName .. "TextLeft" .. i]
        if leftText then
            local text = leftText:GetText()
            if text and string.find(text, "^Item Level:") then
                return leftText
            end
        end
    end
    return nil
end

local function UpdateOrCreateTooltipLine(tooltip, text)
    local existingLine = FindItemLevelLine(tooltip)
    if existingLine then
        existingLine:SetText(text)
        tooltip:Show()
    else
        tooltip:AddLine(text)
    end
end

local function RefreshActiveTooltip(guid, avgILvl)
    if not GameTooltip:IsShown() then return end

    local _, tooltipUnit = GameTooltip:GetUnit()
    if not tooltipUnit and UnitGUID("mouseover") == guid then
        tooltipUnit = "mouseover"
    end

    local currentGUID = tooltipUnit and UnitGUID(tooltipUnit)
    if not currentGUID and GameTooltip.GetPrimaryTooltipData then
        local tooltipData = GameTooltip:GetPrimaryTooltipData()
        currentGUID = tooltipData and tooltipData.guid
    end

    if currentGUID == guid then
        local lineText = "Item Level: " .. FormatItemLevel(avgILvl)
        UpdateOrCreateTooltipLine(GameTooltip, lineText)
    end
end

-- ============================================================================
-- Inspect Queue & Event Management
-- ============================================================================
local eventFrame = CreateFrame("Frame", "iLevelEventFrame")

local function ProcessQueue()
    if isInspecting then return end
    if #inspectQueue == 0 then return end

    -- Avoid interrupting if the user has the default Blizzard Inspect frame open
    if InspectFrame and InspectFrame:IsShown() then
        return
    end

    local now = GetTime()
    local timeSinceLast = now - lastInspectTime
    if timeSinceLast < INSPECT_COOLDOWN then
        C_Timer.After(INSPECT_COOLDOWN - timeSinceLast, ProcessQueue)
        return
    end

    local item = table.remove(inspectQueue, 1)
    local unit, guid = item.unit, item.guid

    -- Re-resolve unit token in case player moved cursor
    local resolvedUnit = ResolveUnitByGUID(guid, unit)

    if not resolvedUnit or not CanInspect(resolvedUnit) or not CheckInspectDistance(resolvedUnit) then
        ProcessQueue()
        return
    end

    isInspecting = true
    currentInspectGUID = guid
    currentInspectUnit = resolvedUnit
    lastInspectTime = now

    ClearInspectPlayer()
    NotifyInspect(resolvedUnit)

    -- Watchdog timeout in case server drops or ignores inspect request
    C_Timer.After(INSPECT_TIMEOUT, function()
        if isInspecting and currentInspectGUID == guid then
            isInspecting = false
            currentInspectGUID = nil
            currentInspectUnit = nil
            ClearInspectPlayer()
            ProcessQueue()
        end
    end)
end

local function QueueInspect(unit, guid)
    -- Don't queue if already inspecting this guid
    if currentInspectGUID == guid then return end

    -- Check if already queued
    for _, item in ipairs(inspectQueue) do
        if item.guid == guid then return end
    end

    table.insert(inspectQueue, { unit = unit, guid = guid })
    ProcessQueue()
end

-- Handle INSPECT_READY event with retry mechanism for pending item info
local function OnInspectReady(guid)
    if not isInspecting or currentInspectGUID ~= guid then
        return
    end

    local unit = ResolveUnitByGUID(guid, currentInspectUnit)
    if not unit then
        isInspecting = false
        currentInspectGUID = nil
        currentInspectUnit = nil
        ClearInspectPlayer()
        ProcessQueue()
        return
    end

    local function TryCalculate(attemptsLeft)
        local avgILvl, isPending = CalculateUnitItemLevel(unit)

        if not isPending and avgILvl then
            cache[guid] = {
                ilvl = avgILvl,
                timestamp = GetTime()
            }

            RefreshActiveTooltip(guid, avgILvl)

            isInspecting = false
            currentInspectGUID = nil
            currentInspectUnit = nil
            ClearInspectPlayer()
            ProcessQueue()
        elseif isPending and attemptsLeft > 0 then
            -- Wait for client to download item data from server
            C_Timer.After(0.2, function()
                TryCalculate(attemptsLeft - 1)
            end)
        else
            -- Max retries reached or unable to get items
            isInspecting = false
            currentInspectGUID = nil
            currentInspectUnit = nil
            ClearInspectPlayer()
            ProcessQueue()
        end
    end

    TryCalculate(3)
end

-- ============================================================================
-- Tooltip Integration (Modern Retail TooltipDataProcessor)
-- ============================================================================
local function OnTooltipSetUnit(tooltip, data)
    if tooltip ~= GameTooltip then return end

    local _, unit = tooltip:GetUnit()
    if not unit and data and data.guid then
        unit = ResolveUnitByGUID(data.guid, "mouseover")
    end

    if not unit or not UnitIsPlayer(unit) then return end

    -- 1. Local Player
    if UnitIsUnit(unit, "player") then
        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then
            local text = "Item Level: " .. FormatItemLevel(equipped)
            UpdateOrCreateTooltipLine(tooltip, text)
        end
        return
    end

    -- 2. Other Players
    local guid = (data and data.guid) or UnitGUID(unit)
    if not guid then return end

    local now = GetTime()
    local cached = cache[guid]

    -- Check if we have a fresh cached value
    local ttl = (iLevelDB and iLevelDB.cacheTTL) or defaults.cacheTTL
    if cached and (now - cached.timestamp < ttl) then
        local text = "Item Level: " .. FormatItemLevel(cached.ilvl)
        UpdateOrCreateTooltipLine(tooltip, text)
        return
    end

    -- Value is not cached: check if player is inspectable
    if CanInspect(unit) and CheckInspectDistance(unit) then
        if iLevelDB == nil or iLevelDB.showLoading ~= false then
            local text = "Item Level: |cff888888Loading...|r"
            UpdateOrCreateTooltipLine(tooltip, text)
        end
        QueueInspect(unit, guid)
    end
end

-- Register tooltip processor hook for Modern WoW (Retail 10.x / 11.x)
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipSetUnit)
end

-- Hook InspectFrame OnHide so queued inspections can resume when Inspect window is closed
local function HookInspectFrame()
    if InspectFrame and not InspectFrame._iLevelHooked then
        InspectFrame._iLevelHooked = true
        InspectFrame:HookScript("OnHide", function()
            ProcessQueue()
        end)
    end
end

-- ============================================================================
-- Event Frame Handlers
-- ============================================================================
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("INSPECT_READY")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == ADDON_NAME then
            iLevelDB = iLevelDB or {}
            for k, v in pairs(defaults) do
                if iLevelDB[k] == nil then
                    iLevelDB[k] = v
                end
            end
            HookInspectFrame()
        elseif loadedAddon == "Blizzard_InspectUI" then
            HookInspectFrame()
        end
    elseif event == "INSPECT_READY" then
        local guid = ...
        OnInspectReady(guid)
    end
end)

-- ============================================================================
-- Slash Command (/ilvl or /ilevel)
-- ============================================================================
SLASH_ILEVEL1 = "/ilvl"
SLASH_ILEVEL2 = "/ilevel"

SlashCmdList["ILEVEL"] = function(msg)
    local cmd = string.lower(string.match(msg or "", "^%s*(.-)%s*$") or "")
    if cmd == "clear" then
        local count = 0
        for _ in pairs(cache) do count = count + 1 end
        cache = {}
        print("|cff00ccffiLevel:|r Cache cleared (" .. count .. " records removed).")
    elseif cmd == "help" then
        print("|cff00ccffiLevel Commands:|r")
        print("  |cff00ccff/ilvl|r - Show addon status, your item level, and cache count")
        print("  |cff00ccff/ilvl clear|r - Wipe the inspected characters cache")
        print("  |cff00ccff/ilvl help|r - Display this help text")
    else
        local count = 0
        for _ in pairs(cache) do count = count + 1 end
        local _, equipped = GetAverageItemLevel()
        print("|cff00ccffiLevel v1.0.0|r")
        print("  Your Item Level: " .. FormatItemLevel(equipped or 0))
        print("  Cached characters: " .. count)
        print("  Type |cff00ccff/ilvl help|r for available commands.")
    end
end
