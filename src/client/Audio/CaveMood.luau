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
	over at 0. F3 shows it as "mood N%", as Minecraft's debug screen does.

	One change from Minecraft: the bigger the cave, the sooner it comes. A dark block that is open
	(cave air, not rock) counts OPEN_WEIGHT times (`Light`'s third value), so the mood grows with
	the share f of open cave among the blocks within 8 of the player (5 minutes / (1 + 3f)): about
	5 minutes in a narrow tunnel, 2 1/2 in a big cavern (f ~ 0.3), 1 1/2 in the vast caves of the
	Underlands (f ~ 0.8); Minecraft takes 5 wherever it's dark. Daylight still wins it back.

	The light is the game's estimate (`Light`): Rendering/SkyExposure.skyLight for the sky (no
	dimming by leaves or water), and `blockLight` below for light sources (Shared/World/
	LightEstimate: a search through the open cells around, as far as Minecraft's light spreads; the
	server's mob spawning and WAILA use the same). A block that isn't loaded leaves the mood as it
	is.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local LightEstimate = require(Shared.World.LightEstimate)

-- (sky, block) light at a cell (0..15 each) and whether it is open (not opaque); nil sky: the
-- cell isn't loaded.
export type Light = (x: number, y: number, z: number) -> (number?, number, boolean?)
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
-- How much more a dark open block counts than dark rock (bigger caves, sooner moods).
CaveMood.OPEN_WEIGHT = 4
-- Open cells the block light search may visit (LightEstimate.BLOCK_BUDGET): a tunnel's light
-- reaches its full 14 blocks, a big cavern's is searched a few blocks around (missing torches
-- farther off). Measured on generated caves (interpreted Luau): a mood tick costs ~0.2 ms on
-- average, one every 50 ms.
CaveMood.LIGHT_BUDGET = LightEstimate.BLOCK_BUDGET

local MAX_LIGHT = LightEstimate.MAX

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
	local sky, block, open = light(bx, by, bz)
	if sky == nil then
		return nil
	end
	if sky > 0 then
		state.mood -= sky / MAX_LIGHT * CaveMood.SKY_PULL
	elseif block < 1 and open then
		-- (Dark open cave: the bigger the cave around, the more of these.)
		state.mood += (1 - block) * CaveMood.OPEN_WEIGHT / CaveMood.TICK_DELAY
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

--[[
	Minecraft's block light (0..15) at cell (x, y, z), from the blocks: Shared/World/LightEstimate's
	(a light source's level less one per open cell it travels through, at most `budget` cells
	searched: CaveMood.LIGHT_BUDGET), the estimate mob spawning and WAILA use too.
]]
CaveMood.blockLight = LightEstimate.blockLight

return CaveMood
