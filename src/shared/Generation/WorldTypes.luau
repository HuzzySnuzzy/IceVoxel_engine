--!strict
--[[
	World types (Minecraft's world presets: Default, Superflat, ... and the debug worlds): a registry
	of generators, and how the server tells every client and chunk worker which one to build.

	  Registry   `WorldTypes.list`, in menu order: { id, name, description, create(seed, options),
	             hidden?, settings? } (`settings`: the Create World screen's Customize screen,
	             see Setting below).
	             `create` returns a TerrainGenerator.Generator (the whole interface the server,
	             the client's streamer, the chunk workers, the map and the far terrain use), built
	             only from the seed and the options, so every machine builds the same world.
	             `WorldTypes.register` adds one (Generation's own types register below; other
	             modules may add theirs before the world is created).
	  Options    a flat table of strings, numbers and booleans (a world type's settings: a
	             superflat preset, a biome, structures on or off). `encodeOptions` writes it as one
	             string ("key=value" pairs, values typed: s:text, n:12, b:1), `decodeOptions` reads
	             it back; keys sorted, so equal options give equal strings.
	  Settings   a world type's `settings` declares its options for the Create World screen, in
	             order: { key (the Options key), name, kind ("toggle" | "choice" | "text"),
	             default, choices + labels (a choice's values and what the menu shows for each),
	             maxLength, presets ({ name, value }: ready-made texts a menu may offer, Minecraft's
	             flat presets), check (what is wrong with a text), description }. A menu renders
	             the list generically (client Ui/CreateWorldForm; "structures" is its own Generate
	             Structures toggle); anything it leaves out takes its default in `create`.
	  Hints      what a world type asks of the rest of the game: `mobs = false` (no natural mob
	             spawning: Mobs/Mobs), `ticks = false` (no block updates and no random ticks,
	             Minecraft's debug world: the server script builds its BlockTicker without
	             behaviours), `gameMode` (the game mode the type suggests: the Create World screen
	             preselects it, and a server without the menu gives it), `debug` (a debug world:
	             listed last). The server applies the hints when the world starts (World/WorldInfo
	             .apply, the boot's startWorld); `published` reads the type back from the
	             attributes once the world exists.
	  Replicated the server sets three attributes on ReplicatedStorage.IceVoxel, in this order:
	             "WorldType" (the id), "WorldOptions" (the encoded options), then "Seed" (a number).
	             Clients and chunk workers wait for "Seed" (it comes last, once the world exists:
	             the main menu's world creation may hold it back) and then `fromAttributes` builds
	             their generator. A world type or options unknown to a client build the Default.

	The types (menu order): Default (TerrainGenerator), Superflat (Generation/Superflat), Void
	(Minecraft's The Void: a stone platform over nothing), Single Biome and Large Biomes (the
	Default's terrain with TerrainGenerator's `biome` / `climateScale`), and the debug worlds All
	Blocks, All Structures and All Biomes (Generation/DebugWorlds).
]]

local Biomes = require(script.Parent.Parent.Biomes)
local Blocks = require(script.Parent.Parent.Blocks)
local GameMode = require(script.Parent.Parent.GameMode)
local TerrainGenerator = require(script.Parent.TerrainGenerator)
local LayeredGenerator = require(script.Parent.LayeredGenerator)
local Superflat = require(script.Parent.Superflat)
local DebugWorlds = require(script.Parent.DebugWorlds)

export type Options = { [string]: string | number | boolean }

--[[
	One of a world type's settings, for the Create World screen's Customize screen (client
	Ui/MainMenu draws them generically: a type declares them, nothing else is needed). `key` is
	the Options key `create` reads, `default` its value when the player changes nothing:
	  "toggle"  ON / OFF (a boolean);
	  "choice"  one of `choices` (strings, cycled in this order; `labels` are what the button
	            shows, in the same order, default the choices themselves);
	  "text"    a code typed in (a preset, an id), at most `maxLength` characters (default 64) of
	            letters, digits and _ : ; , . * + - = / # (Shared/WorldSettings.cleanText): never
	            free text, so it is never shown to other players. `presets` ({ name, value }) are
	            ready-made texts the screen offers (Minecraft's flat presets); `check` (text) is
	            nil when the text is good, else what is wrong with it, shown under the box (a
	            world made from a bad text still builds the type's fallback).
	The server keeps only the declared keys, of their kind (WorldSettings.validateOptions).
]]
export type Setting = {
	key: string,
	name: string,
	kind: "toggle" | "choice" | "text",
	default: string | number | boolean,
	choices: { string }?,
	labels: { string }?,
	maxLength: number?,
	presets: { { name: string, value: string } }?,
	check: ((text: string) -> string?)?,
	-- A line under the Customize screen's widget.
	description: string?,
}

export type WorldType = {
	id: string,
	name: string,
	description: string,
	create: (seed: number, options: Options) -> TerrainGenerator.Generator,
	-- Hidden from the create-world menu (still buildable by id).
	hidden: boolean?,
	-- The Customize screen's settings (none: no Customize button). Options outside them are
	-- dropped when the world is created from the menu ("structures" is the screen's own toggle).
	settings: { Setting }?,
	-- Hints (see the header): false turns natural mob spawning / ticks off; the suggested game
	-- mode (GameMode names); a debug world.
	mobs: boolean?,
	ticks: boolean?,
	gameMode: string?,
	debug: boolean?,
}

local WorldTypes = {}

WorldTypes.DEFAULT = "default"

local list: { WorldType } = {}
local byId: { [string]: WorldType } = {}
WorldTypes.list = list

-- Adds `worldType` (an id already there is replaced, keeping its place in the list).
function WorldTypes.register(worldType: WorldType)
	local old = byId[worldType.id]
	byId[worldType.id] = worldType
	if old then
		local index = table.find(list, old)
		if index then
			list[index] = worldType
			return
		end
	end
	table.insert(list, worldType)
end

-- The world type `id`, nil when unknown.
function WorldTypes.get(id: string?): WorldType?
	return if id then byId[id] else nil
end

-- The generator of world type `id` (unknown: the Default) for `seed` and `options`.
function WorldTypes.create(id: string?, seed: number, options: Options?): TerrainGenerator.Generator
	local worldType = WorldTypes.get(id) or byId[WorldTypes.DEFAULT]
	return worldType.create(seed, options or {})
end

--[[ Options as one string ]]

local function escape(text: string): string
	return (
		string.gsub(text, "[%%;=]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

local function unescape(text: string): string
	return (
		string.gsub(text, "%%(%x%x)", function(hex: string): string
			return string.char(tonumber(hex, 16) :: number)
		end)
	)
end

function WorldTypes.encodeOptions(options: Options?): string
	if options == nil then
		return ""
	end
	local keys: { string } = {}
	for key in options do
		table.insert(keys, key)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, key in keys do
		local value = options[key]
		local typed = if type(value) == "number"
			then "n:" .. tostring(value)
			elseif type(value) == "boolean" then "b:" .. (if value then "1" else "0")
			else "s:" .. escape(tostring(value))
		table.insert(parts, escape(key) .. "=" .. typed)
	end
	return table.concat(parts, ";")
end

function WorldTypes.decodeOptions(text: string?): Options
	local options: Options = {}
	if type(text) ~= "string" or text == "" then
		return options
	end
	for part in string.gmatch(text, "[^;]+") do
		local key, kind, value = string.match(part, "^([^=]*)=(%a):(.*)$")
		if key and kind and value then
			local name = unescape(key)
			if kind == "n" then
				local number = tonumber(value)
				if number then
					options[name] = number
				end
			elseif kind == "b" then
				options[name] = value == "1"
			elseif kind == "s" then
				options[name] = unescape(value)
			end
		end
	end
	return options
end

--[[
	The generator the attributes of `folder` (ReplicatedStorage.IceVoxel) describe; call once "Seed"
	is a number. Also returns the world type's id and options.
]]
function WorldTypes.fromAttributes(folder: Instance): (TerrainGenerator.Generator, string, Options)
	local seed = folder:GetAttribute("Seed")
	assert(type(seed) == "number", "WorldTypes.fromAttributes: no Seed yet")
	local id = folder:GetAttribute("WorldType")
	local options = WorldTypes.decodeOptions(folder:GetAttribute("WorldOptions") :: string?)
	local typeId = if type(id) == "string" and byId[id] then id else WorldTypes.DEFAULT
	return WorldTypes.create(typeId, seed, options), typeId, options
end

--[[
	The world type the attributes of `folder` name (the Default when none or unknown) and its
	options, for the server's parts that follow a type's hints (Mobs, the block ticker). Read it
	once the world is published.
]]
function WorldTypes.published(folder: Instance): (WorldType, Options)
	local id = folder:GetAttribute("WorldType")
	local worldType = WorldTypes.get(if type(id) == "string" then id else nil) or byId[WorldTypes.DEFAULT]
	return worldType, WorldTypes.decodeOptions(folder:GetAttribute("WorldOptions") :: string?)
end

--[[
	Publishes a world on `folder` for the clients: "WorldType", "WorldOptions", then "Seed" (see the
	header).
]]
function WorldTypes.publish(folder: Instance, id: string, seed: number, options: Options?)
	folder:SetAttribute("WorldType", id)
	folder:SetAttribute("WorldOptions", WorldTypes.encodeOptions(options))
	folder:SetAttribute("Seed", seed)
end

--[[ The world types ]]

-- Minecraft's "Generate Structures" (library structures: Structures/Library).
local STRUCTURES: Setting = {
	key = "structures",
	name = "Generate Structures",
	kind = "toggle",
	default = true,
	description = "Outposts and the other structures of the structure library",
}

-- "BirchForest" -> "Birch Forest".
local function spaced(name: string): string
	return (string.gsub(name, "(%l)(%u)", "%1 %2"))
end

local biomeNames: { string } = {}
local biomeLabels: { string } = {}
for _, biome in Biomes.list do
	table.insert(biomeNames, biome.name)
	table.insert(biomeLabels, spaced(biome.name))
end

-- Superflat's preset line (Generation/Superflat) and its trees and plants.
local PRESET: Setting = {
	key = "preset",
	name = "Preset",
	kind = "text",
	default = Superflat.CLASSIC,
	-- (Room for Minecraft's own strings: "minecraft:bedrock,2*minecraft:dirt,..." pasted as is.)
	maxLength = 256,
	presets = Superflat.PRESETS :: any,
	check = function(text: string): string?
		local _, problem = Superflat.parse(text)
		return problem
	end,
	description = "The layers from the bottom up, then the biome: Bedrock,2*Dirt,Grass;Plains",
}
local DECORATION: Setting = {
	key = "decoration",
	name = "Trees and Plants",
	kind = "toggle",
	default = false,
	description = "The biome's trees and ground plants on the top layer",
}
-- Single Biome's biome (BiomeList names).
local BIOME: Setting = {
	key = "biome",
	name = "Biome",
	kind = "choice",
	default = "Plains",
	choices = biomeNames,
	labels = biomeLabels,
}

-- The biome index an option names (BiomeList name), `fallback` when none or unknown.
local function biomeOption(value: any, fallback: string): number
	local biome = if type(value) == "string" then Biomes.byName(value) else nil
	return (biome or Biomes.byName(fallback) :: Biomes.Biome).index
end

WorldTypes.register({
	id = WorldTypes.DEFAULT,
	name = "Default",
	description = "IceVoxel's own terrain: huge mountains, deep caves, the Underlands",
	create = function(seed: number, options: Options): TerrainGenerator.Generator
		return TerrainGenerator.new(seed, { structures = options.structures ~= false })
	end,
	settings = { STRUCTURES },
})

WorldTypes.register({
	id = "superflat",
	name = "Superflat",
	description = "Flat layers of blocks, Minecraft's presets or your own",
	create = Superflat.create,
	settings = { PRESET, DECORATION },
})

-- The Void's platform: VOID_RADIUS blocks around the origin at VOID_Y, cobblestone in the middle.
WorldTypes.VOID_RADIUS = 16
WorldTypes.VOID_Y = 64

WorldTypes.register({
	id = "void",
	name = "The Void",
	description = "Nothing at all but a small stone platform to start on",
	create = function(seed: number): TerrainGenerator.Generator
		local placed: { number } = {}
		local r, y = WorldTypes.VOID_RADIUS, WorldTypes.VOID_Y
		for x = -r, r do
			for z = -r, r do
				table.insert(placed, x)
				table.insert(placed, y)
				table.insert(placed, z)
				table.insert(placed, if x == 0 and z == 0 then Blocks.id.Cobblestone else Blocks.id.Stone)
			end
		end
		return LayeredGenerator.new({
			seed = seed,
			stack = LayeredGenerator.EMPTY,
			biome = biomeOption(nil, "Plains"),
			blocks = placed,
		})
	end,
	-- (Minecraft's the_void biome spawns nothing.)
	mobs = false,
})

WorldTypes.register({
	id = "singleBiome",
	name = "Single Biome",
	description = "The Default terrain with one biome everywhere",
	create = function(seed: number, options: Options): TerrainGenerator.Generator
		return TerrainGenerator.new(seed, {
			structures = options.structures ~= false,
			biome = biomeOption(options.biome, "Plains"),
		})
	end,
	settings = { BIOME, STRUCTURES },
})

WorldTypes.register({
	id = "largeBiomes",
	name = "Large Biomes",
	description = "The Default terrain with biomes four times as wide",
	create = function(seed: number, options: Options): TerrainGenerator.Generator
		return TerrainGenerator.new(seed, { structures = options.structures ~= false, climateScale = 4 })
	end,
	settings = { STRUCTURES },
})

WorldTypes.register({
	id = "debugBlocks",
	name = "Debug: All Blocks",
	description = "Every block in a grid over the void; nothing ticks",
	create = DebugWorlds.allBlocks,
	mobs = false,
	ticks = false,
	gameMode = GameMode.SPECTATOR,
	debug = true,
})

WorldTypes.register({
	id = "debugStructures",
	name = "Debug: All Structures",
	description = "Every structure of the library in a grid, each with its name tag",
	create = function(seed: number): TerrainGenerator.Generator
		return DebugWorlds.allStructures(seed)
	end,
	mobs = false,
	ticks = false,
	gameMode = GameMode.CREATIVE,
	debug = true,
})

WorldTypes.register({
	id = "debugBiomes",
	name = "Debug: All Biomes",
	description = "A strip of every biome's ground, trees and plants",
	create = DebugWorlds.allBiomes,
	mobs = false,
	gameMode = GameMode.CREATIVE,
	debug = true,
})

return WorldTypes
