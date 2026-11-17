-- FishLog: Tracker.lua
--
-- Detects fishing catches and feeds them to Core.lua's RecordCatch.
--
-- Catch detection: fishing almost always auto-loots a single item straight
-- to your bags with no loot window at all, so watching LOOT_OPENED alone
-- would miss most catches. CHAT_MSG_LOOT fires for every item you receive
-- either way (auto-looted or taken from a window), so that's the one
-- reliable signal -- we just need to know "was this loot message caused by
-- a fishing catch", which we get by remembering that Fishing was cast
-- successfully a few seconds ago.
--
-- Pool-vs-open-water detection is the honest weak point here: Blizzard
-- doesn't expose a direct "you're fishing a pool" flag to addons. We use
-- two real signals real fishing addons rely on:
--   1. The client-side progress toward the "That's a Lot of Bait" /
--      "fish from X pools" achievement criterion updates right when a pool
--      catch resolves -- if we see that update land within ~1.5s of a
--      catch, it's a confirmed pool catch. This is Blizzard's own tracking,
--      not a guess, but it depends on that achievement existing/being
--      tracked on this server's ruleset, which we can't confirm for
--      Forever ahead of time.
--   2. A mouseover tooltip reading like "<something> School" at the moment
--      you cast, since pools are usually right-clicked directly.
-- If NEITHER signal fires, we log the catch as open water rather than a
-- third "unsure" bucket -- meaning a real pool catch can end up
-- mislabeled as open water if you weren't hovering it and the achievement
-- signal didn't fire, but a genuine open-water catch should never get
-- mislabeled the other way around.

local addonName, ns = ...

-- How long after a successful Fishing cast we still attribute the next
-- loot message to fishing. Long enough for the bobber travel + splash +
-- your reaction time; short enough that an unrelated loot minutes later
-- (e.g. a mob you killed while waiting) doesn't get miscounted.
local ATTRIBUTION_WINDOW = 30

-- How close a pool-achievement update has to land to a catch to count as
-- confirming it (FishingBuddy, a real fishing addon, uses 0.75s for the
-- same correlation -- we're a little more lenient to allow for latency).
local POOL_CONFIRM_WINDOW = 1.5

local pending -- { zone, subzone, tooltipPool, expires }
local lastPoolAchievementTime

local function GetSpellName(spellID)
	if C_Spell and C_Spell.GetSpellName then
		return C_Spell.GetSpellName(spellID)
	end
	if GetSpellInfo then
		return GetSpellInfo(spellID)
	end
	return nil
end

-- Best-effort "is the player hovering something that looks like a fishing
-- pool right now" check, done at the moment of casting (pools are
-- typically clicked directly, so the tooltip is often still showing).
-- Words that show up in fishing-pool names: "Firefin Snapper School",
-- "Patch of Elemental Water", "Stonescale Eel Swarm", "Floating Wreckage",
-- "Oil Spill", "Muddy Churning Waters", "Steam Pump Flotsam", etc.
local POOL_WORDS = { "school", "pool", "shoal", "patch", "swarm", "wreckage", "debris", "spill", "waters", "flotsam" }

-- Returns the hovered pool's name (original casing), or nil.
local function TooltipPoolName()
	if not (GameTooltip and GameTooltip.IsShown and GameTooltip:IsShown()) then
		return nil
	end
	local textLine = _G["GameTooltipTextLeft1"]
	local text = textLine and textLine.GetText and textLine:GetText()
	if issecretvalue and issecretvalue(text) then
		return nil
	end
	if type(text) ~= "string" then
		return nil
	end
	local lower = text:lower()
	for _, word in ipairs(POOL_WORDS) do
		if lower:find(word, 1, true) then
			return text
		end
	end
	return nil
end
ns.TooltipPoolName = TooltipPoolName

local function TooltipLooksLikePool()
	return TooltipPoolName() ~= nil
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
watcher:RegisterEvent("TRACKED_ACHIEVEMENT_UPDATE")
watcher:RegisterEvent("CHAT_MSG_LOOT")

watcher:SetScript("OnEvent", function(_, event, ...)
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellID = ...
		if unit ~= "player" then
			return
		end
		local name = GetSpellName(spellID)
		if name ~= "Fishing" then
			return
		end
		pending = {
			zone = GetRealZoneText() or "",
			subzone = GetSubZoneText() or "",
			tooltipPool = TooltipLooksLikePool(),
			expires = GetTime() + ATTRIBUTION_WINDOW,
		}
	elseif event == "TRACKED_ACHIEVEMENT_UPDATE" then
		local achievementID = ...
		-- 5036 is "That's a Lot of Bait" (catch fish from pools) on
		-- retail; harmless to check for even if this ruleset doesn't have
		-- it -- the event just never fires with that ID and we fall back
		-- to the tooltip signal below.
		if achievementID == 5036 then
			lastPoolAchievementTime = GetTime()
		end
	elseif event == "CHAT_MSG_LOOT" then
		if not pending or GetTime() > pending.expires then
			return
		end
		-- loot from opening a Bloated fish/clam (or a mob) isn't a catch
		if ns.LootIsNotFishing and ns.LootIsNotFishing() then
			return
		end
		local text = ...
		if not text then
			return
		end
		local link = text:match("|Hitem:[^|]+|h%[.-%]|h")
		if not link then
			return
		end
		local displayName = text:match("%[(.-)%]")
		local quantity = tonumber(text:match("x(%d+)%s*%.?%s*$")) or 1

		local itemID
		if C_Item and C_Item.GetItemInfoInstant then
			itemID = C_Item.GetItemInfoInstant(link)
		elseif GetItemInfoInstant then
			itemID = GetItemInfoInstant(link)
		end
		if not itemID then
			return
		end

		local poolConfirmed = lastPoolAchievementTime and (GetTime() - lastPoolAchievementTime) < POOL_CONFIRM_WINDOW
		local pool = (poolConfirmed or pending.tooltipPool) and true or false

		ns.RecordCatch(itemID, displayName or ("Item #" .. itemID), pending.zone, pending.subzone, pool, quantity)
		-- Don't clear `pending` here: a single fishing catch can trigger
		-- more than one CHAT_MSG_LOOT line (e.g. a treasure catch that
		-- includes bonus items), and those all belong to the same cast.
		-- It naturally expires via ATTRIBUTION_WINDOW instead.
	end
end)
