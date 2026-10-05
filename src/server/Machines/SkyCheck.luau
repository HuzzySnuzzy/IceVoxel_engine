--!strict
--[[
	Does a cell see the sky straight up (Minecraft's canSeeSky, which Mekanism's solar generators
	check)? Nothing opaque (Blocks.isOpaque: full cubes, leaves, ice) may be in any cell above it,
	up to the top of the world; glass, water, torches, transmitters and other shaped blocks let the
	light through (Minecraft's water dims the sky light, so canSeeSky fails under it there). Pure
	(no Roblox APIs), over the server's WorldServer, and never generates a chunk:

	  loaded      a chunk the server has generated holds its terrain with every edit applied, and
	              everything from its crop height up is air: its cells above are read as they are
	              (trees and player builds included).
	  not loaded  the column is its edits over the natural terrain, whose height (the first air
	              block) the generator gives for one column without making the chunk
	              (TerrainGenerator.column): an unedited cell below that height is ground, which
	              covers the cell (the surface is never open: caves don't reach it), and an
	              unedited cell above it counts as air. So trees and frozen sea ice over a cell
	              are only seen while the chunk is loaded, and an unedited cave cell a dug shaft
	              passes through counts as rock; Machines/MachineWorld looks when blocks change,
	              which always loads the chunk.

	Machines/MachineWorld caches the answers per cell (`seesSky`) and drops them when a block above
	changes; this is the uncached look, at most a column's height of reads.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Config = require(Shared.Config)

local WorldServer = require(script.Parent.Parent.World.WorldServer)

local HEIGHT = Config.WorldHeight
local SIZE = ChunkLayout.SIZE

local SkyCheck = {}

--[[
	Is nothing opaque in any cell straight above (x, y, z) in `world`? Cells at the top of the
	world (and above it) always see the sky. Reads the chunk if the server has it, else the edits
	and the generator's ground height (see the header); never generates terrain.
]]
function SkyCheck.open(world: WorldServer.World, x: number, y: number, z: number): boolean
	local from = math.max(y + 1, 0)
	if from >= HEIGHT then
		return true
	end
	local cx, cz = x // SIZE, z // SIZE
	local lx, lz = x - cx * SIZE, z - cz * SIZE
	local chunk = world:peekChunk(cx, cz)
	if chunk then
		local data = chunk.data
		for cy = from, chunk.height - 1 do
			if Blocks.isOpaque(ChunkLayout.get(data, lx, cy, lz)) then
				return false
			end
		end
		return true
	end
	local edits = world:chunkEdits(cx, cz)
	local ground = world.generator.column(x, z)
	for cy = from, HEIGHT - 1 do
		local block = if edits then edits[ChunkLayout.localIndex(lx, cy, lz)] else nil
		if block == nil then
			if cy < ground then
				-- (Natural ground nobody dug out.)
				return false
			elseif edits == nil then
				return true
			end
		elseif Blocks.isOpaque(block) then
			return false
		end
	end
	return true
end

return SkyCheck
