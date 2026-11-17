-- FishLog: Sound.lua
--
-- "Louder splash": addons get no event when a fish bites -- the only cue
-- is the bobber's splash sound. So while you're fishing, FishLog turns
-- the Sound Effects slider to full (leaving Master, Music, Ambience and
-- Dialog exactly as you set them), then puts it back once you stop.
--
-- Your original settings are saved to FishLogDB before anything changes,
-- so if the game closes or crashes mid-fishing they're restored on your
-- next login instead of being stuck on the fishing mix.

local addonName, ns = ...

local FISHING = "Fishing"
local RESTORE_AFTER = 20 -- seconds without a new cast before restoring

-- CVar -> value while fishing. Only the Sound Effects volume is changed;
-- the two Enable switches just make sure effects aren't muted outright
-- (they only change anything if you had sound/effects switched off).
local FISHING_MIX = {
	Sound_EnableAllSound = "1",
	Sound_EnableSFX = "1",
	Sound_SFXVolume = "1.0",
}

local function GetCV(name)
	if C_CVar and C_CVar.GetCVar then
		return C_CVar.GetCVar(name)
	end
	return GetCVar and GetCVar(name)
end

local function SetCV(name, value)
	if C_CVar and C_CVar.SetCVar then
		return C_CVar.SetCVar(name, value)
	end
	return SetCVar and SetCVar(name, value)
end

local function Settings()
	FishLogDB.settings = FishLogDB.settings or {}
	local s = FishLogDB.settings
	if s.loudSplash == nil then
		s.loudSplash = true
	end
	return s
end

local restoreToken = 0

local function Restore()
	local backup = FishLogDB.soundBackup
	if not backup then
		return
	end
	for name, value in pairs(backup) do
		SetCV(name, value)
	end
	FishLogDB.soundBackup = nil
end
ns.RestoreSound = Restore

local function Boost()
	if not Settings().loudSplash then
		return
	end
	if not FishLogDB.soundBackup then
		local backup = {}
		for name in pairs(FISHING_MIX) do
			local value = GetCV(name)
			if value ~= nil then
				backup[name] = value
			end
		end
		FishLogDB.soundBackup = backup
	end
	for name, value in pairs(FISHING_MIX) do
		SetCV(name, value)
	end
end

local function ScheduleRestore()
	restoreToken = restoreToken + 1
	local token = restoreToken
	C_Timer.After(RESTORE_AFTER, function()
		if token == restoreToken then
			Restore()
		end
	end)
end

local function GetSpellName(spellID)
	if C_Spell and C_Spell.GetSpellName then
		return C_Spell.GetSpellName(spellID)
	end
	if GetSpellInfo then
		return GetSpellInfo(spellID)
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_LOGIN" then
		-- Left over from a crash or a closed game while fishing.
		Restore()
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, _, spellID = ...
		if unit == "player" and GetSpellName(spellID) == FISHING then
			restoreToken = restoreToken + 1 -- cancel any pending restore
			Boost()
		end
	elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		local unit = ...
		if unit == "player" and FishLogDB.soundBackup then
			ScheduleRestore()
		end
	elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_LOGOUT" then
		-- Something attacked you, or you're leaving: normal sound right away.
		restoreToken = restoreToken + 1
		Restore()
	end
end)

--------------------------------------------------------------------------
-- /fishlog loud [on|off]
--------------------------------------------------------------------------

local previousSlash = SlashCmdList.FISHLOG
SlashCmdList.FISHLOG = function(msg)
	local cmd, rest = ((msg or ""):match("^%s*(.-)%s*$")):match("^(%S*)%s*(.-)$")
	if (cmd or ""):lower() == "loud" then
		local s = Settings()
		rest = (rest or ""):lower()
		if rest == "on" then
			s.loudSplash = true
		elseif rest == "off" then
			s.loudSplash = false
		else
			s.loudSplash = not s.loudSplash
		end
		if not s.loudSplash then
			restoreToken = restoreToken + 1
			Restore()
		end
		print("|cff40c0ffFishLog|r: louder splash " .. (s.loudSplash and "on" or "off") .. ".")
		return
	end
	previousSlash(msg)
end
