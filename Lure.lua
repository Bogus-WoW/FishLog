-- FishLog: Lure.lua
--
-- A small clickable icon that shows up when you hold a Fishing Pole that has no
-- lure on it, and you carry one. Click it and the lure goes on the pole:
-- the icon is a button that runs "/use <lure>" then "/use 16" (main hand).
--
-- Next to it sits a food reminder: while the pole is equipped and you carry
-- Filet of Redgill (+18 fishing) but don't have the food buff, an icon appears;
-- click it to eat. Buff is matched by name ("Well Fed"), see /fishlog lure auras.
--
-- They're secure buttons, like GroupAssist's buff icons, so it can only change
-- out of combat; during combat it is hidden.
--
-- Which lure: the strongest one in your bags (Aquadynamic Fish Attractor, then
-- Flesh Eating Worm / Bright Baubles, Aquadynamic Fish Lens / Nightcrawlers,
-- Shiny Bauble). Lures are found by name.
--
--   /fishlog lure             what the icon sees right now
--   /fishlog lure reset       put the icon back in its default spot
--
-- To move it: press and hold the icon for a second, then drag. A quick click
-- still applies the lure.
--   /fishlog lure on|off      turn the icon on or off

local addonName, ns = ...

-- name -> fishing skill bonus (used to pick the strongest)
local LURES = {
	["Aquadynamic Fish Attractor"] = 100,
	["Flesh Eating Worm"] = 75,
	["Bright Baubles"] = 75,
	["Aquadynamic Fish Lens"] = 50,
	["Nightcrawlers"] = 50,
	["Shiny Bauble"] = 25,
}

local ICON = 40
local bar, button, foodBtn
local foodItem -- { itemID, count }
local dragging = false
local Update
local HOLD = 1.0
local pending = false
local current -- { itemID, name, bonus, count }

local function DB()
	local st = ns.Store()
	st.lure = st.lure or {}
	return st.lure
end

local function Print(msg)
	print("|cff40c0ffFishLog|r: " .. msg)
end

local function PoleEquipped()
	if ns.IsFishingPoleEquipped then return ns.IsFishingPoleEquipped() end
	local id = GetInventoryItemID("player", 16)
	if not id then return false end
	local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(id)
	return classID == 2 and subclassID == 20
end

-- Is a lure on the pole? Same check GroupAssist uses for weapon oils.
local function PoleHasLure()
	local has = GetWeaponEnchantInfo and GetWeaponEnchantInfo()
	return has and true or false
end

-- strongest lure in your bags: { itemID, name, bonus, count }
local function FindLure()
	local best
	local maxBag = (NUM_BAG_SLOTS or 4)
	for bag = 0, maxBag do
		local slots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID then
				local name = info.itemName or C_Item.GetItemInfo(info.itemID)
				local bonus = name and LURES[name]
				if bonus and (not best or bonus > best.bonus) then
					best = { itemID = info.itemID, name = name, bonus = bonus }
				end
			end
		end
	end
	if best then best.count = C_Item.GetItemCount(best.itemID) or 1 end
	return best
end

local function FoodName()
	return DB().food or "Filet of Redgill"
end

-- Does the player have the food buff? Looks for an aura with the configured name
-- ("Well Fed" by default; /fishlog lure foodbuff <name> changes it).
local function HasFoodBuff()
	local want = DB().foodBuff or "Well Fed"
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return false end
	for i = 1, 40 do
		local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
		if not aura then break end
		local n = aura.name
		if n and not (issecretvalue and issecretvalue(n)) and n == want then return true end
	end
	return false
end

local function FindFood()
	local name = FoodName()
	for bag = 0, (NUM_BAG_SLOTS or 4) do
		for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID then
				local n = info.itemName or C_Item.GetItemInfo(info.itemID)
				if n == name then
					return { itemID = info.itemID, count = C_Item.GetItemCount(info.itemID) or 1 }
				end
			end
		end
	end
end

-- one icon button on the bar; hold it for a second to drag the whole bar
local function MakeButton(name, offsetX)
	local btn = CreateFrame("Button", name, bar, "SecureActionButtonTemplate")
	btn:SetSize(ICON, ICON)
	btn:SetPoint("LEFT", bar, "LEFT", offsetX, 0)
	-- Fire on release so a long press (to drag) can cancel the click. Register
	-- both directions and pin useOnKeyDown off: with only AnyUp registered, the
	-- game's "cast on key down" setting makes the click never fire.
	btn:RegisterForClicks("AnyUp", "AnyDown")
	btn:SetAttribute("useOnKeyDown", false)
	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	btn.count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	btn.count:SetPoint("BOTTOMRIGHT", -2, 2)
	btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	btn.label:SetPoint("TOP", btn, "BOTTOM", 0, -2)
	btn:SetScript("OnEnter", function(self)
		if not self.tip then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		for i, line in ipairs(self.tip()) do
			if i == 1 then GameTooltip:AddLine(line, 1, 1, 1) else GameTooltip:AddLine(line, 0.6, 0.8, 1) end
		end
		GameTooltip:AddLine("Hold 1 second and drag to move", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", GameTooltip_Hide)

	-- while held/dragging the click is switched off so letting go doesn't use the item
	local downAt
	local function StopDrag()
		downAt = nil
		btn:SetScript("OnUpdate", nil)
		if dragging then
			bar:StopMovingOrSizing()
			local a, _, rp, x, y = bar:GetPoint()
			DB().pos = { a, rp, x, y }
			C_Timer.After(0.3, function() dragging = false; Update() end)
		end
	end
	btn:SetScript("OnMouseDown", function(self, mb)
		if mb ~= "LeftButton" then return end
		downAt = 0
		self:SetScript("OnUpdate", function(f, dt)
			if not downAt or dragging then return end
			downAt = downAt + dt
			if downAt >= HOLD and not InCombatLockdown() then
				dragging = true
				f:SetAttribute("type1", nil)
				bar:StartMoving()
			end
		end)
	end)
	btn:SetScript("OnMouseUp", StopDrag)
	btn:SetScript("OnHide", StopDrag)
	btn:Hide()
	return btn
end

local function Build()
	bar = CreateFrame("Frame", "FishLogLureBar", UIParent, "SecureHandlerStateTemplate")
	bar:SetSize(ICON * 2 + 4, ICON)
	local p = DB().pos
	if p then bar:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else bar:SetPoint("CENTER", 0, -120) end
	bar:SetMovable(true)
	bar:SetClampedToScreen(true)
	RegisterStateDriver(bar, "visibility", "[combat] hide; show")

	button = MakeButton("FishLogLureButton", 0)
	button.label:SetText("Add lure")
	button.tip = function()
		return { "Your Fishing Pole has no lure",
			("Click: put on %s (+%d fishing)"):format(current.name, current.bonus) }
	end

	foodBtn = MakeButton("FishLogFoodButton", ICON + 4)
	foodBtn.label:SetText("Eat")
	foodBtn.tip = function()
		return { "No fishing food buff", "Click: eat " .. FoodName() }
	end
end

-- The bar itself stays shown (its own state driver hides it in combat); only
-- the button comes and goes, like GroupAssist's buff icons.
Update = function()
	if not bar or dragging then return end
	if InCombatLockdown() then pending = true return end
	pending = false
	local off = DB().off == true or not PoleEquipped()
	-- lure
	current = (not off and not PoleHasLure()) and FindLure() or nil
	if not current then
		button:Hide()
	else
		button.icon:SetTexture(C_Item.GetItemIconByID(current.itemID) or 134400)
		button.count:SetText(current.count > 1 and current.count or "")
		button:SetAttribute("type1", "macro")
		button:SetAttribute("macrotext1", "/use " .. current.name .. "\n/use 16")
		button:Show()
	end
	-- fishing food reminder
	foodItem = (not off and DB().foodOff ~= true and not HasFoodBuff()) and FindFood() or nil
	if not foodItem then
		foodBtn:Hide()
	else
		foodBtn.icon:SetTexture(C_Item.GetItemIconByID(foodItem.itemID) or 134400)
		foodBtn.count:SetText(foodItem.count > 1 and foodItem.count or "")
		foodBtn:SetAttribute("type1", "macro")
		foodBtn:SetAttribute("macrotext1", "/use " .. FoodName())
		foodBtn:Show()
	end
end

function ns.LureCommand(arg)
	local d = DB()
	local raw = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	arg = raw:lower()
	if arg == "reset" then
		d.pos = nil
		if bar and not InCombatLockdown() then bar:ClearAllPoints() bar:SetPoint("CENTER", 0, -120) end
		Print("icons moved back to their default spot.")
	elseif arg == "on" or arg == "off" then
		d.off = (arg == "off")
		Print("lure and food icons " .. (d.off and "off." or "on."))
		Update()
	elseif arg == "food off" or arg == "food on" then
		d.foodOff = (arg == "food off")
		Print("food reminder " .. (d.foodOff and "off." or "on."))
		Update()
	elseif arg:match("^food ") then
		d.food = raw:match("^%S+%s+(.+)$")
		Print("food reminder item is now: " .. d.food)
		Update()
	elseif arg:match("^foodbuff ") then
		d.foodBuff = raw:match("^%S+%s+(.+)$")
		Print("food buff name is now: " .. d.foodBuff)
		Update()
	elseif arg == "auras" then
		Print("your buffs right now (use the name with /fishlog lure foodbuff <name>):")
		for i = 1, 40 do
			local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
			if not aura then break end
			local n = aura.name
			if n and not (issecretvalue and issecretvalue(n)) then print("  " .. n) end
		end
	else
		local lure = FindLure()
		local a, b, c2, d2 = GetWeaponEnchantInfo()
		Print(("game says: hasMainHandEnchant=%s expires=%s charges=%s enchantID=%s"):format(tostring(a), tostring(b), tostring(c2), tostring(d2)))
		Print(("fishing pole equipped: %s; lure on it: %s; best lure in bags: %s%s."):format(
			PoleEquipped() and "yes" or "no", PoleHasLure() and "yes" or "no",
			lure and lure.name or "none", lure and (" x" .. lure.count) or ""))
		local f = FindFood()
		Print(("food: %s in bags: %s; buff \"%s\" active: %s; reminder %s."):format(
			FoodName(), f and ("x" .. f.count) or "none", d.foodBuff or "Well Fed",
			HasFoodBuff() and "yes" or "no", d.foodOff and "off" or "on"))
		Print("/fishlog lure on|off|reset|auras, /fishlog lure food on|off|<item name>, /fishlog lure foodbuff <name>")
	end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("UNIT_INVENTORY_CHANGED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
local acc = 0
ev:SetScript("OnUpdate", function(_, dt)
	-- an expiring lure has no event of its own, so look every couple of seconds
	acc = acc + dt
	if acc >= 2 then
		acc = 0
		if bar and (pending or not InCombatLockdown()) then Update() end
	end
end)
ev:SetScript("OnEvent", function(_, event, unit)
	if event == "PLAYER_LOGIN" then
		Build()
		Update()
	elseif event == "UNIT_INVENTORY_CHANGED" and unit ~= "player" then
		return
	else
		Update()
	end
end)
