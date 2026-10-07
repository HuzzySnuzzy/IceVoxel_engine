--!strict
--[[
	Where rain falls on the server: Minecraft 1.20.1's Level.isRainingAt, pure over the server's
	world (peekChunk: loaded chunks only, never generating one) and the weather there (Shared/
	Weather), so the tests run it. Fire going out and spreading less (Behaviours/Fire), players
	getting wet (Players/ToughAsNails), zombies and skeletons not burning (Mobs/MobWorld) and where
	lightning may strike (World/Lightning) all ask it, through World/WeatherServer.

	  Raining   a cell is rained on when the precipitation over its column is over
	            Weather.RAINING (0.2), what falls there is rain (Weather.formAt: not snow, not a
	            biome without precipitation) and nothing that stops rain stands in the cell or
	            above it (`top`: Minecraft's canSeeSky and its MOTION_BLOCKING heightmap).
	  Stops     a block that blocks movement (Blocks.obstruction: full blocks, leaves, glass, slabs,
	            fences...) or holds a fluid (Minecraft's MOTION_BLOCKING: blocksMotion or a fluid;
	            Shared/Weather.blocksRain, which the client's drops use too). Torches, plants, fire
	            and the like let rain through.
	  Top       the first cell above the highest such block of a column (Minecraft's
	            getHeightmapPos(MOTION_BLOCKING)): where rain lands and where lightning strikes.
	            A column of an unloaded chunk has none (nil).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local ChunkLayout = require(Shared.World.ChunkLayout)
local Weather = require(Shared.Weather)

local SIZE = ChunkLayout.SIZE
local get = ChunkLayout.get

local WeatherRules = {}

-- Does `block` stop rain (Minecraft's MOTION_BLOCKING: Shared/Weather.blocksRain)?
local blocksRain = Weather.blocksRain
WeatherRules.blocksRain = blocksRain

--[[
	The first cell above the highest rain-stopping block of column (x, z) in `world` (0 for a column
	with none), nil when its chunk isn't loaded.
]]
function WeatherRules.top(world: any, x: number, z: number): number?
	local cx, cz = x // SIZE, z // SIZE
	local chunk = world:peekChunk(cx, cz)
	if chunk == nil then
		return nil
	end
	local data = chunk.data
	local lx, lz = x - cx * SIZE, z - cz * SIZE
	for y = chunk.height - 1, 0, -1 do
		if blocksRain(get(data, lx, y, lz)) then
			return y + 1
		end
	end
	return 0
end

--[[
	Is it raining on cell (x, y, z) of `world`, with `precipitation` (0..1) over the column and a
	biome of Minecraft `temperature` (Weather.biomeTemperature; nil: nothing falls)? Minecraft's
	Level.isRainingAt (see the header). An unloaded column is never rained on.
]]
function WeatherRules.rainingAt(
	world: any,
	x: number,
	y: number,
	z: number,
	precipitation: number,
	temperature: number?
): boolean
	if precipitation <= Weather.RAINING or Weather.formAt(temperature, x, y, z) ~= Weather.RAIN then
		return false
	end
	local top = WeatherRules.top(world, x, z)
	return top ~= nil and top <= y
end

return WeatherRules
