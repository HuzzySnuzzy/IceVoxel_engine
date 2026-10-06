--[[
	Turns the texture pack (src/shared/TexturePack.luau) into the two Rojo model files the game's
	textures come from. tests/build_textures.luau writes them; the TexturePack spec checks that the
	committed ones are up to date.

	Game scripts cannot set a MaterialVariant's maps or its BaseMaterial, nor a Texture's normal,
	roughness and metalness maps (all PluginSecurity), so these are made at edit time and Rojo
	(7.7.1) builds or syncs them:
	  Materials.model.json   MaterialService.IceVoxel: a MaterialVariant per filled texture, named
	                         Blocks.variantName ("IV_grass_top"), BaseMaterial = the texture's
	                         Material, its maps (never "": Rojo would store an empty Uri), StudsPerTile
	                         and MaterialPattern "Regular". No AlphaMode: cut-outs are not live.
	  Images.model.json      ReplicatedStorage.IceVoxelTextures: a Texture prototype per filled
	                         texture, of the same name, with TextureContent and its maps and
	                         StudsPerTileU / V. The client clones one for each face image, sprite
	                         and item cube, since a clone keeps the maps scripts cannot set.

	`build` checks what Blocks does not (ids, map fields, averages; Blocks has already checked
	names and materials when it loaded) and refuses a pack with errors. Its output is
	deterministic: sorted names and keys, tabs, one property per line, a final newline. It also
	names the filled textures with no Average yet (`unmeasured`, `unmeasuredNote`, `list`): until
	one is pasted in, the game guesses those textures' distant colours.
]]

local TextureBuild = {}

TextureBuild.MATERIALS = "src/textures/Materials.model.json"
TextureBuild.IMAGES = "src/textures/Images.model.json"

-- Pack map field -> MaterialVariant property, Texture property.
local MAPS = {
	{ "Color", "ColorMapContent", "TextureContent" },
	{ "Normal", "NormalMapContent", "NormalMapContent" },
	{ "Roughness", "RoughnessMapContent", "RoughnessMapContent" },
	{ "Metalness", "MetalnessMapContent", "MetalnessMapContent" },
}
local FIELDS = {
	Color = true,
	Normal = true,
	Roughness = true,
	Metalness = true,
	Material = true,
	Tint = true,
	Average = true,
	Align = true,
}
-- Materials that cannot take a MaterialVariant (Blocks.VARIANT_MATERIALS has the ones that can).
local REFUSED = { Neon = true, Glass = true, ForceField = true, Air = true, Water = true }

export type Result = {
	-- Path -> file text, for both files (empty when there are errors).
	files: { [string]: string },
	errors: { string },
	warnings: { string },
	-- Filled textures (one variant and one prototype each) and blank ones, sorted.
	filled: { string },
	blank: { string },
	-- Filled textures without an Average, sorted: until it is pasted in, the game guesses their
	-- distant colours, then measures them and restyles the world (see the pack's header).
	unmeasured: { string },
}

local function sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for key in t do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function isId(value: any): boolean
	return type(value) == "string" and string.match(value, "^rbxassetid://%d+$") ~= nil
end

--[[ Deterministic JSON ]]

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }

local function jsonString(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(c)
			return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
		end)
		.. '"'
end

local function jsonNumber(n: number): string
	if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	return string.format("%.9g", n)
end

-- Model objects keep Rojo's key order; property tables are sorted.
local MODEL_KEYS = { "name", "className", "properties", "children" }

local function encode(value: any, indent: string): string
	local kind = type(value)
	if kind == "string" then
		return jsonString(value)
	elseif kind == "number" then
		return jsonNumber(value)
	elseif kind == "boolean" then
		return tostring(value)
	end
	local inner = indent .. "\t"
	local parts = {}
	if #value > 0 then
		for _, item in value do
			table.insert(parts, inner .. encode(item, inner))
		end
		return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
	end
	local keys
	if value.className ~= nil then
		keys = {}
		for _, key in MODEL_KEYS do
			if value[key] ~= nil then
				table.insert(keys, key)
			end
		end
	else
		keys = sortedKeys(value)
	end
	for _, key in keys do
		table.insert(parts, `{inner}{jsonString(key)}: {encode(value[key], inner)}`)
	end
	if #parts == 0 then
		return "{}"
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function folder(children: { any }): string
	return encode({ className = "Folder", children = if #children > 0 then children else nil }, "") .. "\n"
end

--[[ Building ]]

-- The model files for `pack` (Shared/TexturePack's shape), with `Blocks` for variant names and
-- materials. Errors leave `files` empty.
function TextureBuild.build(pack: any, Blocks: any): Result
	local errors, warnings = {}, {}
	local filled, blank, unmeasured = {}, {}, {}
	local canTake: { [string]: boolean } = {}
	for _, material in Blocks.VARIANT_MATERIALS do
		canTake[material] = true
	end

	local studs = pack.StudsPerTile
	if type(studs) ~= "number" or studs <= 0 then
		table.insert(errors, `StudsPerTile must be a number above 0, got {studs}`)
	end
	if pack.Textures[pack.Missing] == nil then
		table.insert(errors, `the Missing texture "{pack.Missing}" is not in Textures`)
	end

	-- Textures some block names (the rest is unused).
	local used: { [string]: boolean } = {}
	for _, faces in pack.Blocks do
		for _, name in faces do
			used[name] = true
		end
	end

	local variantNames: { [string]: string } = {}
	for _, name in sortedKeys(pack.Textures) do
		local texture = pack.Textures[name]
		local function err(message: string)
			table.insert(errors, `texture "{name}": {message}`)
		end
		for _, field in sortedKeys(texture) do
			if not FIELDS[field] then
				err(`unknown field {field} (Color, Normal, Roughness, Metalness, Material, Tint, Average, Align)`)
			end
		end
		if type(texture.Color) ~= "string" or (texture.Color ~= "" and not isId(texture.Color)) then
			err(`Color must be "" or "rbxassetid://<number>", got {texture.Color}`)
		end
		for _, map in MAPS do
			local value = texture[map[1]]
			if map[1] ~= "Color" and value ~= nil and value ~= "" and not isId(value) then
				err(`{map[1]} must be "", nil or "rbxassetid://<number>", got {value}`)
			elseif map[1] ~= "Color" and value ~= nil and value ~= "" and value == texture.Color then
				table.insert(
					warnings,
					`texture "{name}": the {map[1]} map is the colour map ({value}): a typo for another id?`
				)
			end
		end
		local material = texture.Material
		if REFUSED[material] then
			err(`Material {material} cannot take a MaterialVariant`)
		elseif not canTake[material] then
			err(`unknown Material {material} (an Enum.Material name)`)
		end
		local tint = texture.Tint
		if tint ~= nil and type(tint) ~= "boolean" and type(tint) ~= "string" then
			err(`Tint must be true, false or a block name, got {tint}`)
		end
		local average = texture.Average
		if average ~= nil then
			local ok = type(average) == "table" and #average == 3
			for k = 1, 3 do
				local c = if ok then average[k] else nil
				ok = ok and type(c) == "number" and c >= 0 and c <= 255
			end
			if not ok then
				err("Average must be { r, g, b } in 0-255")
			end
		end
		if texture.Align ~= nil and type(texture.Align) ~= "boolean" then
			err(`Align must be true or false, got {texture.Align}`)
		end

		if texture.Color == "" then
			table.insert(blank, name)
		else
			table.insert(filled, name)
			if average == nil then
				table.insert(unmeasured, name)
			end
			if not used[name] and name ~= pack.Missing then
				table.insert(warnings, `texture "{name}" is filled in but no block uses it`)
			end
		end
		local variant = Blocks.variantName(name)
		if variantNames[variant] then
			err(`its variant name {variant} is also "{variantNames[variant]}"'s`)
		end
		variantNames[variant] = name
	end
	if pack.Textures[pack.Missing] and pack.Textures[pack.Missing].Color == "" then
		table.insert(warnings, `the Missing texture "{pack.Missing}" is blank: nothing can stand in for others`)
	end

	local result: Result = {
		files = {},
		errors = errors,
		warnings = warnings,
		filled = filled,
		blank = blank,
		unmeasured = unmeasured,
	}
	if #errors > 0 then
		return result
	end

	-- `column` 2: MaterialVariant properties, 3: Texture properties. Never "" (see the header).
	local function maps(texture: any, column: number): { [string]: any }
		local props = {}
		for _, map in MAPS do
			local value = texture[map[1]]
			if value ~= nil and value ~= "" then
				props[map[column]] = value
			end
		end
		return props
	end

	local variants, images = {}, {}
	for _, name in filled do
		local texture = pack.Textures[name]
		local variant = maps(texture, 2)
		variant.BaseMaterial = texture.Material
		variant.StudsPerTile = studs
		variant.MaterialPattern = "Regular"
		table.insert(variants, { name = Blocks.variantName(name), className = "MaterialVariant", properties = variant })
		local image = maps(texture, 3)
		image.StudsPerTileU = studs
		image.StudsPerTileV = studs
		table.insert(images, { name = Blocks.variantName(name), className = "Texture", properties = image })
	end
	-- (Sorted by instance name: "_" and " " sort alike, but be exact.)
	local function byName(a: any, b: any): boolean
		return a.name < b.name
	end
	table.sort(variants, byName)
	table.sort(images, byName)
	result.files[TextureBuild.MATERIALS] = folder(variants)
	result.files[TextureBuild.IMAGES] = folder(images)
	return result
end

--[[
	The paths whose current text (`read` answers nil for a missing file) differs from `result`'s.
	Line endings do not count: Git's `text=auto` checks the files out with CRLF on Windows, and the
	generated text has no "\r" of its own (strings escape it).
]]
function TextureBuild.stale(result: Result, read: (path: string) -> string?): { string }
	local stale = {}
	for _, path in sortedKeys(result.files) do
		local text = read(path)
		if text == nil or (string.gsub(text, "\r\n", "\n")) ~= result.files[path] then
			table.insert(stale, path)
		end
	end
	return stale
end

-- What to do about the filled textures without an Average (one line), nil when every one has it.
function TextureBuild.unmeasuredNote(result: Result): string?
	local count = #result.unmeasured
	if count == 0 then
		return nil
	end
	return `{count} filled textures have no Average yet, so distant chunks guess their colours: play once in Studio and paste the "[IceVoxel] Texture averages" lines it prints into the pack (--list names them)`
end

--[[
	Lines listing the blank textures and the blocks waiting on each (Blocks.textureUsers), then the
	filled textures still waiting for an Average (when any is).
]]
function TextureBuild.list(result: Result, Blocks: any): { string }
	local lines = { `{#result.blank} blank textures (fill them in src/shared/TexturePack.luau):` }
	local width = 0
	for _, name in result.blank do
		width = math.max(width, #name)
	end
	for _, name in result.blank do
		local users = Blocks.textureUsers(name)
		local waiting = if #users > 0 then table.concat(users, ", ") else "(no block uses it)"
		table.insert(lines, `  {name}{string.rep(" ", width - #name)}  {waiting}`)
	end
	if #result.unmeasured > 0 then
		table.insert(
			lines,
			`{#result.unmeasured} filled textures without an Average (measured in game, printed to paste in):`
		)
		for _, name in result.unmeasured do
			table.insert(lines, `  {name}`)
		end
	end
	return lines
end

return TextureBuild
