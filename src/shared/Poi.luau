--!strict
--[[
	Points of interest: the blocks /locate poi finds (Minecraft 1.20.1's PoiTypes and their tags,
	on this game's blocks). Minecraft's are villagers' job sites, beds, bells, beehives, portals,
	lodestones and lightning rods, none of which this game has; these are the blocks a player
	looks for here instead.

	  Types   each an id (snake case, as /locate shows it) and the block names it covers: every
	          block whose BlockList `item` (or name, without one) is one of them, so a type takes in
	          every variant of its block (structure blocks' four modes, jigsaws' twelve facings,
	          lit TNT) and a family is one type (`battery`: the four tiers, `fluid_tank` the four
	          tanks).
	  Tags    Minecraft's tag files' idea (#acquirable_job_site, #village): `workstation`,
	          `machine` (every type whose blocks have a BlockList `machine`), `generator`,
	          `container`, `structure`, `explosive`.
	  Lookup  `lut` holds each block id's type index (u8, 0: none), for the hot loops that scan
	          edits and templates (World/PoiSearch, Generation/StructureGen.pieceBlocks); `of`
	          gives a block's type id.
]]

local Blocks = require(script.Parent.Blocks)

export type Type = { id: string, index: number, blocks: { number } }

local Poi = {}

-- id, then the block names (BlockList names, matched against `item or name`).
local TYPES: { { any } } = {
	{ "chest", "Chest" },
	{ "crafting_table", "CraftingTable" },
	{ "furnace", "Furnace" },
	{ "campfire", "Campfire" },
	{ "electric_furnace", "ElectricFurnace" },
	{ "heat_generator", "HeatGenerator" },
	{ "combustion_generator", "CombustionGenerator" },
	{ "oil_refinery", "OilRefinery" },
	{ "solar_panel", "SolarPanel" },
	{ "energy_cube", "CreativeEnergyCube" },
	{ "battery", "BasicBattery", "AdvancedBattery", "EliteBattery", "UltimateBattery" },
	{ "fluid_tank", "BasicFluidTank", "AdvancedFluidTank", "EliteFluidTank", "UltimateFluidTank" },
	{ "structure_block", "StructureBlock" },
	{ "jigsaw", "Jigsaw" },
	{ "tnt", "Tnt" },
	{ "nuke", "Nuke" },
}

Poi.TAGS = table.freeze({
	workstation = { "crafting_table", "furnace", "campfire", "electric_furnace", "oil_refinery" },
	generator = { "heat_generator", "combustion_generator", "solar_panel" },
	container = { "chest", "furnace", "fluid_tank" },
	structure = { "structure_block", "jigsaw" },
	explosive = { "tnt", "nuke" },
} :: { [string]: { string } })
-- Every type whose blocks are machines.
Poi.MACHINE_TAG = "machine"

-- The types in order (Poi.types[i].index == i).
Poi.types = {} :: { Type }
local byId: { [string]: Type } = {}
-- u8 per block id: its type's index, 0 for none.
Poi.lut = buffer.create(Blocks.count)

local machines: { string } = {}
do
	local wanted: { [string]: number } = {}
	for i, entry in TYPES do
		local poiType: Type = { id = entry[1] :: string, index = i, blocks = {} }
		Poi.types[i] = poiType
		byId[poiType.id] = poiType
		for k = 2, #entry do
			wanted[entry[k] :: string] = i
		end
	end
	for id = 0, Blocks.count - 1 do
		local def = Blocks.get(id)
		local index = wanted[def.item or def.name]
		if index then
			table.insert(Poi.types[index].blocks, id)
			buffer.writeu8(Poi.lut, id, index)
		end
	end
	for _, poiType in Poi.types do
		assert(#poiType.blocks > 0, `Poi: no block for {poiType.id}`)
		if Blocks.get(poiType.blocks[1]).machine ~= nil then
			table.insert(machines, poiType.id)
		end
	end
end

-- Every type id, in order.
Poi.ids = {} :: { string }
for i, poiType in Poi.types do
	Poi.ids[i] = poiType.id
end

-- The tags, the machine tag included.
function Poi.tags(): { [string]: { string } }
	local tags: { [string]: { string } } = {}
	for tag, members in Poi.TAGS do
		tags[tag] = members
	end
	tags[Poi.MACHINE_TAG] = machines
	return tags
end

-- The type with this id, nil when none.
function Poi.get(id: string): Type?
	return byId[id]
end

-- The type id of a block, nil when it is no point of interest.
function Poi.of(block: number): string?
	if block < 0 or block >= Blocks.count then
		return nil
	end
	local index = buffer.readu8(Poi.lut, block)
	return if index > 0 then Poi.types[index].id else nil
end

-- A lut (u8 per block id, 1: wanted) of the blocks of the types `ids`.
function Poi.lutOf(ids: { string }): buffer
	local lut = buffer.create(Blocks.count)
	for _, id in ids do
		local poiType = byId[id]
		if poiType then
			for _, block in poiType.blocks do
				buffer.writeu8(lut, block, 1)
			end
		end
	end
	return lut
end

return Poi
