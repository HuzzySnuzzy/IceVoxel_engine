--!strict
--[[
	The blood moon's schedule (the zombie apocalypse's horde nights), pure: a function of the day
	time alone, which every client has (Shared/DayCycle's replicated clock), so the server's
	director (Mobs/ZombieDirector), the sky (client Rendering/BloodMoonSky) and the day counter
	(client Ui/SurvivorHud) agree with no message and nothing to save. `s` is
	Config.Apocalypse.BloodMoon.

	  The day   DayCycle's: day 0 starts at sunrise. The night of day d spans `Start` (12500)
	            .. `End` (23500) ticks into it.
	  Which     that night is a blood moon's when (d + 1) is a multiple of `Every` (3) and at
	            least `First` (3): nights 3, 6, 9... (days 2, 5, 8 counting from 0), one an hour
	            of play. `number` is which one it is (k: 1, 2, 3...): the hordes grow with it.
	  How much  `intensity` ramps from 0 at Start to 1 `Ramp` ticks later, and back down to 0 at
	            End over the last Ramp ticks; it is 0 all day and on other nights. A blood moon is
	            `active` while it is above 0.
	  When      `daysUntil`: 0 when tonight's (or the one now) is a blood moon, else the whole
	            days to the next.
	`/time set` moves the clock, and the schedule with it: everything derived from it is worked
	out again every tick. With `Enabled` false there is none.
	Seasons: the night's day and ticks are the sun's (DayCycle.solarDay, solarTimeInDay: the
	season's warp of the day), so a winter blood moon still rises after the seasonal sunset and
	its night ends after the sunrise, the same night's however the seasons stretch it; with the
	seasons off they are the day time's.
]]

local DayCycle = require(script.Parent.Parent.DayCycle)

-- What the schedule reads of Config.Apocalypse.BloodMoon.
export type Settings = {
	Enabled: boolean?,
	Every: number,
	First: number,
	Start: number,
	End: number,
	Ramp: number,
}

local BloodMoon = {}

-- Is the night of day `day` (0-based, DayCycle.day) a blood moon's?
function BloodMoon.isBloodDay(day: number, s: Settings): boolean
	if s.Enabled == false or not (s.Every >= 1) then
		return false
	end
	local night = day + 1
	return night >= s.First and night % s.Every == 0
end

-- How strong the blood moon is at `dayTime` (0..1; see the header).
function BloodMoon.intensity(dayTime: number, s: Settings): number
	local solar = DayCycle.solarTime(dayTime)
	if not BloodMoon.isBloodDay(DayCycle.day(solar), s) then
		return 0
	end
	local t = DayCycle.timeInDay(solar)
	if t < s.Start or t > s.End then
		return 0
	end
	if s.Ramp <= 0 then
		return 1
	end
	return math.clamp(math.min((t - s.Start) / s.Ramp, (s.End - t) / s.Ramp), 0, 1)
end

-- Is a blood moon up at `dayTime` (its intensity above 0)?
function BloodMoon.active(dayTime: number, s: Settings): boolean
	return BloodMoon.intensity(dayTime, s) > 0
end

-- The day whose night is up at `dayTime` (DayCycle.solarDay: see the header), for `isBloodDay`
-- and `number`.
function BloodMoon.nightOf(dayTime: number): number
	return DayCycle.solarDay(dayTime)
end

-- Which blood moon the night of day `day` has (1, 2, 3...), 0 when it has none.
function BloodMoon.number(day: number, s: Settings): number
	if not BloodMoon.isBloodDay(day, s) then
		return 0
	end
	return math.floor((day + 1) / s.Every) - math.floor((s.First - 1) / s.Every)
end

-- Days from `dayTime` to the next blood moon: 0 when tonight's (or the one now) is one, else the
-- whole days to the next (math.huge when there is none).
function BloodMoon.daysUntil(dayTime: number, s: Settings): number
	if s.Enabled == false or not (s.Every >= 1) then
		return math.huge
	end
	local solar = DayCycle.solarTime(dayTime)
	local day = DayCycle.day(solar)
	if BloodMoon.isBloodDay(day, s) and DayCycle.timeInDay(solar) <= s.End then
		return 0
	end
	-- (The next one is at most First + Every nights away.)
	for ahead = 1, math.max(s.First, 0) + s.Every do
		if BloodMoon.isBloodDay(day + ahead, s) then
			return ahead
		end
	end
	return math.huge
end

return BloodMoon
