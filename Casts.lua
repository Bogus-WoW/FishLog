-- FishLog: Casts.lua
--
-- "Casts per catch" tracking. Tracker.lua only sees catches; this file
-- follows every Fishing cast to its outcome so failures count too:
--
--   catch    -- a loot line for you arrives after the cast
--   escaped  -- "Your fish got away!" (ERR_FISH_ESCAPED): the skill roll
--               failed. This is the one that matters for pools like
--               Patch of Elemental Water, where the chance is roughly
--               (effective skill - zone minimum + 5)%.
--   nobite   -- "No fish are hooked." (ERR_FISH_NOT_HOOKED): you clicked
--               the bobber before a bite. Your mistake, not a failed roll.
--   abandoned-- the cast ended with none of the above (you moved, cancelled,
--               or let the bobber time out). Not counted as a real attempt.
--
-- "Skill not high enough" never gets this far -- the cast is refused, so
-- UNIT_SPELLCAST_SUCCEEDED never fires.
--
-- Every finished cast is added to up to three buckets:
--   subzone  -- zone + subzone, always (covers "Bay of Storms" on its own)
--   pool     -- zone + subzone + pool name, if you were hovering a pool
--               when you cast (same tooltip trick as Tracker.lua)
--   session  -- a manual /fishlog session, if one is running
--
-- Each bucket also keeps attempts/catches per effective fishing skill, so
-- the catch-chance formula can be checked against real numbers.
--
-- Camp buff: every cast also notes whether you had the Fishing Rack (or
-- Fishing Hut) buff, and each bucket keeps catches and Bloated fish split
-- by "with buff" / "without buff" (b.byBuff). Casts from before this was
-- added aren't in either side. If the buff drops while you're fishing you
-- get a warning on screen. /fishlog buff shows the comparison.

local addonName, ns = ...

local FISHING = "Fishing"
local RESOLVE_WINDOW = 30 -- seconds after the cast we still attribute an outcome to it

local current -- the cast in flight: { keys = {...}, skill, t, resolved }
local session -- { key, label }

local function Clean(v)
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return v
end

local function GetSpellName(spellID)
	if C_Spell and C_Spell.GetSpellName then
		return C_Spell.GetSpellName(spellID)
	end
	if GetSpellInfo then
		return GetSpellInfo(spellID)
	end
end

-- Effective fishing skill (base + lure + buffs + gear), and the base alone.
local function FishingSkill()
	if GetProfessions and GetProfessionInfo then
		local _, _, _, fishing = GetProfessions()
		if fishing then
			local _, _, rank, _, _, _, _, modifier = GetProfessionInfo(fishing)
			if rank then
				return rank + (modifier or 0), rank
			end
		end
	end
	if GetNumSkillLines and GetSkillLineInfo then
		for i = 1, GetNumSkillLines() do
			local name, isHeader, _, rank, temp, modifier = GetSkillLineInfo(i)
			if not isHeader and name == FISHING then
				return rank + (temp or 0) + (modifier or 0), rank
			end
		end
	end
end

--------------------------------------------------------------------------
-- Camp buff detection
--------------------------------------------------------------------------

-- An aura counts as the camp buff if its name or description mentions the
-- rack/hut or catching uncommon/rare fish. Results are cached per spell ID.
local CAMP_WORDS = { "fishing rack", "fishing hut", "uncommon fish", "rare fish" }
local buffVerdict = {} -- [spellID] = true/false

local function SpellDescription(spellID)
	if C_Spell and C_Spell.GetSpellDescription then
		return Clean(C_Spell.GetSpellDescription(spellID))
	elseif GetSpellDescription then
		return Clean(GetSpellDescription(spellID))
	end
end

local function IsCampBuff(name, spellID)
	if spellID and buffVerdict[spellID] ~= nil then
		return buffVerdict[spellID]
	end
	local desc = spellID and SpellDescription(spellID) or nil
	local text = ((name or "") .. " " .. (desc or "")):lower()
	local hit = false
	for _, w in ipairs(CAMP_WORDS) do
		if text:find(w, 1, true) then hit = true break end
	end
	-- only cache a "no" once the description has loaded
	if spellID and (hit or (desc and desc ~= "")) then
		buffVerdict[spellID] = hit
	end
	return hit
end

-- Calls fn(name, spellID, expirationTime) for each of your buffs.
local function EachBuff(fn)
	for i = 1, 40 do
		local name, spellID, expires
		if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
			local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
			if not a then break end
			name, spellID, expires = Clean(a.name), Clean(a.spellId), Clean(a.expirationTime)
		elseif UnitBuff then
			local n, _, _, _, _, exp, _, _, _, id = UnitBuff("player", i)
			if not n then break end
			name, spellID, expires = n, id, exp
		else
			break
		end
		if name then fn(name, spellID, expires) end
	end
end

-- Returns the camp buff's name (and expiry) if you have it, else nil.
local function CampBuff()
	local found, foundExp
	EachBuff(function(name, spellID, expires)
		if not found and IsCampBuff(name, spellID) then
			found, foundExp = name, expires
		end
	end)
	return found, foundExp
end
ns.CampBuff = CampBuff

local function IsBloated(name)
	return type(name) == "string" and name:find("^Bloated") ~= nil
end

--------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------

local function CastStore()
	local store = ns.Store()
	store.casts = store.casts or {}
	return store.casts
end

local function Bucket(key, info)
	local all = CastStore()
	local b = all[key]
	if not b then
		b = {
			kind = info.kind,
			zone = info.zone,
			subzone = info.subzone,
			pool = info.pool,
			label = info.label,
			casts = 0,
			catches = 0,
			escaped = 0,
			nobite = 0,
			abandoned = 0,
			items = {},
			bySkill = {},
		}
		all[key] = b
	end
	return b
end

local function BucketName(b)
	if b.kind == "session" then
		return "Session: " .. (b.label or "?")
	elseif b.kind == "pool" then
		return ("%s (%s / %s)"):format(b.pool, b.zone, b.subzone)
	end
	return b.zone .. " / " .. b.subzone
end
ns.CastBucketName = BucketName

local function BuffSide(b, buffed)
	b.byBuff = b.byBuff or {}
	local side = buffed and "on" or "off"
	local t = b.byBuff[side]
	if not t then
		t = { casts = 0, catches = 0, bloated = 0 }
		b.byBuff[side] = t
	end
	return t
end

local function Resolve(outcome)
	if not current or current.resolved then
		return
	end
	current.resolved = true
	current.outcome = outcome
	current.resolvedAt = GetTime()
	for _, key in ipairs(current.keys) do
		local b = CastStore()[key]
		if b then
			if outcome == "abandoned" then
				b.abandoned = b.abandoned + 1
			else
				b.casts = b.casts + 1
				b[outcome] = b[outcome] + 1
				local side = BuffSide(b, current.buffed)
				side.casts = side.casts + 1
				if outcome == "catches" then
					side.catches = side.catches + 1
				end
				-- Only catch/escape are skill rolls; a no-bite is a misclick.
				if current.skill and (outcome == "catches" or outcome == "escaped") then
					local s = b.bySkill[current.skill] or { attempts = 0, catches = 0 }
					s.attempts = s.attempts + 1
					if outcome == "catches" then
						s.catches = s.catches + 1
					end
					b.bySkill[current.skill] = s
				end
			end
		end
	end
	if ns.RefreshCastHUD then
		ns.RefreshCastHUD()
	end
end

local function AddItem(itemID, name, quantity)
	if not current then
		return
	end
	for _, key in ipairs(current.keys) do
		local b = CastStore()[key]
		if b then
			local e = b.items[itemID] or { name = name, count = 0 }
			e.name = name or e.name
			e.count = e.count + quantity
			b.items[itemID] = e
			if IsBloated(name) then
				local side = BuffSide(b, current.buffed)
				side.bloated = side.bloated + quantity
			end
		end
	end
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

-- "You receive loot: %s." -> "You receive loot: " (and the multiple-item form)
local function SelfLootPrefixes()
	local out = {}
	for _, fmt in ipairs({ LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF, LOOT_ITEM_PUSHED_SELF_MULTIPLE }) do
		if type(fmt) == "string" then
			local prefix = fmt:match("^(.-)%%s")
			if prefix and prefix ~= "" then
				out[#out + 1] = prefix
			end
		end
	end
	return out
end
local selfPrefixes = SelfLootPrefixes()

local function IsOwnLoot(text)
	if #selfPrefixes == 0 then
		return true -- can't tell; assume solo fishing like Tracker.lua does
	end
	for _, prefix in ipairs(selfPrefixes) do
		if text:sub(1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function StartCast()
	-- A previous cast that never resolved was abandoned.
	if current and not current.resolved then
		Resolve("abandoned")
	end

	local zone = GetRealZoneText() or ""
	local subzone = GetSubZoneText() or ""
	zone = zone ~= "" and zone or "Unknown zone"
	subzone = subzone ~= "" and subzone or "(open area)"
	local skill = FishingSkill()

	local keys = {}
	local subKey = "sub|" .. zone .. "|" .. subzone
	Bucket(subKey, { kind = "subzone", zone = zone, subzone = subzone })
	keys[#keys + 1] = subKey

	local poolName = ns.TooltipPoolName and ns.TooltipPoolName()
	if poolName then
		local poolKey = "pool|" .. zone .. "|" .. subzone .. "|" .. poolName
		Bucket(poolKey, { kind = "pool", zone = zone, subzone = subzone, pool = poolName })
		keys[#keys + 1] = poolKey
	end

	if session then
		Bucket(session.key, { kind = "session", zone = zone, subzone = subzone, label = session.label })
		keys[#keys + 1] = session.key
	end

	local buffName = CampBuff()
	local buffed = buffName ~= nil
	if ns.lastCastBuffed and not buffed then
		if UIErrorsFrame and UIErrorsFrame.AddMessage then
			UIErrorsFrame:AddMessage("FishLog: your Fishing Rack buff is gone.", 1, 0.5, 0.1)
		end
		print("|cff40c0ffFishLog|r: |cffff8020your Fishing Rack buff is gone|r -- casts now count as unbuffed.")
		if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then
			PlaySound(SOUNDKIT.RAID_WARNING)
		end
	end
	ns.lastCastBuffed = buffed

	current = { keys = keys, skill = skill, t = GetTime(), resolved = false, display = keys[#keys], buffed = buffed }
	ns.lastCastBucket = current.display
end

--------------------------------------------------------------------------
-- Opened containers (Bloated fish, clams, crates)
--
-- Opening a container shows its own loot window. Those loot lines are not
-- catches: they're kept out of the cast/catch stats and logged per container
-- instead, so you can see e.g. how many Aquamarines per Bloated Redgill, or
-- Black Pearls per Big-mouth Clam. /fishlog opened shows it.
--------------------------------------------------------------------------

local lootWindow = { open = false, fishing = false, closedAt = 0 }
local lastUsed     -- { id, name, t }: last bag item you used
local opening      -- the container whose loot window is open right now

-- True while (or just after) a loot window that isn't a fishing catch is open.
function ns.LootIsNotFishing()
	if lootWindow.fishing then
		return false
	end
	return lootWindow.open or (GetTime() - lootWindow.closedAt) < 1.5
end

local function OpenedStore()
	local store = ns.Store()
	store.opened = store.opened or {}
	return store.opened
end

local function OnBagItemUsed(bag, slot)
	local getID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
	local id = getID and getID(bag, slot)
	if id then
		local name = (C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(id)) or (GetItemInfo and GetItemInfo(id))
		lastUsed = { id = id, name = name, t = GetTime() }
	end
end
if C_Container and C_Container.UseContainerItem then
	hooksecurefunc(C_Container, "UseContainerItem", OnBagItemUsed)
elseif UseContainerItem then
	hooksecurefunc("UseContainerItem", OnBagItemUsed)
end

local function OnLootOpened()
	lootWindow.open = true
	lootWindow.fishing = IsFishingLoot and IsFishingLoot() or false
	opening = nil
	if not lootWindow.fishing and lastUsed and GetTime() - lastUsed.t < 3 then
		opening = lastUsed
		lastUsed = nil
		local all = OpenedStore()
		local c = all[opening.id] or { name = opening.name, opened = 0, items = {} }
		c.name = opening.name or c.name
		c.opened = c.opened + 1
		all[opening.id] = c
	end
end

local function OnContainerLoot(itemID, name, quantity)
	if not opening then
		return
	end
	local c = OpenedStore()[opening.id]
	if c then
		local e = c.items[itemID] or { name = name, count = 0 }
		e.name = name or e.name
		e.count = e.count + quantity
		c.items[itemID] = e
	end
end

local function PrintOpened(filter)
	local needle = filter and filter ~= "" and filter:lower() or nil
	local list = {}
	for id, c in pairs(OpenedStore()) do
		if not needle or (c.name or ""):lower():find(needle, 1, true) then
			list[#list + 1] = { id = id, c = c }
		end
	end
	table.sort(list, function(a, b) return a.c.opened > b.c.opened end)
	if #list == 0 then
		print("|cff40c0ffFishLog|r: nothing opened yet (logged from now on).")
		return
	end
	print("|cff40c0ffFishLog|r opened containers:")
	for _, row in ipairs(list) do
		local c = row.c
		print(("  |cffffd100%s|r: opened %d"):format(c.name or ("Item #" .. row.id), c.opened))
		local items = {}
		for itemID, e in pairs(c.items) do items[#items + 1] = e end
		table.sort(items, function(a, b) return a.count > b.count end)
		for _, e in ipairs(items) do
			print(("      %s x%d (%.0f%% of opens)"):format(e.name or "?", e.count, e.count / c.opened * 100))
		end
	end
end
ns.PrintOpened = PrintOpened

function ns.OpenedForExport()
	local out = {}
	for id, c in pairs(OpenedStore()) do
		local items = {}
		for itemID, e in pairs(c.items) do
			items[#items + 1] = { __isObject = true, { "itemID", itemID }, { "itemName", e.name or "" }, { "count", e.count } }
		end
		out[#out + 1] = { __isObject = true, { "itemID", id }, { "name", c.name or "" }, { "opened", c.opened }, { "items", items } }
	end
	return out
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("LOOT_OPENED")
watcher:RegisterEvent("LOOT_READY")
watcher:RegisterEvent("LOOT_CLOSED")
watcher:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
watcher:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
watcher:RegisterEvent("UI_ERROR_MESSAGE")
watcher:RegisterEvent("UI_INFO_MESSAGE")
watcher:RegisterEvent("CHAT_MSG_LOOT")

watcher:SetScript("OnEvent", function(_, event, ...)
	if event == "LOOT_OPENED" or event == "LOOT_READY" then
		if not lootWindow.open then
			OnLootOpened()
		end
	elseif event == "LOOT_CLOSED" then
		lootWindow.open = false
		lootWindow.closedAt = GetTime()
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellID = ...
		if unit == "player" and GetSpellName(spellID) == FISHING then
			StartCast()
		end
	elseif event == "UI_ERROR_MESSAGE" or event == "UI_INFO_MESSAGE" then
		local _, message = ...
		message = Clean(message)
		if type(message) ~= "string" or not current then
			return
		end
		if message == ERR_FISH_ESCAPED or message:find("got away", 1, true) then
			Resolve("escaped")
		elseif message == ERR_FISH_NOT_HOOKED or message:find("No fish are hooked", 1, true) then
			Resolve("nobite")
		end
	elseif event == "CHAT_MSG_LOOT" then
		local text = Clean(...)
		if type(text) ~= "string" or not IsOwnLoot(text) then
			return
		end
		local link = text:match("|Hitem:[^|]+|h%[.-%]|h")
		if not link then
			return
		end
		local itemID
		if C_Item and C_Item.GetItemInfoInstant then
			itemID = C_Item.GetItemInfoInstant(link)
		elseif GetItemInfoInstant then
			itemID = GetItemInfoInstant(link)
		end
		if not itemID then
			return
		end
		local name = text:match("%[(.-)%]")
		local quantity = tonumber(text:match("x(%d+)%s*%.?%s*$")) or 1
		if ns.LootIsNotFishing() then
			OnContainerLoot(itemID, name, quantity) -- an opened clam/fish, a mob, etc. -- never a catch
			return
		end
		if not current or GetTime() - current.t > RESOLVE_WINDOW then
			return
		end
		if not current.resolved then
			Resolve("catches")
		elseif current.outcome ~= "catches" or GetTime() - current.resolvedAt > 3 then
			return -- unrelated loot (a mob, a quest reward) after this cast was settled
		end
		-- 2nd+ loot lines within a few seconds belong to the same catch.
		AddItem(itemID, name, quantity)
		if ns.RefreshCastHUD then
			ns.RefreshCastHUD()
		end
	elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		local unit = ...
		if unit ~= "player" or not current or current.resolved then
			return
		end
		-- The catch/escape message can land just after the channel ends;
		-- give it a moment before calling the cast abandoned.
		local cast = current
		C_Timer.After(2, function()
			if current == cast and not cast.resolved then
				Resolve("abandoned")
			end
		end)
	end
end)

--------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------

-- Real skill rolls: catches + escapes. No-bites are misclicks.
local function Rolls(b)
	return b.catches + b.escaped
end

local function CatchPct(b)
	local rolls = Rolls(b)
	return rolls > 0 and (b.catches / rolls * 100) or 0
end

local function CastsPerCatch(b)
	return b.catches > 0 and (b.casts / b.catches) or nil
end

local function SortedItems(b)
	local list = {}
	for itemID, e in pairs(b.items) do
		list[#list + 1] = { itemID = itemID, name = e.name or ("Item #" .. itemID), count = e.count }
	end
	table.sort(list, function(a, c)
		return a.count < c.count -- rarest first: that's what you're fishing for
	end)
	return list
end

local function Per(n, d)
	return n > 0 and ("1 per %.0f"):format(d / n) or "none yet"
end

-- "with buff: 40 caught, 1 Bloated (1 per 40) | without: ..."
local function BuffLine(b)
	if not b.byBuff then
		return nil
	end
	local parts = {}
	for _, side in ipairs({ "on", "off" }) do
		local t = b.byBuff[side]
		if t and t.casts > 0 then
			parts[#parts + 1] = ("%s: %d caught, %d Bloated (%s)"):format(
				side == "on" and "|cff40ff40with buff|r" or "|cffff8020without|r", t.catches, t.bloated, Per(t.bloated, t.catches))
		end
	end
	return #parts > 0 and table.concat(parts, "  |  ") or nil
end
ns.BuffLine = BuffLine

local function SummaryLine(b)
	local cpc = CastsPerCatch(b)
	return ("%d casts, %d caught, %d got away, %d no bite -- %s casts/catch, %.0f%% catch chance"):format(
		b.casts, b.catches, b.escaped, b.nobite, cpc and ("%.1f"):format(cpc) or "--", CatchPct(b))
end

local function ItemLines(b)
	local out = {}
	for _, it in ipairs(SortedItems(b)) do
		out[#out + 1] = ("%s x%d (1 per %.1f casts)"):format(it.name, it.count, b.casts / it.count)
	end
	return out
end

local function PrintCasts(filter)
	local needle = filter and filter ~= "" and filter:lower() or nil
	local list = {}
	for _, b in pairs(CastStore()) do
		local name = BucketName(b)
		if b.casts + b.abandoned > 0 and (not needle or name:lower():find(needle, 1, true)) then
			list[#list + 1] = b
		end
	end
	local order = { session = 1, pool = 2, subzone = 3 }
	table.sort(list, function(a, c)
		if a.kind ~= c.kind then
			return order[a.kind] < order[c.kind]
		end
		return a.casts > c.casts
	end)
	if #list == 0 then
		print("|cff40c0ffFishLog|r: no casts logged" .. (needle and (' matching "' .. filter .. '"') or "") .. " yet.")
		return
	end
	print("|cff40c0ffFishLog|r casts per catch:")
	for _, b in ipairs(list) do
		print("  |cffffd100" .. BucketName(b) .. "|r: " .. SummaryLine(b))
		local bl = BuffLine(b)
		if bl then
			print("      " .. bl)
		end
		for _, line in ipairs(ItemLines(b)) do
			print("      " .. line)
		end
		-- Skill breakdown, so the (skill - zone min + 5)% formula can be checked.
		local skills = {}
		for skill in pairs(b.bySkill) do
			skills[#skills + 1] = skill
		end
		table.sort(skills)
		if #skills > 1 or (b.kind ~= "subzone" and #skills == 1) then
			local parts = {}
			for _, skill in ipairs(skills) do
				local s = b.bySkill[skill]
				parts[#parts + 1] = ("%d: %d/%d"):format(skill, s.catches, s.attempts)
			end
			print("      |cff888888by skill (caught/rolls): " .. table.concat(parts, ", ") .. "|r")
		end
	end
end

function ns.CastStatsForExport()
	local out = {}
	for _, b in pairs(CastStore()) do
		local items = {}
		for _, it in ipairs(SortedItems(b)) do
			items[#items + 1] = { __isObject = true, { "itemID", it.itemID }, { "itemName", it.name }, { "count", it.count } }
		end
		local skills = {}
		for skill, s in pairs(b.bySkill) do
			skills[#skills + 1] = { __isObject = true, { "skill", skill }, { "attempts", s.attempts }, { "catches", s.catches } }
		end
		table.sort(skills, function(a, c) return a[1][2] < c[1][2] end)
		out[#out + 1] = {
			__isObject = true,
			{ "kind", b.kind },
			{ "name", BucketName(b) },
			{ "casts", b.casts },
			{ "catches", b.catches },
			{ "escaped", b.escaped },
			{ "noBite", b.nobite },
			{ "abandoned", b.abandoned },
			{ "withBuff", b.byBuff and b.byBuff.on and { __isObject = true, { "casts", b.byBuff.on.casts }, { "catches", b.byBuff.on.catches }, { "bloated", b.byBuff.on.bloated } } or false },
			{ "withoutBuff", b.byBuff and b.byBuff.off and { __isObject = true, { "casts", b.byBuff.off.casts }, { "catches", b.byBuff.off.catches }, { "bloated", b.byBuff.off.bloated } } or false },
			{ "items", items },
			{ "bySkill", skills },
		}
	end
	return out
end

--------------------------------------------------------------------------
-- HUD: one small line showing the bucket you're fishing into right now
--------------------------------------------------------------------------

local hud
local hudAlways = false

local function EnsureHUD()
	if hud then
		return hud
	end
	hud = CreateFrame("Frame", "FishLogCastHUD", UIParent, "BackdropTemplate")
	hud:SetSize(360, 46)
	hud:SetPoint("TOP", 0, -120)
	hud:SetMovable(true)
	hud:EnableMouse(true)
	hud:RegisterForDrag("LeftButton")
	hud:SetScript("OnDragStart", hud.StartMoving)
	hud:SetScript("OnDragStop", hud.StopMovingOrSizing)
	hud:SetClampedToScreen(true)
	hud:SetBackdrop({
		bgFile = "Interface/Tooltips/UI-Tooltip-Background",
		edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	hud:SetBackdropColor(0, 0, 0, 0.7)
	hud.title = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hud.title:SetPoint("TOPLEFT", 8, -7)
	hud.title:SetPoint("RIGHT", -8, 0)
	hud.title:SetJustifyH("LEFT")
	hud.body = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hud.body:SetPoint("TOPLEFT", hud.title, "BOTTOMLEFT", 0, -3)
	hud.body:SetPoint("RIGHT", -8, 0)
	hud.body:SetJustifyH("LEFT")
	hud:Hide()
	return hud
end

function ns.RefreshCastHUD()
	if not (session or hudAlways) then
		if hud then
			hud:Hide()
		end
		return
	end
	local h = EnsureHUD()
	local key = (session and session.key) or ns.lastCastBucket
	local b = key and CastStore()[key]
	if not b then
		h.title:SetText("FishLog: cast to start counting")
		h.body:SetText("")
	else
		local cpc = CastsPerCatch(b)
		h.title:SetText("FishLog -- " .. BucketName(b))
		local line = ("%d casts, %d caught (%s casts/catch, %.0f%%)"):format(
			b.casts, b.catches, cpc and ("%.1f"):format(cpc) or "--", CatchPct(b))
		local buffName, expires = CampBuff()
		if buffName then
			local left = expires and expires > 0 and math.max(0, expires - GetTime()) or nil
			line = line .. "\n|cff40ff40Rack buff on|r" .. (left and (" (%d min left)"):format(math.ceil(left / 60)) or "")
		else
			line = line .. "\n|cffff8020No Rack buff|r"
		end
		local on = b.byBuff and b.byBuff.on
		if on and on.catches > 0 then
			line = line .. ("  -- Bloated with buff: %d in %d catches"):format(on.bloated, on.catches)
		end
		local items = SortedItems(b)
		if items[1] then
			local rare = items[1]
			line = line .. ("\nRarest: %s x%d (1 per %.1f casts)"):format(rare.name, rare.count, b.casts / rare.count)
		end
		h.body:SetText(line)
	end
	h:SetHeight(22 + h.body:GetStringHeight())
	h:Show()
end

--------------------------------------------------------------------------
-- Slash commands (layered on top of Core.lua's /fishlog)
--------------------------------------------------------------------------

local coreSlash = SlashCmdList.FISHLOG
SlashCmdList.FISHLOG = function(msg)
	local raw = (msg or ""):match("^%s*(.-)%s*$")
	local cmd, rest = raw:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()

	if cmd == "casts" or cmd == "pools" then
		PrintCasts(rest)
	elseif cmd == "session" then
		local sub, label = rest:match("^(%S*)%s*(.-)$")
		sub = (sub or ""):lower()
		if sub == "start" then
			if label == "" then
				label = (GetSubZoneText() ~= "" and GetSubZoneText()) or GetRealZoneText() or "Session"
			end
			label = label .. " " .. date("%Y-%m-%d %H:%M")
			session = { key = "session|" .. label, label = label }
			print("|cff40c0ffFishLog|r: session started: " .. label)
			ns.RefreshCastHUD()
		elseif sub == "stop" then
			if session then
				local b = CastStore()[session.key]
				print("|cff40c0ffFishLog|r: session ended: " .. session.label)
				if b then
					print("  " .. SummaryLine(b))
					for _, line in ipairs(ItemLines(b)) do
						print("    " .. line)
					end
				end
				session = nil
				ns.RefreshCastHUD()
			else
				print("|cff40c0ffFishLog|r: no session running.")
			end
		else
			print("|cff40c0ffFishLog|r: /fishlog session start [label]  or  /fishlog session stop")
		end
	elseif cmd == "buff" then
		local name, expires = CampBuff()
		if name then
			local left = expires and expires > 0 and math.max(0, expires - GetTime()) or nil
			print("|cff40c0ffFishLog|r: camp buff active: " .. name .. (left and (" (%d min left)"):format(math.ceil(left / 60)) or ""))
		else
			print("|cff40c0ffFishLog|r: no Fishing Rack buff found. Your buffs right now:")
			EachBuff(function(n, id) print(("    %s (%s)"):format(n, tostring(id))) end)
			print("    If one of those is the Rack buff, tell Claude its name so FishLog can recognise it.")
		end
		local list = {}
		for _, b in pairs(CastStore()) do
			if BuffLine(b) and b.kind ~= "session" then list[#list + 1] = b end
		end
		table.sort(list, function(a, c) return a.casts > c.casts end)
		if #list == 0 then
			print("  no buffed/unbuffed catches logged yet -- they're tracked from now on.")
		end
		for _, b in ipairs(list) do
			print("  |cffffd100" .. BucketName(b) .. "|r: " .. BuffLine(b))
		end
	elseif cmd == "opened" then
		PrintOpened(rest)
	elseif cmd == "hud" then
		hudAlways = not hudAlways
		print("|cff40c0ffFishLog|r: casts HUD " .. (hudAlways and "always on." or "only during sessions."))
		ns.RefreshCastHUD()
	elseif cmd == "reset" and rest:lower() == "casts" then
		ns.Store().casts = {}
		session = nil
		ns.RefreshCastHUD()
		print("|cff40c0ffFishLog|r: cast stats cleared (catch log kept).")
	else
		coreSlash(msg)
		if cmd == "reset" and rest:lower() == "confirm" then
			ns.Store().casts = {}
			session = nil
			ns.RefreshCastHUD()
		end
	end
end
