--!strict
--[[
	The season clock (DayZ-styled; Config.Seasons.Clock, the player setting "seasonClock"): a dial
	of the year's seasons and the day's segments beside the minimap, with the season's days left
	under it (Ui/SeasonClock's layout over Shared/Seasons/Calendar), and the season's toasts
	(Ui/SeasonLine) through the HUD's shared notice queue. Stub until the clock lands: `start`
	draws nothing.
]]

local SeasonHud = {}

local started = false

-- Starts the clock and its toasts (the client boot, after the day line).
function SeasonHud.start()
	assert(not started, "SeasonHud.start was already called")
	started = true
end

return SeasonHud
