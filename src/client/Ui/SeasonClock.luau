--!strict
--[[
	The season clock's face, pure (numbers in, geometry and colour keys out, so the tests check
	every piece): Don't Starve's segmented clock with the year around it, as the "Combined Status"
	and "Season Clock" mods draw it. Ui/SeasonHud builds it from plain rotated Frames (no images),
	in Ui/Theme's colours, at HudLayout's `clock` place (a dial of HudLayout.CLOCK GUI pixels,
	CLOCK_SMALL on tight screens).

	  Geometry   everything is in fractions of the dial (0..1 from its top left; Frames use scale
	             UDim2s, so nothing is snapped to whole GUI pixels at small sizes) and angles are
	             degrees clockwise from the top. A `Bar` is a radial bar between two radii (as
	             fractions of the dial's radius, the half), centred on its middle and turned by
	             its angle: Frame.Rotation turns about the centre, so AnchorPoint is (0.5, 0.5).
	  Year ring  YEAR_TICKS (32) ticks around the outside, a year's share each from the top
	             (Autumn's first day) clockwise, coloured by the season holding the tick's middle
	             (`yearSeasons`: proportional to the lengths; 8-day seasons make a tick a day), the
	             other seasons' dimmer; the marker (`yearAngle`) crosses the ring at the year's
	             progress.
	  Day ring   DAY_TICKS (16) ticks inside it, Don't Starve's segments: each 1500 ticks of the
	             day (tick 0 is sunrise, 06:00), coloured "day", "dusk" or "night" by the height of
	             the warped sun at its middle (`daySegments`: Shared/DayCycle.sunHeight, which
	             follows the seasons' warp): day from DAY_HEIGHT (the sky at three quarters of its
	             brightness, DayCycle.daylight), night from NIGHT_HEIGHT down (some 12 degrees under
	             the horizon), dusk between. Autumn and spring come out 8 day, 2 dusk and 6 night
	             segments, winter 6 / 2 / 8, summer 10 / 2 / 4, so winter's long nights and
	             summer's long days show. (Minecraft's isDay, then a sunrise glow above 0.1 for
	             dusk, sampled the same way gives autumn no dusk at all: 8 / 0 / 8, its day too
	             generous for 1500 tick segments.) The day ring is a
	             24 hour dial with noon at the top and midnight at the bottom; the hand
	             (`handAngle`) crosses the ring at the time of day.
	  Centre     the day number (DayCycle.day + 1, the "Day N" of the day line) in the HUD's
	             pixel font, smaller for three digits and more (`dayText`).
	Ui/SeasonHud turns the hand and the marker every UPDATE seconds and recolours the ticks only
	when the season, the day or the day's split changes (`signature`).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Calendar = require(Shared.Seasons.Calendar)
local DayCycle = require(Shared.DayCycle)

export type Segment = "day" | "dusk" | "night"

-- A radial bar (see the header): its centre and size in fractions of the dial, its angle.
export type Bar = { x: number, y: number, w: number, h: number, rotation: number }

local SeasonClock = {}

-- Ticks of the year ring and of the day ring.
SeasonClock.YEAR_TICKS = 32
SeasonClock.DAY_TICKS = 16
-- Day ticks a segment spans (24000 / 16: Don't Starve's 30 second segments of its 8 minute day).
SeasonClock.SEGMENT = DayCycle.TICKS_PER_DAY / SeasonClock.DAY_TICKS
-- A segment is day where the sun (DayCycle.sunHeight) stands at least this high, night where it
-- is at most this low, dusk between (see the header).
SeasonClock.DAY_HEIGHT = 0.275
SeasonClock.NIGHT_HEIGHT = -0.2
-- Seconds between turns of the hand and the marker (as Ui/SurvivorHud's looks at the clock).
SeasonClock.UPDATE = 0.25

-- The rings' radii (fractions of the dial's radius) and the ticks' widths (fractions of the dial).
SeasonClock.YEAR_RING = table.freeze({ inner = 0.78, outer = 0.96, width = 0.05 })
SeasonClock.DAY_RING = table.freeze({ inner = 0.5, outer = 0.68, width = 0.075 })
-- The hand and the marker reach this far past their ring on each side, this wide.
SeasonClock.POINTER_REACH = 0.06
SeasonClock.POINTER_WIDTH = 0.04
-- The centre's free disc (a fraction of the dial: its diameter), for the day number.
SeasonClock.CENTRE = 0.5

--[[
	A radial bar at `angle` (degrees clockwise from the top) from radius `inner` to `outer`
	(fractions of the dial's radius), `width` wide (a fraction of the dial).
]]
function SeasonClock.bar(angle: number, inner: number, outer: number, width: number): Bar
	local radians = math.rad(angle)
	local middle = (inner + outer) / 4
	return {
		x = 0.5 + middle * math.sin(radians),
		y = 0.5 - middle * math.cos(radians),
		w = width,
		h = (outer - inner) / 2,
		rotation = angle,
	}
end

-- The angle (degrees) of year tick `i` (1..YEAR_TICKS): its middle.
function SeasonClock.yearTickAngle(i: number): number
	return (i - 0.5) * 360 / SeasonClock.YEAR_TICKS
end

-- The angle (degrees) of day segment `j` (1..DAY_TICKS): its middle, noon at the top.
function SeasonClock.segmentAngle(j: number): number
	return ((j - 0.5) * SeasonClock.SEGMENT - Calendar.NOON) * 360 / DayCycle.TICKS_PER_DAY
end

-- The year ring's ticks (fixed: their colours change, never their places).
function SeasonClock.yearTicks(): { Bar }
	local ring = SeasonClock.YEAR_RING
	local list = table.create(SeasonClock.YEAR_TICKS)
	for i = 1, SeasonClock.YEAR_TICKS do
		list[i] = SeasonClock.bar(SeasonClock.yearTickAngle(i), ring.inner, ring.outer, ring.width)
	end
	return list
end

-- The day ring's ticks.
function SeasonClock.dayTicks(): { Bar }
	local ring = SeasonClock.DAY_RING
	local list = table.create(SeasonClock.DAY_TICKS)
	for j = 1, SeasonClock.DAY_TICKS do
		list[j] = SeasonClock.bar(SeasonClock.segmentAngle(j), ring.inner, ring.outer, ring.width)
	end
	return list
end

-- The season (Calendar.AUTUMN .. SUMMER) of each year tick for `lengths` (see the header).
function SeasonClock.yearSeasons(lengths: { number }): { number }
	local year = lengths[1] + lengths[2] + lengths[3] + lengths[4]
	local list = table.create(SeasonClock.YEAR_TICKS)
	for i = 1, SeasonClock.YEAR_TICKS do
		local day = (i - 0.5) / SeasonClock.YEAR_TICKS * year
		local season, start = Calendar.SEASONS, 0
		for s = 1, Calendar.SEASONS do
			if day < start + lengths[s] then
				season = s
				break
			end
			start += lengths[s]
		end
		list[i] = season
	end
	return list
end

-- The segment (`day`, `dusk` or `night`) of the sun at `dayTime` (see the header).
function SeasonClock.segmentAt(dayTime: number): Segment
	local height = DayCycle.sunHeight(dayTime)
	if height >= SeasonClock.DAY_HEIGHT then
		return "day"
	elseif height > SeasonClock.NIGHT_HEIGHT then
		return "dusk"
	end
	return "night"
end

-- The day ring's segments of the day holding `dayTime` (DAY_TICKS of them, from sunrise).
function SeasonClock.daySegments(dayTime: number, into: { Segment }?): { Segment }
	local list = into or table.create(SeasonClock.DAY_TICKS)
	local start = math.floor(dayTime / DayCycle.TICKS_PER_DAY) * DayCycle.TICKS_PER_DAY
	for j = 1, SeasonClock.DAY_TICKS do
		list[j] = SeasonClock.segmentAt(start + (j - 0.5) * SeasonClock.SEGMENT)
	end
	return list
end

-- The hand's angle (degrees) at `dayTime`: noon at the top, midnight at the bottom.
function SeasonClock.handAngle(dayTime: number): number
	local ticks = dayTime - math.floor(dayTime / DayCycle.TICKS_PER_DAY) * DayCycle.TICKS_PER_DAY
	return ((ticks - Calendar.NOON) / DayCycle.TICKS_PER_DAY * 360) % 360
end

-- The year marker's angle (degrees) at `position` (Calendar.Position): Autumn's first day at the top.
function SeasonClock.yearAngle(position: Calendar.Position): number
	return (position.yearProgress * 360) % 360
end

-- The hand's bar at `angle` (across the day ring).
function SeasonClock.hand(angle: number): Bar
	local ring, reach = SeasonClock.DAY_RING, SeasonClock.POINTER_REACH
	return SeasonClock.bar(angle, ring.inner - reach, ring.outer + reach, SeasonClock.POINTER_WIDTH)
end

-- The year marker's bar at `angle` (across the year ring, its corners kept inside the disc).
function SeasonClock.marker(angle: number): Bar
	local ring, reach = SeasonClock.YEAR_RING, SeasonClock.POINTER_REACH
	return SeasonClock.bar(angle, ring.inner - reach, math.min(ring.outer + reach, 0.98), SeasonClock.POINTER_WIDTH)
end

--[[
	The centre's day number at `dayTime` and its TextSize (GUI pixels) in a dial `dial` GUI pixels
	across: the pixel font's 8 while it fits the centre's disc (8 a character), else 6, else 4.
]]
function SeasonClock.dayText(dayTime: number, dial: number): (string, number)
	local text = tostring(DayCycle.day(dayTime) + 1)
	local room = dial * SeasonClock.CENTRE
	for _, size in { 8, 6 } do
		if #text * size <= room then
			return text, size
		end
	end
	return text, 4
end

--[[
	What the ticks' colours depend on (a string): the season, the lengths and the day's split. The
	owner recolours only when it changes.
]]
function SeasonClock.signature(season: number, lengths: { number }, segments: { Segment }): string
	local parts = table.create(SeasonClock.DAY_TICKS + 2)
	parts[1] = tostring(season)
	parts[2] = table.concat(lengths, ",")
	for j, segment in segments do
		parts[j + 2] = string.sub(segment, 1, 2)
	end
	return table.concat(parts, ":")
end

return SeasonClock
