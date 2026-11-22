-- Buff Sentinel: move the bars from Blizzard's Edit Mode.
--
-- Same approach as SealTwister and HealKit: while Edit Mode is open, the bars
-- show a preview with Blizzard's own selection-box art over them, and dragging
-- that box moves them. Nothing here writes into Edit Mode (Buff Sentinel is not one
-- of its systems and is not saved in its layouts), because writing into it
-- taints Blizzard's layout saving. Only hooks and our own frames.
local _, ns = ...

if not EditModeManagerFrame then return end

local HIGHLIGHT, SELECTED = "editmode-actionbar-highlight-nineslice", "editmode-actionbar-selected-nineslice"
local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end
if not HasAtlas(HIGHLIGHT .. "-corner") then return end -- no Edit Mode art: /bsent unlock still works
local HAS_SELECTED = HasAtlas(SELECTED .. "-corner")

local function Corner(tex, atlas, flipX, flipY)
    local i = C_Texture.GetAtlasInfo(atlas)
    if not i then return end
    local l, r, t, b = i.leftTexCoord, i.rightTexCoord, i.topTexCoord, i.bottomTexCoord
    if flipX then l, r = r, l end
    if flipY then t, b = b, t end
    tex:SetTexture(i.file or i.filename)
    tex:SetTexCoord(l, r, t, b)
end

-- One nine-slice in Blizzard's Edit Mode art: 16x16 corners, tiled edges, a filled centre.
local function NineSlice(box, sub)
    local t = {}
    local function Tex() return box:CreateTexture(nil, "BORDER", nil, sub) end
    for _, c in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }) do
        t[c] = Tex()
        t[c]:SetSize(16, 16)
        t[c]:SetPoint(c)
    end
    t.top, t.bottom, t.left, t.right, t.center = Tex(), Tex(), Tex(), Tex(), Tex()
    t.top:SetPoint("TOPLEFT", t.TOPLEFT, "TOPRIGHT")
    t.top:SetPoint("BOTTOMRIGHT", t.TOPRIGHT, "BOTTOMLEFT")
    t.bottom:SetPoint("TOPLEFT", t.BOTTOMLEFT, "TOPRIGHT")
    t.bottom:SetPoint("BOTTOMRIGHT", t.BOTTOMRIGHT, "BOTTOMLEFT")
    t.left:SetPoint("TOPLEFT", t.TOPLEFT, "BOTTOMLEFT")
    t.left:SetPoint("BOTTOMRIGHT", t.BOTTOMLEFT, "TOPRIGHT")
    t.right:SetPoint("TOPLEFT", t.TOPRIGHT, "BOTTOMLEFT")
    t.right:SetPoint("BOTTOMRIGHT", t.BOTTOMRIGHT, "TOPRIGHT")
    t.center:SetPoint("TOPLEFT", 8, -8)
    t.center:SetPoint("BOTTOMRIGHT", -8, 8)
    function t:Paint(art)
        Corner(self.TOPLEFT, art .. "-corner", false, false)
        Corner(self.TOPRIGHT, art .. "-corner", true, false)
        Corner(self.BOTTOMLEFT, art .. "-corner", false, true)
        Corner(self.BOTTOMRIGHT, art .. "-corner", true, true)
        self.top:SetAtlas("_" .. art .. "-edgetop")
        self.bottom:SetAtlas("_" .. art .. "-edgebottom")
        self.left:SetAtlas("!" .. art .. "-edgeleft")
        self.right:SetAtlas("!" .. art .. "-edgeright")
        self.center:SetAtlas(art .. "-center")
    end
    function t:SetShown(on)
        for _, x in pairs(self) do
            if type(x) == "table" and x.SetShown then x:SetShown(on) end
        end
    end
    return t
end

local box
local moving

local function CreateBox()
    local target = ns.frame
    if box or not target then return box end

    box = CreateFrame("Frame", nil, UIParent)
    box:SetFrameStrata("HIGH")
    -- pinned to the bars, so it rides along during a drag
    box:SetPoint("TOPLEFT", target, "TOPLEFT", -6, 6)
    box:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 6, -6)
    box.art = NineSlice(box, 0)
    box.art:Paint(HIGHLIGHT)
    box.hover = NineSlice(box, 1)
    box.hover:Paint(HIGHLIGHT)
    box.hover:SetShown(false)

    local label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    label:SetPoint("CENTER")
    label:SetWordWrap(false)
    label:SetText("Buff Sentinel")
    label:Hide()

    local function Lit(on)
        box.hover:SetShown(on)
        label:SetShown(on)
        if on then
            GameTooltip:SetOwner(box, "ANCHOR_CURSOR_RIGHT", 12, 4)
            GameTooltip:SetText("Buff Sentinel", NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
            GameTooltip:AddLine("Drag to move the buff bars.", 1, 1, 1, true)
            GameTooltip:Show()
        elseif GameTooltip:IsOwned(box) then
            GameTooltip:Hide()
        end
    end

    box:EnableMouse(true)
    box:RegisterForDrag("LeftButton")
    box:SetScript("OnEnter", function() Lit(true) end)
    box:SetScript("OnLeave", function() if not moving then Lit(false) end end)
    box:SetScript("OnDragStart", function()
        if InCombatLockdown() then return end
        moving = true
        if HAS_SELECTED then box.art:Paint(SELECTED) box.hover:Paint(SELECTED) end
        target:StartMoving()
    end)
    box:SetScript("OnDragStop", function()
        moving = nil
        ns.StopMoving()
        box.art:Paint(HIGHLIGHT) box.hover:Paint(HIGHLIGHT)
        Lit(box:IsMouseOver())
    end)
    box:Hide()
    return box
end

local function StopDrag()
    if moving then
        moving = nil
        ns.StopMoving()
    end
end

-- Shows or hides the box and the preview to match Edit Mode.
local function Sync()
    local ok, err = pcall(function()
        ns.editMode = EditModeManagerFrame:IsShown() and not InCombatLockdown() or nil
        if not ns.db then return end -- not logged in yet
        local b = CreateBox()
        if b then b:SetShown(ns.editMode == true) end
        if not ns.editMode then StopDrag() end
        ns.Update()
    end)
    if not ok then ns.Print("Edit Mode: " .. tostring(err)) end
end

EditModeManagerFrame:HookScript("OnShow", Sync)
EditModeManagerFrame:HookScript("OnHide", Sync)

-- Nothing moves in combat: the box goes away and comes back afterwards.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event)
    if not EditModeManagerFrame:IsShown() then return end
    if event == "PLAYER_REGEN_DISABLED" then
        if box then box:Hide() end
        StopDrag()
        ns.editMode = nil
        ns.Update()
    else
        C_Timer.After(0.2, Sync)
    end
end)
