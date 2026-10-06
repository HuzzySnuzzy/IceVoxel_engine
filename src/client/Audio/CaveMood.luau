--!strict
--[[
	Minecraft's cave mood (pure): BiomeAmbientSoundsHandler's moodiness with the overworld's
	AmbientMoodSettings.LEGACY_CAVE_SETTINGS (ambient.cave, tickDelay 6000, blockSearchExtent 8,
	soundPositionOffset 2). Audio/Ambience runs it every game tick and plays a mood sound
	(Sounds.MOODS) where it says.

	Every tick one block is picked at random within 8 blocks of the player's eyes on each axis
	(nextInt(17) - 8, from the eyes, floored like BlockPos.containing). Then, from that block's
	light:
	  sky light s > 0   the mood drops by s / 15 x 0.001 (daylight wins it back quickly)
	  sky light 0       the mood changes by (1 - block light) / 6000: up by 1 / 6000 in the dark
	                    (block light 0), not at all at 1, down near torches
	The mood never goes below 0. Once it reaches 1 (100%), a mood sound plays in the direction of
	that block, 2 blocks beyond it (its centre's distance from the eyes + 2), and the mood starts
	over at 0. So in complete darkness, with every block around dark (rock counts: light inside
	an opaque block is 0), it takes 6000 ticks, five minutes; with half the blocks around open to
	daylight it never comes. F3 shows it as "mood N%", as Minecraft's debug screen does.

	The light is the game's estimate (`Light`): Rendering/SkyExposure.skyLight for the sky (no
	dimming by leaves or water), and `blockLight` below for light sources (a search through the
	open cells around, as far as Minecraft's light spreads). A block that isn't loaded leaves the
	mood as it is.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

-- (sky, block) light at a cell (0..15 each); nil sky: the cell isn't loaded.
export type Light = (x: number, y: number, z: number) -> (number?, number)
-- The block at a cell, nil where it isn't loaded.
export type GetBlock = (x: number, y: number, z: number) -> number?
-- A random integer in [0, n).
export type NextInt = (n: number) -> number

export type State = { mood: number }

local CaveMood = {}

-- Minecraft's LEGACY_CAVE_SETTINGS.
CaveMood.TICK_DELAY = 6000
CaveMood.SEARCH_EXTENT = 8
CaveMood.SOUND_OFFSET = 2
-- The sky light's pull (per tick, at sky light 15).
CaveMood.SKY_PULL = 0.001
-- Open cells the block light search may visit: a tunnel's light reaches its full 14 blocks, a big
-- cavern's is searched a few blocks around (missing torches farther off). Measured on generated
-- caves (interpreted Luau): a mood tick costs ~0.2 ms on average, one every 50 ms.
CaveMood.LIGHT_BUDGET = 256

local MAX_LIGHT = 15

function CaveMood.new(): State
	return { mood = 0 }
end

--[[
	One game tick for a player whose eyes are at (ex, ey, ez) (blocks). `light` gives the light at
	a cell, `nextInt` the random picks. Returns where a mood sound plays now (blocks), or nil.
]]
function CaveMood.tick(
	state: State,
	ex: number,
	ey: number,
	ez: number,
	light: Light,
	nextInt: NextInt
): (number?, number?, number?)
	local extent = CaveMood.SEARCH_EXTENT
	local span = extent * 2 + 1
	local bx = math.floor(ex + nextInt(span) - extent)
	local by = math.floor(ey + nextInt(span) - extent)
	local bz = math.floor(ez + nextInt(span) - extent)
	local sky, block = light(bx, by, bz)
	if sky == nil then
		return nil
	end
	if sky > 0 then
		state.mood -= sky / MAX_LIGHT * CaveMood.SKY_PULL
	else
		state.mood -= (block - 1) / CaveMood.TICK_DELAY
	end
	if state.mood >= 1 then
		state.mood = 0
		local dx, dy, dz = bx + 0.5 - ex, by + 0.5 - ey, bz + 0.5 - ez
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		if distance <= 0 then
			return ex, ey, ez
		end
		local reach = (distance + CaveMood.SOUND_OFFSET) / distance
		return ex + dx * reach, ey + dy * reach, ez + dz * reach
	end
	state.mood = math.max(state.mood, 0)
	return nil
end

-- Scratch for the block light search, reused by every call: the frontier as flat x, y, z lists
-- and a visited stamp per cell offset from the start (within 32 each way), so a search allocates
-- nothing.
local SPAN = 64
local visited = buffer.create(SPAN * SPAN * SPAN * 2)
local stamp = 0
local frontier: { number } = {}
local nextFrontier: { number } = {}

local function offsetKey(dx: number, dy: number, dz: number): number
	return (((dx + 32) * SPAN + (dy + 32)) * SPAN + (dz + 32)) * 2
end

--[[
	Minecraft's block light (0..15) at cell (x, y, z), from the blocks: a light source's level less
	one per block face it travels through open (not opaque) cells, as Minecraft's light spreads. An
	opaque cell has its own light only (glowstone 15, stone 0). Unknown cells stop the light. At
	most `budget` open cells are searched (CaveMood.LIGHT_BUDGET).
]]
function CaveMood.blockLight(getBlock: GetBlock, x: number, y: number, z: number, budget: number?): number
	local start = getBlock(x, y, z)
	if start == nil then
		return 0
	end
	local own = Blocks.light(start)
	if Blocks.isOpaque(start) then
		return own
	end
	local best = own
	local limit = budget or CaveMood.LIGHT_BUDGET
	stamp += 1
	if stamp > 65535 then
		buffer.fill(visited, 0, 0)
		stamp = 1
	end
	buffer.writeu16(visited, offsetKey(0, 0, 0), stamp)
	table.clear(frontier)
	frontier[1], frontier[2], frontier[3] = 0, 0, 0
	local count = 1
	local distance = 0
	-- Breadth first: cells at distance d come before d + 1, so once a source found can't be beaten
	-- by anything farther (MAX_LIGHT - (d + 1) <= best) the search stops.
	while #frontier > 0 and MAX_LIGHT - (distance + 1) > best do
		table.clear(nextFrontier)
		for i = 1, #frontier, 3 do
			local cx, cy, cz = frontier[i], frontier[i + 1], frontier[i + 2]
			for side = 1, 6 do
				local dx = if side == 1 then 1 elseif side == 2 then -1 else 0
				local dy = if side == 3 then 1 elseif side == 4 then -1 else 0
				local dz = if side == 5 then 1 elseif side == 6 then -1 else 0
				local nx, ny, nz = cx + dx, cy + dy, cz + dz
				if nx >= -31 and nx <= 31 and ny >= -31 and ny <= 31 and nz >= -31 and nz <= 31 then
					local key = offsetKey(nx, ny, nz)
					if buffer.readu16(visited, key) ~= stamp then
						buffer.writeu16(visited, key, stamp)
						local block = getBlock(x + nx, y + ny, z + nz)
						if block then
							local emits = Blocks.light(block) - (distance + 1)
							if emits > best then
								best = emits
							end
							if count < limit and not Blocks.isOpaque(block) then
								count += 1
								local n = #nextFrontier
								nextFrontier[n + 1], nextFrontier[n + 2], nextFrontier[n + 3] = nx, ny, nz
							end
						end
					end
				end
			end
		end
		frontier, nextFrontier = nextFrontier, frontier
		distance += 1
	end
	return math.max(best, 0)
end

return CaveMood
