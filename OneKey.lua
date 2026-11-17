-- FishLog: OneKey.lua
--
-- One-key fishing. Pick a key with /fishlog key; while a Fishing Pole is in
-- your hands that key does the next fishing step:
--   loot   a loot window is open (Auto Loot off): takes everything
--   reel   the bobber is your interact target: clicks it (Interact Key)
--   cast   anything else: casts Fishing
-- You still press the key for every step: addons get no signal when a fish
-- bites, so the splash (FishLog's louder splash helps) is your cue.
--
-- How: the key is put on top of your normal binding as an "override" that
-- only exists while you hold a pole and aren't in combat, so your own
-- keybinds are never changed and the key works as usual the rest of the
-- time. To reach the bobber with the Interact Key, the soft-target interact
-- settings are raised while you hold a pole, and put back afterwards
-- (also on the next login if the game closed mid-fishing).
--
--   /fishlog key        pick the key (press it; Esc cancels)
--   /fishlog key clear  stop using a key
--   /fishlog onekey on|off

local addonName, ns = ...

local TAG = "|cff40c0ffFishLog|r: "
local BOBBER = "35591"            -- the Fishing Bobber's object ID
local CAST_BUTTON = "FishLogOneKeyCast"
local LOOT_BUTTON = "FishLogOneKeyLoot"

-- Soft-target settings while fishing: interact with any object in front of
-- you out to 30 yards (the bobber lands 10-20 yards out).
local FISHING_CVARS = {
	SoftTargetInteract = "3",
	SoftTargetInteractRange = "30",
	SoftTargetInteractArc = "2",
}

local function Print(msg) print(TAG .. msg) end

local function GetCV(name)
	if C_CVar and C_CVar.GetCVar then return C_CVar.GetCVar(name) end
	return GetCVar and GetCVar(name)
end
local function SetCV(name, value)
	if C_CVar and C_CVar.SetCVar then return C_CVar.SetCVar(name, value) end
	return SetCVar and SetCVar(name, value)
end

local function DB()
	FishLogDB.oneKey = FishLogDB.oneKey or {}
	local d = FishLogDB.oneKey
	if d.enabled == nil then d.enabled = true end
	return d
end

--------------------------------------------------------------------------
-- Pole and bobber
--------------------------------------------------------------------------

local function PoleEquipped()
	if ns.IsFishingPoleEquipped then return ns.IsFishingPoleEquipped() end
	local id = GetInventoryItemID("player", 16)
	if not id then return false end
	local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(id)
	return classID == 2 and subclassID == 20
end

-- GameObject-0-[server]-[instance]-[zone]-[objectID]-[spawn]
local function IsBobber(guid)
	if type(guid) ~= "string" or (issecretvalue and issecretvalue(guid)) then return false end
	local kind, _, _, _, _, id = strsplit("-", guid)
	return kind == "GameObject" and id == BOBBER
end

--------------------------------------------------------------------------
-- Settings that are changed while you fish, and put back
--------------------------------------------------------------------------

local function ApplyCVars()
	local d = DB()
	d.restore = d.restore or {}
	for name, value in pairs(FISHING_CVARS) do
		local cur = GetCV(name)
		if cur ~= nil and cur ~= value then
			if d.restore[name] == nil then d.restore[name] = { old = cur, set = value } end
			SetCV(name, value)
		end
	end
end

-- Only puts a setting back if it still holds what FishLog set, so a change
-- you made yourself in the meantime is kept.
local function RestoreCVars()
	local d = DB()
	if not d.restore then return end
	for name, r in pairs(d.restore) do
		if GetCV(name) == r.set then SetCV(name, r.old) end
	end
	d.restore = nil
end

--------------------------------------------------------------------------
-- Buttons the key clicks
--------------------------------------------------------------------------

local owner = CreateFrame("Frame", "FishLogOneKeyOwner", UIParent)

local castBtn = CreateFrame("Button", CAST_BUTTON, UIParent, "SecureActionButtonTemplate")
castBtn:SetAttribute("type", "macro")
castBtn:SetAttribute("macrotext", "/cast Fishing")
castBtn:RegisterForClicks("AnyDown", "AnyUp")
castBtn:Hide()

local lootBtn = CreateFrame("Button", LOOT_BUTTON, UIParent)
lootBtn:RegisterForClicks("AnyDown")
lootBtn:SetScript("OnClick", function()
	for i = GetNumLootItems(), 1, -1 do LootSlot(i) end
end)
lootBtn:Hide()

--------------------------------------------------------------------------
-- What the key does right now
--------------------------------------------------------------------------

local state      -- "cast" / "reel" / "loot" / nil (key not taken)
local bobberSoft = false
local lootOpen = false
local active = false -- holding a pole with the feature on

local function SetState(new)
	if new == state then return end
	if InCombatLockdown() then return end
	local key = DB().key
	ClearOverrideBindings(owner)
	state = nil
	if not (new and key) then return end
	if new == "cast" then
		SetOverrideBindingClick(owner, true, key, CAST_BUTTON)
	elseif new == "reel" then
		SetOverrideBinding(owner, true, key, "INTERACTTARGET")
	elseif new == "loot" then
		SetOverrideBindingClick(owner, true, key, LOOT_BUTTON)
	end
	state = new
end

local function Update()
	if InCombatLockdown() then return end
	local d = DB()
	local want = d.enabled and d.key and PoleEquipped()
	if want and not active then
		active = true
		ApplyCVars()
	elseif not want and active then
		active = false
		bobberSoft = false
		RestoreCVars()
	end
	if not active then SetState(nil) return end
	if lootOpen and GetNumLootItems() > 0 then
		SetState("loot")
	elseif bobberSoft then
		SetState("reel")
	else
		SetState("cast")
	end
end
ns.OneKeyUpdate = Update

--------------------------------------------------------------------------
-- Picking the key
--------------------------------------------------------------------------

local MOUSE = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }
local IGNORE = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, UNKNOWN = true }
local catcher

local function Modified(key)
	local mods = ""
	if IsAltKeyDown() then mods = mods .. "ALT-" end
	if IsControlKeyDown() then mods = mods .. "CTRL-" end
	if IsShiftKeyDown() then mods = mods .. "SHIFT-" end
	return mods .. key
end

local function SetKey(key)
	catcher:Hide()
	SetState(nil)
	DB().key = key
	local normal = GetBindingAction(key)
	Print(("one-key fishing on %s. It only takes over that key while you hold a Fishing Pole%s."):format(
		GetBindingText and GetBindingText(key) or key,
		(normal and normal ~= "") and (", the rest of the time it stays " .. (_G["BINDING_NAME_" .. normal] or normal)) or ""))
	Update()
end

local function PickKey()
	if InCombatLockdown() then Print("not in combat.") return end
	if not catcher then
		catcher = CreateFrame("Button", "FishLogKeyCatcher", UIParent, "BackdropTemplate")
		catcher:SetSize(380, 80)
		catcher:SetPoint("CENTER", 0, 120)
		catcher:SetFrameStrata("DIALOG")
		if catcher.SetBackdrop then
			catcher:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16,
				insets = { left = 4, right = 4, top = 4, bottom = 4 } })
			catcher:SetBackdropColor(0, 0, 0, 0.9)
		end
		local t = catcher:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		t:SetPoint("CENTER")
		t:SetText("FishLog: press the key for one-key fishing\n(modifiers allowed; Esc cancels)")
		catcher:EnableKeyboard(true)
		catcher:RegisterForClicks("AnyDown")
		catcher:SetScript("OnKeyDown", function(self, key)
			if key == "ESCAPE" then self:Hide(); Print("key unchanged.") return end
			if IGNORE[key] then return end
			SetKey(Modified(key))
		end)
		catcher:SetScript("OnMouseDown", function(_, button)
			if MOUSE[button] then SetKey(Modified(MOUSE[button])) end
		end)
	end
	catcher:Show()
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

owner:RegisterEvent("PLAYER_LOGIN")
owner:RegisterEvent("PLAYER_LOGOUT")
owner:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
owner:RegisterEvent("PLAYER_REGEN_DISABLED")
owner:RegisterEvent("PLAYER_REGEN_ENABLED")
owner:RegisterEvent("LOOT_READY")
owner:RegisterEvent("LOOT_OPENED")
owner:RegisterEvent("LOOT_CLOSED")
pcall(owner.RegisterEvent, owner, "PLAYER_SOFT_INTERACT_CHANGED")
owner:SetScript("OnEvent", function(_, event, a, b)
	if event == "PLAYER_LOGIN" then
		-- the game closed mid-fishing last time: put those settings back first
		if DB().restore and not PoleEquipped() then RestoreCVars() end
		Update()
	elseif event == "PLAYER_LOGOUT" then
		if active then RestoreCVars() end
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- the last moment bindings can change: give the key back for the fight
		ClearOverrideBindings(owner)
		state = nil
	elseif event == "PLAYER_SOFT_INTERACT_CHANGED" then
		bobberSoft = IsBobber(b)
		Update()
	elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
		lootOpen = true
		Update()
	elseif event == "LOOT_CLOSED" then
		lootOpen = false
		bobberSoft = false
		Update()
	else
		Update()
	end
end)

--------------------------------------------------------------------------
-- Slash commands: /fishlog key, /fishlog onekey
--------------------------------------------------------------------------

local previousSlash = SlashCmdList.FISHLOG
SlashCmdList.FISHLOG = function(msg)
	local cmd, rest = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "key" then
		if rest == "clear" or rest == "off" then
			SetState(nil)
			DB().key = nil
			Update()
			Print("one-key fishing has no key now.")
		else
			PickKey()
		end
	elseif cmd == "onekey" then
		local d = DB()
		if rest == "on" then d.enabled = true elseif rest == "off" then d.enabled = false end
		Update()
		Print(("one-key fishing is %s, key: %s%s."):format(d.enabled and "on" or "off", d.key or "none (/fishlog key)",
			(d.enabled and d.key and not PoleEquipped()) and " (waiting for a Fishing Pole)" or ""))
	else
		if msg == "" or msg == "help" then
			print("  One-key fishing: /fishlog key (pick it), /fishlog onekey [on|off]. Also /fl for /fishlog.")
		end
		previousSlash(msg)
	end
end
