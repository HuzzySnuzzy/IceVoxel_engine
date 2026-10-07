--!strict
--[[
	A lightning bolt's shape and timing, pure (Weather/LightningView draws it; tests/spec/
	WeatherVisuals checks it). Minecraft's LightningBolt and LightningBoltRenderer, with this
	game's random numbers (Shared/Util/Hash's) from the u32 seed of the server's Lightning message:

	  Shape     `segments(seed)`: the bolt rises SECTIONS (8) sections of SECTION (16) blocks above
	            the struck point, 128 blocks. The main bolt zigzags by -5..5 blocks along x and z
	            a section and ends exactly on the struck point; two branches leave it, from
	            section 6 down to 4 and from 5 down to 3, zigzagging by -15..15
	            (LightningBoltRenderer: k = 0, 1, 2). Widths are Minecraft's widest layer's,
	            0.7 blocks (x (1 + 0.1 x section) on the main bolt, so it thickens upwards).
	  Timing    `timeline(seed, flashes)`: the bolt lives in ticks (20 a second). It shows from
	            tick 0 with life 2, counting down a tick at a time; once life is below 0 it goes
	            when no flashes are left, else when life < -random(10) it flashes again (flashes
	            - 1, life 1, a new shape seed). The sky flashes (Level.skyFlashTime) while life >= 0.
	            Minecraft draws the bolt the whole time it lives, in its latest shape. Returns the
	            phases (each with its shape's seed, the tick it starts and the tick its sky flash
	            ends) and the tick the bolt is gone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Hash = require(Shared.Util.Hash)

export type Segment = {
	x0: number,
	y0: number,
	z0: number,
	x1: number,
	y1: number,
	z1: number,
	-- Width (blocks) and whether it is a branch.
	width: number,
	branch: boolean,
}

export type Phase = { seed: number, start: number, flashUntil: number }

local LightningBolt = {}

LightningBolt.SECTIONS = 8
LightningBolt.SECTION = 16
LightningBolt.HEIGHT = LightningBolt.SECTIONS * LightningBolt.SECTION
-- Minecraft's widest layer (0.1 + 3 x 0.2).
LightningBolt.WIDTH = 0.7

-- An integer in [0, n) from `rng` (Java's nextInt(n), with Hash's generator).
local function nextInt(rng: Hash.Rng, n: number): number
	return rng:next() % n
end

-- The bolt of `seed`: its segments, relative to the struck point (blocks).
function LightningBolt.segments(seed: number): { Segment }
	local sections = LightningBolt.SECTIONS
	local height = LightningBolt.SECTION
	-- The main bolt's offsets at each section's foot (Minecraft's afloat / afloat1), summed from
	-- the top down.
	local xs, zs = table.create(sections, 0), table.create(sections, 0)
	local first = Hash.rng(seed)
	local sx, sz = 0, 0
	for i = sections - 1, 0, -1 do
		xs[i + 1], zs[i + 1] = sx, sz
		sx += nextInt(first, 11) - 5
		sz += nextInt(first, 11) - 5
	end
	local list: { Segment } = {}
	local rng = Hash.rng(seed)
	for k = 0, 2 do
		local from = if k > 0 then sections - 1 - k else sections - 1
		local to = if k > 0 then from - 2 else 0
		local x, z = xs[from + 1] - sx, zs[from + 1] - sz
		for section = from, to, -1 do
			local px, pz = x, z
			if k == 0 then
				x += nextInt(rng, 11) - 5
				z += nextInt(rng, 11) - 5
			else
				x += nextInt(rng, 31) - 15
				z += nextInt(rng, 31) - 15
			end
			local width = LightningBolt.WIDTH
			if k == 0 then
				width *= section * 0.1 + 1
			end
			table.insert(list, {
				x0 = x,
				y0 = section * height,
				z0 = z,
				x1 = px,
				y1 = (section + 1) * height,
				z1 = pz,
				width = width,
				branch = k > 0,
			})
		end
	end
	return list
end

--[[
	The bolt's phases for `seed` and `flashes` (1..3; Minecraft's random 1 + nextInt(3)) and the
	tick it is gone (see the header).
]]
function LightningBolt.timeline(seed: number, flashes: number): ({ Phase }, number)
	local rng = Hash.rng(seed + 0x5BD1E995)
	local phases: { Phase } = { { seed = seed, start = 0, flashUntil = 3 } }
	local life = 2
	local left = math.max(math.floor(flashes), 0)
	local tick = 0
	while tick < 200 do
		tick += 1
		life -= 1
		if life < 0 then
			if left == 0 then
				return phases, tick
			elseif life < -nextInt(rng, 10) then
				left -= 1
				life = 1
				table.insert(phases, { seed = rng:next(), start = tick, flashUntil = tick + 2 })
			end
		end
	end
	return phases, tick
end

-- The phase showing at tick `tick` (nil once the bolt is gone) and whether the sky flashes.
function LightningBolt.at(phases: { Phase }, finish: number, tick: number): (Phase?, boolean)
	if tick < 0 or tick >= finish then
		return nil, false
	end
	local current = phases[1]
	for _, phase in phases do
		if phase.start <= tick then
			current = phase
		end
	end
	return current, tick < current.flashUntil
end

return LightningBolt
