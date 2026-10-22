--!strict
--[[
	Foliage colours by season (Shared/Seasons/Foliage, Config.Seasons.Foliage): follows the calendar
	and drives Rendering/ChunkRenderer, which recolours the live seasonal parts in place (grass tops,
	leaves, tinted plants, vines; colours from Rendering/TextureLooks.seasonalTint) and hands the far
	meshes their palette (Rendering/MeshOverlay rebuilds a mesh whose colours drifted too far).
	Items, icons, held and dropped blocks and the map keep their authored colours.

	  Steps    Every frame the calendar time (Rendering/LightingController.dayTime through
	           Shared/Seasons/Calendar) gives the near step (Foliage.stepOf: BlendDays / 24 days,
	           100 s of play, shorter with short seasons); a new step hands the renderer its
	           palette (Foliage.targets at the step's midpoint, `ChunkRenderer:setSeason`), which
	           starts a sweep only when some colour changed (never in summer's steady weeks). The
	           far step (Foliage.farStepOf, FarStepDays) hands the far meshes theirs
	           (`setFarSeason`).
	  Sweep    `renderer:seasonSweep(SweepWrites, SweepMs)` every frame while it has work: at most
	           SweepWrites property writes and SweepMs a frame (the walk over nodes and sections
	           included), nearest sections first, every seasonal part written once a step (about
	           15-26 frames a step).
	  Classes  A chunk column's biome class is SeasonClimate.classOf of the generator's biome at
	           its centre column (`classOf`); the renderer asks it per chunk of each seasonal box
	           and far-mesh quad, and keeps the answers (ChunkRenderer.setSeasonClass).
	  Off      Config.Seasons.Enabled or Config.Seasons.Foliage.Enabled false: `start` does nothing,
	           so every colour is exactly as without seasons. The calendar off (before the server
	           publishes, a world without seasons): the authored palette (nothing written unless a
	           season's colours were shown before).
	  Dark     A texture too dark for a season's colours (a part's tint only darkens) is named once,
	           as TextureLooks' clamp log does: a lighter greyscale texture gives the full colour.

	`start(renderer, terrain?)`: `terrain` is the world's generator (the client boot's); without it
	one is made from the published world (Generation/WorldTypes.fromAttributes, a second generator).
	`follow(renderer, dayTime, s?)` is the per-frame rule (specs drive it with a fake renderer).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Calendar = require(Shared.Seasons.Calendar)
local Foliage = require(Shared.Seasons.Foliage)
local SeasonClimate = require(Shared.Seasons.SeasonClimate)
local Blocks = require(Shared.Blocks)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)
local WorldTypes = require(Shared.Generation.WorldTypes)

local ChunkRenderer = require(script.Parent.ChunkRenderer)
local TextureLooks = require(script.Parent.TextureLooks)

local Settings = Config.Seasons.Foliage
-- How much darker than a season's colour a texture may show before it is named (0-255).
local DARK_VISIBLE = 4
-- Near steps between checks for textures too dark (12: once a calendar day).
local DARK_EVERY = 12

-- What the renderer needs (ChunkRenderer, or a spec's fake).
export type Renderer = {
	setSeason: (self: any, targets: Foliage.Targets?) -> boolean,
	setFarSeason: (self: any, targets: Foliage.Targets?, id: number) -> (),
	seasonSweep: (self: any, writes: number, ms: number) -> (number, boolean),
}

local SeasonTint = {}

local started = false
-- What was handed to the renderer: active or not, the near and far steps, the lengths.
local current = {
	active = false,
	step = nil :: number?,
	farStep = nil :: number?,
	lengths = { 0, 0, 0, 0 },
	darkStep = nil :: number?,
}
-- Targets reused from step to step (the renderer keeps its own copies).
local nearTargets: Foliage.Targets? = nil
local farTargets: Foliage.Targets? = nil
-- Textures named as too dark already.
local named: { [string]: boolean } = {}

-- Forgets what was handed over (specs; a new renderer).
function SeasonTint.reset()
	current.active = false
	current.step = nil
	current.farStep = nil
	current.darkStep = nil
	table.clear(current.lengths)
	nearTargets, farTargets = nil, nil
end

-- The first block name of each appearance (messages).
local nameOf: { [number]: string } = {}
for id = Blocks.count - 1, 0, -1 do
	nameOf[Blocks.get(id).appearance] = Blocks.get(id).name
end

-- Names, once, the textures that show darker than the season's colours (see the header).
local function noteDark(targets: Foliage.Targets)
	local colours = targets.colours[Foliage.TEMPERATE]
	if colours == nil then
		return
	end
	local found: { string } = {}
	for _, appearance in Foliage.appearances() do
		local tint = TextureLooks.seasonalTint(appearance, colours[appearance])
		local name = nameOf[appearance] or tostring(appearance)
		if tint.short > DARK_VISIBLE and not named[name] then
			named[name] = true
			table.insert(found, `{name} {math.round(tint.short)}`)
		end
	end
	if #found > 0 then
		warn(
			`[IceVoxel] textures darker than the season's foliage colours (by how much, 0-255; a part's tint can only darken, so a lighter greyscale texture gives the full colour): {table.concat(
				found,
				", "
			)}`
		)
	end
end

--[[
	The per-frame rule (see the header): hands `renderer` a new palette when the near step of the
	calendar time at `dayTime` (with `s`, default the calendar's state) changed, the far meshes one
	when the far step did, and the authored colours once the calendar is off.
]]
function SeasonTint.follow(renderer: Renderer, dayTime: number, s: Calendar.State?)
	local state = s or Calendar.state()
	if not Foliage.active(state) then
		if current.active then
			current.active = false
			current.step = nil
			current.farStep = nil
			renderer:setSeason(nil)
			renderer:setFarSeason(nil, -1)
		end
		return
	end
	local lengths = state.lengths
	local known = current.lengths
	local sameLengths = known[1] == lengths[1]
		and known[2] == lengths[2]
		and known[3] == lengths[3]
		and known[4] == lengths[4]
	if not sameLengths then
		for i = 1, 4 do
			known[i] = lengths[i]
		end
	end
	local time = Calendar.time(dayTime, state)
	local step = Foliage.stepOf(time, state)
	if step ~= current.step or not current.active or not sameLengths then
		current.step = step
		nearTargets = Foliage.targets(Foliage.midpoint(step, state), state, nearTargets)
		renderer:setSeason(nearTargets)
		local darkStep = current.darkStep
		if nearTargets and (darkStep == nil or math.abs(step - darkStep) >= DARK_EVERY) then
			current.darkStep = step
			noteDark(nearTargets)
		end
	end
	local farStep = Foliage.farStepOf(time, state)
	if farStep ~= current.farStep or not current.active or not sameLengths then
		current.farStep = farStep
		farTargets = Foliage.targets(Foliage.farMidpoint(farStep, state), state, farTargets)
		renderer:setFarSeason(farTargets, farStep)
	end
	current.active = true
end

--[[
	The biome class (Foliage.classIndex) of chunk column (cx, cz) from `terrain`: the class of the
	biome at its centre column (see the header).
]]
function SeasonTint.classOf(terrain: TerrainGenerator.Generator, cx: number, cz: number): number
	local half = Config.ChunkSize // 2
	local _, biome = terrain.column(cx * Config.ChunkSize + half, cz * Config.ChunkSize + half)
	return Foliage.classIndex(SeasonClimate.classOf(biome))
end

-- Starts following the calendar (the client boot, after the renderer and the lighting).
function SeasonTint.start(renderer: ChunkRenderer.ChunkRenderer, terrain: TerrainGenerator.Generator?)
	assert(not started, "SeasonTint.start was already called")
	started = true
	if not Foliage.configured() then
		return
	end
	-- (Required here: the rule above runs without the lighting, in specs.)
	local LightingController = require(script.Parent.LightingController)
	local generator = terrain or (WorldTypes.fromAttributes(Shared))
	renderer:setSeasonClass(function(cx: number, cz: number): number
		return SeasonTint.classOf(generator, cx, cz)
	end)
	RunService.Heartbeat:Connect(function()
		SeasonTint.follow(renderer, LightingController.dayTime())
		renderer:seasonSweep(Settings.SweepWrites, Settings.SweepMs)
	end)
end

return SeasonTint
