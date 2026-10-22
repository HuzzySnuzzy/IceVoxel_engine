--!strict
--[[
	Snow layers (BlockList SnowLayer1 .. SnowLayer8, Minecraft's SnowLayerBlock), pure: which block
	is how many layers, what a Snow Layer used on a layer makes, what holds snow, how fast one
	walks in it, and the tile rules the server's snowfall and thaw follow (server
	Seasons/SnowWorld).

	  Ids        `block(n)` the block of n layers (1..MAX), `layers(block)` a block's (0: none),
	             `isLayer`.
	  Stacking   `stackOnto(block)`: the Snow Layer item used on a snow layer of n < 8 layers makes
	             it n + 1 (Minecraft's canBeReplaced): the block to set, else nil (server
	             Network/EditRules; predicted by client Interaction/BlockInteraction, which may
	             require this module: it requires only Blocks and Config).
	  Support    `supports(block)`: snow lies on a sturdy full top, on leaves or on a full layer of
	             8, never on ice or packed ice (Minecraft's SnowLayerBlock.canSurvive).
	  Speed      `speedFactor(block)`: Blocks.speedFactor (1 for 1-2 layers, 0.9 for 3-4, 0.8 for
	             5-6, 0.75 for 7-8; 1 for anything that is not snow).
	  Columns    a column's top cell `c` is WeatherRules.top's (the first cell above the highest
	             block that stops rain): layers 2+ stop rain, so a column of n >= 2 layers has
	             them at c - 1, and one of a single layer at c (`layersAt`).
	             `column(column)`: a column's layers, the cell they are in (or a first layer
	             would go into) and whether it takes snow at all: layers already, or air (or a
	             cave mouth's cave air) in its top cell over a block snow lies on (a plant, a
	             torch or water there takes none).
	  Tiles      what one visit of a 4 x 4 tile (TILE; server Seasons/SnowWorld) changes, so
	             tiles rise and fall evenly and same-height cells merge into one box:
	               snowfall  `accumulate(columns, held)`: every column that takes snow, has the
	                         tile's least layers among those below their cap and is below its own
	                         cap gets one more (a first layer in its top cell, else the layer block
	                         one higher in place). A column at its cap never holds the rest back,
	                         nor does one that waits (`held`: someone in the way of its layer).
	               thaw      `melt(columns)`: the columns with the tile's most layers lose one
	                         (a single layer goes back to air), one layer at a time (Bedrock's
	                         melting), so roofs drain gradually.
	             `meltColumn(column)` takes one layer off a single column (heat, a warm room),
	             `lessOne(block)` is what a layer less of `block` makes (AIR for one layer).
	             A Column is { x, z, top, atTop, below, cap }, a Change { x, y, z, block }.
]]

local Blocks = require(script.Parent.Parent.Blocks)

-- One column of a tile as server Seasons/SnowWorld reads it: its top cell (WeatherRules.top; nil
-- when its chunk isn't loaded), the blocks at it and just below, and its cap (SeasonClimate
-- .snowCap).
export type Column = { x: number, z: number, top: number?, atTop: number, below: number, cap: number }
-- One block a tile rule sets.
export type Change = { x: number, y: number, z: number, block: number }

local SnowLayers = {}

local AIR, CAVE_AIR = Blocks.AIR, Blocks.CAVE_AIR

-- The most layers, and a tile's side (columns).
SnowLayers.MAX = Blocks.MAX_LAYERS
SnowLayers.TILE = 4

local byLayers: { number } = {}
for n = 1, SnowLayers.MAX do
	byLayers[n] = Blocks.id[`SnowLayer{n}`]
	assert(Blocks.layer(byLayers[n]) == n, `SnowLayer{n} must have {n} layers`)
end
SnowLayers.ids = table.freeze(byLayers)
-- The Snow Layer item's block (the one layer).
SnowLayers.ITEM = byLayers[1]

-- Blocks snow lies on (see the header), built once.
local supportLut = buffer.create(Blocks.count)
local NOT_ON: { [string]: boolean } = { Ice = true, PackedIce = true }
for id = 0, Blocks.count - 1 do
	local def = Blocks.get(id)
	local holds = def.layer == SnowLayers.MAX
		or def.behaviour == "Leaves"
		or (Blocks.isSturdy(id) and def.layer == 0 and def.fluid == nil)
	if NOT_ON[def.name] or NOT_ON[def.caveTwin or ""] then
		holds = false
	end
	buffer.writeu8(supportLut, id, if holds then 1 else 0)
end

-- The block of `n` layers (1..MAX), nil for any other n.
function SnowLayers.block(n: number): number?
	return byLayers[n]
end

-- A block's layers (1..MAX), 0 when it is no snow layer.
function SnowLayers.layers(block: number): number
	return Blocks.layer(block)
end

-- Is `block` a snow layer?
function SnowLayers.isLayer(block: number): boolean
	return Blocks.layer(block) > 0
end

-- The Snow Layer item used on `block`: the block it becomes (a layer more), nil when it can't
-- take one (no snow layer, or a full one).
function SnowLayers.stackOnto(block: number): number?
	local n = Blocks.layer(block)
	if n <= 0 or n >= SnowLayers.MAX then
		return nil
	end
	return byLayers[n + 1]
end

-- Does snow lie on `block` (see the header)?
function SnowLayers.supports(block: number): boolean
	return block >= 0 and block < Blocks.count and buffer.readu8(supportLut, block) == 1
end

-- What walking in or on `block` multiplies the ground speed by.
function SnowLayers.speedFactor(block: number): number
	return Blocks.speedFactor(block)
end

--[[
	A column's layers from the blocks at its top cell (`atTop`) and below it (`below`): the count
	and where they are (0: the top cell, -1: the cell below; see the header). (0, 0) for none.
]]
function SnowLayers.layersAt(atTop: number, below: number): (number, number)
	local under = Blocks.layer(below)
	if under >= 2 then
		return under, -1
	end
	local here = Blocks.layer(atTop)
	if here == 1 then
		return 1, 0
	end
	return 0, 0
end

--[[
	One layer less of `block`: the layer block below it, AIR for a single layer; nil when `block`
	is no snow layer.
]]
function SnowLayers.lessOne(block: number): number?
	local n = Blocks.layer(block)
	if n <= 0 then
		return nil
	end
	return if n == 1 then AIR else byLayers[n - 1]
end

--[[
	A column's snow: its layers (0..MAX), the y of the cell they are in (with none: its top cell,
	where a first layer would go), and whether it takes snow at all (it has layers, or its top
	cell is air or cave air over a block snow lies on: `supports`). A column with no top (its
	chunk isn't loaded) has none and takes none. (A melted layer goes back to AIR here; server
	Seasons/SnowWorld puts a cave mouth's own cave air back.)
]]
function SnowLayers.column(column: Column): (number, number, boolean)
	local top = column.top
	if top == nil then
		return 0, 0, false
	end
	local n, dy = SnowLayers.layersAt(column.atTop, column.below)
	if n > 0 then
		return n, top + dy, true
	end
	local atTop = column.atTop
	return 0, top, (atTop == AIR or atTop == CAVE_AIR) and SnowLayers.supports(column.below)
end

--[[
	One snowfall visit of a tile's `columns` (TILE x TILE of them): the blocks to set. Every
	column that takes snow, whose layers equal the least of those below their cap and are below
	its own cap gets one more (see the header). `held[i]` true: column i waits (someone is in the
	way of its next layer: server Seasons/SnowWorld's Bodies), neither counted for the least nor
	given a layer, so it holds nobody back. Nothing for a tile with no room left.
]]
function SnowLayers.accumulate(columns: { Column }, held: { boolean }?): { Change }
	local changes: { Change } = {}
	local least = math.huge
	for i, column in columns do
		local n, _, takes = SnowLayers.column(column)
		if takes and n < column.cap and n < SnowLayers.MAX and n < least and not (held and held[i]) then
			least = n
		end
	end
	if least == math.huge then
		return changes
	end
	for i, column in columns do
		local n, y, takes = SnowLayers.column(column)
		if takes and n == least and n < column.cap and n < SnowLayers.MAX and not (held and held[i]) then
			table.insert(changes, { x = column.x, y = y, z = column.z, block = byLayers[n + 1] })
		end
	end
	return changes
end

--[[
	One thaw visit of a tile's `columns`: the blocks to set. The columns with the tile's most
	layers lose one (a single layer goes back to air). Nothing for a tile without snow.
]]
function SnowLayers.melt(columns: { Column }): { Change }
	local changes: { Change } = {}
	local most = 0
	for _, column in columns do
		local n = SnowLayers.column(column)
		if n > most then
			most = n
		end
	end
	if most == 0 then
		return changes
	end
	for _, column in columns do
		local n, y = SnowLayers.column(column)
		if n == most then
			table.insert(
				changes,
				{ x = column.x, y = y, z = column.z, block = if n == 1 then AIR else byLayers[n - 1] }
			)
		end
	end
	return changes
end

-- One layer off `column` alone (heat, a warm room): the block to set, nil when it has no snow.
function SnowLayers.meltColumn(column: Column): Change?
	local n, y = SnowLayers.column(column)
	if n <= 0 then
		return nil
	end
	return { x = column.x, y = y, z = column.z, block = if n == 1 then AIR else byLayers[n - 1] }
end

return SnowLayers
