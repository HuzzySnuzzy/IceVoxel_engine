--!strict
--[[
	The structure library: every template, template pool and generated structure the world knows.

	Sources (`Library.load`, read once per Luau VM: the server, each client and each worker actor):
	  1. the content packs (Shared/Content; Content/Schema has the fields): their `templates`
	     (name -> IVS1 text, as a structure block's SAVE gives it; the name is the one inside),
	     `pools` (explicit template pools: { [poolName] = { fallback?, projection?, elements } })
	     and `structures` (generated structures: a list of structure specs, fields below), merged
	     and their names checked as the packs load (a structure's biomes too, by their exact
	     names);
	  2. the place's optional `ReplicatedStorage.IceVoxelStructures` folder (any depth of Folders):
	     StringValues holding IVS1 data (one or more strings each). Attributes on a StringValue
	     make its (first) template generate with no code: Generate (bool), Biomes (comma list),
	     Spacing, Separation, Size (jigsaw depth), Foundation (bool), OnLand (bool), StartHeight,
	     MaxDistance; TerrainMatching (bool) is the projection of all its templates in implicit
	     pools. The folder's templates and structures replace the packs' with the same name.
	Biome names are matched loosely here, like final states ("plains", "minecraft:plains",
	"Plains"), against Shared/Biomes (the packs' biomes): the place's Biomes attribute is typed by
	hand in Studio, and an unknown one is warned.
	The packs' part is built alone first, and strictly: anything this module would warn about in
	it (a number out of range, a start jigsaw no start piece has, a jigsaw's pool with no
	templates or its unknown final state, an unknown item in a chest) is an error
	naming the pack, the file and the entry, as Content's own checks are (`Content.where`). The
	place's folder is Studio's to fill: its bad entries are reported (Roblox `warn`, and
	`library.warnings`) and skipped; nothing errors. Its values are read in path order (then data
	and attributes), so every machine resolves a template defined twice (the later one wins)
	alike, whatever order the children replicate in.
	Clients generate terrain too, so every machine must load the same library: the server never
	writes into the folder at runtime (saves go to ServerStorage.IceVoxelSavedStructures).

	Pools (`library.pool(name)`):
	  - an explicit pool (a pack's `pools`);
	  - else the template with exactly that name, alone (so a structure or a jigsaw can name one
	    template);
	  - else the implicit pool: every template whose name starts with "<name>/", sorted by name,
	    weight 1, rigid unless the template is marked terrain matching. So pieces named
	    "mything/houses/a" and "mything/houses/b" make the pool "mything/houses" with no code.

	`Library.new` is pure (tests build libraries from in-memory templates with it). Its warnings
	name what they are about (`warn(message, kind, name)`: "template", "pool" or "structure" and
	its name), which is how `load` names the pack.
]]

local Biomes = require(script.Parent.Parent.Biomes)
local Content = require(script.Parent.Parent.Content)
local Hash = require(script.Parent.Parent.Util.Hash)
local Jigsaw = require(script.Parent.Jigsaw)

type Element = Jigsaw.Element
type Pool = Jigsaw.Pool

-- Structures/Template's Template (the contract's type, repeated so this module loads without it).
export type Marker = { x: number, y: number, z: number, data: string }
export type ContainerItem = { slot: number, item: string, count: number, damage: number }
export type Container = { x: number, y: number, z: number, items: { ContainerItem } }
export type Template = {
	name: string,
	size: { number },
	palette: { number },
	cells: buffer,
	jigsaws: { Jigsaw.JigsawData },
	markers: { Marker },
	containers: { Container },
}

-- A generated structure, validated, every field filled in.
export type Structure = {
	name: string,
	startPool: string,
	startJigsawName: string?,
	size: number, -- jigsaw depth 0..7
	maxDistance: number, -- 1..128
	biomes: { string }, -- biome names (Shared/Biomes, the packs' biomes)
	biomeSet: { [number]: boolean }, -- the same, by biome index
	spacing: number, -- region size in chunks
	separation: number, -- 0..spacing - 1
	salt: number,
	startHeight: number,
	projectToHeightmap: boolean,
	onLand: boolean,
	foundation: boolean,
	-- Every block of the structure lies within ± reach blocks (x and z) of its start position.
	reach: number,
}

export type Spec = {
	templates: { Template }?, -- later ones replace earlier ones with the same name
	pools: { [string]: any }?, -- the `pools` kind's format (Content/Schema)
	structures: { any }?, -- the `structures` kind's format (Content/Schema)
	-- Template name -> projection it has in implicit pools (default rigid).
	projections: { [string]: string }?,
	-- Each warning, and what it is about: "template", "pool" or "structure" and its name (nil
	-- for an entry with no name).
	warn: ((message: string, kind: string?, name: string?) -> ())?,
}

export type Library = {
	templates: { [string]: Template },
	names: { string }, -- template names, sorted
	pools: { [string]: Pool }, -- the explicit pools
	structures: { Structure }, -- in definition order
	warnings: { string },
	template: (name: string) -> Template?,
	pool: (name: string) -> Pool?,
	structure: (name: string) -> Structure?,
}

export type LoadOptions = {
	content: Content.Content?, -- default: Content.default, the game's packs
	folder: Instance?, -- default: ReplicatedStorage.IceVoxelStructures, when there is one
	warn: ((message: string) -> ())?, -- default: Roblox warn (the folder's problems)
}

local Library = {}

Library.FOLDER = "IceVoxelStructures"
Library.MAX_WEIGHT = 150
Library.MAX_SPACING = 4096
Library.DEFAULT_SPACING = 34 -- Minecraft's villages
Library.DEFAULT_SEPARATION = 8
Library.DEFAULT_SIZE = 7
-- Attributes read from StringValues in the folder, and their types.
Library.ATTRIBUTES = table.freeze({
	Generate = "boolean",
	Biomes = "string",
	Spacing = "number",
	Separation = "number",
	Size = "number",
	Foundation = "boolean",
	OnLand = "boolean",
	StartHeight = "number",
	MaxDistance = "number",
	TerrainMatching = "boolean",
})

local floor = math.floor

local ATTRIBUTE_NAMES: { string } = {}
for name: string in Library.ATTRIBUTES :: { [string]: string } do
	table.insert(ATTRIBUTE_NAMES, name)
end
table.sort(ATTRIBUTE_NAMES)

local VALID_FRONT_TOP: { [string]: { [string]: boolean } } = {
	Up = { North = true, South = true, West = true, East = true },
	Down = { North = true, South = true, West = true, East = true },
	North = { Up = true },
	South = { Up = true },
	West = { Up = true },
	East = { Up = true },
}

-- "terrain_matching", "terrainMatching", "TerrainMatching" -> "terrain_matching"; nil if unknown.
local function projectionOf(value: any): string?
	if type(value) ~= "string" then
		return nil
	end
	local key = string.gsub(string.lower(value), "_", "")
	if key == "rigid" then
		return Jigsaw.RIGID
	elseif key == "terrainmatching" then
		return Jigsaw.TERRAIN_MATCHING
	end
	return nil
end

local function isInteger(v: any): boolean
	return type(v) == "number" and v == v and v == floor(v) and math.abs(v) < 2 ^ 31
end

-- Comma (or semicolon) separated names, trimmed, empty ones dropped. (Trimmed by scanning, not
-- with "^%s*(.-)%s*$", which backtracks quadratically over long runs of spaces.)
function Library.splitList(text: string): { string }
	local list = {}
	for part in string.gmatch(text, "[^,;]+") do
		local first = string.find(part, "%S")
		if first then
			local last = #part
			while string.find(string.sub(part, last, last), "%s") do
				last -= 1
			end
			table.insert(list, string.sub(part, first, last))
		end
	end
	return list
end

local function sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for k in t do
		if type(k) == "string" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	return keys
end

-- Index of the first name in `sorted` that is >= `prefix` (names starting with the prefix follow it
-- together, sorted strings keep prefixes contiguous).
local function lowerBound(sorted: { string }, prefix: string): number
	local lo, hi = 1, #sorted + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if sorted[mid] < prefix then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return lo
end

-- The names in `sorted` starting with `prefix`, in order.
local function withPrefix(sorted: { string }, prefix: string): { string }
	local list = {}
	local n = #prefix
	for i = lowerBound(sorted, prefix), #sorted do
		local name = sorted[i]
		if string.sub(name, 1, n) ~= prefix then
			break
		end
		table.insert(list, name)
	end
	return list
end

local function validTemplate(t: any): string?
	if type(t) ~= "table" then
		return "is not a template"
	end
	if type(t.name) ~= "string" or t.name == "" then
		return "has no name"
	end
	local size = t.size
	if type(size) ~= "table" or not (isInteger(size[1]) and isInteger(size[2]) and isInteger(size[3])) then
		return "has no size"
	end
	if size[1] < 1 or size[2] < 1 or size[3] < 1 then
		return "is empty"
	end
	if type(t.cells) ~= "buffer" or buffer.len(t.cells) < size[1] * size[2] * size[3] * 2 then
		return "has no cells"
	end
	if type(t.palette) ~= "table" or type(t.jigsaws) ~= "table" then
		return "is incomplete"
	end
	return nil
end

function Library.new(spec: Spec): Library
	local warnings: { string } = {}
	local function warn(message: string, kind: string?, name: string?)
		table.insert(warnings, message)
		if spec.warn then
			spec.warn(message, kind, name)
		end
	end

	--[[ Templates ]]
	local templates: { [string]: Template } = {}
	local given: { Template } = spec.templates or {}
	for i, t in given do
		local problem = validTemplate(t)
		if problem then
			warn(`Template #{i} {problem}; skipped`)
		else
			if templates[t.name] then
				warn(`Template '{t.name}' is defined twice; the later one is used`, "template", t.name)
			end
			templates[t.name] = t
		end
	end
	local names = sortedKeys(templates)
	local projections = spec.projections or {}

	--[[ Explicit pools ]]
	local pools: { [string]: Pool } = {}
	local rawPools = spec.pools or {}
	for _, poolName in sortedKeys(rawPools) do
		local raw = rawPools[poolName]
		if type(raw) ~= "table" or type(raw.elements) ~= "table" then
			warn(`Pool '{poolName}' has no elements list; skipped`, "pool", poolName)
			continue
		end
		local default = Jigsaw.RIGID
		if raw.projection ~= nil then
			default = projectionOf(raw.projection) or default
			if projectionOf(raw.projection) == nil then
				warn(
					`Pool '{poolName}': unknown projection '{tostring(raw.projection)}' (rigid used)`,
					"pool",
					poolName
				)
			end
		end
		local elements: { Element } = {}
		for i, e in raw.elements do
			if type(e) ~= "table" then
				warn(`Pool '{poolName}' element #{i} is not a table; skipped`, "pool", poolName)
				continue
			end
			local weight = e.weight
			if weight == nil then
				weight = 1
			elseif not isInteger(weight) or weight < 1 or weight > Library.MAX_WEIGHT then
				local fixed = if type(weight) == "number" and weight == weight
					then math.clamp(floor(weight), 1, Library.MAX_WEIGHT)
					else 1
				warn(
					`Pool '{poolName}' element #{i}: weight must be 1..{Library.MAX_WEIGHT} ({fixed} used)`,
					"pool",
					poolName
				)
				weight = fixed
			end
			local projection = default
			if e.projection ~= nil then
				local p = projectionOf(e.projection)
				if p then
					projection = p
				else
					warn(
						`Pool '{poolName}' element #{i}: unknown projection '{tostring(e.projection)}'`,
						"pool",
						poolName
					)
				end
			end
			local name = e.template
			if name == nil or e.empty == true then
				table.insert(elements, { template = nil, weight = weight, projection = projection })
			elseif type(name) ~= "string" then
				warn(`Pool '{poolName}' element #{i}: template must be a name; skipped`, "pool", poolName)
			elseif templates[name] == nil then
				warn(`Pool '{poolName}': no template '{name}'; skipped`, "pool", poolName)
			else
				table.insert(elements, { template = name, weight = weight, projection = projection })
			end
		end
		local fallback = raw.fallback
		if fallback ~= nil and type(fallback) ~= "string" then
			warn(`Pool '{poolName}': fallback must be a pool name; ignored`, "pool", poolName)
			fallback = nil
		end
		if #elements == 0 then
			warn(`Pool '{poolName}' has no usable elements`, "pool", poolName)
		end
		pools[poolName] = { name = poolName, fallback = fallback, elements = elements }
	end

	--[[ Pool lookup: explicit, exact template, implicit (cached, misses too) ]]
	local resolved: { [string]: Pool | false } = {}
	local function pool(name: string): Pool?
		if type(name) ~= "string" then
			return nil
		end
		local cached = resolved[name]
		if cached ~= nil then
			return if cached == false then nil else cached :: Pool
		end
		local found: Pool? = pools[name]
		if found == nil and templates[name] then
			found = {
				name = name,
				elements = { { template = name, weight = 1, projection = projections[name] or Jigsaw.RIGID } },
			}
		end
		if found == nil then
			local elements: { Element } = {}
			for _, t in withPrefix(names, name .. "/") do
				table.insert(elements, { template = t, weight = 1, projection = projections[t] or Jigsaw.RIGID })
			end
			if #elements > 0 then
				found = { name = name, elements = elements }
			end
		end
		resolved[name] = found or false
		return found
	end

	local function template(name: string): Template?
		return if type(name) == "string" then templates[name] else nil
	end

	--[[ Validation of what templates and pools point at ]]
	for _, poolName in sortedKeys(pools) do
		local fallback = pools[poolName].fallback
		if fallback and not Jigsaw.EMPTY_POOLS[fallback] and pool(fallback) == nil then
			warn(`Pool '{poolName}': fallback pool '{fallback}' has no templates`, "pool", poolName)
		end
	end
	local missingPools: { [string]: { string } } = {}
	for _, name in names do
		local t = templates[name]
		local size = t.size
		for _, j in t.jigsaws do
			if type(j) ~= "table" or not (isInteger(j.x) and isInteger(j.y) and isInteger(j.z)) then
				warn(`Template '{name}': a jigsaw has no position`, "template", name)
				continue
			end
			local at = `Template '{name}': jigsaw at {j.x} {j.y} {j.z}`
			if type(j.name) ~= "string" or type(j.target) ~= "string" or type(j.pool) ~= "string" then
				warn(`{at} has no name, target or pool`, "template", name)
				continue
			end
			if j.x < 0 or j.y < 0 or j.z < 0 or j.x >= size[1] or j.y >= size[2] or j.z >= size[3] then
				warn(`{at} is outside the template`, "template", name)
			end
			local tops = VALID_FRONT_TOP[j.front]
			if tops == nil or not tops[j.top] then
				warn(`{at} has a bad orientation ({tostring(j.front)} / {tostring(j.top)})`, "template", name)
			end
			if j.joint ~= "rollable" and j.joint ~= "aligned" then
				warn(`{at} has an unknown joint '{tostring(j.joint)}' (the default is used)`, "template", name)
			end
			if type(j.finalState) == "string" and j.finalState ~= "" then
				local final = Jigsaw.finalStateBlock(j.finalState)
				if final == 0 and string.lower(j.finalState) ~= "air" and j.finalState ~= "minecraft:air" then
					warn(`{at}: unknown final state '{j.finalState}' (air used)`, "template", name)
				end
			end
			if type(j.pool) == "string" and not Jigsaw.EMPTY_POOLS[j.pool] and pool(j.pool) == nil then
				local users = missingPools[j.pool]
				if users == nil then
					users = {}
					missingPools[j.pool] = users
				end
				if not table.find(users, name) then
					table.insert(users, name)
				end
			end
		end
	end
	for _, poolName in sortedKeys(missingPools) do
		local users = missingPools[poolName]
		-- (About the first template using it.)
		warn(`Pool '{poolName}' (used by {table.concat(users, ", ")}) has no templates`, "template", users[1])
	end
	for _, name in names do
		if pools[name] == nil and #withPrefix(names, name .. "/") > 0 then
			warn(
				`'{name}' is a template's name, so pool '{name}' is that template alone, not the templates under '{name}/'`,
				"template",
				name
			)
		end
	end

	--[[ Structures ]]
	-- Biome names match as final state names do (Jigsaw.nameKey): "plains", "minecraft:plains"
	-- and "Plains" are alike.
	local allBiomes: { string } = {}
	local biomeByKey: { [string]: Biomes.Biome } = {}
	for _, biome in Biomes.list do
		table.insert(allBiomes, biome.name)
		biomeByKey[Jigsaw.nameKey(biome.name)] = biome
	end
	local knownBiomes = table.concat(allBiomes, ", ")

	local structures: { Structure } = {}
	local byName: { [string]: Structure } = {}
	local specs: { any } = spec.structures or {}
	for i, raw in specs do
		if type(raw) ~= "table" or type(raw.name) ~= "string" or raw.name == "" then
			warn(`Structure #{i} has no name; skipped`)
			continue
		end
		local name = raw.name :: string
		local function number(field: string, default: number, min: number, max: number): number
			local v = raw[field]
			if v == nil then
				return default
			end
			if not isInteger(v) then
				warn(`Structure '{name}': {field} must be a whole number ({default} used)`, "structure", name)
				return default
			end
			if v < min or v > max then
				local fixed = math.clamp(v, min, max)
				warn(`Structure '{name}': {field} must be {min}..{max} ({fixed} used)`, "structure", name)
				return fixed
			end
			return v
		end
		local function flag(field: string, default: boolean): boolean
			local v = raw[field]
			if v == nil then
				return default
			end
			if type(v) ~= "boolean" then
				warn(`Structure '{name}': {field} must be true or false ({default} used)`, "structure", name)
				return default
			end
			return v
		end

		local startPool = raw.startPool
		if type(startPool) ~= "string" then
			warn(`Structure '{name}' has no startPool; skipped`, "structure", name)
			continue
		end
		local start = pool(startPool)
		if start == nil or #start.elements == 0 then
			warn(`Structure '{name}': start pool '{startPool}' has no templates; skipped`, "structure", name)
			continue
		end
		local startJigsawName = raw.startJigsawName
		if startJigsawName ~= nil then
			if type(startJigsawName) ~= "string" then
				warn(`Structure '{name}': startJigsawName must be a name; skipped`, "structure", name)
				continue
			end
			local found = false
			for _, e in start.elements do
				local t = if e.template then templates[e.template] else nil
				if t then
					for _, j in t.jigsaws do
						if type(j) == "table" and j.name == startJigsawName then
							found = true
						end
					end
				end
			end
			if not found then
				warn(
					`Structure '{name}': no template in '{startPool}' has a jigsaw named '{startJigsawName}'; skipped`,
					"structure",
					name
				)
				continue
			end
		end

		local biomeNames: { string } = {}
		local biomeSet: { [number]: boolean } = {}
		local rawBiomes = raw.biomes
		if type(rawBiomes) == "string" then
			rawBiomes = Library.splitList(rawBiomes)
		end
		if rawBiomes ~= nil and type(rawBiomes) ~= "table" then
			warn(`Structure '{name}': biomes must be a list of names (every biome used)`, "structure", name)
			rawBiomes = nil
		end
		for _, biomeName in (rawBiomes or allBiomes) :: { any } do
			local biome = if type(biomeName) == "string" then biomeByKey[Jigsaw.nameKey(biomeName)] else nil
			if biome == nil then
				warn(
					`Structure '{name}': unknown biome '{tostring(biomeName)}' (biomes: {knownBiomes})`,
					"structure",
					name
				)
			elseif not biomeSet[biome.index] then
				biomeSet[biome.index] = true
				table.insert(biomeNames, biome.name)
			end
		end
		if #biomeNames == 0 then
			warn(`Structure '{name}' can grow in no biome; skipped`, "structure", name)
			continue
		end

		local spacing = number("spacing", Library.DEFAULT_SPACING, 1, Library.MAX_SPACING)
		local separation = number("separation", math.min(Library.DEFAULT_SEPARATION, spacing - 1), 0, spacing - 1)
		local size = number("size", Library.DEFAULT_SIZE, 0, Jigsaw.MAX_DEPTH)
		local maxDistance = number("maxDistance", Jigsaw.DEFAULT_DISTANCE, 1, Jigsaw.MAX_DISTANCE)
		local salt = raw.salt
		if salt == nil then
			salt = Hash.string(name)
		elseif not isInteger(salt) then
			warn(`Structure '{name}': salt must be a whole number (one from the name used)`, "structure", name)
			salt = Hash.string(name)
		end

		-- The start piece's widest turned side bounds how far its centre is from the start.
		local widest = 1
		for _, e in start.elements do
			local t = if e.template then templates[e.template] else nil
			if t then
				widest = math.max(widest, t.size[1], t.size[3])
			end
		end

		local structure: Structure = {
			name = name,
			startPool = startPool,
			startJigsawName = startJigsawName,
			size = size,
			maxDistance = maxDistance,
			biomes = biomeNames,
			biomeSet = biomeSet,
			spacing = spacing,
			separation = separation,
			salt = salt,
			startHeight = number("startHeight", 0, -4096, 4096),
			projectToHeightmap = flag("projectToHeightmap", true),
			onLand = flag("onLand", true),
			foundation = flag("foundation", true),
			reach = widest - 1 + (if size > 0 then maxDistance else 0),
		}
		local old = byName[name]
		if old then
			warn(`Structure '{name}' is defined twice; the later one is used`, "structure", name)
			structures[table.find(structures, old) :: number] = structure
		else
			table.insert(structures, structure)
		end
		byName[name] = structure
	end

	return {
		templates = templates,
		names = names,
		pools = pools,
		structures = structures,
		warnings = warnings,
		template = template,
		pool = pool,
		structure = function(name: string): Structure?
			return byName[name]
		end,
	}
end

--[[ Loading from the packs and the place ]]

-- The IVS1 strings in a text: a StringValue may hold several, separated by anything that is not
-- base64url (spaces, new lines, quotes, commas), which is trimmed off each one's end.
function Library.splitData(text: string): { string }
	local list = {}
	local at = string.find(text, "IVS1:", 1, true)
	while at do
		local nextAt = string.find(text, "IVS1:", at + 5, true)
		local chunk = string.sub(text, at, if nextAt then nextAt - 1 else #text)
		-- (Trimmed by scanning back over non-base64url bytes: an end-anchored pattern would
		-- backtrack quadratically over long runs of them inside the data.)
		local stop = #chunk
		while stop > 0 and not string.find(string.sub(chunk, stop, stop), "[%w%-_]") do
			stop -= 1
		end
		table.insert(list, string.sub(chunk, 1, stop))
		at = nextAt
	end
	return list
end

local cached: Library? = nil

--[[
	Loads the library from the content packs and the IceVoxelStructures folder. Without options the
	result is cached: later calls return the same library. Errors, naming the pack, for anything
	wrong with the packs' templates, pools and structures (the header).
]]
function Library.load(options: LoadOptions?): Library
	if options == nil and cached ~= nil then
		return cached
	end
	local opts: LoadOptions = options or {}
	local report = opts.warn or function(message: string)
		warn(`[Structures] {message}`)
	end
	-- (Required here so this module loads, and Library.new works, without the codec.)
	local Template = require(script.Parent.Template)
	local content: Content.Content = opts.content or Content.default

	local templates: { Template } = {}
	local projections: { [string]: string } = {}
	local structures: { any } = {}

	local function decode(text: string, where: string): { Template }
		local list = {}
		local chunks = Library.splitData(text)
		if #chunks == 0 then
			report(`{where}: no IVS1 data`)
		end
		for _, chunk in chunks do
			local t, err, notes = Template.decode(chunk)
			if t then
				table.insert(list, t)
			else
				report(`{where}: {err or "bad data"}`)
			end
			local noted: { string } = notes or {}
			for _, note in noted do
				report(`{where}: {note}`)
			end
		end
		return list
	end

	--[[ The packs' ]]
	local function packError(kind: string, name: string, message: string): never
		error(`Structures: {content.where(kind, name)}: {message}`, 0)
	end
	for _, name in sortedKeys(content.templates) do
		local t, err, notes = Template.decode(content.templates[name])
		if t == nil then
			packError("template", name, err or "bad data")
		end
		-- (An unknown item in a chest, a jigsaw not in its cell: left out by the decode.)
		local noted: { string } = notes or {}
		if #noted > 0 then
			packError("template", name, table.concat(noted, "; "))
		end
		table.insert(templates, t :: Template)
	end
	for _, structure in content.structures do
		table.insert(structures, structure)
	end
	-- (Alone, so whatever it would warn about is the packs' doing.)
	Library.new({
		templates = templates,
		pools = content.pools,
		structures = structures,
		warn = function(message: string, kind: string?, name: string?)
			if kind and name then
				packError(kind, name, message)
			end
			error(`Structures: the packs' structures: {message}`, 0)
		end,
	})

	--[[ The place's folder ]]
	local folder = opts.folder
	if folder == nil then
		folder = game:GetService("ReplicatedStorage"):FindFirstChild(Library.FOLDER)
	end
	if folder then
		local function attribute(instance: Instance, name: string, where: string): any
			local value = instance:GetAttribute(name)
			if value ~= nil and type(value) ~= Library.ATTRIBUTES[name] then
				report(`{where}: attribute {name} must be a {Library.ATTRIBUTES[name]}; ignored`)
				return nil
			end
			return value
		end
		-- Every StringValue, sorted by path, then data, then attributes: clients may receive the
		-- folder's children in another order than the server has them, and duplicates (the later
		-- one wins) must resolve alike everywhere.
		type Entry = { where: string, value: string, key: string, instance: Instance }
		local entries: { Entry } = {}
		local function collect(instance: Instance, path: string)
			for _, child in instance:GetChildren() do
				local where = `{path}/{child.Name}`
				if child:IsA("StringValue") then
					local parts = {}
					for _, name in ATTRIBUTE_NAMES do
						table.insert(parts, `{name}={tostring(child:GetAttribute(name))}`)
					end
					table.insert(entries, {
						where = where,
						value = (child :: StringValue).Value,
						key = table.concat(parts, ";"),
						instance = child :: Instance,
					})
				end
				collect(child, where)
			end
		end
		collect(folder, Library.FOLDER)
		table.sort(entries, function(a, b)
			if a.where ~= b.where then
				return a.where < b.where
			elseif a.value ~= b.value then
				return a.value < b.value
			end
			return a.key < b.key
		end)
		for _, entry in entries do
			local child, where = entry.instance, entry.where
			local list = decode(entry.value, where)
			if attribute(child, "TerrainMatching", where) == true then
				for _, t in list do
					projections[t.name] = Jigsaw.TERRAIN_MATCHING
				end
			end
			for _, t in list do
				table.insert(templates, t)
			end
			local first = list[1]
			if first and attribute(child, "Generate", where) == true then
				local biomes = attribute(child, "Biomes", where)
				table.insert(structures, {
					name = first.name,
					startPool = first.name,
					biomes = if biomes then Library.splitList(biomes) else nil,
					spacing = attribute(child, "Spacing", where),
					separation = attribute(child, "Separation", where),
					size = attribute(child, "Size", where),
					foundation = attribute(child, "Foundation", where),
					onLand = attribute(child, "OnLand", where),
					startHeight = attribute(child, "StartHeight", where),
					maxDistance = attribute(child, "MaxDistance", where),
				})
			end
		end
	end

	local library = Library.new({
		templates = templates,
		pools = content.pools,
		structures = structures,
		projections = projections,
		warn = function(message: string)
			report(message)
		end,
	})
	if options == nil then
		cached = library
	end
	return library
end

return Library
