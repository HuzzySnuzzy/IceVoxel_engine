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
	  Replicated the server sets three attributes on ReplicatedStorage.IceVoxel, in this order:
	             "WorldType" (the id), "WorldOptions" (the encoded options), then "Seed" (a number).
	             Clients and chunk workers wait for "Seed" (it comes last, once the world exists:
	             the main menu's world creation may hold it back) and then `fromAttributes` builds
	             their generator. A world type or options unknown to a client build the Default.
]]

local TerrainGenerator = require(script.Parent.TerrainGenerator)

export type Options = { [string]: string | number | boolean }

--[[
	One of a world type's settings, for the Create World screen's Customize screen (client
	Ui/MainMenu draws them generically: a type declares them, nothing else is needed). `key` is
	the Options key `create` reads, `default` its value when the player changes nothing:
	  "toggle"  ON / OFF (a boolean);
	  "choice"  one of `choices` (strings, cycled in this order; `names` are what the button shows,
	            in the same order, default the choices themselves);
	  "text"    a code typed in (a preset, an id), at most `maxLength` characters (default 64) of
	            letters, digits and _ : , . * + - = / # (Shared/WorldSettings.cleanText): never
	            free text, so it is never shown to other players.
	The server keeps only the declared keys, of their kind (WorldSettings.validateOptions).
]]
export type Setting = {
	key: string,
	name: string,
	kind: "toggle" | "choice" | "text",
	default: string | number | boolean,
	choices: { string }?,
	names: { string }?,
	maxLength: number?,
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
	Publishes a world on `folder` for the clients: "WorldType", "WorldOptions", then "Seed" (see the
	header).
]]
function WorldTypes.publish(folder: Instance, id: string, seed: number, options: Options?)
	folder:SetAttribute("WorldType", id)
	folder:SetAttribute("WorldOptions", WorldTypes.encodeOptions(options))
	folder:SetAttribute("Seed", seed)
end

--[[ The world types ]]

WorldTypes.register({
	id = WorldTypes.DEFAULT,
	name = "Default",
	description = "IceVoxel's own terrain: huge mountains, deep caves, the Underlands",
	create = function(seed: number, options: Options): TerrainGenerator.Generator
		return TerrainGenerator.new(seed, { structures = options.structures ~= false })
	end,
})

return WorldTypes
