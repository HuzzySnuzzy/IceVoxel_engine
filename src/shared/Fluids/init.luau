--!strict
--[[
	Fluid registry: water, lava, oil and fuel, by id (FluidList; u8, append only):

	  0 none, 1 water, 2 lava, 3 oil, 4 fuel.

	Everything that holds or tells fluids apart asks here instead of naming water: the blocks of each
	fluid (`ofBlock`, `blockLut`, `isSource`, `sourceOf`, `caveSourceOf`), its bucket (`bucketOf`,
	`ofBucket`), the ids Protocol's Tanks and Transmitters records and a Fluid Tank's sustained data
	carry (`isValid`), and each fluid's record (`get`, `list`): colour, light, how it moves and
	hurts players, its furnace fuel value, whether pipes and tanks carry it (all four do), its fog,
	its bucket sounds and the status effects it gives (`effects`: Shared/Effects ids and ticks; see
	FluidList for each field).

	A fluid is a BlockList fluid group of the same name (Water, WaterFlow1..7, WaterFalling), plus
	the cave twin of its source for lava and oil (CaveLava, CaveOil: generated underground, cave air
	while caves are hidden, otherwise the source itself). The checks below make the three lists
	agree when the game loads: every fluid group of BlockList is a fluid here, with this colour and
	light, and every fluid's bucket is an item of its own.

	Requires Blocks, Items (both of which only read FluidList) and Effects (which reads nothing of
	it), so Protocol, Smelting, machine kinds and Transmitters may require it.
]]

local Blocks = require(script.Parent.Blocks)
local Effects = require(script.Parent.Effects)
local FluidList = require(script.FluidList)
local Items = require(script.Parent.Items)

export type FluidSpec = FluidList.FluidSpec

-- A status effect a fluid gives (FluidList `effects`): the effect's id, its ticks and amplifier,
-- when ("in", "head", "left") and after how many ticks of unbroken contact (0: at once).
export type FluidEffect = { effect: number, ticks: number, amplifier: number, when: string, after: number }

export type Fluid = {
	id: number,
	-- Its BlockList group, and how it is shown ("Water").
	name: string,
	displayName: string,
	-- Block ids: the source, and its cave twin (nil for water and fuel, which have none).
	source: number,
	caveSource: number?,
	-- Item id of its full bucket.
	bucket: number,
	color: { number },
	light: number,
	-- Movement (Shared/Movement): Minecraft's travel branch ("water" | "lava"), the horizontal
	-- speed kept per tick, the flow push per tick, and whether players swim in it.
	physics: string,
	drag: number,
	push: number,
	swim: boolean,
	-- Health points it takes every `damageInterval` ticks (0: harmless), seconds a player keeps
	-- burning after leaving it, and whether it puts burning out.
	damage: number,
	damageInterval: number,
	burnSeconds: number,
	extinguishes: boolean,
	-- Ticks its bucket burns in a furnace (0: no fuel; Crafting/Smelting).
	furnaceFuel: number,
	-- Buckets, Mechanical Pipes and Fluid Tanks carry it.
	carriable: boolean,
	-- The view while the eye is in it: tint and fog (blocks from the eye).
	fogColor: { number },
	fogStart: number,
	fogEnd: number,
	-- Sound events of a bucket taking and pouring it (Shared/Sounds names).
	fillSound: string,
	emptySound: string,
	-- Status effects it gives a player in it (none: empty).
	effects: { FluidEffect },
}

local Fluids = {}

Fluids.NONE = 0
Fluids.WATER = 1
Fluids.LAVA = 2
Fluids.OIL = 3
Fluids.FUEL = 4
Fluids.COUNT = #FluidList
-- mB in a bucket (and a source block).
Fluids.BUCKET = 1000
-- Burning players (`burnSeconds`): Minecraft's 1 health point every 20 ticks (Entity.baseTick's
-- onFire damage), outside lava.
Fluids.BURN_DAMAGE = 1
Fluids.BURN_INTERVAL = 20

assert(Fluids.COUNT < 256, "Fluid ids must fit a u8")

local PHYSICS: { [string]: boolean } = { water = true, lava = true }
local WHEN: { [string]: boolean } = { ["in"] = true, head = true, left = true }

local list: { Fluid } = {}
local byName: { [string]: number } = {}
local byBucket: { [number]: number } = {}

for id, spec in FluidList do
	-- (`find`, not `Blocks.id`: a missing group is reported with the fluid's name.)
	local source = Blocks.find(spec.name)
	assert(source ~= nil and Blocks.get(source).fluid ~= nil, `Fluid {spec.name} has no fluid blocks in BlockList`)
	local def = Blocks.get(source)
	local fluid = def.fluid
	assert(fluid and fluid.group == spec.name and fluid.level == 0, `Block {spec.name} is not {spec.name}'s source`)
	for level = 0, 8 do
		assert(pcall(Blocks.fluidId, spec.name, level), `Fluid {spec.name} lacks level {level}`)
	end
	local c = def.color
	assert(
		c[1] == spec.color[1] and c[2] == spec.color[2] and c[3] == spec.color[3],
		`Fluid {spec.name}'s colour differs from its blocks'`
	)
	assert(def.light == spec.light, `Fluid {spec.name}'s light differs from its blocks'`)
	local bucket = Items.find(spec.bucket)
	assert(bucket ~= nil, `Fluid {spec.name} has an unknown bucket {spec.bucket}`)
	local item = Items.get(bucket)
	assert(item and item.block == nil, `Fluid {spec.name}'s bucket {spec.bucket} is a block`)
	assert(byBucket[bucket] == nil, `Two fluids fill {spec.bucket}`)
	assert(PHYSICS[spec.physics], `Fluid {spec.name} has unknown physics {spec.physics}`)
	assert(spec.drag > 0 and spec.drag <= 1 and spec.push >= 0, `Fluid {spec.name} has bad movement`)
	assert(
		spec.damage >= 0 and (spec.damage == 0 or spec.damageInterval >= 1) and spec.burnSeconds >= 0,
		`Fluid {spec.name} has bad damage`
	)
	assert(spec.furnaceFuel >= 0 and spec.furnaceFuel == math.floor(spec.furnaceFuel), `Fluid {spec.name}: fuel`)
	local effects: { FluidEffect } = {}
	for _, given in (spec.effects or {}) :: { FluidList.FluidEffect } do
		local effect = Effects.id[given.effect]
		assert(effect ~= nil, `Fluid {spec.name} gives an unknown effect {given.effect}`)
		assert(WHEN[given.when], `Fluid {spec.name}'s {given.effect} has an unknown when {given.when}`)
		local amplifier = given.amplifier or 0
		assert(
			given.seconds > 0 and amplifier >= 0 and amplifier <= Effects.MAX_AMPLIFIER and (given.after or 0) >= 0,
			`Fluid {spec.name}'s {given.effect} has bad numbers`
		)
		table.insert(
			effects,
			table.freeze({
				effect = effect,
				ticks = math.round(given.seconds * Effects.TICKS_PER_SECOND),
				amplifier = amplifier,
				when = given.when,
				after = math.round((given.after or 0) * Effects.TICKS_PER_SECOND),
			})
		)
	end
	local record: Fluid = {
		id = id,
		name = spec.name,
		displayName = spec.displayName or spec.name,
		source = source,
		caveSource = Blocks.caveTwinFor(source),
		bucket = bucket,
		color = table.freeze(table.clone(spec.color)),
		light = spec.light,
		physics = spec.physics,
		drag = spec.drag,
		push = spec.push,
		swim = spec.swim,
		damage = spec.damage,
		damageInterval = spec.damageInterval,
		burnSeconds = spec.burnSeconds,
		extinguishes = spec.extinguishes,
		furnaceFuel = spec.furnaceFuel,
		carriable = spec.carriable,
		fogColor = table.freeze(table.clone(spec.fogColor)),
		fogStart = spec.fogStart,
		fogEnd = spec.fogEnd,
		fillSound = spec.fillSound,
		emptySound = spec.emptySound,
		effects = table.freeze(effects),
	}
	list[id] = table.freeze(record)
	byName[spec.name] = id
	byBucket[bucket] = id
end

assert(
	byName.Water == Fluids.WATER
		and byName.Lava == Fluids.LAVA
		and byName.Oil == Fluids.OIL
		and byName.Fuel == Fluids.FUEL,
	"FluidList's first four must be water, lava, oil and fuel"
)

-- The fluid id of each block (u8 per block id, 0 = none): every level of a group, and the cave
-- twins of its source. For hot loops (movement, meshing); `ofBlock` answers the same.
Fluids.blockLut = buffer.create(Blocks.count)
-- 1 per block id for a fluid's source or its cave twin (what an empty bucket takes: Minecraft's
-- Fluid.SOURCE_ONLY).
local sourceLut = buffer.create(Blocks.count)
for blockId = 0, Blocks.count - 1 do
	local fluid = Blocks.get(blockId).fluid
	if fluid then
		local id = byName[fluid.group]
		assert(id ~= nil, `Block {Blocks.get(blockId).name}'s fluid group {fluid.group} is no fluid in FluidList`)
		buffer.writeu8(Fluids.blockLut, blockId, id)
		if fluid.level == 0 then
			buffer.writeu8(sourceLut, blockId, 1)
		end
	end
end

Fluids.list = table.freeze(list)

-- Is `id` a fluid (1..COUNT, whole)? 0 (none) is not.
function Fluids.isValid(id: number): boolean
	return type(id) == "number" and id >= 1 and id <= Fluids.COUNT and id == math.floor(id)
end

-- The fluid with id `id`, nil for none and unknown ids.
function Fluids.get(id: number): Fluid?
	return if Fluids.isValid(id) then list[id] else nil
end

-- The fluid's name as players see it ("Lava"), "Empty" for none and unknown ids.
function Fluids.name(id: number): string
	local fluid = Fluids.get(id)
	return if fluid then fluid.displayName else "Empty"
end

-- The id of the fluid named `name` (its BlockList group, "Lava"), nil when there is none.
function Fluids.find(name: string): number?
	return byName[name]
end

-- The fluid of block `block` (any level, cave twins included), 0 for every other block and unknown
-- ids.
function Fluids.ofBlock(block: number): number
	if type(block) ~= "number" or block < 0 or block >= Blocks.count or block ~= math.floor(block) then
		return 0
	end
	return buffer.readu8(Fluids.blockLut, block)
end

-- Is `block` a fluid's source (level 0), its cave twin included? What an empty bucket takes.
function Fluids.isSource(block: number): boolean
	return Fluids.ofBlock(block) ~= 0 and buffer.readu8(sourceLut, block) == 1
end

-- The source block of fluid `id` (what a bucket pours: never a cave twin), nil for unknown ids.
function Fluids.sourceOf(id: number): number?
	local fluid = Fluids.get(id)
	return if fluid then fluid.source else nil
end

-- The cave twin of fluid `id`'s source (CaveLava, CaveOil), nil for fluids without one.
function Fluids.caveSourceOf(id: number): number?
	local fluid = Fluids.get(id)
	return if fluid then fluid.caveSource else nil
end

-- The full bucket of fluid `id` (an item id), nil for none and unknown ids.
function Fluids.bucketOf(id: number): number?
	local fluid = Fluids.get(id)
	return if fluid then fluid.bucket else nil
end

-- The fluid a full bucket holds, 0 for any other item (the empty Bucket included).
function Fluids.ofBucket(item: number?): number
	return if item then byBucket[item] or 0 else 0
end

-- May buckets, pipes and tanks carry fluid `id`?
function Fluids.carriable(id: number): boolean
	local fluid = Fluids.get(id)
	return fluid ~= nil and fluid.carriable
end

return Fluids
