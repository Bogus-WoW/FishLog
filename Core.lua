-- FishLog: Core.lua
--
-- SavedVariables storage and the /fishlog slash command. Every fishing
-- catch (see Tracker.lua) gets folded into a per-realm, per-(item, zone,
-- subzone, pool-or-open-water) count -- an aggregated tally rather than a
-- raw event log, since "how many Firefin Snapper did I get in the Barrens"
-- is what actually answers "is this spot worth fishing", and an aggregate
-- stays small no matter how long you fish for.

local addonName, ns = ...

FishLogDB = FishLogDB or {}

local function RealmKey()
	return GetRealmName() or "Unknown"
end
ns.RealmKey = RealmKey

local function Store()
	local key = RealmKey()
	local store = FishLogDB[key]
	if not store then
		store = { catches = {} }
		FishLogDB[key] = store
	end
	store.catches = store.catches or {}
	return store
end
ns.Store = Store

-- pool is true (confirmed/likely fishing pool), false (open water), or nil
-- (couldn't tell -- see Tracker.lua's honesty note about this). We still
-- bucket nil separately from false rather than guessing, so an "unknown"
-- catch never quietly gets counted as a confirmed open-water one.
function ns.RecordCatch(itemID, itemName, zone, subzone, pool, quantity)
	if not itemID or not itemName then
		return
	end
	zone = zone ~= "" and zone or "Unknown zone"
	subzone = subzone ~= "" and subzone or "(open area)"
	quantity = quantity or 1

	local poolKey = (pool == true) and "pool" or (pool == false) and "open" or "unsure"
	local key = table.concat({ itemID, zone, subzone, poolKey }, "|")

	local store = Store()
	local entry = store.catches[key]
	if not entry then
		entry = {
			itemID = itemID,
			itemName = itemName,
			zone = zone,
			subzone = subzone,
			pool = pool,
			count = 0,
		}
		store.catches[key] = entry
	end
	entry.count = entry.count + quantity
end

local function TotalCatches()
	local total, distinct = 0, 0
	for _, entry in pairs(Store().catches) do
		total = total + entry.count
		distinct = distinct + 1
	end
	return total, distinct
end
ns.TotalCatches = TotalCatches

local function PoolLabel(pool)
	if pool == true then
		return "pool"
	elseif pool == false then
		return "open water"
	end
	return "unsure"
end
ns.PoolLabel = PoolLabel

-- Sorted view of the log: by zone, then subzone, then most-caught first --
-- reads like a per-spot report rather than a random dump.
local function SortedCatches(zoneFilter)
	local list = {}
	local needle = zoneFilter and zoneFilter:lower()
	for _, entry in pairs(Store().catches) do
		if not needle or entry.zone:lower():find(needle, 1, true) or entry.subzone:lower():find(needle, 1, true) then
			table.insert(list, entry)
		end
	end
	table.sort(list, function(a, b)
		if a.zone ~= b.zone then
			return a.zone < b.zone
		end
		if a.subzone ~= b.subzone then
			return a.subzone < b.subzone
		end
		return a.count > b.count
	end)
	return list
end
ns.SortedCatches = SortedCatches

--------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------

local function PrintHelp()
	print("|cff40c0ffFishLog|r commands: /fishlog status, /fishlog show [zone text], /fishlog export, /fishlog reset confirm")
	print("  Casts per catch: /fishlog casts [zone/pool text], /fishlog session start [label] | stop, /fishlog hud")
	print("  Louder splash while fishing: /fishlog loud [on|off]")
	print("  Rack buff vs Bloated fish: /fishlog buff   What Bloated fish/clams gave you: /fishlog opened")
end

SLASH_FISHLOG1 = "/fishlog"
SLASH_FISHLOG2 = "/fl"
SlashCmdList.FISHLOG = function(msg)
	msg = (msg or ""):lower()
	msg = msg:match("^%s*(.-)%s*$")

	if msg == "status" then
		local total, distinct = TotalCatches()
		print(("|cff40c0ffFishLog|r: %d catches logged across %d (item, zone, pool-type) combinations for %s."):format(
			total, distinct, RealmKey()))
	elseif msg == "" or msg == "show" or msg:sub(1, 5) == "show " then
		local filter = msg:sub(1, 5) == "show " and msg:sub(6) or nil
		local list = SortedCatches(filter)
		if #list == 0 then
			print("|cff40c0ffFishLog|r: nothing logged yet" .. (filter and (' matching "' .. filter .. '"') or "") .. ". Go fish somewhere!")
		else
			print(("|cff40c0ffFishLog|r: %d entries%s"):format(#list, filter and (' matching "' .. filter .. '"') or ""))
			for _, entry in ipairs(list) do
				print(("  %s / %s -- %s x%d (%s)"):format(
					entry.zone, entry.subzone, entry.itemName, entry.count, PoolLabel(entry.pool)))
			end
		end
	elseif msg == "export" then
		if ns.ShowExport then
			ns.ShowExport()
		end
	elseif msg == "reset confirm" then
		Store().catches = {}
		print("|cff40c0ffFishLog|r: log cleared.")
	elseif msg == "reset" then
		print("|cff40c0ffFishLog|r: this wipes everything logged for this realm. Run /fishlog reset confirm if you're sure.")
	else
		PrintHelp()
	end
end
