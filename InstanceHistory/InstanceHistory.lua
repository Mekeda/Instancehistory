local addonName, ns = ...

local HOUR_SECONDS = 3600
local MAX_LEVEL = 60
local INSTANCE_CAP = 5

local DEFAULT_ACCENT = { r = 0.09, g = 0.52, b = 0.82 }
local DEFAULT_BAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"

local defaults = {
    locked = false,
    histLocked = false,
    showMinimap = true,
    minimapPos = 225,
    onlyMaxLevel = false,
    onlyInGroup = false,
    announceReset = true,
    announceFailed = true,
    notifyNearLimit = true,
    alwaysShowTimer = true,
    accountWide = false,
    showTooltip = true,
    minInstancesToShow = 1,
    maxInstances = 5,
    barWidth = 260,
    barHeight = 16,
    fontSize = 12,
    fontName = "Friz Quadrata TT",
    fontPath = STANDARD_TEXT_FONT,
    fontOutline = "OUTLINE",
    barTextureName = "Blizzard",
    barTexturePath = DEFAULT_BAR_TEX,
    useClassColor = false,
    accentR = DEFAULT_ACCENT.r,
    accentG = DEFAULT_ACCENT.g,
    accentB = DEFAULT_ACCENT.b,
    scale = 1.0,
    point = "CENTER",
    relativePoint = "CENTER",
    xOfs = 0,
    yOfs = 180,
    history = {},
    fullHistory = {},
    histWidth = 650,
    histHeight = 360,
    histPoint = "CENTER",
    histRelPoint = "CENTER",
    histX = 0,
    histY = 0,
    histCurrentCharOnly = false,
    histSortAsc = false,
}

local db
local charKey
local pendingReset = false
local wasInInstance = false
local currentSessionEntry = nil
local currentFullEntry = nil
local currentZoneInTime = nil

-- Reusable tables to avoid per-tick garbage collection
local activeHistory = {}
local remainingList = {}

-- Forward declarations
local ApplyLayout
local UpdateDisplay
local UpdateHistoryWindow
local UpdateMinimapButton
local RefreshTheme
local ToggleHistoryWindow
local OpenOptions

-- Preview timestamps when unlocked with 0 active instances (oldest = 29 Mins 5 Secs)
local PREVIEW_REMAINING = { 1745, 2074, 2466, 2850, 3211 }

-- Base ElvUI Dark Palette
local ELV_BG        = { 0.08, 0.08, 0.08, 0.95 }
local ELV_WIDGET_BG = { 0.12, 0.12, 0.12, 1.00 }
local ELV_BORDER    = { 0.22, 0.22, 0.22, 1.00 }

-- Registry of callbacks for dynamic theme & font updates
local themeCallbacks = {}
local function RegisterThemeCallback(fn)
    table.insert(themeCallbacks, fn)
end

--------------------------------------------------------------------------------
-- Dynamic Accent & Class Color Resolution
--------------------------------------------------------------------------------
local function RGBToHex(r, g, b)
    r = math.max(0, math.min(255, math.floor((r or 0) * 255 + 0.5)))
    g = math.max(0, math.min(255, math.floor((g or 0) * 255 + 0.5)))
    b = math.max(0, math.min(255, math.floor((b or 0) * 255 + 0.5)))
    return string.format("%02x%02x%02x", r, g, b)
end

local function GetClassColorTable(classFile)
    if not classFile then return nil end
    return (CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[classFile])
        or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile])
        or (C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(classFile))
end

local function GetPlayerClassColor()
    local _, classFile = UnitClass("player")
    local c = GetClassColorTable(classFile)
    if c then return c.r, c.g, c.b end
    return DEFAULT_ACCENT.r, DEFAULT_ACCENT.g, DEFAULT_ACCENT.b
end

local function GetAccentColor()
    local r, g, b
    if db and db.useClassColor then
        r, g, b = GetPlayerClassColor()
    elseif db then
        r = db.accentR or DEFAULT_ACCENT.r
        g = db.accentG or DEFAULT_ACCENT.g
        b = db.accentB or DEFAULT_ACCENT.b
    else
        r, g, b = DEFAULT_ACCENT.r, DEFAULT_ACCENT.g, DEFAULT_ACCENT.b
    end
    return r, g, b, RGBToHex(r, g, b)
end

--------------------------------------------------------------------------------
-- Media Management (Built-in + LibSharedMedia-3.0 Support)
--------------------------------------------------------------------------------
local builtinFonts = {
    { name = "Friz Quadrata TT", path = "Fonts\\FRIZQT__.TTF" },
    { name = "Arial Narrow",     path = "Fonts\\ARIALN.TTF" },
    { name = "Skurri",           path = "Fonts\\SKURRI.TTF" },
    { name = "Morpheus",         path = "Fonts\\MORPHEUS.TTF" },
}

local builtinTextures = {
    { name = "Blizzard",         path = DEFAULT_BAR_TEX },
    { name = "Flat (ElvUI)",     path = "Interface\\Buttons\\WHITE8X8" },
    { name = "Raid Bar",         path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
    { name = "Skills Bar",       path = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar" },
}

local outlineOptions = {
    { name = "Outline",            value = "OUTLINE" },
    { name = "Thick Outline",      value = "THICKOUTLINE" },
    { name = "Monochrome Outline", value = "MONOCHROME, OUTLINE" },
    { name = "None",               value = "" },
}

local function GetLSM()
    return LibStub and LibStub("LibSharedMedia-3.0", true) or nil
end

local function SortByNameLower(a, b)
    return a.name:lower() < b.name:lower()
end

local function GetMediaList(mediaType, builtins)
    local list, seen = {}, {}
    local lsm = GetLSM()
    if lsm then
        for _, name in ipairs(lsm:List(mediaType)) do
            local path = lsm:Fetch(mediaType, name, true)
            if path then
                table.insert(list, { name = name, path = path })
                seen[name] = true
            end
        end
    end
    for _, item in ipairs(builtins) do
        if not seen[item.name] then
            table.insert(list, item)
        end
    end
    table.sort(list, SortByNameLower)
    return list
end

local function GetFontList() return GetMediaList("font", builtinFonts) end
local function GetTextureList() return GetMediaList("statusbar", builtinTextures) end

local function ResolveMediaPath(mediaType, nameKey, pathKey, fallback)
    if not db then return fallback end
    local lsm = GetLSM()
    if lsm and db[nameKey] then
        local fetched = lsm:Fetch(mediaType, db[nameKey], true)
        if fetched then
            db[pathKey] = fetched
            return fetched
        end
    end
    return db[pathKey] or fallback
end

local function ResolveFontPath()
    return ResolveMediaPath("font", "fontName", "fontPath", STANDARD_TEXT_FONT)
end

local function ResolveTexturePath()
    return ResolveMediaPath("statusbar", "barTextureName", "barTexturePath", DEFAULT_BAR_TEX)
end

local function ApplyConfiguredFont(fontString, size, overrideOutline)
    if not fontString then return end
    local fontPath = ResolveFontPath()
    local outline = overrideOutline ~= nil and overrideOutline or (db and db.fontOutline or "OUTLINE")
    local fontSize = size or (db and db.fontSize) or 11
    if not fontString:SetFont(fontPath, fontSize, outline) then
        fontString:SetFont(STANDARD_TEXT_FONT, fontSize, outline)
    end
end

--------------------------------------------------------------------------------
-- Helpers & Pattern Matching for Instance Resets
--------------------------------------------------------------------------------
local function MakeSystemPattern(globalString, unanchored)
    if not globalString then return nil end
    local body = globalString:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"):gsub("%%%%s", "(.+)")
    return unanchored and body or ("^" .. body .. "$")
end

local PAT_RESET_SUCCESS       = MakeSystemPattern(INSTANCE_RESET_SUCCESS, false)
local PAT_RESET_SUCCESS_LOOSE = MakeSystemPattern(INSTANCE_RESET_SUCCESS, true)
local PAT_RESET_FAILED        = MakeSystemPattern(INSTANCE_RESET_FAILED, false)
local PAT_RESET_OFFLINE       = MakeSystemPattern(INSTANCE_RESET_FAILED_OFFLINE, false)
local PAT_RESET_ZONING        = MakeSystemPattern(INSTANCE_RESET_FAILED_ZONING, false)

local function GetCharKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "Realm")
end

local function FormatTimeRemaining(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    local sLabel = (secs == 1) and "Sec" or "Secs"
    if mins > 0 then
        return string.format("%d %s %d %s", mins, (mins == 1) and "Min" or "Mins", secs, sLabel)
    end
    return string.format("%d %s", secs, sLabel)
end

local function FormatShortDuration(seconds)
    if not seconds or seconds <= 0 then return "< 1m" end
    seconds = math.floor(seconds + 0.5)
    local hrs = math.floor(seconds / 3600)
    local mins = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hrs > 0 then
        return string.format("%dh %dm", hrs, mins)
    elseif mins > 0 then
        return string.format("%dm %ds", mins, secs)
    end
    return string.format("%ds", secs)
end

local function FormatColoredChar(charStr, classFile, level)
    local shortName = charStr and charStr:match("^([^%-]+)") or (charStr or "Unknown")
    local c = GetClassColorTable(classFile)
    local colorHex = c and (c.colorStr or ("ff" .. RGBToHex(c.r, c.g, c.b))) or "ffcccccc"
    if level and level > 0 then
        return string.format("|c%s%s|r |cff888888(%d)|r", colorHex, shortName, level)
    end
    return string.format("|c%s%s|r", colorHex, shortName)
end

local function SortByEntryTime(a, b)
    return a.time < b.time
end

local function PruneAndGetActiveHistory()
    wipe(activeHistory)
    if not db or not db.history then return activeHistory end

    local now = time()
    local removed = false
    for i = #db.history, 1, -1 do
        local entry = db.history[i]
        if not entry or not entry.time or (now - entry.time) >= HOUR_SECONDS then
            if currentSessionEntry == entry then
                currentSessionEntry = nil
            end
            table.remove(db.history, i)
            removed = true
        end
    end

    if removed then
        table.sort(db.history, SortByEntryTime)
    end

    for _, entry in ipairs(db.history) do
        if db.accountWide or entry.char == charKey then
            table.insert(activeHistory, entry)
        end
    end

    return activeHistory
end

local function AddActiveLocksToTooltip(active)
    if #active == 0 then
        GameTooltip:AddLine("No instances entered in the last hour.", 0.7, 0.7, 0.7)
        return
    end
    local now = time()
    for i, entry in ipairs(active) do
        local rem = math.max(0, (entry.time + HOUR_SECONDS) - now)
        GameTooltip:AddDoubleLine(
            string.format("%d. %s", i, entry.name or "Unknown Instance"),
            FormatTimeRemaining(rem),
            0.92, 0.92, 0.92,
            0.75, 0.75, 0.75
        )
    end
end

local function GetGroupChatChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup(LE_PARTY_CATEGORY_HOME) or IsInGroup() then
        return "PARTY"
    end
    return nil
end

local function SendGroupChat(msg)
    local channel = GetGroupChatChannel()
    if not channel then return end
    if C_ChatInfo and C_ChatInfo.SendChatMessage then
        C_ChatInfo.SendChatMessage(msg, channel)
    elseif SendChatMessage then
        SendChatMessage(msg, channel)
    end
end

local function PrintAddonMsg(text)
    local _, _, _, hex = GetAccentColor()
    print(string.format("|cff%sInstanceHistory:|r %s", hex, text))
end

local function TriggerLimitNotification(count)
    local msg
    if count == 4 then
        msg = "You are nearing the instances per hour limit."
    elseif count >= INSTANCE_CAP then
        msg = "You have reached the 5 instances per hour limit!"
    else
        return
    end
    PrintAddonMsg(string.format("|cffffcc00%s (%d/%d in the last hour)|r", msg, count, INSTANCE_CAP))
end

local function ResetBarPosition()
    if not db then return end
    db.point, db.relativePoint, db.xOfs, db.yOfs = defaults.point, defaults.relativePoint, defaults.xOfs, defaults.yOfs
    ApplyLayout()
end

local function ClearActiveHistory()
    if not db then return end
    wipe(db.history)
    currentSessionEntry = nil
    UpdateDisplay()
    if UpdateHistoryWindow then UpdateHistoryWindow() end
end

--------------------------------------------------------------------------------
-- ElvUI Skinning Helpers (Shared by Options & Full History Window)
--------------------------------------------------------------------------------
local function SetElvBorder(f, r, g, b, a)
    if not f._elvBorders then
        local top = f:CreateTexture(nil, "BORDER")
        top:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        top:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
        top:SetHeight(1)

        local bottom = f:CreateTexture(nil, "BORDER")
        bottom:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
        bottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
        bottom:SetHeight(1)

        local left = f:CreateTexture(nil, "BORDER")
        left:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        left:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
        left:SetWidth(1)

        local right = f:CreateTexture(nil, "BORDER")
        right:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
        right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
        right:SetWidth(1)

        f._elvBorders = { top, bottom, left, right }
    end
    a = a or 1
    for _, tex in ipairs(f._elvBorders) do
        tex:SetColorTexture(r, g, b, a)
    end
end

local function SkinElvFrame(f, bgCol, borderCol)
    bgCol = bgCol or ELV_WIDGET_BG
    borderCol = borderCol or ELV_BORDER
    if not f._elvBg then
        f._elvBg = f:CreateTexture(nil, "BACKGROUND")
        f._elvBg:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        f._elvBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    end
    f._elvBg:SetColorTexture(bgCol[1], bgCol[2], bgCol[3], bgCol[4] or 1)
    SetElvBorder(f, borderCol[1], borderCol[2], borderCol[3], borderCol[4] or 1)
end

local activeDropdownMenu = nil
local function CloseActiveDropdown()
    if activeDropdownMenu and activeDropdownMenu:IsShown() then
        activeDropdownMenu:Hide()
    end
end

local function CreateElvButton(parent, text, width, height, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width or 140, height or 24)
    SkinElvFrame(btn, ELV_WIDGET_BG, ELV_BORDER)

    local label = btn:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(label, 11)
    label:SetPoint("CENTER", btn, "CENTER", 0, 0)
    label:SetTextColor(0.92, 0.92, 0.92, 1)
    label:SetText(text)
    btn.label = label

    btn:SetScript("OnEnter", function(self)
        local r, g, b = GetAccentColor()
        SetElvBorder(self, r, g, b, 1)
        self._elvBg:SetColorTexture(0.16, 0.16, 0.16, 1)
        label:SetTextColor(r, g, b, 1)
    end)

    btn:SetScript("OnLeave", function(self)
        SetElvBorder(self, ELV_BORDER[1], ELV_BORDER[2], ELV_BORDER[3], 1)
        self._elvBg:SetColorTexture(ELV_WIDGET_BG[1], ELV_WIDGET_BG[2], ELV_WIDGET_BG[3], 1)
        label:SetTextColor(0.92, 0.92, 0.92, 1)
    end)

    btn:SetScript("OnClick", function(self, mouseBtn)
        CloseActiveDropdown()
        if onClick then onClick(self, mouseBtn) end
    end)

    RegisterThemeCallback(function()
        ApplyConfiguredFont(label, 11)
    end)

    return btn
end

local function CreateElvCheckbox(parent, label, tooltip, getVal, setVal, onChange)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(250, 20)

    local box = CreateFrame("Frame", nil, btn)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", btn, "LEFT", 0, 0)
    SkinElvFrame(box, ELV_WIDGET_BG, ELV_BORDER)

    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)

    local text = btn:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(text, 11)
    text:SetPoint("LEFT", box, "RIGHT", 8, 0)
    text:SetTextColor(0.9, 0.9, 0.9, 1)
    text:SetText(label)
    btn.text = text

    local function Refresh()
        local r, g, b = GetAccentColor()
        fill:SetColorTexture(r, g, b, 1)
        ApplyConfiguredFont(text, 11)
        fill:SetShown(getVal() and true or false)
    end
    btn.Refresh = Refresh

    btn:SetScript("OnShow", Refresh)
    btn:SetScript("OnClick", function()
        CloseActiveDropdown()
        local newState = not getVal()
        setVal(newState)
        Refresh()
        if onChange then onChange(newState) end
    end)

    btn:SetScript("OnEnter", function(self)
        local r, g, b = GetAccentColor()
        SetElvBorder(box, r, g, b, 1)
        if tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, r, g, b)
            GameTooltip:AddLine(tooltip, 0.85, 0.85, 0.85, true)
            GameTooltip:Show()
        end
    end)

    btn:SetScript("OnLeave", function()
        SetElvBorder(box, ELV_BORDER[1], ELV_BORDER[2], ELV_BORDER[3], 1)
        GameTooltip:Hide()
    end)

    RegisterThemeCallback(Refresh)

    return btn
end

--------------------------------------------------------------------------------
-- Tracker Frame UI Construction
--------------------------------------------------------------------------------
local frame = CreateFrame("Frame", "InstanceHistoryFrame", UIParent)
frame:SetSize(260, 52)
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")

local barContainer = CreateFrame("Frame", nil, frame)
barContainer:SetPoint("BOTTOM", frame, "BOTTOM", 0, 0)
barContainer:SetSize(260, 16)

local textTop = frame:CreateFontString(nil, "OVERLAY")
textTop:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
textTop:SetTextColor(0.95, 0.95, 0.95, 1)
textTop:SetShadowColor(0, 0, 0, 1)
textTop:SetShadowOffset(1, -1)
textTop:SetPoint("BOTTOM", barContainer, "TOP", 0, 4)

local unlockLabel = frame:CreateFontString(nil, "OVERLAY")
unlockLabel:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
unlockLabel:SetPoint("BOTTOM", textTop, "TOP", 0, 2)
unlockLabel:SetText("[InstanceHistory Unlocked - Drag to Move]")
unlockLabel:Hide()

local border = barContainer:CreateTexture(nil, "BACKGROUND", nil, -2)
border:SetAllPoints(barContainer)
border:SetColorTexture(0, 0, 0, 1)

local barBg = barContainer:CreateTexture(nil, "BACKGROUND", nil, -1)
barBg:SetPoint("TOPLEFT", barContainer, "TOPLEFT", 1, -1)
barBg:SetPoint("BOTTOMRIGHT", barContainer, "BOTTOMRIGHT", -1, 1)
barBg:SetTexture(DEFAULT_BAR_TEX)
barBg:SetVertexColor(0.18, 0.18, 0.18, 0.92)

local barFill = barContainer:CreateTexture(nil, "ARTWORK", nil, 0)
barFill:SetPoint("TOPRIGHT", barContainer, "TOPRIGHT", -1, -1)
barFill:SetPoint("BOTTOMRIGHT", barContainer, "BOTTOMRIGHT", -1, 1)
barFill:SetTexture(DEFAULT_BAR_TEX)
barFill:SetVertexColor(0.76, 0.76, 0.76, 0.95)

local ticks = {}
local function GetTick(index)
    if not ticks[index] then
        local tick = barContainer:CreateTexture(nil, "OVERLAY", nil, 2)
        tick:SetColorTexture(0, 0, 0, 1)
        tick:SetWidth(2)
        ticks[index] = tick
    end
    return ticks[index]
end

--------------------------------------------------------------------------------
-- Minimap Button UI Construction
--------------------------------------------------------------------------------
local minimapBtn
local optMinimapCB

local MINIMAP_SHAPES = {
    ["ROUND"]                 = { true,  true,  true,  true },
    ["SQUARE"]                = { false, false, false, false },
    ["CORNER-TOPLEFT"]        = { false, false, false, true },
    ["CORNER-TOPRIGHT"]       = { false, false, true,  false },
    ["CORNER-BOTTOMLEFT"]     = { false, true,  false, false },
    ["CORNER-BOTTOMRIGHT"]    = { true,  false, false, false },
    ["SIDE-LEFT"]             = { false, true,  false, true },
    ["SIDE-RIGHT"]            = { true,  false, true,  false },
    ["SIDE-TOP"]              = { false, false, true,  true },
    ["SIDE-BOTTOM"]           = { true,  true,  false, false },
    ["TRICORNER-TOPLEFT"]     = { false, true,  true,  true },
    ["TRICORNER-TOPRIGHT"]    = { true,  false, true,  true },
    ["TRICORNER-BOTTOMLEFT"]  = { true,  true,  false, true },
    ["TRICORNER-BOTTOMRIGHT"] = { true,  true,  true,  false },
}

local function UpdateMinimapButtonPosition()
    if not minimapBtn or not db or not Minimap then return end
    local angle = math.rad(db.minimapPos or 225)
    local x, y, q = math.cos(angle), math.sin(angle), 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end

    local minimapShape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local quadTable = MINIMAP_SHAPES[minimapShape] or MINIMAP_SHAPES["ROUND"]
    local w = (Minimap:GetWidth() / 2) + 5
    local h = (Minimap:GetHeight() / 2) + 5

    if quadTable[q] then
        x, y = x * w, y * h
    else
        local diagRadiusW = math.sqrt(2 * (w ^ 2)) - 10
        local diagRadiusH = math.sqrt(2 * (h ^ 2)) - 10
        x = math.max(-w, math.min(x * diagRadiusW, w))
        y = math.max(-h, math.min(y * diagRadiusH, h))
    end

    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function ShowMinimapTooltip(self, precomputedActive)
    if not db then return end
    local r, g, b, hex = GetAccentColor()
    local active = precomputedActive or PruneAndGetActiveHistory()
    local count = #active

    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddDoubleLine(
        string.format("|cff%sInstance|rHistory", hex),
        string.format("|cff%s%d/%d|r Locks (1h)", (count >= INSTANCE_CAP and "ff4444" or (count == 4 and "ffcc00" or hex)), count, INSTANCE_CAP),
        1, 1, 1, 0.85, 0.85, 0.85
    )

    AddActiveLocksToTooltip(active)

    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Left-Click:", "Toggle History Window", r, g, b, 0.9, 0.9, 0.9)
    GameTooltip:AddDoubleLine("Right-Click:", "Open Options", r, g, b, 0.9, 0.9, 0.9)
    GameTooltip:AddDoubleLine("Drag:", "Move Minimap Button", 0.65, 0.65, 0.65, 0.65, 0.65, 0.65)
    GameTooltip:Show()
end

local function CreateMinimapButton()
    if minimapBtn or not Minimap then return minimapBtn end

    minimapBtn = CreateFrame("Button", "InstanceHistoryMinimapButton", Minimap)
    minimapBtn:SetSize(31, 31)
    minimapBtn:SetFrameStrata("MEDIUM")
    minimapBtn:SetFrameLevel(8)
    minimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapBtn:RegisterForDrag("LeftButton")
    minimapBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = minimapBtn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(21, 21)
    bg:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 6, -5)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetVertexColor(0.08, 0.08, 0.08, 0.95)
    minimapBtn.bg = bg

    local accentRing = minimapBtn:CreateTexture(nil, "BORDER")
    accentRing:SetSize(20, 20)
    accentRing:SetPoint("CENTER", bg, "CENTER", 0, 0)
    accentRing:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    minimapBtn.accentRing = accentRing

    local icon = minimapBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER", bg, "CENTER", 0, 0)
    icon:SetTexture("Interface\\Icons\\Spell_Nature_TimeStop")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    minimapBtn.icon = icon

    if minimapBtn.CreateMaskTexture then
        local mask = minimapBtn:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(icon)
        icon:AddMaskTexture(mask)
    end

    local overlay = minimapBtn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT", minimapBtn, "TOPLEFT", 0, 0)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    minimapBtn.overlay = overlay

    local badgeText = minimapBtn:CreateFontString(nil, "OVERLAY")
    badgeText:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    badgeText:SetPoint("BOTTOMRIGHT", minimapBtn, "BOTTOMRIGHT", -3, 3)
    badgeText:SetJustifyH("RIGHT")
    minimapBtn.badgeText = badgeText

    minimapBtn:SetScript("OnEnter", function(self)
        self.isHovered = true
        ShowMinimapTooltip(self)
    end)

    minimapBtn:SetScript("OnLeave", function(self)
        self.isHovered = false
        GameTooltip:Hide()
    end)

    minimapBtn:SetScript("OnMouseDown", function(self)
        self.icon:SetPoint("CENTER", self.bg, "CENTER", 1, -1)
    end)

    minimapBtn:SetScript("OnMouseUp", function(self)
        self.icon:SetPoint("CENTER", self.bg, "CENTER", 0, 0)
    end)

    minimapBtn:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        self.icon:SetPoint("CENTER", self.bg, "CENTER", 1, -1)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            if mx and my then
                db.minimapPos = math.deg(math.atan2(cy - my, cx - mx)) % 360
                UpdateMinimapButtonPosition()
            end
        end)
    end)

    minimapBtn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self:UnlockHighlight()
        self.icon:SetPoint("CENTER", self.bg, "CENTER", 0, 0)
    end)

    minimapBtn:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            ToggleHistoryWindow()
        elseif button == "RightButton" then
            OpenOptions()
        end
    end)

    RegisterThemeCallback(function()
        if not minimapBtn or not db then return end
        local r, g, b = GetAccentColor()
        minimapBtn.accentRing:SetVertexColor(r, g, b, 0.9)
        ApplyConfiguredFont(minimapBtn.badgeText, 10, "OUTLINE")
        UpdateMinimapButtonPosition()
        UpdateMinimapButton()
    end)

    UpdateMinimapButtonPosition()
    return minimapBtn
end

UpdateMinimapButton = function(precomputedActive)
    if not db then return end
    if not minimapBtn then
        CreateMinimapButton()
        if not minimapBtn then return end
    end

    if not db.showMinimap then
        minimapBtn:Hide()
        return
    end

    if not minimapBtn:IsShown() then
        minimapBtn:Show()
        UpdateMinimapButtonPosition()
    end

    local active = precomputedActive or PruneAndGetActiveHistory()
    local count = #active
    if count > 0 then
        if count >= INSTANCE_CAP then
            minimapBtn.badgeText:SetTextColor(1, 0.25, 0.25, 1)
        elseif count == 4 then
            minimapBtn.badgeText:SetTextColor(1, 0.80, 0, 1)
        else
            minimapBtn.badgeText:SetTextColor(0.35, 1, 0.35, 1)
        end
        minimapBtn.badgeText:SetText(tostring(count))
        minimapBtn.badgeText:Show()
    else
        minimapBtn.badgeText:Hide()
    end

    if minimapBtn.isHovered and GameTooltip:GetOwner() == minimapBtn then
        ShowMinimapTooltip(minimapBtn, active)
    end
end

--------------------------------------------------------------------------------
-- Full Dungeon History Window (/ih history)
--------------------------------------------------------------------------------
local histFrame
local optHistLockCB

local function CreateHistoryWindow()
    if histFrame then return histFrame end

    local MIN_W, MIN_H = 520, 220
    local MAX_W, MAX_H = 1200, 900
    local ROW_HEIGHT = 22

    histFrame = CreateFrame("Frame", "InstanceHistoryLogFrame", UIParent)
    histFrame:SetSize(db.histWidth or 650, db.histHeight or 360)
    histFrame:SetPoint(db.histPoint or "CENTER", UIParent, db.histRelPoint or "CENTER", db.histX or 0, db.histY or 0)
    histFrame:SetFrameStrata("HIGH")
    histFrame:SetToplevel(true)
    histFrame:SetClampedToScreen(true)
    histFrame:SetMovable(true)
    histFrame:SetResizable(true)
    histFrame:EnableMouse(true)
    histFrame:EnableMouseWheel(true)
    SkinElvFrame(histFrame, ELV_BG, ELV_BORDER)
    histFrame:Hide()

    if histFrame.SetResizeBounds then
        histFrame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    else
        if histFrame.SetMinResize then histFrame:SetMinResize(MIN_W, MIN_H) end
        if histFrame.SetMaxResize then histFrame:SetMaxResize(MAX_W, MAX_H) end
    end

    tinsert(UISpecialFrames, "InstanceHistoryLogFrame")

    local header = CreateFrame("Frame", nil, histFrame)
    header:SetPoint("TOPLEFT", histFrame, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", histFrame, "TOPRIGHT", -1, -1)
    header:SetHeight(32)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function()
        if db and not db.histLocked then
            histFrame:StartMoving()
        end
    end)
    header:SetScript("OnDragStop", function()
        histFrame:StopMovingOrSizing()
        local p, _, rp, x, y = histFrame:GetPoint()
        db.histPoint, db.histRelPoint = p, rp
        db.histX, db.histY = math.floor(x + 0.5), math.floor(y + 0.5)
    end)

    local headerBg = header:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints(header)
    headerBg:SetColorTexture(0.11, 0.11, 0.11, 1)

    local headerLine = header:CreateTexture(nil, "ARTWORK")
    headerLine:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    headerLine:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    headerLine:SetHeight(1)

    local title = header:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(title, 13)
    title:SetPoint("LEFT", header, "LEFT", 12, 0)

    local closeBtn = CreateElvButton(header, "X", 22, 22, function()
        histFrame:Hide()
    end)
    closeBtn:SetPoint("RIGHT", header, "RIGHT", -6, 0)

    local toolbar = CreateFrame("Frame", nil, histFrame)
    toolbar:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 10, -6)
    toolbar:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -10, -6)
    toolbar:SetHeight(24)

    local charFilterCB = CreateElvCheckbox(
        toolbar,
        "Current Character Only",
        "When checked, only shows dungeon runs entered on the currently logged-in character.",
        function() return db.histCurrentCharOnly end,
        function(v) db.histCurrentCharOnly = v end,
        function()
            histFrame.scrollOffset = 0
            UpdateHistoryWindow()
        end
    )
    charFilterCB:SetPoint("LEFT", toolbar, "LEFT", 0, 0)
    charFilterCB:SetWidth(160)

    local lockHistCB = CreateElvCheckbox(
        toolbar,
        "Lock Window",
        "Locks the history window position and size so it cannot be moved or resized.",
        function() return db.histLocked end,
        function(v) db.histLocked = v end,
        function()
            if optHistLockCB then optHistLockCB:Refresh() end
            UpdateHistoryWindow()
        end
    )
    lockHistCB:SetPoint("LEFT", charFilterCB, "RIGHT", 10, 0)
    lockHistCB:SetWidth(105)
    histFrame.lockHistCB = lockHistCB

    local statsText = toolbar:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(statsText, 11)
    statsText:SetPoint("LEFT", lockHistCB, "RIGHT", 10, 0)
    statsText:SetTextColor(0.78, 0.78, 0.78, 1)

    local clearAllBtn = CreateElvButton(toolbar, "Clear Full Log (Shift-Click)", 165, 20, function()
        if IsShiftKeyDown() then
            wipe(db.fullHistory)
            currentFullEntry = nil
            histFrame.scrollOffset = 0
            UpdateHistoryWindow()
            PrintAddonMsg("Full dungeon history log cleared.")
        else
            PrintAddonMsg("Hold |cffffcc00Shift|r and click 'Clear Full Log' to confirm.")
        end
    end)
    clearAllBtn:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)

    local colHeader = CreateFrame("Frame", nil, histFrame)
    colHeader:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -6)
    colHeader:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -6)
    colHeader:SetHeight(22)
    SkinElvFrame(colHeader, { 0.13, 0.13, 0.13, 1 }, ELV_BORDER)

    local function CreateColHeader(textStr)
        local fs = colHeader:CreateFontString(nil, "OVERLAY")
        ApplyConfiguredFont(fs, 11)
        fs:SetJustifyH("LEFT")
        fs:SetText(textStr)
        return fs
    end

    colHeader.cNum    = CreateColHeader("#")
    colHeader.cInst   = CreateColHeader("Instance")
    colHeader.cChar   = CreateColHeader("Character")
    colHeader.cDate   = CreateColHeader("Entered")
    colHeader.cStatus = CreateColHeader("Lock Status")
    colHeader.cells   = { colHeader.cNum, colHeader.cInst, colHeader.cChar, colHeader.cDate, colHeader.cStatus }

    local colNumBtn = CreateFrame("Button", nil, colHeader)
    colNumBtn:SetPoint("TOPLEFT", colHeader.cNum, "TOPLEFT", 0, 4)
    colNumBtn:SetPoint("BOTTOMRIGHT", colHeader.cNum, "BOTTOMRIGHT", 0, -4)
    colNumBtn:SetScript("OnClick", function()
        db.histSortAsc = not db.histSortAsc
        histFrame.scrollOffset = 0
        UpdateHistoryWindow()
    end)
    colNumBtn:SetScript("OnEnter", function()
        colHeader.cNum:SetTextColor(1, 1, 1, 1)
    end)
    colNumBtn:SetScript("OnLeave", function()
        local r, g, b = GetAccentColor()
        colHeader.cNum:SetTextColor(r, g, b, 1)
    end)

    local listBox = CreateFrame("Frame", nil, histFrame)
    listBox:SetPoint("TOPLEFT", colHeader, "BOTTOMLEFT", 0, -2)
    listBox:SetPoint("BOTTOMRIGHT", histFrame, "BOTTOMRIGHT", -10, 22)
    SkinElvFrame(listBox, { 0.06, 0.06, 0.06, 0.95 }, ELV_BORDER)

    local scrollBar = CreateFrame("Slider", nil, listBox)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetPoint("TOPRIGHT", listBox, "TOPRIGHT", -2, -2)
    scrollBar:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -2, 2)
    scrollBar:SetWidth(10)
    scrollBar:SetValueStep(1)
    scrollBar:SetObeyStepOnDrag(true)
    SkinElvFrame(scrollBar, { 0.04, 0.04, 0.04, 1 }, ELV_BORDER)

    local scrollThumb = scrollBar:CreateTexture(nil, "OVERLAY")
    scrollThumb:SetSize(8, 32)
    scrollBar:SetThumbTexture(scrollThumb)

    local emptyText = listBox:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(emptyText, 12)
    emptyText:SetPoint("CENTER", listBox, "CENTER", 0, 0)
    emptyText:SetTextColor(0.55, 0.55, 0.55, 1)
    emptyText:SetText("No dungeon history recorded yet.")
    emptyText:Hide()

    local footerHint = histFrame:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(footerHint, 10)
    footerHint:SetPoint("BOTTOMLEFT", histFrame, "BOTTOMLEFT", 12, 6)
    footerHint:SetTextColor(0.55, 0.55, 0.55, 1)

    local resizeGrip = CreateFrame("Button", nil, histFrame)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", histFrame, "BOTTOMRIGHT", -2, 2)
    resizeGrip:SetFrameLevel(histFrame:GetFrameLevel() + 10)

    local gripLines = {}
    for idx, spec in ipairs({ { 10, 2 }, { 6, 6 }, { 2, 10 } }) do
        local line = resizeGrip:CreateTexture(nil, "OVERLAY")
        line:SetSize(spec[1], 2)
        line:SetPoint("BOTTOMRIGHT", resizeGrip, "BOTTOMRIGHT", -2, spec[2])
        gripLines[idx] = line
    end

    local function ColorGripLines(r, g, b, a)
        for _, line in ipairs(gripLines) do
            line:SetColorTexture(r, g, b, a)
        end
    end

    resizeGrip:SetScript("OnEnter", function()
        ColorGripLines(1, 1, 1, 1)
    end)
    resizeGrip:SetScript("OnLeave", function()
        local r, g, b = GetAccentColor()
        ColorGripLines(r, g, b, 0.85)
    end)
    resizeGrip:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" and db and not db.histLocked then
            histFrame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        histFrame:StopMovingOrSizing()
        db.histWidth = math.floor(histFrame:GetWidth() + 0.5)
        db.histHeight = math.floor(histFrame:GetHeight() + 0.5)
        UpdateHistoryWindow()
    end)

    histFrame.rows = {}
    histFrame.scrollOffset = 0
    histFrame.filteredEntries = {}
    histFrame.filteredIndices = {}
    local isUpdatingScroll = false

    local function LayoutColumns(target, totalWidth)
        local usable = math.max(460, totalWidth - 20)
        local wNum, wDate, wStatus = 40, 130, 125
        local flex  = math.max(120, usable - (wNum + wDate + wStatus))
        local wInst = math.floor(flex * 0.56)
        local wChar = flex - wInst

        local widths = { wNum, wInst, wChar, wDate, wStatus }
        local x = 8
        for i, cell in ipairs(target.cells) do
            local w = widths[i]
            cell:ClearAllPoints()
            cell:SetPoint("LEFT", target, "LEFT", x, 0)
            cell:SetWidth(w)
            x = x + w + 4
        end
    end

    local function ShowRowTooltip(row)
        local e = row.entry
        if not e then return end
        local r, g, b = GetAccentColor()
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(e.name or "Instance", r, g, b)
        GameTooltip:AddDoubleLine("Character:", e.char or "Unknown", 0.8, 0.8, 0.8, 1, 1, 1)
        if e.level and e.level > 0 then
            GameTooltip:AddDoubleLine("Character Level:", tostring(e.level), 0.8, 0.8, 0.8, 1, 1, 1)
        end
        if e.difficultyName and e.difficultyName ~= "" then
            GameTooltip:AddDoubleLine("Difficulty:", e.difficultyName, 0.8, 0.8, 0.8, 1, 1, 1)
        end
        if e.time then
            GameTooltip:AddDoubleLine("Entered At:", date("%Y-%m-%d %H:%M:%S", e.time), 0.8, 0.8, 0.8, 1, 1, 1)
        end
        GameTooltip:Show()
    end

    local function GetOrCreateRow(index)
        if histFrame.rows[index] then
            return histFrame.rows[index]
        end

        local row = CreateFrame("Button", nil, listBox)
        row:SetHeight(ROW_HEIGHT)
        row:EnableMouseWheel(true)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints(row)

        row.hoverTex = row:CreateTexture(nil, "ARTWORK")
        row.hoverTex:SetAllPoints(row)
        row.hoverTex:Hide()

        local function MakeCell()
            local fs = row:CreateFontString(nil, "OVERLAY")
            ApplyConfiguredFont(fs, 11)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            return fs
        end

        row.cNum    = MakeCell()
        row.cInst   = MakeCell()
        row.cChar   = MakeCell()
        row.cDate   = MakeCell()
        row.cStatus = MakeCell()
        row.cells   = { row.cNum, row.cInst, row.cChar, row.cDate, row.cStatus }

        row:SetScript("OnEnter", function(self)
            self.isHovered = true
            local r, g, b = GetAccentColor()
            self.hoverTex:SetColorTexture(r, g, b, 0.28)
            self.hoverTex:Show()
            ShowRowTooltip(self)
        end)

        row:SetScript("OnLeave", function(self)
            self.isHovered = false
            self.hoverTex:Hide()
            GameTooltip:Hide()
        end)

        row:SetScript("OnMouseWheel", function(_, delta)
            histFrame:GetScript("OnMouseWheel")(histFrame, delta)
        end)

        histFrame.rows[index] = row
        return row
    end

    local function ApplyHistoryThemeAndFonts()
        local r, g, b, hex = GetAccentColor()

        ApplyConfiguredFont(title, 13)
        title:SetText(string.format("|cff%sInstance|rHistory — Full Dungeon Log", hex))
        headerLine:SetColorTexture(r, g, b, 0.9)

        ApplyConfiguredFont(statsText, 11)
        ApplyConfiguredFont(emptyText, 12)
        ApplyConfiguredFont(footerHint, 10)

        for _, colFS in ipairs(colHeader.cells) do
            ApplyConfiguredFont(colFS, 11)
            colFS:SetTextColor(r, g, b, 1)
        end

        scrollThumb:SetColorTexture(r, g, b, 0.85)
        ColorGripLines(r, g, b, 0.85)

        for _, row in ipairs(histFrame.rows) do
            for _, cell in ipairs(row.cells) do
                ApplyConfiguredFont(cell, 11)
            end
            if row.isHovered then
                row.hoverTex:SetColorTexture(r, g, b, 0.28)
            end
        end
    end

    RegisterThemeCallback(function()
        ApplyHistoryThemeAndFonts()
        if histFrame and histFrame:IsShown() then
            UpdateHistoryWindow()
        end
    end)

    UpdateHistoryWindow = function()
        if not histFrame or not histFrame:IsShown() or not db then return end

        local r, g, b, hex = GetAccentColor()

        if db.histLocked then
            resizeGrip:Hide()
            footerHint:SetText("Window Locked • Scroll wheel to browse")
        else
            resizeGrip:Show()
            footerHint:SetText("Drag header to move • Drag bottom-right corner to resize • Scroll wheel to browse")
        end

        local listWidth = listBox:GetWidth() or (histFrame:GetWidth() - 20)
        local listHeight = listBox:GetHeight() or (histFrame:GetHeight() - 115)
        local visibleRows = math.max(1, math.floor((listHeight - 4) / ROW_HEIGHT))

        LayoutColumns(colHeader, listWidth)

        local entries = histFrame.filteredEntries
        local indices = histFrame.filteredIndices
        wipe(entries)
        wipe(indices)

        local full = db.fullHistory or {}
        local activeCountLastHour = 0
        local now = time()

        local startIdx, endIdx, step = #full, 1, -1
        if db.histSortAsc then
            startIdx, endIdx, step = 1, #full, 1
        end

        local total = 0
        for i = startIdx, endIdx, step do
            local e = full[i]
            if e and e.time and (not db.histCurrentCharOnly or e.char == charKey) then
                total = total + 1
                entries[total] = e
                indices[total] = i
                if (now - e.time) < HOUR_SECONDS then
                    activeCountLastHour = activeCountLastHour + 1
                end
            end
        end

        statsText:SetText(string.format(
            "Total Runs: |cffffffff%d|r   •   Active Locks (1h): |cff%s%d/%d|r",
            total, hex, activeCountLastHour, INSTANCE_CAP
        ))

        emptyText:SetShown(total == 0)

        local maxOffset = math.max(0, total - visibleRows)
        histFrame.scrollOffset = math.max(0, math.min(maxOffset, histFrame.scrollOffset or 0))

        isUpdatingScroll = true
        if maxOffset > 0 then
            scrollBar:SetMinMaxValues(0, maxOffset)
            scrollBar:SetValue(histFrame.scrollOffset)
            scrollBar:Show()
        else
            scrollBar:SetMinMaxValues(0, 0)
            scrollBar:SetValue(0)
            scrollBar:Hide()
        end
        isUpdatingScroll = false

        local rightPad = (maxOffset > 0) and -14 or -2

        for i = 1, math.max(#histFrame.rows, visibleRows) do
            local row = GetOrCreateRow(i)
            local dataIdx = i + histFrame.scrollOffset
            local e = (i <= visibleRows) and entries[dataIdx] or nil
            if e then
                row.entry = e
                row.rowIndex = i
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", listBox, "TOPLEFT", 2, -2 - ((i - 1) * ROW_HEIGHT))
                row:SetPoint("TOPRIGHT", listBox, "TOPRIGHT", rightPad, -2 - ((i - 1) * ROW_HEIGHT))

                if i % 2 == 0 then
                    row.bg:SetColorTexture(0.11, 0.11, 0.11, 0.65)
                else
                    row.bg:SetColorTexture(0.07, 0.07, 0.07, 0.40)
                end

                if row.isHovered or row:IsMouseOver() then
                    row.isHovered = true
                    row.hoverTex:SetColorTexture(r, g, b, 0.28)
                    row.hoverTex:Show()
                else
                    row.hoverTex:Hide()
                end

                LayoutColumns(row, listWidth)

                row.cNum:SetText(string.format("|cff888888%d|r", indices[dataIdx]))
                row.cInst:SetText(e.name or "Instance")
                row.cInst:SetTextColor(0.95, 0.95, 0.95, 1)

                row.cChar:SetText(FormatColoredChar(e.char, e.class, e.level))
                row.cDate:SetText(e.time and date("%Y-%m-%d %H:%M", e.time) or "-")
                row.cDate:SetTextColor(0.82, 0.82, 0.82, 1)

                local rem = (e.time or 0) + HOUR_SECONDS - now
                if rem > 0 then
                    row.cStatus:SetText(string.format("|cffffaa00Locked (%s)|r", FormatShortDuration(rem)))
                else
                    row.cStatus:SetText("|cff55ff55Expired|r")
                end

                row:Show()
            else
                row.entry = nil
                row.isHovered = false
                row.hoverTex:Hide()
                row:Hide()
            end
        end
    end

    scrollBar:SetScript("OnValueChanged", function(_, value)
        if isUpdatingScroll then return end
        histFrame.scrollOffset = math.floor(value + 0.5)
        UpdateHistoryWindow()
    end)

    histFrame:SetScript("OnMouseWheel", function(_, delta)
        local listHeight = listBox:GetHeight() or 200
        local visibleRows = math.max(1, math.floor((listHeight - 4) / ROW_HEIGHT))
        local maxOffset = math.max(0, #histFrame.filteredEntries - visibleRows)
        if maxOffset <= 0 then return end
        histFrame.scrollOffset = math.max(0, math.min(maxOffset, (histFrame.scrollOffset or 0) - (delta * 2)))
        UpdateHistoryWindow()
    end)

    histFrame:SetScript("OnSizeChanged", function()
        if histFrame:IsShown() then
            UpdateHistoryWindow()
        end
    end)

    histFrame:SetScript("OnShow", function()
        charFilterCB:Refresh()
        lockHistCB:Refresh()
        ApplyHistoryThemeAndFonts()
        UpdateHistoryWindow()
    end)

    local histAccum = 0
    histFrame:SetScript("OnUpdate", function(_, elapsed)
        histAccum = histAccum + elapsed
        if histAccum >= 1.0 then
            histAccum = 0
            UpdateHistoryWindow()
        end
    end)

    ApplyHistoryThemeAndFonts()
    return histFrame
end

ToggleHistoryWindow = function()
    CreateHistoryWindow()
    histFrame:SetShown(not histFrame:IsShown())
end

--------------------------------------------------------------------------------
-- Layout, Visibility & OnUpdate for 1-Hour Bar
--------------------------------------------------------------------------------
ApplyLayout = function()
    if not db then return end
    local fontPath = ResolveFontPath()
    local texPath  = ResolveTexturePath()
    local outline  = db.fontOutline or "OUTLINE"
    local fontSize = db.fontSize or 12
    local barW     = db.barWidth or 260
    local barH     = db.barHeight or 16
    local r, g, b  = GetAccentColor()

    frame:SetScale(db.scale or 1.0)
    barContainer:SetSize(barW, barH)
    frame:SetSize(math.max(barW, 260), barH + (fontSize * 2) + 14)

    if not textTop:SetFont(fontPath, fontSize, outline) then
        textTop:SetFont(STANDARD_TEXT_FONT, fontSize, outline)
    end
    if not unlockLabel:SetFont(fontPath, math.max(9, fontSize - 2), outline) then
        unlockLabel:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    end
    unlockLabel:SetTextColor(r, g, b, 1)

    barBg:SetTexture(texPath)
    barBg:SetVertexColor(0.18, 0.18, 0.18, 0.92)
    barFill:SetTexture(texPath)
    barFill:SetVertexColor(0.76, 0.76, 0.76, 0.95)

    frame:ClearAllPoints()
    frame:SetPoint(db.point or "CENTER", UIParent, db.relativePoint or "CENTER", db.xOfs or 0, db.yOfs or 180)

    unlockLabel:SetShown(not db.locked)
    frame:EnableMouse((not db.locked) or db.showTooltip)
end

RefreshTheme = function()
    ApplyLayout()
    for _, fn in ipairs(themeCallbacks) do
        fn()
    end
    UpdateDisplay()
end

frame:SetScript("OnDragStart", function(self)
    if db and not db.locked then
        self:StartMoving()
    end
end)

frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if db then
        local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
        db.point, db.relativePoint = point, relativePoint
        db.xOfs, db.yOfs = math.floor(xOfs + 0.5), math.floor(yOfs + 0.5)
    end
end)

local function ShouldDisplay(activeCount)
    if not db then return false end
    if not db.locked then return true end
    if db.onlyMaxLevel and (UnitLevel("player") or 0) < MAX_LEVEL then return false end
    if db.onlyInGroup and not IsInGroup() then return false end
    return activeCount >= (db.minInstancesToShow or 1)
end

UpdateDisplay = function()
    if not db then return end

    if wasInInstance and currentFullEntry and currentFullEntry.time then
        currentFullEntry.duration = math.max(0, time() - currentFullEntry.time)
    end

    local active = PruneAndGetActiveHistory()
    local count = #active

    if UpdateMinimapButton then
        UpdateMinimapButton(active)
    end

    if not ShouldDisplay(count) then
        frame:Hide()
        return
    end
    frame:Show()

    wipe(remainingList)
    local now = time()

    if count == 0 and not db.locked then
        for i, rem in ipairs(PREVIEW_REMAINING) do
            remainingList[i] = rem
        end
        count = #remainingList
    else
        for i, entry in ipairs(active) do
            remainingList[i] = math.max(0, (entry.time + HOUR_SECONDS) - now)
        end
    end

    local innerWidth = math.max(1, (db.barWidth or 260) - 2)
    local innerHeight = math.max(1, (db.barHeight or 16) - 2)

    for _, tick in ipairs(ticks) do
        tick:Hide()
    end

    if count > 0 then
        local oldestRem = remainingList[1]
        local oldestFrac = math.min(1, math.max(0, oldestRem / HOUR_SECONDS))

        barFill:Show()
        barFill:SetWidth(math.max(1, innerWidth * (1 - oldestFrac)))

        for i = 1, count do
            local frac = math.min(1, math.max(0, remainingList[i] / HOUR_SECONDS))
            local xPos = 1 + (innerWidth * frac)
            local tick = GetTick(i)
            tick:ClearAllPoints()
            tick:SetSize(2, innerHeight)
            tick:SetPoint("LEFT", barContainer, "LEFT", xPos - 1, 0)
            tick:Show()
        end

        local line1 = string.format("You have entered %d %s recently.", count, (count == 1) and "instance" or "instances")
        if db.alwaysShowTimer or count >= (db.maxInstances or INSTANCE_CAP) then
            textTop:SetText(string.format("%s\nMore instances will be available in %s.", line1, FormatTimeRemaining(oldestRem)))
        else
            textTop:SetText(line1)
        end
    else
        barFill:Hide()
        textTop:SetText("You have entered 0 instances recently.")
    end
end

local elapsedAccum = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    elapsedAccum = elapsedAccum + elapsed
    if elapsedAccum >= 0.2 then
        elapsedAccum = 0
        UpdateDisplay()
    end
end)

frame:SetScript("OnEnter", function(self)
    if not db or not db.showTooltip then return end
    local r, g, b = GetAccentColor()
    local active = PruneAndGetActiveHistory()
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Instance History (Last Hour)", r, g, b)

    AddActiveLocksToTooltip(active)

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Type /ih history to view Full Dungeon History.", 0.65, 0.65, 0.65)
    if not db.locked then
        GameTooltip:AddLine("Left-Click & Drag to move. Type /ih lock to lock.", r, g, b)
    end
    GameTooltip:Show()
end)

frame:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

--------------------------------------------------------------------------------
-- Instance Tracking & Heuristic Detection
--------------------------------------------------------------------------------
local function CloneEntry(src, fallbackClass, fallbackLevel)
    return {
        name = src.name,
        mapID = src.mapID,
        difficulty = src.difficulty,
        difficultyName = src.difficultyName,
        time = src.time,
        char = src.char,
        class = src.class or fallbackClass,
        level = src.level or fallbackLevel,
        zoneUID = src.zoneUID,
        duration = src.duration or 0,
    }
end

local function RemoveFromList(tbl, target)
    if not tbl or not target then return end
    for i = #tbl, 1, -1 do
        if tbl[i] == target then
            table.remove(tbl, i)
            return
        end
    end
end

local function FindFullEntry(matchField, matchVal, char)
    if not db or not db.fullHistory then return nil end
    for i = #db.fullHistory, 1, -1 do
        local fe = db.fullHistory[i]
        if fe and fe[matchField] == matchVal and fe.char == char then
            return fe
        end
    end
    return nil
end

local function RecordNewInstance(name, instanceMapID, difficultyID, difficultyName, timestamp, zoneUID)
    local _, playerClass = UnitClass("player")
    local entry = {
        name = name or "Instance",
        mapID = instanceMapID,
        difficulty = difficultyID,
        difficultyName = difficultyName,
        time = timestamp or time(),
        char = charKey,
        class = playerClass,
        level = UnitLevel("player") or 0,
        zoneUID = zoneUID,
        duration = 0,
    }
    table.insert(db.history, entry)
    table.sort(db.history, SortByEntryTime)
    currentSessionEntry = entry

    local fullEntry = CloneEntry(entry)
    table.insert(db.fullHistory, fullEntry)
    currentFullEntry = fullEntry
    pendingReset = false

    local active = PruneAndGetActiveHistory()
    if db.notifyNearLimit and (#active == 4 or #active >= INSTANCE_CAP) then
        TriggerLimitNotification(#active)
    end

    UpdateDisplay()
    if UpdateHistoryWindow then UpdateHistoryWindow() end
end

local function CheckInstanceStatus()
    if not db then return end
    local inInstance, instanceType = IsInInstance()
    local isTrackedType = inInstance and (instanceType == "party" or instanceType == "raid")

    if not isTrackedType then
        if wasInInstance and currentFullEntry and currentFullEntry.time then
            currentFullEntry.duration = math.max(0, time() - currentFullEntry.time)
        end
        wasInInstance = false
        currentSessionEntry = nil
        currentFullEntry = nil
        currentZoneInTime = nil
        UpdateDisplay()
        if UpdateHistoryWindow then UpdateHistoryWindow() end
        return
    end

    local name, _, difficultyID, difficultyName, _, _, _, instanceMapID = GetInstanceInfo()
    if not name or name == "" then
        C_Timer.After(0.5, CheckInstanceStatus)
        return
    end

    if not wasInInstance then
        wasInInstance = true
        currentZoneInTime = time()

        local active = PruneAndGetActiveHistory()
        local lastEntry = active[#active]

        if pendingReset or not lastEntry or lastEntry.mapID ~= instanceMapID or lastEntry.difficulty ~= difficultyID then
            RecordNewInstance(name, instanceMapID, difficultyID, difficultyName, currentZoneInTime, nil)
        else
            currentSessionEntry = lastEntry
            currentSessionEntry.name = name
            currentFullEntry = FindFullEntry("time", lastEntry.time, lastEntry.char)
            if currentFullEntry then
                currentFullEntry.name = name
            end
        end
    end

    UpdateDisplay()
    if UpdateHistoryWindow then UpdateHistoryWindow() end
end

local function VerifyGUIDZoneUID(guid)
    if not wasInInstance or not guid or not db or not currentSessionEntry then return end
    local unitType, _, _, _, zoneUID = strsplit("-", guid)
    if (unitType ~= "Creature" and unitType ~= "Vehicle") or not zoneUID then
        return
    end

    if not currentSessionEntry.zoneUID then
        local active = PruneAndGetActiveHistory()
        for _, entry in ipairs(active) do
            if entry ~= currentSessionEntry and entry.zoneUID == zoneUID then
                RemoveFromList(db.history, currentSessionEntry)
                RemoveFromList(db.fullHistory, currentFullEntry)
                currentSessionEntry = entry
                currentFullEntry = FindFullEntry("zoneUID", zoneUID, entry.char)
                UpdateDisplay()
                if UpdateHistoryWindow then UpdateHistoryWindow() end
                return
            end
        end
        currentSessionEntry.zoneUID = zoneUID
        if currentFullEntry then
            currentFullEntry.zoneUID = zoneUID
        end
    elseif currentSessionEntry.zoneUID ~= zoneUID then
        local active = PruneAndGetActiveHistory()
        for _, entry in ipairs(active) do
            if entry.zoneUID == zoneUID then
                currentSessionEntry = entry
                UpdateDisplay()
                if UpdateHistoryWindow then UpdateHistoryWindow() end
                return
            end
        end
        local name, _, difficultyID, difficultyName, _, _, _, instanceMapID = GetInstanceInfo()
        RecordNewInstance(name, instanceMapID, difficultyID, difficultyName, currentZoneInTime or time(), zoneUID)
    end
end

if type(ResetInstances) == "function" and hooksecurefunc then
    hooksecurefunc("ResetInstances", function()
        pendingReset = true
    end)
end

--------------------------------------------------------------------------------
-- Options Panel Widgets (Sliders, Scrollable Dropdowns & Color Picker)
--------------------------------------------------------------------------------
local function CreateElvSlider(parent, label, minVal, maxVal, step, formatFunc, getVal, setVal, onAfterChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(230, 38)

    local title = container:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(title, 11)
    title:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    title:SetTextColor(0.9, 0.9, 0.9, 1)
    title:SetText(label)

    local valText = container:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(valText, 11)
    valText:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)

    local slider = CreateFrame("Slider", nil, container)
    slider:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -16)
    slider:SetSize(230, 12)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    SkinElvFrame(slider, { 0.07, 0.07, 0.07, 1 }, ELV_BORDER)

    local fill = slider:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", slider, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", slider, "BOTTOMLEFT", 1, 1)

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(8, 14)
    thumb:SetColorTexture(0.85, 0.85, 0.85, 1)
    slider:SetThumbTexture(thumb)

    local function UpdateVisuals(v)
        local r, g, b = GetAccentColor()
        ApplyConfiguredFont(title, 11)
        ApplyConfiguredFont(valText, 11)
        valText:SetTextColor(r, g, b, 1)
        fill:SetColorTexture(r, g, b, 0.78)

        local frac = math.min(1, math.max(0, (v - minVal) / math.max(0.0001, (maxVal - minVal))))
        fill:SetWidth(math.max(1, 228 * frac))
        valText:SetText(formatFunc(v))
    end

    slider:SetScript("OnShow", function(self)
        local v = getVal()
        self:SetValue(v)
        UpdateVisuals(v)
    end)

    slider:SetScript("OnValueChanged", function(_, value)
        CloseActiveDropdown()
        local inv = 1 / step
        value = math.floor(value * inv + 0.5) / inv
        setVal(value)
        UpdateVisuals(value)
        ApplyLayout()
        UpdateDisplay()
        if onAfterChange then onAfterChange(value) end
    end)

    slider:SetScript("OnEnter", function(self)
        local r, g, b = GetAccentColor()
        SetElvBorder(self, r, g, b, 1)
    end)

    slider:SetScript("OnLeave", function(self)
        SetElvBorder(self, ELV_BORDER[1], ELV_BORDER[2], ELV_BORDER[3], 1)
    end)

    RegisterThemeCallback(function()
        UpdateVisuals(getVal())
    end)

    return container
end

local function CreateElvDropdown(parent, label, width, previewType, getItems, getSelectedName, onSelect)
    local MAX_VISIBLE_ROWS = 10
    local ROW_HEIGHT = 22
    local dropdownWidth = width or 230

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(dropdownWidth, 42)

    local title = container:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(title, 11)
    title:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    title:SetTextColor(0.9, 0.9, 0.9, 1)
    title:SetText(label)

    local button = CreateFrame("Button", nil, container)
    button:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -15)
    button:SetSize(dropdownWidth, 24)
    SkinElvFrame(button, ELV_WIDGET_BG, ELV_BORDER)

    local previewTex = button:CreateTexture(nil, "ARTWORK")
    previewTex:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    previewTex:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -24, 2)
    previewTex:Hide()

    local selectedText = button:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(selectedText, 11)
    selectedText:SetPoint("LEFT", button, "LEFT", 8, 0)
    selectedText:SetPoint("RIGHT", button, "RIGHT", -22, 0)
    selectedText:SetJustifyH("LEFT")
    selectedText:SetTextColor(0.95, 0.95, 0.95, 1)

    local arrow = button:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(arrow, 10)
    arrow:SetPoint("RIGHT", button, "RIGHT", -6, 0)
    arrow:SetText("v")

    local menu = CreateFrame("Frame", nil, UIParent)
    menu:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2)
    menu:SetWidth(dropdownWidth)
    menu:SetFrameStrata("TOOLTIP")
    menu:SetFrameLevel(120)
    menu:EnableMouse(true)
    menu:EnableMouseWheel(true)
    SkinElvFrame(menu, { 0.09, 0.09, 0.09, 0.98 }, ELV_BORDER)
    menu:Hide()

    button:SetScript("OnHide", function()
        menu:Hide()
    end)

    local scrollBar = CreateFrame("Slider", nil, menu)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -2, -2)
    scrollBar:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -2, 2)
    scrollBar:SetWidth(10)
    scrollBar:SetValueStep(1)
    scrollBar:SetObeyStepOnDrag(true)
    SkinElvFrame(scrollBar, { 0.05, 0.05, 0.05, 1 }, ELV_BORDER)

    local scrollThumb = scrollBar:CreateTexture(nil, "OVERLAY")
    scrollThumb:SetSize(8, 28)
    scrollBar:SetThumbTexture(scrollThumb)

    local rows = {}
    local currentItems = {}
    local scrollOffset = 0
    local isUpdatingScroll = false

    local function RefreshButtonDisplay()
        local r, g, b = GetAccentColor()
        ApplyConfiguredFont(title, 11)
        ApplyConfiguredFont(selectedText, 11)
        ApplyConfiguredFont(arrow, 10)
        arrow:SetTextColor(r, g, b, 1)
        SetElvBorder(menu, r, g, b, 1)
        scrollThumb:SetColorTexture(r, g, b, 0.85)

        selectedText:SetText(getSelectedName() or "")
        if previewType == "texture" then
            previewTex:SetTexture(ResolveTexturePath())
            previewTex:SetVertexColor(0.45, 0.45, 0.45, 0.65)
            previewTex:Show()
        else
            previewTex:Hide()
        end
    end

    local function UpdateVisibleRows()
        local r, g, b = GetAccentColor()
        local total = #currentItems
        local visibleRows = math.min(total, MAX_VISIBLE_ROWS)
        local rightPad = (total > MAX_VISIBLE_ROWS) and -14 or -2
        local selectedName = getSelectedName()

        for i = 1, MAX_VISIBLE_ROWS do
            local row = rows[i]
            local item = (i <= visibleRows) and currentItems[i + scrollOffset] or nil
            if item then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", menu, "TOPLEFT", 2, -2 - ((i - 1) * ROW_HEIGHT))
                row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", rightPad, -2 - ((i - 1) * ROW_HEIGHT))

                if previewType == "texture" and item.path then
                    row.texPreview:SetTexture(item.path)
                    row.texPreview:SetVertexColor(0.55, 0.55, 0.55, 0.65)
                    row.texPreview:Show()
                    ApplyConfiguredFont(row.label, 11)
                elseif previewType == "font" and item.path then
                    row.texPreview:Hide()
                    if not row.label:SetFont(item.path, 12, db and db.fontOutline or "OUTLINE") then
                        ApplyConfiguredFont(row.label, 11)
                    end
                else
                    row.texPreview:Hide()
                    ApplyConfiguredFont(row.label, 11)
                end

                row.label:SetText(item.name)
                if item.name == selectedName then
                    row.label:SetTextColor(r, g, b, 1)
                else
                    row.label:SetTextColor(0.92, 0.92, 0.92, 1)
                end

                row:SetScript("OnClick", function()
                    onSelect(item)
                    menu:Hide()
                    RefreshTheme()
                end)

                row:Show()
            elseif row then
                row:Hide()
            end
        end
    end

    local function SetScrollOffset(newOffset)
        local maxOffset = math.max(0, #currentItems - MAX_VISIBLE_ROWS)
        scrollOffset = math.max(0, math.min(maxOffset, math.floor(newOffset + 0.5)))
        isUpdatingScroll = true
        scrollBar:SetValue(scrollOffset)
        isUpdatingScroll = false
        UpdateVisibleRows()
    end

    scrollBar:SetScript("OnValueChanged", function(_, value)
        if isUpdatingScroll then return end
        SetScrollOffset(value)
    end)

    local function OnMenuMouseWheel(_, delta)
        if #currentItems <= MAX_VISIBLE_ROWS then return end
        SetScrollOffset(scrollOffset - (delta * 2))
    end

    menu:SetScript("OnMouseWheel", OnMenuMouseWheel)
    scrollBar:EnableMouseWheel(true)
    scrollBar:SetScript("OnMouseWheel", OnMenuMouseWheel)

    for i = 1, MAX_VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, menu)
        row:SetHeight(ROW_HEIGHT)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", OnMenuMouseWheel)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints(row)
        row.bg:SetColorTexture(0.12, 0.12, 0.12, 0)

        row.texPreview = row:CreateTexture(nil, "ARTWORK")
        row.texPreview:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -2)
        row.texPreview:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 2)
        row.texPreview:Hide()

        row.label = row:CreateFontString(nil, "OVERLAY")
        row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.label:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        row.label:SetJustifyH("LEFT")

        row:SetScript("OnEnter", function(self)
            local r, g, b = GetAccentColor()
            self.bg:SetColorTexture(r, g, b, 0.35)
        end)
        row:SetScript("OnLeave", function(self)
            self.bg:SetColorTexture(0.12, 0.12, 0.12, 0)
        end)

        rows[i] = row
    end

    local function RebuildMenu()
        RefreshButtonDisplay()
        currentItems = getItems() or {}
        local total = #currentItems
        local visibleRows = math.min(total, MAX_VISIBLE_ROWS)
        menu:SetHeight(math.max(28, visibleRows * ROW_HEIGHT + 4))

        local maxOffset = math.max(0, total - MAX_VISIBLE_ROWS)
        if maxOffset > 0 then
            scrollBar:SetMinMaxValues(0, maxOffset)
            scrollBar:Show()
        else
            scrollBar:SetMinMaxValues(0, 0)
            scrollBar:Hide()
        end

        local selectedName = getSelectedName()
        local startOffset = 0
        if selectedName and maxOffset > 0 then
            for idx, item in ipairs(currentItems) do
                if item.name == selectedName then
                    startOffset = math.max(0, math.min(maxOffset, idx - math.floor(MAX_VISIBLE_ROWS / 2)))
                    break
                end
            end
        end

        SetScrollOffset(startOffset)
    end

    button:SetScript("OnShow", RefreshButtonDisplay)
    button:SetScript("OnEnter", function(self)
        local r, g, b = GetAccentColor()
        SetElvBorder(self, r, g, b, 1)
    end)
    button:SetScript("OnLeave", function(self)
        SetElvBorder(self, ELV_BORDER[1], ELV_BORDER[2], ELV_BORDER[3], 1)
    end)
    button:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            CloseActiveDropdown()
            RebuildMenu()
            activeDropdownMenu = menu
            menu:Show()
        end
    end)

    RegisterThemeCallback(RefreshButtonDisplay)

    return container
end

local function OpenAccentColorPicker()
    if not db then return end
    CloseActiveDropdown()

    local prevR = db.accentR or DEFAULT_ACCENT.r
    local prevG = db.accentG or DEFAULT_ACCENT.g
    local prevB = db.accentB or DEFAULT_ACCENT.b

    local function ApplyPickedColor()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        if nr and ng and nb then
            db.useClassColor = false
            db.accentR, db.accentG, db.accentB = nr, ng, nb
            RefreshTheme()
        end
    end

    local function CancelPickedColor()
        db.accentR, db.accentG, db.accentB = prevR, prevG, prevB
        RefreshTheme()
    end

    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({
            r = prevR,
            g = prevG,
            b = prevB,
            hasOpacity = false,
            swatchFunc = ApplyPickedColor,
            cancelFunc = CancelPickedColor,
        })
    else
        ColorPickerFrame:Hide()
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.func = ApplyPickedColor
        ColorPickerFrame.cancelFunc = CancelPickedColor
        ColorPickerFrame:SetColorRGB(prevR, prevG, prevB)
        ColorPickerFrame:Show()
    end
end

--------------------------------------------------------------------------------
-- ElvUI-Skinned Options Panel Construction
--------------------------------------------------------------------------------
local optionsPanel
local function CreateOptionsPanel()
    if optionsPanel then return optionsPanel end

    optionsPanel = CreateFrame("Frame", "InstanceHistoryOptionsPanel", UIParent)
    optionsPanel.name = "InstanceHistory"

    local canvas = CreateFrame("Frame", nil, optionsPanel)
    canvas:SetPoint("TOPLEFT", optionsPanel, "TOPLEFT", 4, -4)
    canvas:SetPoint("BOTTOMRIGHT", optionsPanel, "BOTTOMRIGHT", -4, 4)
    SkinElvFrame(canvas, ELV_BG, ELV_BORDER)

    local title = canvas:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(title, 16)
    title:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, -16)

    local subtitle = canvas:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(subtitle, 11)
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetTextColor(0.7, 0.7, 0.7, 1)
    subtitle:SetText("Hourly instance lock tracker (5/hr cap), full run log (/ih history) & reset announcer.")

    local headerLine = canvas:CreateTexture(nil, "ARTWORK")
    headerLine:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -8)
    headerLine:SetPoint("RIGHT", canvas, "RIGHT", -16, 0)
    headerLine:SetHeight(1)

    local col1Header = canvas:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(col1Header, 12)
    col1Header:SetPoint("TOPLEFT", headerLine, "BOTTOMLEFT", 0, -12)
    col1Header:SetText("General & Visibility")

    local function OptCheckbox(label, tooltip, getVal, setVal, extraFn)
        return CreateElvCheckbox(canvas, label, tooltip, getVal, setVal, function(val)
            ApplyLayout()
            UpdateDisplay()
            if extraFn then extraFn(val) end
        end)
    end

    local cb1 = OptCheckbox(
        "Lock Bar Tracker Position",
        "Locks the 1-hour bar tracker in place. Uncheck to drag it anywhere on screen.",
        function() return db.locked end,
        function(v) db.locked = v end
    )
    cb1:SetPoint("TOPLEFT", col1Header, "BOTTOMLEFT", 0, -8)

    local cbHistLock = OptCheckbox(
        "Lock History Window (/ih history)",
        "Locks the Full Dungeon History window so it cannot be dragged or resized.",
        function() return db.histLocked end,
        function(v) db.histLocked = v end,
        function()
            if histFrame and histFrame.lockHistCB then
                histFrame.lockHistCB:Refresh()
            end
            if UpdateHistoryWindow then UpdateHistoryWindow() end
        end
    )
    cbHistLock:SetPoint("TOPLEFT", cb1, "BOTTOMLEFT", 0, -5)
    optHistLockCB = cbHistLock

    local cbMinimap = OptCheckbox(
        "Show Minimap Button",
        "Displays a draggable minimap button. Left-Click to toggle the History window, Right-Click to open Options.",
        function() return db.showMinimap end,
        function(v) db.showMinimap = v end,
        function()
            if UpdateMinimapButton then UpdateMinimapButton() end
        end
    )
    cbMinimap:SetPoint("TOPLEFT", cbHistLock, "BOTTOMLEFT", 0, -5)
    optMinimapCB = cbMinimap

    local cb2 = OptCheckbox(
        "Only Show at Max Level (Level 60)",
        "Hides the tracker unless the current character is level 60.",
        function() return db.onlyMaxLevel end,
        function(v) db.onlyMaxLevel = v end
    )
    cb2:SetPoint("TOPLEFT", cbMinimap, "BOTTOMLEFT", 0, -5)

    local cb3 = OptCheckbox(
        "Only Show in a Group",
        "Hides the tracker unless you are in a party or raid.",
        function() return db.onlyInGroup end,
        function(v) db.onlyInGroup = v end
    )
    cb3:SetPoint("TOPLEFT", cb2, "BOTTOMLEFT", 0, -5)

    local cb4 = OptCheckbox(
        "Notify When Approaching Instance Cap",
        "Displays 'You are nearing the instances per hour limit.' when you enter your 4th instance within the hour.",
        function() return db.notifyNearLimit end,
        function(v) db.notifyNearLimit = v end
    )
    cb4:SetPoint("TOPLEFT", cb3, "BOTTOMLEFT", 0, -5)

    local cb5 = OptCheckbox(
        "Announce Resets to Party / Raid",
        "Automatically sends a chat message to party or raid when you reset an instance (like SavedInstances).",
        function() return db.announceReset end,
        function(v) db.announceReset = v end
    )
    cb5:SetPoint("TOPLEFT", cb4, "BOTTOMLEFT", 0, -5)

    local cb6 = OptCheckbox(
        "Always Show Expiry Countdown Line",
        "Shows 'More instances will be available in X Mins Y Secs.' based on your oldest instance lock.",
        function() return db.alwaysShowTimer end,
        function(v) db.alwaysShowTimer = v end
    )
    cb6:SetPoint("TOPLEFT", cb5, "BOTTOMLEFT", 0, -5)

    local cb7 = OptCheckbox(
        "Track Account-Wide History",
        "Combines recent instance history across all characters on this account instead of only the current character.",
        function() return db.accountWide end,
        function(v) db.accountWide = v end
    )
    cb7:SetPoint("TOPLEFT", cb6, "BOTTOMLEFT", 0, -5)

    local cb8 = OptCheckbox(
        "Show Mouseover Tooltip",
        "Displays individual dungeon names and expiration timers when hovering over the bar.",
        function() return db.showTooltip end,
        function(v) db.showTooltip = v end
    )
    cb8:SetPoint("TOPLEFT", cb7, "BOTTOMLEFT", 0, -5)

    local minSlider = CreateElvSlider(
        canvas,
        "Minimum Instances to Show",
        0, 5, 1,
        tostring,
        function() return db.minInstancesToShow or 1 end,
        function(v) db.minInstancesToShow = v end
    )
    minSlider:SetPoint("TOPLEFT", cb8, "BOTTOMLEFT", 0, -10)

    local scaleSlider = CreateElvSlider(
        canvas,
        "Frame Scale",
        0.5, 2.0, 0.05,
        function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end,
        function() return db.scale or 1.0 end,
        function(v) db.scale = v end
    )
    scaleSlider:SetPoint("TOPLEFT", minSlider, "BOTTOMLEFT", 0, -6)

    -- Right Column: Appearance, Media & Theme Color
    local col2Header = canvas:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(col2Header, 12)
    col2Header:SetPoint("TOPLEFT", headerLine, "BOTTOMLEFT", 310, -12)
    col2Header:SetText("Appearance & Media")

    local texDropdown = CreateElvDropdown(
        canvas,
        "Bar Texture",
        230,
        "texture",
        GetTextureList,
        function() return db.barTextureName or "Blizzard" end,
        function(item)
            db.barTextureName = item.name
            db.barTexturePath = item.path
        end
    )
    texDropdown:SetPoint("TOPLEFT", col2Header, "BOTTOMLEFT", 0, -8)

    local fontDropdown = CreateElvDropdown(
        canvas,
        "Font",
        230,
        "font",
        GetFontList,
        function() return db.fontName or "Friz Quadrata TT" end,
        function(item)
            db.fontName = item.name
            db.fontPath = item.path
        end
    )
    fontDropdown:SetPoint("TOPLEFT", texDropdown, "BOTTOMLEFT", 0, -6)

    local outlineDropdown = CreateElvDropdown(
        canvas,
        "Font Outline",
        230,
        "none",
        function() return outlineOptions end,
        function()
            local cur = db.fontOutline or "OUTLINE"
            for _, opt in ipairs(outlineOptions) do
                if opt.value == cur then
                    return opt.name
                end
            end
            return "Outline"
        end,
        function(item)
            db.fontOutline = item.value
        end
    )
    outlineDropdown:SetPoint("TOPLEFT", fontDropdown, "BOTTOMLEFT", 0, -6)

    local fontSizeSlider = CreateElvSlider(
        canvas,
        "Font Size",
        8, 24, 1,
        function(v) return tostring(v) .. " pt" end,
        function() return db.fontSize or 12 end,
        function(v) db.fontSize = v end
    )
    fontSizeSlider:SetPoint("TOPLEFT", outlineDropdown, "BOTTOMLEFT", 0, -8)

    local widthSlider = CreateElvSlider(
        canvas,
        "Bar Width",
        160, 450, 2,
        function(v) return tostring(v) .. " px" end,
        function() return db.barWidth or 260 end,
        function(v) db.barWidth = v end
    )
    widthSlider:SetPoint("TOPLEFT", fontSizeSlider, "BOTTOMLEFT", 0, -6)

    local heightSlider = CreateElvSlider(
        canvas,
        "Bar Height",
        8, 36, 1,
        function(v) return tostring(v) .. " px" end,
        function() return db.barHeight or 16 end,
        function(v) db.barHeight = v end
    )
    heightSlider:SetPoint("TOPLEFT", widthSlider, "BOTTOMLEFT", 0, -6)

    local cbClassColor = CreateElvCheckbox(
        canvas,
        "Use Class Color",
        "Dynamically colors all UI accent elements using the class color of the currently logged-in character.",
        function() return db.useClassColor end,
        function(v) db.useClassColor = v end,
        RefreshTheme
    )
    cbClassColor:SetPoint("TOPLEFT", heightSlider, "BOTTOMLEFT", 0, -8)

    local swatchBtn = CreateFrame("Button", nil, canvas)
    swatchBtn:SetSize(145, 22)
    swatchBtn:SetPoint("TOPLEFT", cbClassColor, "BOTTOMLEFT", 0, -6)
    SkinElvFrame(swatchBtn, ELV_WIDGET_BG, ELV_BORDER)

    local swatchBox = CreateFrame("Frame", nil, swatchBtn)
    swatchBox:SetSize(14, 14)
    swatchBox:SetPoint("LEFT", swatchBtn, "LEFT", 5, 0)
    SkinElvFrame(swatchBox, ELV_WIDGET_BG, ELV_BORDER)

    local swatchFill = swatchBox:CreateTexture(nil, "ARTWORK")
    swatchFill:SetPoint("TOPLEFT", swatchBox, "TOPLEFT", 1, -1)
    swatchFill:SetPoint("BOTTOMRIGHT", swatchBox, "BOTTOMRIGHT", -1, 1)

    local swatchLabel = swatchBtn:CreateFontString(nil, "OVERLAY")
    ApplyConfiguredFont(swatchLabel, 11)
    swatchLabel:SetPoint("LEFT", swatchBox, "RIGHT", 6, 0)
    swatchLabel:SetTextColor(0.92, 0.92, 0.92, 1)
    swatchLabel:SetText("Pick Accent Color")

    swatchBtn:SetScript("OnEnter", function(self)
        local r, g, b = GetAccentColor()
        SetElvBorder(self, r, g, b, 1)
        swatchLabel:SetTextColor(r, g, b, 1)
    end)
    swatchBtn:SetScript("OnLeave", function(self)
        SetElvBorder(self, ELV_BORDER[1], ELV_BORDER[2], ELV_BORDER[3], 1)
        swatchLabel:SetTextColor(0.92, 0.92, 0.92, 1)
    end)
    swatchBtn:SetScript("OnClick", OpenAccentColorPicker)

    local resetColBtn = CreateElvButton(canvas, "Default", 80, 22, function()
        db.useClassColor = false
        db.accentR = DEFAULT_ACCENT.r
        db.accentG = DEFAULT_ACCENT.g
        db.accentB = DEFAULT_ACCENT.b
        cbClassColor:Refresh()
        RefreshTheme()
    end)
    resetColBtn:SetPoint("LEFT", swatchBtn, "RIGHT", 5, 0)

    -- Bottom Action Buttons
    local openHistBtn = CreateElvButton(canvas, "Full History (/ih history)", 155, 24, ToggleHistoryWindow)
    openHistBtn:SetPoint("BOTTOMLEFT", canvas, "BOTTOMLEFT", 16, 14)

    local resetPosBtn = CreateElvButton(canvas, "Reset Bar Pos", 115, 24, ResetBarPosition)
    resetPosBtn:SetPoint("LEFT", openHistBtn, "RIGHT", 8, 0)

    local clearBtn = CreateElvButton(canvas, "Clear 1h Locks", 115, 24, ClearActiveHistory)
    clearBtn:SetPoint("LEFT", resetPosBtn, "RIGHT", 8, 0)

    local testWarnBtn = CreateElvButton(canvas, "Test 4/5 Warning", 125, 24, function()
        TriggerLimitNotification(4)
    end)
    testWarnBtn:SetPoint("LEFT", clearBtn, "RIGHT", 8, 0)

    local function RefreshOptionsTheme()
        local r, g, b, hex = GetAccentColor()
        ApplyConfiguredFont(title, 16)
        ApplyConfiguredFont(subtitle, 11)
        ApplyConfiguredFont(col1Header, 12)
        ApplyConfiguredFont(col2Header, 12)
        ApplyConfiguredFont(swatchLabel, 11)

        title:SetText(string.format("|cff%sInstance|rHistory", hex))
        headerLine:SetColorTexture(r, g, b, 0.85)
        col1Header:SetTextColor(r, g, b, 1)
        col2Header:SetTextColor(r, g, b, 1)
        swatchFill:SetColorTexture(r, g, b, 1)
        cbClassColor:Refresh()
    end

    RegisterThemeCallback(RefreshOptionsTheme)
    RefreshOptionsTheme()

    optionsPanel:SetScript("OnHide", CloseActiveDropdown)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(optionsPanel, optionsPanel.name)
        Settings.RegisterAddOnCategory(category)
        optionsPanel.categoryID = category:GetID()
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(optionsPanel)
    end

    return optionsPanel
end

OpenOptions = function()
    CreateOptionsPanel()
    if Settings and Settings.OpenToCategory and optionsPanel.categoryID then
        Settings.OpenToCategory(optionsPanel.categoryID)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    end
end

--------------------------------------------------------------------------------
-- Events & Slash Commands
--------------------------------------------------------------------------------
local EVENTS = {
    "ADDON_LOADED",
    "PLAYER_ENTERING_WORLD",
    "ZONE_CHANGED_NEW_AREA",
    "PLAYER_LEVEL_UP",
    "GROUP_ROSTER_UPDATE",
    "CHAT_MSG_SYSTEM",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_ADDON",
    "NAME_PLATE_UNIT_ADDED",
    "PLAYER_TARGET_CHANGED",
    "UPDATE_MOUSEOVER_UNIT",
}
for _, ev in ipairs(EVENTS) do
    frame:RegisterEvent(ev)
end

local GROUP_CHAT_EVENTS = {
    CHAT_MSG_PARTY = true,
    CHAT_MSG_PARTY_LEADER = true,
    CHAT_MSG_RAID = true,
    CHAT_MSG_RAID_LEADER = true,
    CHAT_MSG_INSTANCE_CHAT = true,
    CHAT_MSG_INSTANCE_CHAT_LEADER = true,
}

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName == addonName then
            InstanceHistoryDB = InstanceHistoryDB or {}
            db = InstanceHistoryDB
            for k, v in pairs(defaults) do
                if db[k] == nil then
                    db[k] = (type(v) == "table") and {} or v
                end
            end
            charKey = GetCharKey()
            table.sort(db.history, SortByEntryTime)

            local _, playerClass = UnitClass("player")
            local playerLevel = UnitLevel("player") or 0

            if #db.fullHistory == 0 and #db.history > 0 then
                for _, entry in ipairs(db.history) do
                    local isSelf = (entry.char == charKey)
                    table.insert(db.fullHistory, CloneEntry(entry, isSelf and playerClass or nil, isSelf and playerLevel or nil))
                end
            end

            if playerClass then
                for _, fe in ipairs(db.fullHistory) do
                    if fe.char == charKey and not fe.class then
                        fe.class = playerClass
                    end
                end
            end

            if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
                C_ChatInfo.RegisterAddonMessagePrefix("InstHist")
            end
            CreateOptionsPanel()
            CreateHistoryWindow()
            CreateMinimapButton()
            RefreshTheme()
        end

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        if db and db.useClassColor then
            RefreshTheme()
        end
        CheckInstanceStatus()

    elseif event == "PLAYER_LEVEL_UP" or event == "GROUP_ROSTER_UPDATE" then
        UpdateDisplay()

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if not msg then return end

        if PAT_RESET_SUCCESS and msg:match(PAT_RESET_SUCCESS) then
            pendingReset = true
            local channel = GetGroupChatChannel()
            if channel and C_ChatInfo and C_ChatInfo.SendAddonMessage then
                C_ChatInfo.SendAddonMessage("InstHist", "RESET", channel)
            end
            if db and db.announceReset then
                SendGroupChat(msg)
            end
        elseif db and db.announceReset and db.announceFailed then
            if (PAT_RESET_FAILED and msg:match(PAT_RESET_FAILED))
                or (PAT_RESET_OFFLINE and msg:match(PAT_RESET_OFFLINE))
                or (PAT_RESET_ZONING and msg:match(PAT_RESET_ZONING)) then
                SendGroupChat(msg)
            end
        end

    elseif GROUP_CHAT_EVENTS[event] then
        local msg, sender = ...
        if not msg then return end
        local shortSender = sender and Ambiguate(sender, "none") or nil
        if shortSender ~= UnitName("player") then
            if (PAT_RESET_SUCCESS_LOOSE and msg:match(PAT_RESET_SUCCESS_LOOSE)) or msg:lower():find("has been reset", 1, true) then
                pendingReset = true
            end
        end

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, _, sender = ...
        if prefix == "InstHist" and text == "RESET" then
            local shortSender = sender and Ambiguate(sender, "none") or nil
            if shortSender ~= UnitName("player") then
                pendingReset = true
            end
        end

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local unit = ...
        if unit then VerifyGUIDZoneUID(UnitGUID(unit)) end

    elseif event == "PLAYER_TARGET_CHANGED" then
        if UnitExists("target") then VerifyGUIDZoneUID(UnitGUID("target")) end

    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        if UnitExists("mouseover") then VerifyGUIDZoneUID(UnitGUID("mouseover")) end
    end
end)

SLASH_INSTANCEHISTORY1 = "/ih"
SLASH_INSTANCEHISTORY2 = "/instancehistory"
SlashCmdList["INSTANCEHISTORY"] = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")
    if cmd == "history" or cmd == "log" then
        ToggleHistoryWindow()
    elseif cmd == "minimap" or cmd == "mm" then
        db.showMinimap = not db.showMinimap
        if optMinimapCB then optMinimapCB:Refresh() end
        if UpdateMinimapButton then UpdateMinimapButton() end
        PrintAddonMsg(string.format("Minimap button is now %s.", db.showMinimap and "|cff55ff55Shown|r" or "|cffff5555Hidden|r"))
    elseif cmd == "histlock" then
        db.histLocked = not db.histLocked
        if optHistLockCB then optHistLockCB:Refresh() end
        if histFrame and histFrame.lockHistCB then histFrame.lockHistCB:Refresh() end
        if UpdateHistoryWindow then UpdateHistoryWindow() end
        PrintAddonMsg(string.format("History window is now %s.", db.histLocked and "|cffff5555Locked|r" or "|cff55ff55Unlocked|r"))
    elseif cmd == "lock" or cmd == "unlock" then
        db.locked = not db.locked
        RefreshTheme()
        PrintAddonMsg(string.format("Bar tracker is now %s.", db.locked and "|cffff5555Locked|r" or "|cff55ff55Unlocked|r"))
    elseif cmd == "level" or cmd == "maxlevel" then
        db.onlyMaxLevel = not db.onlyMaxLevel
        RefreshTheme()
        PrintAddonMsg(string.format("Only show at Level 60: %s", db.onlyMaxLevel and "|cff55ff55ON|r" or "|cffff5555OFF|r"))
    elseif cmd == "group" then
        db.onlyInGroup = not db.onlyInGroup
        RefreshTheme()
        PrintAddonMsg(string.format("Only show in a Group: %s", db.onlyInGroup and "|cff55ff55ON|r" or "|cffff5555OFF|r"))
    elseif cmd == "announce" then
        db.announceReset = not db.announceReset
        RefreshTheme()
        PrintAddonMsg(string.format("Announce resets to Party/Raid: %s", db.announceReset and "|cff55ff55ON|r" or "|cffff5555OFF|r"))
    elseif cmd == "classcolor" then
        db.useClassColor = not db.useClassColor
        RefreshTheme()
        PrintAddonMsg(string.format("Use Class Color: %s", db.useClassColor and "|cff55ff55ON|r" or "|cffff5555OFF|r"))
    elseif cmd == "test" or cmd == "warn" then
        TriggerLimitNotification(4)
    elseif cmd == "reset" then
        ResetBarPosition()
        PrintAddonMsg("Position reset to center.")
    elseif cmd == "clear" then
        ClearActiveHistory()
        PrintAddonMsg("1-hour instance lock history cleared.")
    else
        OpenOptions()
    end
end