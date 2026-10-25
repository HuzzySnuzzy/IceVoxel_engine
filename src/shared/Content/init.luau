--!strict
--[[
	Content packs (Minecraft's data packs): every block, item, recipe, tag, texture, loot table, ore
	feature, Age and lore line of the game comes from a pack, a folder under Content/Packs. The
	registries (Blocks, Items, TexturePack, Crafting, Progression, the Metal Miner, Radiation,
	generation, loot, sounds, Tough As Nails) build themselves from what this module loads; adding
	content is adding entries to a pack, or a pack.

	A pack
	  A folder holding `pack`, its manifest ({ order = n, description = "...", requires = { pack
	  names }? }), and any of the kinds Content/Schema lists (blocks, items, recipes, tags, textures,
	  loot, ores, ages, lore), each a module of the kind's name: a Luau module returning its data, or
	  `function(define) -> data` (define: Content/Define, the shared helpers and Config, for packs
	  that build entries or read switches), or a `.json` file holding it (Rojo makes a JSON file a
	  ModuleScript returning its table, and so does the Lune loader). Any other module in a pack is
	  an error (a misspelt kind would be ignored otherwise) unless its name starts with "_": the
	  pack's own helpers, which its kind modules require.

	Order and ids
	  Packs load sorted by (`order`, name), and a pack's entries keep their order. A block's id is
	  its place among every pack's blocks, minus one (Core's Air 0 and Cave Air 1 come first: order
	  0); an item's is ITEM_BASE + its place among every pack's items, minus one (every placeable
	  block is an item too, with its block's id: Shared/Items). Ids are dense and given here at
	  load, the same on every machine, so packs may add, remove and reorder content (saves are to
	  keep names, not ids); fewer than ITEM_BASE blocks. A pack's `requires` must load before it
	  (a lower order, or the same and an earlier name); it orders packs, while the names an entry
	  gives may be any pack's.

	Merging
	  blocks, items  by name: an entry with `override = true` patches the entry of that name an
	                 earlier pack made, field by field ({ name = "Stone", override = true, hardness
	                 = 2 }: Minecraft's data pack override); without it a name already taken, by a
	                 block or an item, is an error naming both packs, and so is an override of
	                 nothing.
	  textures       by name, the same way (an override patches the texture's fields).
	  tags           a union: each pack's lists in load order, then every entry's `tags`, each
	                 name once.
	  recipes        appended in load order; so are ore features (each with a name of its own)
	                 and Ages (each id once).
	  loot, lore     by name, each once.

	Checks, as packs load (each message names the pack, the kind and the entry):
	  * the manifest and every entry against Content/Schema: unknown fields (with "did you mean"),
	    wrong types, missing fields;
	  * names taken twice, overrides of nothing, a `requires` that does not load first;
	  * every cross-reference: the names recipes, tags and loot tables give (items or blocks), the
	    tags recipes name, `drops`, `shearDrops`, `item`, `places`, `caveTwin`, a plant's other half,
	    a toggle's `to`, a block's loot table, an ore feature's block, the Ages entries name (`age`),
	    the textures blocks name (`texture`) and the blocks textures are tinted like, the Ages'
	    milestones' items, every lore line's item, and a lore line both on an entry and in a pack's
	    `lore`.
	  The registries check the rest as they load, naming the pack too (`where`): a skill, a sound
	  event, a machine kind; and a value given both on an entry and in a side table a registry still
	  keeps while content moves into packs (each registry's header names its side tables).

	API
	  Content.default             the packs under Content/Packs, loaded once: what the game uses
	  Content.load(root)          the packs in any folder (specs load fixture packs)
	  Content.build(packs)        merges and checks packs already loaded ({ PackData })
	  content.blocks, .items      the merged entries, in id order (Schema's BlockSpec, ItemSpec);
	                              .entries: both, blocks first
	  content.recipes, .tags, .textures, .loot, .ores, .ages, .lore   the other kinds, merged
	  content.packs               the packs, in load order
	  content.blockId, .itemId    name -> id (items: those that are no blocks)
	  content.block(name), .item(name), .entry(name)   an entry by name, nil when there is none
	  content.where(kind, name)   "pack Base, block Stone" (kind: Schema.SINGULAR's word: "block",
	                              "item", "texture"...), for registries' messages
]]

local Define = require(script.Define)
local Schema = require(script.Schema)

type BlockSpec = Schema.BlockSpec
type ItemSpec = Schema.ItemSpec
type Entry = Schema.Entry
type Recipe = Schema.Recipe
type Texture = Schema.Texture
type Pool = Schema.Pool
type OreFeature = Schema.OreFeature
type AgeRecord = Schema.AgeRecord

-- A pack, as loaded: its folder's name, its manifest's numbers.
export type PackInfo = { name: string, order: number, description: string, requires: { string } }
-- A pack's data before merging: its name, its manifest and its kinds (kind -> data).
export type PackData = { name: string, manifest: any, kinds: { [string]: any } }

export type Content = {
	packs: { PackInfo },
	blocks: { BlockSpec },
	items: { ItemSpec },
	entries: { Entry },
	recipes: { Recipe },
	tags: { [string]: { string } },
	textures: { [string]: Texture },
	loot: { [string]: { Pool } },
	ores: { OreFeature },
	ages: { AgeRecord },
	lore: { [string]: string },
	blockId: { [string]: number },
	itemId: { [string]: number },
	block: (name: string) -> BlockSpec?,
	item: (name: string) -> ItemSpec?,
	entry: (name: string) -> Entry?,
	where: (kind: string, name: string) -> string,
}

local Content = {}

-- First id of the items that are no blocks; there are fewer blocks than this.
Content.ITEM_BASE = 4096

local SINGULAR = Schema.SINGULAR

local function fail(text: string): never
	error(`Content: {text}`, 0)
end

-- Is `value` a list (keys 1..n only)?
local function isList(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local n = #value
	for key in value do
		if type(key) ~= "number" or key < 1 or key > n or key ~= math.floor(key) then
			return false
		end
	end
	return true
end

-- " (did you mean X?)" for a name near one of `names`' keys, else "".
local function hint(name: string, names: { [string]: any }): string
	local near = Schema.suggest(name, names)
	return if near then ` (did you mean {near}?)` else ""
end

--[[
	Merges `input` (packs already loaded) into one content and checks it (see the header). Errors
	name the pack, the kind and the entry.
]]
function Content.build(input: { PackData }): Content
	-- The packs: names once, manifests, the order, what each requires.
	local named: { [string]: boolean } = {}
	for _, data in input do
		if named[data.name] then
			fail(`two packs are named {data.name}`)
		end
		named[data.name] = true
		local problem = Schema.checkManifest(data.manifest)
		if problem then
			fail(`pack {data.name}: {problem}`)
		end
	end
	local sorted = table.clone(input)
	table.sort(sorted, function(a: PackData, b: PackData): boolean
		if a.manifest.order ~= b.manifest.order then
			return a.manifest.order < b.manifest.order
		end
		return a.name < b.name
	end)
	local position: { [string]: number } = {}
	for index, data in sorted do
		position[data.name] = index
	end
	local packs: { PackInfo } = {}
	for index, data in sorted do
		local manifest = data.manifest
		for _, required in manifest.requires or {} do
			local at = position[required]
			if at == nil then
				fail(`pack {data.name} requires pack {required}, which is not there{hint(required, position)}`)
			elseif at > index then
				fail(`pack {data.name} requires pack {required}, which loads after it (give it a lower order)`)
			end
		end
		table.insert(packs, {
			name = data.name,
			order = manifest.order,
			description = manifest.description or "",
			requires = table.clone(manifest.requires or {}),
		})
	end

	local blocks: { BlockSpec } = {}
	local items: { ItemSpec } = {}
	local blockAt: { [string]: number } = {}
	local itemAt: { [string]: number } = {}
	-- Where each named thing comes from, by Schema kind: name -> the pack that made it, and the
	-- packs that patched it.
	local made: { [string]: { [string]: string } } = {}
	local patched: { [string]: { [string]: { string } } } = {}
	for kind in SINGULAR do
		made[kind] = {}
		patched[kind] = {}
	end
	local recipes: { Recipe } = {}
	-- Each recipe's pack and its place in the pack's list.
	local recipeFrom: { { pack: string, index: number } } = {}
	local tags: { [string]: { string } } = {}
	local tagHas: { [string]: { [string]: boolean } } = {}
	-- Who put each name in a tag: tag -> name -> "pack X" or "pack X, block Y".
	local tagFrom: { [string]: { [string]: string } } = {}
	local textures: { [string]: Texture } = {}
	local loot: { [string]: { Pool } } = {}
	local lore: { [string]: string } = {}
	local ores: { OreFeature } = {}
	local ages: { AgeRecord } = {}

	local function whereOf(kind: string, name: string): string
		local pack = made[kind][name]
		if pack == nil then
			return `{SINGULAR[kind]} {name}`
		end
		local by = patched[kind][name]
		local patches = if by and #by > 0 then ` (patched by {table.concat(by, ", ")})` else ""
		return `pack {pack}{patches}, {SINGULAR[kind]} {name}`
	end

	-- The kind and pack that took a block's or item's name, or nil.
	local function takenBy(name: string): string?
		if made.blocks[name] then
			return whereOf("blocks", name)
		elseif made.items[name] then
			return whereOf("items", name)
		end
		return nil
	end

	local function addToTag(tag: string, name: string, from: string)
		local list = tags[tag]
		if list == nil then
			list = {}
			tags[tag] = list
			tagHas[tag] = {}
			tagFrom[tag] = {}
		end
		if not tagHas[tag][name] then
			tagHas[tag][name] = true
			tagFrom[tag][name] = from
			table.insert(list, name)
		end
	end

	-- A block or item entry of `pack` (checked): appended, or patched onto the earlier one.
	local function mergeEntry(kind: string, pack: string, entry: any)
		local name = entry.name :: string
		local list: { any } = if kind == "blocks" then blocks else items
		local at = if kind == "blocks" then blockAt else itemAt
		local here = `pack {pack}, {SINGULAR[kind]} {name}`
		if entry.override then
			local index = at[name]
			if index == nil then
				local other = takenBy(name)
				fail(
					`{here} overrides a {SINGULAR[kind]} no earlier pack makes{if other
						then ` ({other} has the name)`
						else hint(name, at)}`
				)
			end
			local target = table.clone(list[index])
			for field, value in entry do
				if field ~= "override" and field ~= "name" then
					target[field] = value
				end
			end
			list[index] = target
			table.insert(patched[kind][name], pack)
		else
			local other = takenBy(name)
			if other then
				fail(`{here}: the name is taken by {other} (another name, or override = true to patch it)`)
			end
			table.insert(list, table.clone(entry))
			at[name] = #list
			made[kind][name] = pack
			patched[kind][name] = {}
		end
	end

	-- A named kind's entry (textures, loot, lore): once, or a texture's override.
	local function mergeNamed(kind: string, pack: string, into: { [string]: any }, name: string, value: any)
		local here = `pack {pack}, {SINGULAR[kind]} {name}`
		local before = made[kind][name]
		if kind == "textures" and value.override then
			if before == nil then
				fail(`{here} overrides a texture no earlier pack makes{hint(name, into)}`)
			end
			local target = table.clone(into[name])
			for field, v in value do
				if field ~= "override" then
					target[field] = v
				end
			end
			into[name] = target
			table.insert(patched[kind][name], pack)
			return
		end
		if before then
			fail(`{here}: pack {before} has one by that name already`)
		end
		into[name] = if type(value) == "table" then table.clone(value) else value
		made[kind][name] = pack
		patched[kind][name] = {}
	end

	for _, data in sorted do
		local pack = data.name
		for kind in data.kinds do
			if SINGULAR[kind] == nil then
				fail(`pack {pack} has a module {kind}, which is no kind{hint(kind, SINGULAR)}`)
			end
		end
		for _, kind in Schema.KINDS do
			local value = data.kinds[kind]
			if value == nil then
				continue
			end
			if Schema.LISTS[kind] then
				if not isList(value) then
					fail(`pack {pack}'s {kind} must be a list of entries`)
				end
			elseif type(value) ~= "table" or (next(value) ~= nil and isList(value)) then
				fail(`pack {pack}'s {kind} must be a table of names`)
			end
			if Schema.LISTS[kind] then
				for index, entry in value do
					local name = if type(entry) ~= "table" then nil elseif kind == "ages" then entry.id else entry.name
					local label = if type(name) == "string" then name else `#{index}`
					if kind == "recipes" then
						local result = if type(entry) == "table" then entry.result else nil
						label = `#{index}{if type(result) == "string" then ` ({result})` else ""}`
					end
					local problem = Schema.check(kind, entry)
					if problem then
						fail(`pack {pack}, {SINGULAR[kind]} {label}: {problem}`)
					end
					if kind == "blocks" or kind == "items" then
						mergeEntry(kind, pack, entry)
					elseif kind == "recipes" then
						table.insert(recipes, table.clone(entry))
						table.insert(recipeFrom, { pack = pack, index = index })
					elseif kind == "ores" then
						if made.ores[entry.name] then
							fail(
								`pack {pack}, ore feature {entry.name}: pack {made.ores[entry.name]} has one by that name`
							)
						end
						made.ores[entry.name] = pack
						patched.ores[entry.name] = {}
						table.insert(ores, table.clone(entry))
					elseif kind == "ages" then
						if made.ages[entry.id] then
							fail(`pack {pack}, Age {entry.id}: pack {made.ages[entry.id]} has an Age with that id`)
						end
						made.ages[entry.id] = pack
						patched.ages[entry.id] = {}
						table.insert(ages, table.clone(entry))
					end
				end
			else
				local names: { string } = {}
				for name in value do
					if type(name) ~= "string" then
						fail(`pack {pack}'s {kind} has a key that is no name`)
					end
					table.insert(names, name)
				end
				-- (Sorted, so a pack's tag lists and errors come out the same everywhere.)
				table.sort(names)
				for _, name in names do
					local problem = Schema.check(kind, value[name])
					if problem then
						fail(`pack {pack}, {SINGULAR[kind]} {name}: {problem}`)
					end
					if kind == "tags" then
						for _, member in value[name] do
							addToTag(name, member, `pack {pack}`)
						end
					else
						mergeNamed(
							kind,
							pack,
							if kind == "textures" then textures elseif kind == "loot" then loot else lore,
							name,
							value[name]
						)
					end
				end
			end
		end
	end

	if #blocks >= Content.ITEM_BASE then
		fail(`{#blocks} blocks: block ids must stay under ITEM_BASE ({Content.ITEM_BASE})`)
	end

	-- Ids, by place.
	local blockId: { [string]: number } = {}
	local itemId: { [string]: number } = {}
	for index, spec in blocks do
		blockId[spec.name] = index - 1
	end
	for index, spec in items do
		itemId[spec.name] = Content.ITEM_BASE + index - 1
	end
	local entries: { Entry } = table.clone(blocks) :: { any }
	for _, spec in items do
		table.insert(entries, spec)
	end

	-- Entries' own tags, after every pack's lists.
	for _, entry in entries do
		for _, tag in (entry.tags or {}) :: { string } do
			addToTag(tag, entry.name, whereOf(if blockAt[entry.name] then "blocks" else "items", entry.name))
		end
	end

	--[[ Cross-references ]]

	local names: { [string]: boolean } = {}
	for name in blockAt do
		names[name] = true
	end
	for name in itemAt do
		names[name] = true
	end
	local ageIds: { [string]: boolean } = {}
	for _, age in ages do
		ageIds[age.id] = true
	end

	-- `name` must be a block or an item ("item" in the message), a block (`blockOnly`).
	local function needName(here: string, what: string, name: string, blockOnly: boolean?)
		local known = if blockOnly then blockAt[name] ~= nil else names[name] == true
		if not known then
			local noun = if blockOnly then "block" else "item"
			fail(`{here}: {what} names unknown {noun} {name}{hint(name, if blockOnly then blockAt else names)}`)
		end
	end
	-- An ingredient: an item, or "#tag" of a known tag.
	local function needIngredient(here: string, what: string, name: string)
		if string.sub(name, 1, 1) == "#" then
			local tag = string.sub(name, 2)
			if tags[tag] == nil then
				fail(`{here}: {what} names unknown tag {name}{hint(tag, tags)}`)
			end
		else
			needName(here, what, name)
		end
	end
	local function needPools(here: string, pools: { Pool })
		for p, pool in pools do
			for e, entry in pool.entries do
				local item = entry[1]
				if item then
					needName(here, `pool {p}, entry {e}`, item)
				end
			end
		end
	end

	for _, spec in blocks do
		local here = whereOf("blocks", spec.name)
		if type(spec.drops) == "string" then
			needName(here, "drops", spec.drops)
		end
		if type(spec.shearDrops) == "string" then
			needName(here, "shearDrops", spec.shearDrops)
		end
		if spec.item then
			needName(here, "item", spec.item)
		end
		if spec.caveTwin then
			needName(here, "caveTwin", spec.caveTwin, true)
		end
		local plant = spec.plant
		if plant and plant.top then
			needName(here, "plant top", plant.top, true)
		end
		if plant and plant.bottom then
			needName(here, "plant bottom", plant.bottom, true)
		end
		if spec.toggle then
			needName(here, "toggle", spec.toggle.to, true)
		end
		if spec.texture then
			for face, texture in spec.texture :: { [string]: string } do
				if textures[texture] == nil then
					fail(`{here}: texture {face} names unknown texture "{texture}"{hint(texture, textures)}`)
				end
			end
		end
		local blockLoot = spec.loot
		if type(blockLoot) == "string" then
			if loot[blockLoot] == nil then
				fail(`{here}: loot names unknown loot table {blockLoot}{hint(blockLoot, loot)}`)
			end
		elseif blockLoot then
			needPools(here, blockLoot)
		end
	end
	for _, spec in items do
		if spec.places then
			needName(whereOf("items", spec.name), "places", spec.places, true)
		end
	end
	for _, entry in entries do
		local age = entry.age
		if age and not ageIds[age] then
			local kind = if blockAt[entry.name] then "blocks" else "items"
			fail(`{whereOf(kind, entry.name)}: age names unknown Age {age}{hint(age, ageIds)}`)
		end
		if entry.lore and made.lore[entry.name] then
			local kind = if blockAt[entry.name] then "blocks" else "items"
			fail(`{whereOf(kind, entry.name)}: its lore is pack {made.lore[entry.name]}'s lore too`)
		end
	end
	for index, recipe in recipes do
		local from = recipeFrom[index]
		local here = `pack {from.pack}, recipe #{from.index} ({recipe.result})`
		needName(here, "result", recipe.result)
		for _, name in (recipe.ingredients or {}) :: { string } do
			needIngredient(here, "ingredients", name)
		end
		for char, name in (recipe.key or {}) :: { [string]: string } do
			needIngredient(here, `key {char}`, name)
		end
		if recipe.input then
			needIngredient(here, "input", recipe.input)
		end
	end
	for tag, members in tags do
		for _, name in members do
			if not names[name] then
				fail(`{tagFrom[tag][name]}: tag {tag} names unknown item {name}{hint(name, names)}`)
			end
		end
	end
	for name, pools in loot do
		needPools(whereOf("loot", name), pools)
	end
	for name, texture in textures do
		if type(texture.Tint) == "string" then
			needName(whereOf("textures", name), "Tint", texture.Tint, true)
		end
	end
	for _, ore in ores do
		needName(whereOf("ores", ore.name), "block", ore.block, true)
	end
	for _, age in ages do
		for _, milestone in age.milestones do
			local key = milestone.key
			if key and (milestone.category == "craft" or milestone.category == "smelt") then
				needName(whereOf("ages", age.id), `milestone {milestone.category}`, key)
			elseif key and milestone.category == "mine" then
				needName(whereOf("ages", age.id), "milestone mine", key, true)
			end
		end
	end
	for name in lore do
		needName(whereOf("lore", name), "lore", name)
	end

	local content = {
		packs = packs,
		blocks = blocks,
		items = items,
		entries = entries,
		recipes = recipes,
		tags = tags,
		textures = textures,
		loot = loot,
		ores = ores,
		ages = ages,
		lore = lore,
		blockId = blockId,
		itemId = itemId,
	} :: Content
	function content.block(name: string): BlockSpec?
		local index = blockAt[name]
		return if index then blocks[index] else nil
	end
	function content.item(name: string): ItemSpec?
		local index = itemAt[name]
		return if index then items[index] else nil
	end
	function content.entry(name: string): Entry?
		return content.block(name) or content.item(name)
	end
	-- `kind`: Schema.SINGULAR's word ("block", "item", "texture", "loot table"...) or the kind.
	local kindOfWord: { [string]: string } = {}
	for kind, word in SINGULAR do
		kindOfWord[word] = kind
		kindOfWord[kind] = kind
	end
	function content.where(kind: string, name: string): string
		local plural = kindOfWord[kind]
		return if plural then whereOf(plural, name) else `{kind} {name}`
	end
	return content
end

local function sortedChildren(folder: Instance): { Instance }
	local children = folder:GetChildren()
	table.sort(children, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)
	return children
end

-- A pack module's data: its value, or what its function makes with Content/Define.
local function loadModule(module: Instance): any
	local data = (require :: any)(module)
	if type(data) == "function" then
		data = data(Define)
	end
	return data
end

--[[
	The packs in `root` (a folder of pack folders), loaded and merged (`build`). A pack folder holds
	its `pack` manifest and its kind modules (Luau or JSON); modules named "_..." are its own
	helpers, left alone.
]]
function Content.load(root: Instance): Content
	local packs: { PackData } = {}
	for _, folder in sortedChildren(root) do
		if not folder:IsA("Folder") then
			fail(`{root.Name}/{folder.Name} is no pack folder`)
		end
		local manifest: any = nil
		local kinds: { [string]: any } = {}
		for _, module in sortedChildren(folder) do
			local name = module.Name
			if string.sub(name, 1, 1) == "_" then
				continue
			end
			if not module:IsA("ModuleScript") then
				fail(`pack {folder.Name} has {name}, which is no module (a helper's name starts with "_")`)
			elseif name == "pack" then
				manifest = loadModule(module)
			elseif SINGULAR[name] then
				kinds[name] = loadModule(module)
			else
				fail(
					`pack {folder.Name} has a module {name}, which is no kind{hint(name, SINGULAR)} (a helper's name starts with "_")`
				)
			end
		end
		if manifest == nil then
			fail(`pack {folder.Name} has no manifest (a module named pack)`)
		end
		table.insert(packs, { name = folder.Name, manifest = manifest, kinds = kinds })
	end
	return Content.build(packs)
end

-- The game's packs (Content/Packs), loaded once.
Content.default = Content.load(script.Packs)

return Content
