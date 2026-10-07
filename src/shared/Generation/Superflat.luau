--!strict
--[[
	Superflat: Minecraft's flat world type (FlatLevelGeneratorSettings and its presets screen), on
	Generation/LayeredGenerator, for Generation/WorldTypes.

	A preset is one line of text, Minecraft's preset string with this game's names:

	    Bedrock,2*Dirt,Grass;Plains

	the layers from the bottom of the world (y = 0) up, `count*Block` (count 1..MAX_HEIGHT,
	default 1), then `;` and the biome (BiomeList; default Plains). Names match loosely, as
	structure final states do (Structures/Jigsaw.nameKey: any case, "minecraft:" dropped, no
	underscores or spaces), and a few of Minecraft's names map onto this game's (grass_block is
	Grass, snowy_plains is Tundra), so most Minecraft presets paste as they are. Air layers are
	allowed (Minecraft's own: the void is "minecraft:air"); water layers on top of the stack are
	its sea (players spawn over open water, the map draws it as water). The whole stack is at most
	MAX_HEIGHT blocks: the world's height less the room trees need above it.

	`parse` explains what is wrong in words for the player (the menu's Create World screen shows
	it); a world made from a bad preset is Classic Flat (`resolve`), so every machine still builds
	the same world.

	PRESETS are Minecraft 1.20.1's flat presets whose blocks this game has (Redstone Ready has no
	redstone here; it is its sandstone), with the biome nearest Minecraft's: Classic Flat,
	Tunnelers' Dream, Water World (Minecraft's deep ocean: here Plains, there is no ocean biome),
	Overworld, Snowy Kingdom (a snow block for the snow layer, Tundra for snowy plains), Bottomless
	Pit, Desert and Redstone Ready. Minecraft's "The Void" is the Void world type.

	Options (WorldTypes Options): `preset` (the text, default Classic Flat) and `decoration`
	(true: the biome's trees and ground plants; Minecraft's flat worlds have a few presets with
	features, here it is a switch). No library structures, caves, lakes or ores: a flat world is
	its layers.
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local Biomes = require(script.Parent.Parent.Biomes)
local Jigsaw = require(script.Parent.Parent.Structures.Jigsaw)
local LayeredGenerator = require(script.Parent.LayeredGenerator)
local TerrainGenerator = require(script.Parent.TerrainGenerator)

export type Preset = {
	layers: { LayeredGenerator.Layer },
	stack: LayeredGenerator.Stack,
	biome: number,
}

local Superflat = {}

-- Tallest stack (blocks): the world's height less room for trees on top.
Superflat.MAX_HEIGHT = Config.WorldHeight - LayeredGenerator.TREE_ROOM
Superflat.CLASSIC = "Bedrock,2*Dirt,Grass;Plains"
Superflat.DEFAULT_BIOME = "Plains"

Superflat.PRESETS = table.freeze({
	table.freeze({ name = "Classic Flat", value = Superflat.CLASSIC }),
	table.freeze({ name = "Tunnelers' Dream", value = "Bedrock,230*Stone,5*Dirt,Grass;WindsweptHills" }),
	table.freeze({ name = "Water World", value = "Bedrock,5*Stone,5*Dirt,5*Sand,90*Water;Plains" }),
	table.freeze({ name = "Overworld", value = "Bedrock,59*Stone,3*Dirt,Grass;Plains" }),
	table.freeze({ name = "Snowy Kingdom", value = "Bedrock,59*Stone,3*Dirt,Grass,Snow;Tundra" }),
	table.freeze({ name = "Bottomless Pit", value = "2*Cobblestone,3*Dirt,Grass;Plains" }),
	table.freeze({ name = "Desert", value = "Bedrock,3*Stone,52*Sandstone,8*Sand;Desert" }),
	table.freeze({ name = "Redstone Ready", value = "Bedrock,3*Stone,116*Sandstone;Desert" }),
})

-- Minecraft names that are something else here (by Jigsaw.nameKey).
local BLOCK_ALIASES: { [string]: string } = {
	grassblock = "Grass",
	snowblock = "Snow",
	oakplanks = "Planks",
	bricks = "Brick",
	glowstone = "GlowBlock",
}
local BIOME_ALIASES: { [string]: string } = {
	snowyplains = "Tundra",
	snowytundra = "Tundra",
	windsweptsavanna = "WindsweptSavanna",
	mountains = "WindsweptHills",
}

local blockByKey: { [string]: number } = {}
for id = 0, Blocks.count - 1 do
	blockByKey[Jigsaw.nameKey(Blocks.get(id).name)] = id
end
for alias, name in BLOCK_ALIASES do
	blockByKey[alias] = Blocks.id[name]
end
local biomeByKey: { [string]: number } = {}
for _, biome in Biomes.list do
	biomeByKey[Jigsaw.nameKey(biome.name)] = biome.index
end
for alias, name in BIOME_ALIASES do
	local biome = Biomes.byName(name)
	if biome then
		biomeByKey[alias] = biome.index
	end
end

local function trim(text: string): string
	return string.match(text, "^%s*(.-)%s*$") :: string
end

--[[
	The preset `text` describes, or nil and what is wrong with it (a sentence for the player).
]]
function Superflat.parse(text: string): (Preset?, string?)
	if type(text) ~= "string" then
		return nil, "The preset is not text"
	end
	local parts = string.split(text, ";")
	if #parts > 2 then
		return nil, "A preset is the layers, then ; and the biome"
	end
	local layers: { LayeredGenerator.Layer } = {}
	local total = 0
	local layerText = trim(parts[1])
	if layerText == "" then
		return nil, "The preset has no layers"
	end
	for _, entry in string.split(layerText, ",") do
		entry = trim(entry)
		local count, name = string.match(entry, "^(%d+)%s*%*%s*(.+)$")
		local n = 1
		if count and name then
			n = tonumber(count) :: number
		else
			name = entry
		end
		if name == nil or name == "" then
			return nil, "An empty layer (two commas in a row?)"
		end
		if n < 1 or n > Superflat.MAX_HEIGHT then
			return nil, `Layer "{entry}": the count must be 1 to {Superflat.MAX_HEIGHT}`
		end
		local block = blockByKey[Jigsaw.nameKey(name :: string)]
		if block == nil then
			return nil, `Unknown block "{name}"`
		end
		total += n
		if total > Superflat.MAX_HEIGHT then
			return nil, `The layers are more than {Superflat.MAX_HEIGHT} blocks tall`
		end
		table.insert(layers, { block = block, count = n })
	end
	local biomeName = if parts[2] then trim(parts[2]) else ""
	if biomeName == "" then
		biomeName = Superflat.DEFAULT_BIOME
	end
	local biome = biomeByKey[Jigsaw.nameKey(biomeName)]
	if biome == nil then
		return nil, `Unknown biome "{biomeName}"`
	end
	return { layers = layers, stack = LayeredGenerator.stack(layers), biome = biome }, nil
end

--[[
	The preset of world type options (`preset`, default Classic Flat): Classic Flat with the
	reason when the text is bad.
]]
function Superflat.resolve(options: { [string]: any }): (Preset, string?)
	local text = options.preset
	if type(text) ~= "string" or trim(text) == "" then
		text = Superflat.CLASSIC
	end
	local preset, err = Superflat.parse(text)
	if preset then
		return preset, nil
	end
	return Superflat.parse(Superflat.CLASSIC) :: Preset, err
end

-- The preset text of a stack and a biome (`parse` reads it back).
function Superflat.format(layers: { LayeredGenerator.Layer }, biome: number): string
	local parts: { string } = {}
	for _, layer in layers do
		local name = Blocks.get(layer.block).name
		table.insert(parts, if layer.count == 1 then name else `{layer.count}*{name}`)
	end
	return table.concat(parts, ",") .. ";" .. Biomes.list[biome].name
end

-- A superflat world (see the header).
function Superflat.create(seed: number, options: { [string]: any }): TerrainGenerator.Generator
	local preset = Superflat.resolve(options)
	return LayeredGenerator.new({
		seed = seed,
		stack = preset.stack,
		biome = preset.biome,
		decoration = options.decoration == true,
	})
end

return Superflat
