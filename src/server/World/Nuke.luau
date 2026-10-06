--!strict
--!native
--[[
	The Nuke's blast (BlockList Nuke, lit by Behaviours/Tnt; Config.Nuke): a crater no ray
	explosion could dig. Minecraft's Explosion casts 1352 rays whatever the power, so a huge one
	leaves untouched gaps between them far out and still reads tens of thousands of blocks in one
	tick; this walks the cells instead, nearest first, a budget a tick. Pure Luau on WorldServer,
	so the tests run it.

	  The blast   `detonate(world, x, y, z)` (the centre, blocks): at once, the handler
	              (Explosions.effects: items, players' damage and push with Config.Nuke.Power
	              through Minecraft's formula, so the open within about 50 blocks is deadly and
	              walls and hills shield; every player within EffectDistance sees the flash and the
	              mushroom cloud: client Rendering/ExplosionView) and the boom
	              (entity.nuke.explode, heard 256 blocks away). Then a job digs the crater.
	  The crater  every cell within Radius x (1 + Ragged x w) + c of the centre, where w (-1..1)
	              is smooth 3D noise of wavelength RaggedScale and c a block of crumble (-0.5..0.5,
	              hashed per cell), seeded by the Nuke's position (`crater`): the same Nuke in the
	              same place digs the same crater. A cell at distance d inside its radius r goes
	              (air, no drops) when its blast resistance is below Strength x (1 - d / r):
	              dirt and sand to the rim, stone (6) to 0.9 of it, obsidian (1200), bedrock and
	              fluids (100) never, so water pours in and an obsidian bunker stands.
	  Scorching   around it, out to ScorchRadius sideways and the crater's largest radius up and
	              down (an ellipsoid): blocks with a blast resistance under ScorchResistance
	              (leaves, plants, glass, snow, torches) are blown away; grass, dry grass, podzol
	              and mycelium turn to dirt, or coarse dirt one time in three; logs stand. Fuel
	              there catches (World/Explosions.ignite).
	  Fire        one air cell in FireOdds (hashed) over an opaque block that stays catches fire,
	              in the crater and around it.
	  Explosives  TNT and Nukes it reaches are lit with the short fuse (Explosions.reached, the
	              primer of Behaviours/Tnt), lit ones stay: chain reactions.
	  Costs       the cells are visited in order of distance (a list built once, `offsets`), so
	              the crater grows outwards from the centre: per server tick (`step`, after
	              World/Explosions) at most EditsPerTick block changes (each replicated to every
	              client: 12 bytes) and ReadsPerTick block reads, shared by every Nuke going off.
	              Unloaded chunks are skipped and never generated.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Hash = require(Shared.Util.Hash)
local Noise = require(Shared.Generation.Noise)
local SharedSounds = require(Shared.Sounds)

local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Explosions = require(script.Parent.Explosions)
local FuelBlast = require(script.Parent.FuelBlast)
local WorldServer = require(script.Parent.WorldServer)

type World = WorldServer.World

local Settings = Config.Nuke
local HEIGHT = Config.WorldHeight
local B = Blocks.id
local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR
local FIRE = B.Fire
local DIRT, COARSE_DIRT = B.Dirt, B.CoarseDirt
local RESISTANCE = Blocks.blastResistanceLut
local readf32 = buffer.readf32
local readi8 = buffer.readi8
local sqrt = math.sqrt
local floor = math.floor
-- (nil until Shared/Sounds has it.)
local BOOM = SharedSounds.find("entity.nuke.explode")
-- Salts of the crater's hashes.
local SEED_SALT = Hash.string("nuke")
local CRUMBLE = 1
local SCORCH = 2
local FIRE_SALT = 3

-- Soil that scorches into dirt.
local SCORCHED: { [number]: boolean } =
	{ [B.Grass] = true, [B.DryGrass] = true, [B.Podzol] = true, [B.Mycelium] = true }

-- One Nuke's crater: its centre (the cell, and the point), seed and edge noise.
export type Crater = {
	x: number,
	y: number,
	z: number,
	fx: number,
	fy: number,
	fz: number,
	seed: number,
	noise: (x: number, y: number, z: number) -> number,
}

type Job = { crater: Crater, cursor: number }

type State = { jobs: { Job } }

local Nuke = {}

local states: { [World]: State } = setmetatable({}, { __mode = "k" }) :: any

local function stateOf(world: World): State
	local state = states[world]
	if state == nil then
		state = { jobs = {} }
		states[world] = state
	end
	return state
end

-- The crater's radius at its widest and narrowest (blocks, crumble included).
function Nuke.maxRadius(): number
	return Settings.Radius * (1 + Settings.Ragged) + 0.5
end
function Nuke.minRadius(): number
	return Settings.Radius * (1 - Settings.Ragged) - 0.5
end

--[[ The cells, nearest first ]]

-- (dx, dy, dz) of every cell the blast visits, i8 each, in order of distance; built on first use.
local offsetList: buffer? = nil
local offsetCount = 0

--[[
	The offsets of every cell the blast visits (the ellipsoid of ScorchRadius sideways and the
	largest crater radius up and down, which holds the crater), nearest first, as i8 triples, and
	how many. Built once (a bucket sort by half blocks), kept.
]]
function Nuke.offsets(): (buffer, number)
	local built = offsetList
	if built then
		return built, offsetCount
	end
	local vertical = math.ceil(Nuke.maxRadius())
	local side = math.ceil(math.max(Settings.ScorchRadius, vertical))
	assert(side <= 127, "Config.Nuke: radii up to 127 blocks")
	local s2, v2 = Settings.ScorchRadius * Settings.ScorchRadius, vertical * vertical
	local buckets: { { number } } = {}
	local count = 0
	for dy = -vertical, vertical do
		local ey = dy * dy / v2
		for dz = -side, side do
			for dx = -side, side do
				local h = dx * dx + dz * dz
				if h / s2 + ey <= 1 or h + dy * dy <= v2 then
					local bucket = floor(sqrt(h + dy * dy) * 2) + 1
					local list = buckets[bucket]
					if list == nil then
						list = {}
						buckets[bucket] = list
					end
					local n = #list
					list[n + 1] = dx
					list[n + 2] = dy
					list[n + 3] = dz
					count += 1
				end
			end
		end
	end
	local out = buffer.create(count * 3)
	local at = 0
	for bucket = 1, floor(sqrt(side * side * 2 + vertical * vertical) * 2) + 1 do
		local list = buckets[bucket]
		if list then
			for i = 1, #list do
				buffer.writei8(out, at, list[i])
				at += 1
			end
		end
	end
	offsetList, offsetCount = out, count
	return out, count
end

--[[ The crater's rules (pure) ]]

-- The crater of a Nuke going off at (x, y, z) (blocks): seeded by its cell.
function Nuke.crater(x: number, y: number, z: number): Crater
	local cx, cy, cz = floor(x), floor(y), floor(z)
	local seed = Hash.hash3(SEED_SALT, cx, cy, cz)
	return {
		x = cx,
		y = cy,
		z = cz,
		fx = x,
		fy = y,
		fz = z,
		seed = seed,
		noise = Noise.noise3(seed, "nuke edge", 1 / Settings.RaggedScale),
	}
end

-- The crater's radius through cell (bx, by, bz) (blocks): the noise's wander and the crumble.
function Nuke.radiusAt(crater: Crater, bx: number, by: number, bz: number): number
	local wander = math.clamp(crater.noise(bx, by, bz) * 2, -1, 1)
	local crumble = Hash.float3(crater.seed + CRUMBLE, bx, by, bz) - 0.5
	return Settings.Radius * (1 + Settings.Ragged * wander) + crumble
end

-- How far cell (bx, by, bz)'s centre is from the crater's centre (blocks).
local function distance(crater: Crater, bx: number, by: number, bz: number): number
	local dx, dy, dz = bx + 0.5 - crater.fx, by + 0.5 - crater.fy, bz + 0.5 - crater.fz
	return sqrt(dx * dx + dy * dy + dz * dz)
end

--[[
	What the blast makes of `block` at (bx, by, bz): the block it becomes (AIR blown away, Dirt
	or CoarseDirt scorched), or nil when it stays. Air and fire stay (fire aside: `fireSpot`), and
	so do fluids outside the crater (World/Nuke lights fuel there). Explosives are lit before
	this matters (Explosions.reached).
]]
function Nuke.fate(crater: Crater, bx: number, by: number, bz: number, block: number): number?
	if block == AIR or block == CAVE_AIR or block == FIRE then
		return nil
	end
	local d = distance(crater, bx, by, bz)
	local resistance = readf32(RESISTANCE, block * 4)
	if d <= Nuke.maxRadius() then
		local r = Nuke.radiusAt(crater, bx, by, bz)
		if d < r then
			return if resistance < Settings.Strength * (1 - d / r) then AIR else nil
		end
	end
	if Blocks.get(block).fluid then
		return nil
	elseif SCORCHED[block] then
		return if Hash.float3(crater.seed + SCORCH, bx, by, bz) < 1 / 3 then COARSE_DIRT else DIRT
	elseif resistance < Settings.ScorchResistance then
		return AIR
	end
	return nil
end

-- Is cell (bx, by, bz) one of the crater's hashed fire spots (one in FireOdds)?
function Nuke.fireSpot(crater: Crater, bx: number, by: number, bz: number): boolean
	return Hash.float3(crater.seed + FIRE_SALT, bx, by, bz) * Settings.FireOdds < 1
end

--[[ In the world ]]

--[[
	A Nuke goes off at (x, y, z) (blocks): its effects and boom now, the crater over the next
	ticks (`step`).
]]
function Nuke.detonate(world: World, x: number, y: number, z: number)
	Explosions.effects(world, x, y, z, Settings.Power, Settings.EffectDistance)
	if BOOM then
		Sounds.play(BOOM, x, y, z)
	end
	table.insert(stateOf(world).jobs, { crater = Nuke.crater(x, y, z), cursor = 0 })
end

-- Craters still being dug.
function Nuke.pending(world: World): number
	local state = states[world]
	return if state then #state.jobs else 0
end

-- Works on `job` until it is done or a budget runs out; returns the edits and reads it took and
-- whether it is done.
local function work(world: World, job: Job, editBudget: number, readBudget: number): (number, number, boolean)
	local offsets, count = Nuke.offsets()
	local crater = job.crater
	local cx, cy, cz = crater.x, crater.y, crater.z
	local edits, reads = 0, 0
	local cursor = job.cursor
	while cursor < count and edits < editBudget and reads < readBudget do
		local at = cursor * 3
		cursor += 1
		local by = cy + readi8(offsets, at + 1)
		if by < 0 or by >= HEIGHT then
			continue
		end
		local bx, bz = cx + readi8(offsets, at), cz + readi8(offsets, at + 2)
		local block = world:peekBlock(bx, by, bz)
		reads += 1
		if block == nil then
			continue
		end
		local now = block
		if block ~= AIR and block ~= CAVE_AIR and block ~= FIRE then
			local fate = Nuke.fate(crater, bx, by, bz, block)
			if fate == nil then
				-- (Fuel the heat reaches outside the crater goes off; inside it is vaporised.)
				if FuelBlast.isFuel(block) then
					Explosions.ignite(world, bx, by, bz)
				end
				continue
			elseif Explosions.reached(world, bx, by, bz, block) then
				-- (Lit: an edit too.)
				if world:peekBlock(bx, by, bz) ~= block then
					edits += 1
				end
				continue
			end
			if world:setBlock(bx, by, bz, fate) then
				edits += 1
			end
			now = fate
		end
		if (now == AIR or now == CAVE_AIR) and by > 0 and edits < editBudget and Nuke.fireSpot(crater, bx, by, bz) then
			local below = world:peekBlock(bx, by - 1, bz)
			reads += 1
			if below ~= nil and Blocks.isOpaque(below) and Nuke.fate(crater, bx, by - 1, bz, below) ~= AIR then
				if world:setBlock(bx, by, bz, FIRE) then
					edits += 1
				end
			end
		end
	end
	job.cursor = cursor
	return edits, reads, cursor >= count
end

--[[
	One server tick (after World/Explosions): digs on at the craters, oldest first, within
	EditsPerTick edits and ReadsPerTick reads together. Returns the edits and reads it took.
]]
function Nuke.step(world: World): (number, number)
	local state = states[world]
	if state == nil or #state.jobs == 0 then
		return 0, 0
	end
	local edits, reads = 0, 0
	local jobs = state.jobs
	local i = 1
	while i <= #jobs and edits < Settings.EditsPerTick and reads < Settings.ReadsPerTick do
		local e, r, done = work(world, jobs[i], Settings.EditsPerTick - edits, Settings.ReadsPerTick - reads)
		edits += e
		reads += r
		if done then
			table.remove(jobs, i)
		else
			i += 1
		end
	end
	return edits, reads
end

return Nuke
