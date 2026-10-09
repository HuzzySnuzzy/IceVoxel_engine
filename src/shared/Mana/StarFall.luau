--!strict
--[[
	When and where Fallen Stars fall (Config.Mana.Stars), pure: server Players/FallenStars rolls
	this once a second for every player who sees stars and drops a Fallen Star item there.

	Terraria drops stars all night (7:30 PM to 4:30 AM) at a chance per tick that gives a small
	world about 40 a night, which a player crossing it meets as roughly one per 100 tiles of width;
	at dawn the ones still lying about vanish. Here the night is Minecraft's 13000..23000 ticks of
	the day (NightStart, NightEnd: 500 s of a 20-minute day, Config.Time.DayLength), and each
	player in a survival-like or creative mode gets PerNight 5 a night on average (about one Mana
	Crystal a night), wherever they are:

	  isNight      time of day (ticks, 0..24000) in NightStart..NightEnd.
	  dawned       the night just ended (a tick of the clock passed NightEnd, or /time jumped to
	               day): the stars still on the ground vanish then.
	  chance       a second's chance of a star: PerNight / the night's real seconds (PerNight / 500
	               at a 1200 s day: 1%), so a night gives PerNight on average whatever the day's
	               length.
	  pick         a column on the ring MinDistance..MaxDistance (16..48) blocks around the
	               player, even over its area (r = sqrt of a uniform r²), at whole block centres.
	  topY         the highest block of that column that is not air (Air or CaveAir), scanning
	               down from the world's top: where the star lands (never inside a cave, on a roof
	               or a tree as it comes); nil when the column has none or isn't generated (the
	               server's peekBlock gives nil there: no star where the world doesn't exist yet).
	  spawnY       FallHeight 40 blocks over the block above that top: where the star starts, to
	               fall with item physics from -1 block a tick (StartSpeed).
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)

local Settings = Config.Mana.Stars
local DAY = 24000

local StarFall = {}

-- Blocks a tick a star starts falling at (downwards).
StarFall.START_SPEED = 1

-- Is time of day `time` (ticks; any day: taken modulo 24000) night?
function StarFall.isNight(time: number): boolean
	local t = time % DAY
	return t >= Settings.NightStart and t < Settings.NightEnd
end

-- Did the night end between time of day `before` and `now` (ticks)?
function StarFall.dawned(before: number, now: number): boolean
	return StarFall.isNight(before) and not StarFall.isNight(now)
end

-- Real seconds of a night with a day of `dayLength` seconds.
function StarFall.nightSeconds(dayLength: number): number
	return (Settings.NightEnd - Settings.NightStart) / DAY * dayLength
end

-- A second's chance of a star for one player (0..1).
function StarFall.chance(dayLength: number): number
	local seconds = StarFall.nightSeconds(dayLength)
	if seconds <= 0 then
		return 0
	end
	return math.clamp(Settings.PerNight / seconds, 0, 1)
end

-- Where on the ring around (x, z) a star falls: a block column's centre (x, z) with `random`
-- giving 0..1.
function StarFall.pick(random: () -> number, x: number, z: number): (number, number)
	local least, most = Settings.MinDistance, Settings.MaxDistance
	local angle = random() * math.pi * 2
	local r = math.sqrt(least * least + random() * (most * most - least * least))
	return math.floor(x + math.cos(angle) * r) + 0.5, math.floor(z + math.sin(angle) * r) + 0.5
end

-- The highest block of column (x, z) that is no air, from `top` down (nil: none, or not generated).
function StarFall.topY(
	getBlock: (x: number, y: number, z: number) -> number?,
	x: number,
	z: number,
	top: number
): number?
	local bx, bz = math.floor(x), math.floor(z)
	for y = top, 0, -1 do
		local block = getBlock(bx, y, bz)
		if block == nil then
			return nil
		elseif block ~= Blocks.AIR and block ~= Blocks.CAVE_AIR then
			return y
		end
	end
	return nil
end

-- Where a star over a column topped at `top` starts (the bottom of its box, blocks).
function StarFall.spawnY(top: number): number
	return top + 1 + Settings.FallHeight
end

return StarFall
