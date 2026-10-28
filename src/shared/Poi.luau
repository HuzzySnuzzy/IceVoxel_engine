--!strict
--[[
	Points of interest: the blocks /locate poi finds (Minecraft 1.20.1's PoiTypes and their tags,
	on this game's blocks). Minecraft's are villagers' job sites, beds, bells, beehives, portals,
	lodestones and lightning rods, none of which this game has; these are the blocks a player
	looks for here instead.

	  Types   each an id (snake case, as /locate shows it): the block entries' `poi` (Content/
	          Schema), in id order. A block without one is of its `item`'s type, so a type takes in
	          every variant of its block (structure blocks' four modes, jigsaws' twelve facings,
	          lit TNT), and the blocks giving one id are one type (`battery`: the four tiers,
	          `fluid_tank` the four tanks).
	  Tags    Minecraft's tag files' idea (#acquirable_job_site, #village): `workstation`,
	          `machine` (every type whose blocks have a BlockList `machine`), `generator`,
	          `container`, `structure`, `explosive`, `scavenge` (what the ruins and bunkers hold
	          loot in); each names types some block gives (checked as this loads).
	  Lookup  `lut` holds each block id's type index (u8, 0: none), for the hot loops that scan
	          edits and templates (World/PoiSearch, Generation/StructureGen.pieceBlocks); `of`
	          gives a block's type id.
]]

local Blocks = require(script.Parent.Blocks)
local BlockList = require(script.Parent.Blocks.BlockList)

export type Type = { id: string, index: number, blocks: { number } }

local Poi = {}

Poi.TAGS = table.freeze({
	workstation = { "crafting_table", "furnace", "campfire", "electric_furnace", "oil_refinery" },
	generator = { "heat_generator", "combustion_generator", "solar_panel" },
	container = { "chest", "furnace", "fluid_tank", "supply_crate", "medicine_cabinet" },
	structure = { "structure_block", "jigsaw" },
	explosive = { "tnt", "nuke" },
	scavenge = { "chest", "supply_crate", "medicine_cabinet" },
} :: { [string]: { string } })
-- Every type whose blocks are machines.
Poi.MACHINE_TAG = "machine"

-- The types, in the id order of their first blocks (Poi.types[i].index == i).
Poi.types = {} :: { Type }
local byId: { [string]: Type } = {}
-- u8 per block id: its type's index, 0 for none.
Poi.lut = buffer.create(Blocks.count)

local machines: { string } = {}
do
	-- A block's type id: its entry's `poi`, else its item's (nil: none).
	local specs = BlockList
	local function poiOf(id: number): string?
		local spec = specs[id + 1]
		if spec.poi then
			return spec.poi
		end
		local item = if spec.item then Blocks.find(spec.item) else nil
		return if item then specs[item + 1].poi else nil
	end
	for id = 0, Blocks.count - 1 do
		local poiId = poiOf(id)
		if poiId then
			local poiType = byId[poiId]
			if poiType == nil then
				poiType = { id = poiId, index = #Poi.types + 1, blocks = {} }
				table.insert(Poi.types, poiType)
				byId[poiId] = poiType
			end
			table.insert(poiType.blocks, id)
			buffer.writeu8(Poi.lut, id, poiType.index)
		end
	end
	assert(#Poi.types < 256, "Poi: point of interest types must fit a u8")
	for _, poiType in Poi.types do
		if Blocks.get(poiType.blocks[1]).machine ~= nil then
			table.insert(machines, poiType.id)
		end
	end
	for tag, members in Poi.TAGS do
		for _, member in members do
			assert(byId[member], `Poi: tag {tag} names {member}, which no block's \`poi\` gives`)
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
