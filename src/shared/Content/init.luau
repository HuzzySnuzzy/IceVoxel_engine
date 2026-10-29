--!strict
--[[
	Content packs (Minecraft's data packs): every block, item, recipe, tag, texture, loot table, ore
	feature, Age, lore line, fuel tag, biome, status effect, potion, structure template, template
	pool, generated structure, sound event and music track of the game comes from a pack, a folder
	under Content/Packs, and every value about an entry is on the entry. The registries (Blocks,
	Items, TexturePack, Crafting, Progression, the Metal Miner, Radiation, generation, biomes, loot,
	sounds and music, Tough As Nails, Effects, PotionList and the structure library) build
	themselves from what this module loads; adding content is adding entries to a pack, or a pack.

	A pack
	  A folder holding `pack`, its manifest ({ order = n, description = "...", requires = { pack
	  names }? }), and any of the kinds Content/Schema lists (blocks, items, recipes, tags, textures,
	  loot, ores, ages, skills, lore, fuel, biomes, effects, potions, templates, pools, structures,
	  sounds, music), each a module of the kind's name: a Luau module returning its data, or
	  `function(define) -> data` (define: Content/Define, the shared helpers and Config, for packs
	  that build entries or read switches), or a `.json` file holding it (Rojo makes a JSON file a
	  ModuleScript returning its table, and so does the Lune loader). Any other module in a pack is
	  an error (a misspelt kind would be ignored otherwise) unless its name starts with "_": the
	  pack's own helpers, which its kind modules require (at the pack's top only). A module must
	  give its data: nil (a function that forgets `return list`) is an error naming the pack and
	  the kind.
	  A pack is read as Rojo builds it, the same in Roblox and in Lune (tests/lib/Loader follows
	  Rojo's rules), and what Rojo would make of a file that is no pack data is an error: a name
	  with a dot (`ores.old.luau`, Rojo's module "ores.old"), anything but a module or a folder (a
	  `.txt` file's StringValue), a name twice (`blocks.luau` beside `blocks.json`, or beside a
	  `blocks` folder: Rojo keeps both, and which one a script finds by the name is not said, so
	  a client and the server could load different ones) and a module with modules in it (a folder
	  holding an `init.luau`, whose other files would never load).

	Kind folders
	  A kind may also be a folder of the kind's name (`Minecraft/blocks/`), as Minecraft's data
	  packs keep one file per recipe or loot table: each module in it (Luau, a function of define,
	  or JSON, as above) holds some of that kind's data, and they merge in their names' order,
	  folders inside it in their place among them (`blocks/plants/flowers` after `blocks/ores`).
	  So a big pack splits into files (`blocks/terrain`, `blocks/plants`...), and adding content
	  may be adding a file. A list kind's files are appended to each other; a named kind's
	  (textures, loot, lore, fuel, templates, pools) may not name one thing twice, and tags join as
	  across packs. Messages name the file: "pack Minecraft, blocks/plants, block Poppy". A pack has
	  a kind as a module or as a folder, not both; a kind folder holds only modules and folders (no
	  "_" helpers, and no `init.luau`: its files merge by their names).

	Order and ids
	  Packs load sorted by (`order`, name), and a pack's entries keep their order. A block's id is
	  its place among every pack's blocks, minus one (Core's Air 0 and Cave Air 1 come first: order
	  0); an item's is ITEM_BASE + its place among every pack's items, minus one (every placeable
	  block is an item too, with its block's id: Shared/Items). Ids are dense and given here at
	  load, the same on every machine, so packs may add, remove and reorder content (saves are to
	  keep names, not ids); fewer than ITEM_BASE blocks. An effect's id is its place among every
	  pack's effects (from 1; sent as a u8, so MAX_EFFECTS at most). A pack's `requires` must load
	  before it (a lower order, or the same and an earlier name); it orders packs, while the names
	  an entry gives may be any pack's.

	Merging
	  blocks, items  by name: an entry with `override = true` patches the entry of that name an
	                 earlier pack made ({ name = "Stone", override = true, hardness = 2 }:
	                 Minecraft's data pack override), as every override does (Schema.patch):
	                   * each field it gives replaces the entry's;
	                   * but a table of fields is patched the same way, key by key: a record (a
	                     block's `texture` faces, an item's `food`) or a map of names (a block's
	                     `sounds`), so { name = "Grass", override = true, texture = { Top = "..."
	                     } } keeps Grass's Sides and Bottom;
	                   * and its `tags` add to the entry's (a union);
	                   * a list (`shape`, `model`, `color`) replaces the entry's whole, and nothing
	                     takes a field away.
	                 The patched entry is checked whole again. Without `override` a name already
	                 taken, by a block or an item, is an error naming both packs, and so is an
	                 override of nothing.
	  textures       by name, the same way (an override patches the texture's fields).
	  biomes         by name, the same way, keeping their place: weather, patches, foliage and its
	                 flowers and herbs are patched key by key, bands, features, plants and species
	                 replaced whole (Schema's BIOME_FIELDS), tags added; the patched biome is
	                 checked whole again.
	  skills         by id, the same way ({ id = "forager", override = true, cost = 2 }); a node's
	                 place among every pack's nodes is its position, sent as a u8
	                 (Progression/Skills).
	  sounds, music  by name, the same way, keeping their place (a sound's number is its place:
	                 Shared/Sounds); each kind's names its own (a track and an event may share
	                 one).
	  tags           a union: each pack's lists in load order, then every entry's `tags`, each
	                 name once.
	  recipes        by name, in load order: a recipe's name is its `name`, else its result's
	                 ("Torch", as Minecraft's recipe ids), and a name taken twice is an error
	                 naming both (a second recipe for a result gives a name of its own:
	                 "IronIngotFromRawIron"). A recipe with `override = true` replaces the earlier
	                 recipe of its name whole, in its place (so the recipes' order, JEI's with
	                 it, stays), and { name = "Torch", remove = true } takes it away; either of a
	                 name no earlier pack gave is an error. Crafting takes the first recipe that
	                 fits a grid (Crafting) and smelting the first for an input
	                 (Crafting/Smelting), so a later pack's new recipe for the same grid or input
	                 never replaces an earlier one: it is never made, which `tests/content check`
	                 warns of (and tests/spec/CraftingGrids fails on); an override replaces it.
	  ores, ages     appended in load order (an ore feature's name and an Age's id each once).
	  loot, lore     by name, each once; so is fuel (by tag: every item in the tag burns that
	                 long, unless its entry gives its own `fuel`, Crafting/Recipes), and so are
	                 structure templates.
	  pools, structures  by name, as textures and blocks are: a template pool (a structure) with
	                 `override = true` patches the earlier one's fields, a list field (a pool's
	                 `elements`, a structure's `biomes`) replaced whole as any override's is;
	                 structures keep their load order.
	  effects, potions  by name, as blocks and items are (each kind's names its own: the potion
	                 Strength gives the effect Strength). Once every pack has merged, each potion
	                 is brewed (Content/Define's `brew`: Minecraft's brewing in a grid) from its
	                 final fields and its effect's colour into its items (each with its `drink`)
	                 and their recipes (each its item's name, PotionOfSwiftness, as any recipe's
	                 result), which go after its pack's own items and recipes ("pack
	                 Minecraft, potion Swiftness, item PotionOfSwiftness"); so a pack patches a
	                 potion's items by patching the potion (its lore, icon, Age...), as they are
	                 made after every pack's items.

	Checks, as packs load (each message names the pack, the kind and the entry):
	  * the manifest and every entry against Content/Schema: unknown fields (with "did you mean"),
	    wrong types, missing fields, a name outside a closed set the Schema gives (with "did you
	    mean": a block's `tool`, `menu`, `material` and `behaviour`, an item's `tool.kind`, an
	    Age's milestones' `category`...), a loot pool's rolls (its fewest above its most);
	  * names taken twice (a recipe's: with a name to give it), overrides of nothing (a recipe's
	    removal too, with "did you mean"), a `requires` that does not load first;
	  * every cross-reference: the names recipes, tags and loot tables give (items or blocks), the
	    tags recipes and fuel name, `drops`, `shearDrops`, `item`, `places`, `caveTwin`, a plant's
	    other half, a toggle's `to`, a block's loot table, a fluid block's `fluid.group` (one of
	    Fluids/FluidList's), an ore feature's block, the Ages entries name (`age`), the textures
	    blocks name (`texture`) and the blocks textures are tinted like, the Ages' milestones (a
	    key or a count, each; a key an item, a block, a biome or an Age, as its category says: a
	    mob's is Progression/Ages' to check), every lore line's item, a lore line both on an entry
	    and in a pack's `lore`, the blocks a biome names (its ground, and its plants: single plants
	    or lower halves), and a potion's effect, its ingredient and its variants
	    (Schema.checkVariants: an instant effect's potion has no seconds and no long variant...);
	    a template's text (IVS1 that reads, under the name it holds) and its palette's blocks, the
	    templates pools' elements give, pools' fallbacks and structures' start pools (each a pool,
	    a template, or the templates named under it: Structures/Library's lookup), and a
	    structure's biomes (by their exact names, at least one); the sound events entries name (a
	    block's `sounds`, `workSound` and toggle's `sound`, an item's `equipSound` and food's
	    `sound`); an explosive's `lit` block (one with a `fuse`), an empty container's `fills` and
	    dirty water's `purified` (its drink's); an entry's former names (`formerly`: each
	    claimed once, none a name an entry has now);
	  * the skills: each node's Age and icon, its `requires` (known nodes, of its Age or an earlier
	    one, never in a loop), one node to an Age's row, and every entry's `skill`.
	  The registries check what only they know of an entry's value as they load, naming the pack
	  too (`where`): a skill's row, icon item and perk numbers, a block's sound action, its sound
	  type and a texture's Material (Blocks), an item's icon (Items), a recipe's key and `keep`
	  (Crafting), a sound event's numbers and limit, a machine kind, the miner's numbers, a
	  radiation or shielding number, a fuel's ticks, an ore feature's heights (Generation/Ores), a
	  mob a milestone names (Progression/Ages), a biome's bands (Biomes) and tree builders
	  (Generation/Structures), two effects /effect would find by one word (Effects), a structure's
	  numbers, start jigsaw and its templates' jigsaws and chests (Structures/Library).

	API
	  Content.default             the packs under Content/Packs, loaded once: what the game uses
	  Content.load(root)          the packs in any folder (specs load fixture packs)
	  Content.build(packs)        merges and checks packs already loaded ({ PackData })
	  content.blocks, .items      the merged entries, in id order (Schema's BlockSpec, ItemSpec);
	                              .entries: both, blocks first
	  content.recipes, .tags, .textures, .loot, .ores, .ages, .skills, .lore, .fuel
	                              the other kinds, merged
	  content.biomes              the merged biomes, in load order (Schema's BiomeSpec; a biome's
	                              place is its index in Shared/Biomes)
	  content.effects, .potions   the effects in id order, the potions in load order (their items
	                              and recipes are among .items and .recipes)
	  content.templates, .pools   template name -> IVS1 text, pool name -> pool
	  content.structures          the structures, in load order
	  content.sounds, .music      the sound events and the tracks, in load order (Schema's
	                              SoundSpec, TrackSpec; Shared/Sounds and Sounds/MusicList)
	  content.packs               the packs, in load order
	  content.blockId, .itemId    name -> id (items: those that are no blocks)
	  content.effectId            name -> effect id (Shared/Effects')
	  content.block(name), .item(name), .entry(name), .biome(name)
	                              an entry by name, nil when there is none
	  content.where(kind, name)   "pack Minecraft, blocks/terrain, block Stone" (kind: Schema
	                              .SINGULAR's word: "block", "item", "texture"..., or the kind;
	                              the file only for a kind folder's; the overrides' packs too,
	                              "(patched by Patch's blocks/stone)"), for registries' messages;
	                              a recipe's by its name or its place in content.recipes ("pack
	                              Minecraft, recipes/tools, recipe #3 (WoodenPickaxe)": its place
	                              in its file, and its name)
	  content.origin(kind, name)  the same as data (Origin, nil when nothing has the name): the
	                              pack that made it, its kind folder's file (nil: the kind's
	                              module), the packs that patched it in load order (`patched`)
	                              and each override's pack and file (`overrides`). A tag's: the
	                              first pack putting names in it, then (`patched`) the packs adding
	                              to it, an override's `tags` its pack's. A recipe's (`name`: its
	                              name, or its place in content.recipes): its pack, file and
	                              `index`, its place in that file's list, and the overrides that
	                              replaced it. A potion's brewed items and recipes: patched by the
	                              packs that patched the potion.
]]

local Define = require(script.Define)
local FluidList = require(script.Parent.Fluids.FluidList)
local Schema = require(script.Schema)
local TemplateText = require(script.Parent.Structures.TemplateText)

type BlockSpec = Schema.BlockSpec
type ItemSpec = Schema.ItemSpec
type Entry = Schema.Entry
type Recipe = Schema.Recipe
type Texture = Schema.Texture
type Pool = Schema.Pool
type OreFeature = Schema.OreFeature
type AgeRecord = Schema.AgeRecord
type BiomeSpec = Schema.BiomeSpec
type EffectSpec = Schema.EffectSpec
type PotionSpec = Schema.PotionSpec
type SkillRecord = Schema.SkillRecord
type TemplatePool = Schema.TemplatePool
type StructureSpec = Schema.StructureSpec
type SoundSpec = Schema.SoundSpec
type TrackSpec = Schema.TrackSpec

-- A pack, as loaded: its folder's name, its manifest's numbers.
export type PackInfo = { name: string, order: number, description: string, requires: { string } }
-- One module of a kind folder: its path in the pack ("blocks/plants") and its data.
export type PackFile = { file: string, data: any }
-- A pack's data before merging: its name, its manifest, its kinds' modules (kind -> data) and its
-- kind folders (kind -> their modules, in order).
export type PackData = {
	name: string,
	manifest: any,
	kinds: { [string]: any },
	folders: { [string]: { PackFile } }?,
}

-- An override: its pack and the kind folder's file it is in (nil: the kind's module).
export type Patch = { pack: string, file: string? }
-- Where something came from (`origin`): the pack that made it and the kind folder's file it is in
-- (nil: the kind's module), the packs that patched it in load order (`overrides`: each one's pack
-- and file); a recipe's place in its file's list (`index`).
export type Origin = { pack: string, file: string?, patched: { string }, overrides: { Patch }, index: number? }
-- A recipe entry as its pack gives it (checked), in load order: its pack and kind folder's file,
-- its place in that file's list, and the overrides of what made it (a brewed recipe's potion's).
type RecipeStep = { entry: any, pack: string, file: string?, index: number, patched: { Patch }? }
-- Where a merged recipe is from: the pack and file that made it, its place in that file's list,
-- and the overrides that replaced it since, in load order (a brewed recipe's: its potion's first).
type RecipeFrom = { pack: string, file: string?, index: number, overrides: { Patch } }

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
	skills: { SkillRecord },
	lore: { [string]: string },
	fuel: { [string]: number },
	biomes: { BiomeSpec },
	effects: { EffectSpec },
	potions: { PotionSpec },
	templates: { [string]: string },
	pools: { [string]: TemplatePool },
	structures: { StructureSpec },
	sounds: { SoundSpec },
	music: { TrackSpec },
	blockId: { [string]: number },
	itemId: { [string]: number },
	effectId: { [string]: number },
	block: (name: string) -> BlockSpec?,
	item: (name: string) -> ItemSpec?,
	entry: (name: string) -> Entry?,
	biome: (name: string) -> BiomeSpec?,
	where: (kind: string, name: string | number) -> string,
	origin: (kind: string, name: string | number) -> Origin?,
}

local Content = {}

-- First id of the items that are no blocks; there are fewer blocks than this.
Content.ITEM_BASE = 4096
-- The most effects there may be: an effect's id (from 1) goes over the wire as a u8.
Content.MAX_EFFECTS = 255

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
	-- (The kind folder's file it is in, for a kind folder's.)
	local madeIn: { [string]: { [string]: string? } } = {}
	local patched: { [string]: { [string]: { string } } } = {}
	-- (Each override's pack and file, in the same order.)
	local overrides: { [string]: { [string]: { Patch } } } = {}
	for kind in SINGULAR do
		made[kind] = {}
		madeIn[kind] = {}
		patched[kind] = {}
		overrides[kind] = {}
	end
	-- A block's or an item's own tags and the pack (and file) that gave each: its maker's, or an
	-- override's that added it (kind -> name -> tag -> where).
	local tagsBy: { [string]: { [string]: { [string]: Patch } } } = { blocks = {}, items = {} }
	-- The recipes, merged by name once every pack's are in (`recipeSteps`, each pack's potions'
	-- after its own): each one's origin, and name -> its place.
	local recipes: { Recipe } = {}
	local recipeFrom: { RecipeFrom } = {}
	local recipeAt: { [string]: number } = {}
	-- Each pack's recipe entries, in order.
	local recipeSteps: { [string]: { RecipeStep } } = {}
	local tags: { [string]: { string } } = {}
	local tagHas: { [string]: { [string]: boolean } } = {}
	-- Who put each name in a tag: tag -> name -> "pack X" or "pack X, block Y".
	local tagFrom: { [string]: { [string]: string } } = {}
	-- The packs that put names in each tag: tag -> pack -> the file it first did so from (none: the
	-- kind's module).
	local tagPacks: { [string]: { [string]: { file: string? } } } = {}
	local textures: { [string]: Texture } = {}
	local loot: { [string]: { Pool } } = {}
	local lore: { [string]: string } = {}
	local fuel: { [string]: number } = {}
	local ores: { OreFeature } = {}
	local ages: { AgeRecord } = {}
	local biomes: { BiomeSpec } = {}
	-- Biome name -> its place in `biomes` (content.biome; what a check of the biomes another kind
	-- names looks up).
	local biomeAt: { [string]: number } = {}
	local effects: { EffectSpec } = {}
	local potions: { PotionSpec } = {}
	local templates: { [string]: string } = {}
	local templatePools: { [string]: TemplatePool } = {}
	local structures: { StructureSpec } = {}
	local sounds: { SoundSpec } = {}
	local music: { TrackSpec } = {}
	-- The kinds merged by name (`mergeEntry`): each one's entries, and name -> place among them.
	local lists: { [string]: { any } } = {
		blocks = blocks,
		items = items,
		effects = effects,
		potions = potions,
		structures = structures,
		sounds = sounds,
		music = music,
	}
	local places: { [string]: { [string]: number } } =
		{ blocks = blockAt, items = itemAt, effects = {}, potions = {}, structures = {}, sounds = {}, music = {} }
	-- Where each pack's own items end (its potions' go after them).
	local ends: { [string]: number } = {}
	local skills: { SkillRecord } = {}
	-- Skill id -> its place in `skills`.
	local skillAt: { [string]: number } = {}

	local function whereOf(kind: string, name: string): string
		local pack = made[kind][name]
		if pack == nil then
			return `{SINGULAR[kind]} {name}`
		end
		-- (Each override's pack, and its file when it is a kind folder's: "Patch's blocks/stone".)
		local by: { string } = {}
		for _, patch in (overrides[kind][name] or {}) :: { Patch } do
			table.insert(by, if patch.file then `{patch.pack}'s {patch.file}` else patch.pack)
		end
		local patches = if #by > 0 then ` (patched by {table.concat(by, ", ")})` else ""
		local file = madeIn[kind][name]
		return `pack {pack}{patches}{if file then `, {file}` else ""}, {SINGULAR[kind]} {name}`
	end

	-- `name` of `kind` made by `pack` (`file`: its kind folder's), or patched by it.
	local function madeBy(kind: string, name: string, pack: string, file: string?)
		made[kind][name] = pack
		madeIn[kind][name] = file
		patched[kind][name] = {}
		overrides[kind][name] = {}
	end
	local function patchedBy(kind: string, name: string, pack: string, file: string?)
		table.insert(patched[kind][name], pack)
		table.insert(overrides[kind][name], { pack = pack, file = file })
	end

	-- "pack P", or "pack P, blocks/plants" for a kind folder's file: where a module's data is.
	local function placeOf(pack: string, file: string?): string
		return if file then `pack {pack}, {file}` else `pack {pack}`
	end

	-- The kind and pack that took a name of `kind`'s, or nil: blocks and items share their names,
	-- effects, potions, structures, sounds and tracks have names of their own.
	local function takenBy(kind: string, name: string): string?
		if kind == "effects" or kind == "potions" or kind == "structures" or kind == "sounds" or kind == "music" then
			return if made[kind][name] then whereOf(kind, name) else nil
		elseif made.blocks[name] then
			return whereOf("blocks", name)
		elseif made.items[name] then
			return whereOf("items", name)
		end
		return nil
	end

	local function addToTag(tag: string, name: string, from: string, pack: string, file: string?)
		local list = tags[tag]
		if list == nil then
			list = {}
			tags[tag] = list
			tagHas[tag] = {}
			tagFrom[tag] = {}
			tagPacks[tag] = {}
		end
		if tagPacks[tag][pack] == nil then
			tagPacks[tag][pack] = { file = file }
		end
		if not tagHas[tag][name] then
			tagHas[tag][name] = true
			tagFrom[tag][name] = from
			table.insert(list, name)
		end
	end

	-- An override of `kind` (`entry`, at `here`) merged onto the entry it patches (`base`:
	-- Schema.patch), and the patched entry checked whole (the override's own check needs none of
	-- a table's fields).
	local function patchOnto(kind: string, base: any, entry: any, here: string): any
		local target = Schema.patch(kind, base, entry)
		local problem = Schema.check(kind, target)
		if problem then
			fail(`{here}: once patched, {problem}`)
		end
		return target
	end

	-- A block's or an item's `tags` (`entry`'s) given by `pack` (`file`), each it has not yet.
	local function tagsOf(kind: string, entry: any, pack: string, file: string?)
		local by = tagsBy[kind]
		if by == nil then
			return
		end
		local own = by[entry.name] or {}
		by[entry.name] = own
		for _, tag in (entry.tags or {}) :: { string } do
			own[tag] = own[tag] or { pack = pack, file = file }
		end
	end

	-- An entry of a kind merged by name (`lists`: a block, an item, an effect, a potion, a
	-- structure, a sound, a track) of `pack` (checked; `file`: its kind folder's file): appended,
	-- or patched onto the earlier one.
	local function mergeEntry(kind: string, pack: string, file: string?, entry: any)
		local name = entry.name :: string
		local list = lists[kind]
		local at = places[kind]
		local here = `{placeOf(pack, file)}, {SINGULAR[kind]} {name}`
		if entry.override then
			local index = at[name]
			if index == nil then
				local other = takenBy(kind, name)
				fail(
					`{here} overrides {if kind == "effects" then "an" else "a"} {SINGULAR[kind]} no earlier pack makes{if other
						then ` ({other} has the name)`
						else hint(name, at)}`
				)
			end
			list[index] = patchOnto(kind, list[index], entry, here)
			patchedBy(kind, name, pack, file)
			tagsOf(kind, entry, pack, file)
		else
			local other = takenBy(kind, name)
			if other then
				fail(`{here}: the name is taken by {other} (another name, or override = true to patch it)`)
			end
			table.insert(list, table.clone(entry))
			at[name] = #list
			madeBy(kind, name, pack, file)
			tagsOf(kind, entry, pack, file)
		end
	end

	-- A named kind's entry (textures, loot, lore, fuel, templates, pools): once, or a texture's or
	-- a pool's override.
	local function mergeNamed(
		kind: string,
		pack: string,
		file: string?,
		into: { [string]: any },
		name: string,
		value: any
	)
		local here = `{placeOf(pack, file)}, {SINGULAR[kind]} {name}`
		local before = made[kind][name]
		if (kind == "textures" or kind == "pools") and value.override then
			if before == nil then
				fail(`{here} overrides a {SINGULAR[kind]} no earlier pack makes{hint(name, into)}`)
			end
			into[name] = patchOnto(kind, into[name], value, here)
			patchedBy(kind, name, pack, file)
			return
		end
		if before then
			fail(`{here}: {placeOf(before, madeIn[kind][name])} has one by that name already`)
		end
		into[name] = if type(value) == "table" then table.clone(value) else value
		madeBy(kind, name, pack, file)
	end

	-- A biome of `pack` (checked): appended, or patched onto the earlier one (Schema.patch; checked
	-- whole with the cross-references).
	local function mergeBiome(pack: string, file: string?, entry: any)
		local name = entry.name :: string
		local here = `{placeOf(pack, file)}, biome {name}`
		local index = biomeAt[name]
		if entry.override then
			if index == nil then
				fail(`{here} overrides a biome no earlier pack makes{hint(name, biomeAt)}`)
			end
			biomes[index] = Schema.patch("biomes", biomes[index], entry) :: any
			patchedBy("biomes", name, pack, file)
		elseif index then
			fail(
				`{here}: the name is taken by {whereOf("biomes", name)} (another name, or override = true to patch it)`
			)
		else
			table.insert(biomes, table.clone(entry))
			biomeAt[name] = #biomes
			madeBy("biomes", name, pack, file)
		end
	end

	-- A skill of `pack` (checked): appended, or patched onto the earlier one of its id.
	local function mergeSkill(pack: string, file: string?, entry: any)
		local id = entry.id :: string
		local here = `{placeOf(pack, file)}, skill {id}`
		if entry.override then
			local index = skillAt[id]
			if index == nil then
				fail(`{here} overrides a skill no earlier pack makes{hint(id, skillAt)}`)
			end
			skills[index] = patchOnto("skills", skills[index], entry, here)
			patchedBy("skills", id, pack, file)
		elseif skillAt[id] then
			fail(`{here}: the id is taken by {whereOf("skills", id)} (another id, or override = true to patch it)`)
		else
			table.insert(skills, table.clone(entry))
			skillAt[id] = #skills
			madeBy("skills", id, pack, file)
		end
	end

	for _, data in sorted do
		local pack = data.name
		recipeSteps[pack] = {}
		local folders: { [string]: { PackFile } } = data.folders or {}
		for kind in data.kinds do
			if SINGULAR[kind] == nil then
				fail(`pack {pack} has a module {kind}, which is no kind{hint(kind, SINGULAR)}`)
			end
		end
		for kind in folders do
			if SINGULAR[kind] == nil then
				fail(`pack {pack} has a folder {kind}, which is no kind{hint(kind, SINGULAR)}`)
			elseif data.kinds[kind] ~= nil then
				fail(`pack {pack} has its {kind} both as a module and as a folder`)
			end
		end
		for _, kind in Schema.KINDS do
			-- The kind's module, or its kind folder's modules in order.
			local parts: { { file: string?, data: any } }? = if data.kinds[kind] ~= nil
				then { { data = data.kinds[kind] } }
				else folders[kind]
			if parts == nil then
				continue
			end
			for _, part in parts do
				local value, file = part.data, part.file
				local place = placeOf(pack, file)
				-- (The whole module: "pack P's blocks", or "pack P, blocks/plants".)
				local whole = if file then place else `pack {pack}'s {kind}`
				if Schema.LISTS[kind] then
					if not isList(value) then
						fail(`{whole} must be a list of entries`)
					end
				elseif type(value) ~= "table" or (next(value) ~= nil and isList(value)) then
					fail(`{whole} must be a table of names`)
				end
				if Schema.LISTS[kind] then
					for index, entry in value do
						local name = if type(entry) ~= "table"
							then nil
							elseif kind == "ages" or kind == "skills" then entry.id
							else entry.name
						local label = if type(name) == "string" then name else `#{index}`
						if kind == "recipes" then
							-- (Its place in the list, and its name: its own, or its result's.)
							local called = if type(entry) ~= "table"
								then nil
								elseif type(entry.name) == "string" then entry.name
								else entry.result
							label = `#{index}{if type(called) == "string" then ` ({called})` else ""}`
						end
						local problem = Schema.check(kind, entry)
						if problem then
							fail(`{place}, {SINGULAR[kind]} {label}: {problem}`)
						end
						if places[kind] then
							mergeEntry(kind, pack, file, entry)
						elseif kind == "biomes" then
							mergeBiome(pack, file, entry)
						elseif kind == "recipes" then
							table.insert(recipeSteps[pack], { entry = entry, pack = pack, file = file, index = index })
						elseif kind == "ores" then
							local before = made.ores[entry.name]
							if before then
								fail(
									`{place}, ore feature {entry.name}: {placeOf(before, madeIn.ores[entry.name])} has one by that name`
								)
							end
							madeBy("ores", entry.name, pack, file)
							table.insert(ores, table.clone(entry))
						elseif kind == "ages" then
							local before = made.ages[entry.id]
							if before then
								fail(
									`{place}, Age {entry.id}: {placeOf(before, madeIn.ages[entry.id])} has an Age with that id`
								)
							end
							madeBy("ages", entry.id, pack, file)
							table.insert(ages, table.clone(entry))
						elseif kind == "skills" then
							mergeSkill(pack, file, entry)
						end
					end
				else
					local names: { string } = {}
					for name in value do
						if type(name) ~= "string" then
							fail(`{whole} has a key that is no name`)
						end
						table.insert(names, name)
					end
					-- (Sorted, so a pack's tag lists and errors come out the same everywhere.)
					table.sort(names)
					for _, name in names do
						local problem = Schema.check(kind, value[name])
						if problem then
							fail(`{place}, {SINGULAR[kind]} {name}: {problem}`)
						end
						if kind == "tags" then
							for _, member in value[name] do
								addToTag(name, member, place, pack, file)
							end
						else
							local into: { [string]: any } = if kind == "textures"
								then textures
								elseif kind == "loot" then loot
								elseif kind == "fuel" then fuel
								elseif kind == "templates" then templates
								elseif kind == "pools" then templatePools
								else lore
							mergeNamed(kind, pack, file, into, name, value[name])
						end
					end
				end
			end
		end
		ends[pack] = #items
	end

	if #blocks >= Content.ITEM_BASE then
		fail(`{#blocks} blocks: block ids must stay under ITEM_BASE ({Content.ITEM_BASE})`)
	end
	if #effects > Content.MAX_EFFECTS then
		fail(
			`{#effects} effects: effect ids must fit a u8 (Protocol's Effects), MAX_EFFECTS ({Content.MAX_EFFECTS}) at most`
		)
	end

	--[[ Potions: each brewed into its items and their recipes, after its pack's own ]]

	local effectAt = places.effects
	-- Each pack's potions' items (their recipes go after the pack's own, `recipeSteps`).
	local brewed: { [string]: { ItemSpec } } = {}
	for _, potion in potions do
		local here = whereOf("potions", potion.name)
		local at = effectAt[potion.effect]
		if at == nil then
			fail(`{here}: effect names unknown effect {potion.effect}{hint(potion.effect, effectAt)}`)
		end
		local effect = effects[at]
		local problem = Schema.checkVariants(potion, effect.instant ~= nil)
		if problem then
			fail(`{here}: {problem}`)
		end
		local pack = made.potions[potion.name]
		-- (Its items and recipes are its own file's, as messages and `origin` name them.)
		local file = `potion {potion.name}`
		local into = brewed[pack] or {}
		brewed[pack] = into
		local brew = Define.brew(potion, effect.color)
		for _, spec in brew.items do
			local other = takenBy("items", spec.name)
			if other then
				fail(
					`{placeOf(pack, file)}, item {spec.name}: the name is taken by {other} (rename the potion or the item)`
				)
			end
			-- (Patched by the packs that patched the potion: what it is brewed from.)
			madeBy("items", spec.name, pack, file)
			for _, patch in overrides.potions[potion.name] do
				patchedBy("items", spec.name, patch.pack, patch.file)
			end
			table.insert(into, spec)
		end
		-- (Each named by its item, as any recipe its result, after its pack's own.)
		for index, recipe in brew.recipes do
			table.insert(
				recipeSteps[pack],
				{ entry = recipe, pack = pack, file = file, index = index, patched = overrides.potions[potion.name] }
			)
		end
	end
	-- (The items put back in pack order, each pack's potions' after its own.)
	if next(brewed) then
		local ownItems = table.clone(items)
		table.clear(items)
		local item = 0
		for _, info in packs do
			local mark = ends[info.name]
			table.move(ownItems, item + 1, mark, #items + 1, items)
			item = mark
			local more = brewed[info.name]
			if more then
				table.move(more, 1, #more, #items + 1, items)
			end
		end
		for index, spec in items do
			itemAt[spec.name] = index
		end
	end

	--[[ Recipes: by name, in load order (each pack's potions' after its own) ]]

	-- Where recipe `at` is from, as messages name it: "pack Minecraft, recipes/tools, recipe #3
	-- (WoodenPickaxe)", its place in its file and its name, the overrides that replaced it as
	-- whereOf names a block's ("(patched by Patch's recipes/torch)").
	local function recipeWhere(at: number): string
		local from = recipeFrom[at]
		local by: { string } = {}
		for _, patch in from.overrides do
			table.insert(by, if patch.file then `{patch.pack}'s {patch.file}` else patch.pack)
		end
		local patches = if #by > 0 then ` (patched by {table.concat(by, ", ")})` else ""
		local file = if from.file then `, {from.file}` else ""
		return `pack {from.pack}{patches}{file}, recipe #{from.index} ({recipes[at].name})`
	end
	-- The ingredients a recipe names, in its order (a shaped one's by its pattern), each once.
	local function ingredientsOf(recipe: any): { string }
		local list: { string } = {}
		local function add(name: any)
			if type(name) == "string" and not table.find(list, name) then
				table.insert(list, name)
			end
		end
		for _, row in (recipe.pattern or {}) :: { string } do
			for x = 1, #row do
				add((recipe.key or {})[string.sub(row, x, x)])
			end
		end
		for _, name in (recipe.ingredients or {}) :: { string } do
			add(name)
		end
		add(recipe.input)
		return list
	end
	-- A name for `entry`, whose name another recipe (`other`) has: its result's from its first
	-- ingredient that one lacks ("GunpowderFromSaltpetre"; a tag's words, "#coals" "Coals"), one
	-- no recipe has yet.
	local function nameFor(entry: any, other: any): string
		local mine, theirs = ingredientsOf(entry), ingredientsOf(other)
		local from = mine[1] or "Something"
		for _, name in mine do
			if not table.find(theirs, name) then
				from = name
				break
			end
		end
		local words = string.gsub(string.gsub(from, "^#", ""), "_(%l)", string.upper)
		local base = `{entry.result}From{string.upper(string.sub(words, 1, 1))}{string.sub(words, 2)}`
		local name, n = base, 1
		while recipeAt[name] do
			n += 1
			name = `{base}{n}`
		end
		return name
	end
	-- (The places of recipes removed, taken out once every pack's are in; a removed name ->
	-- where it was removed.)
	local gone: { [number]: boolean } = {}
	local removedBy: { [string]: string } = {}
	for _, info in packs do
		for _, step in recipeSteps[info.name] do
			local entry = step.entry
			local name = (entry.name or entry.result) :: string
			local here = `{placeOf(step.pack, step.file)}, recipe #{step.index} ({name})`
			local at = recipeAt[name]
			if entry.override or entry.remove then
				local verb = if entry.remove then "removes" else "overrides"
				if at == nil then
					local removed = removedBy[name]
					fail(
						`{here} {verb} a recipe no earlier pack makes{if removed
							then ` ({removed} removed it)`
							else hint(name, recipeAt)}`
					)
				end
				if entry.remove then
					gone[at] = true
					recipeAt[name] = nil
					removedBy[name] = here
				else
					local recipe = table.clone(entry)
					recipe.override = nil
					recipe.name = name
					recipes[at] = recipe
					table.insert(recipeFrom[at].overrides, { pack = step.pack, file = step.file })
				end
			elseif at then
				local own = if entry.name then "" else ", its result's,"
				fail(
					`{here}: the name{own} is taken by {recipeWhere(at)} (a name of its own, name = "{nameFor(
						entry,
						recipes[at]
					)}", or override = true to replace it)`
				)
			else
				local recipe = table.clone(entry)
				recipe.name = name
				table.insert(recipes, recipe)
				table.insert(recipeFrom, {
					pack = step.pack,
					file = step.file,
					index = step.index,
					overrides = table.clone(step.patched or {}),
				})
				recipeAt[name] = #recipes
				removedBy[name] = nil
			end
		end
	end
	-- (The removed ones taken out, the rest in their order.)
	if next(gone) then
		local kept, keptFrom = {}, {}
		for index, recipe in recipes do
			if not gone[index] then
				table.insert(kept, recipe)
				table.insert(keptFrom, recipeFrom[index])
			end
		end
		table.clear(recipes)
		table.move(kept, 1, #kept, 1, recipes)
		table.clear(recipeFrom)
		table.move(keptFrom, 1, #keptFrom, 1, recipeFrom)
		table.clear(recipeAt)
		for index, recipe in recipes do
			recipeAt[recipe.name :: string] = index
		end
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
	local effectId: { [string]: number } = table.clone(effectAt)
	local entries: { Entry } = table.clone(blocks) :: { any }
	for _, spec in items do
		table.insert(entries, spec)
	end

	-- Entries' own tags, after every pack's lists: each the pack's (and file's) that gave it, its
	-- maker's or an override's.
	for _, entry in entries do
		local kind = if blockAt[entry.name] then "blocks" else "items"
		local by = tagsBy[kind][entry.name] or {}
		for _, tag in (entry.tags or {}) :: { string } do
			local from = by[tag] or { pack = made[kind][entry.name], file = madeIn[kind][entry.name] }
			addToTag(tag, entry.name, whereOf(kind, entry.name), from.pack, from.file)
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

	-- The fluids a fluid block's `group` may name (Fluids/FluidList's, by name).
	local fluidNames: { [string]: boolean } = {}
	for _, fluid in FluidList do
		fluidNames[fluid.name] = true
	end

	-- A sound event an entry names: one of the packs' sounds.
	local soundAt = places.sounds
	local function needSound(here: string, what: string, name: string)
		if soundAt[name] == nil then
			fail(`{here}: {what} names unknown sound {name}{hint(name, soundAt)}`)
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
			if spec.toggle.sound then
				needSound(here, "toggle sound", spec.toggle.sound)
			end
		end
		if spec.sounds then
			-- (In order, so the same mistake reads the same everywhere.)
			local actions: { string } = {}
			for action in spec.sounds do
				table.insert(actions, action)
			end
			table.sort(actions)
			for _, action in actions do
				needSound(here, `sounds.{action}`, spec.sounds[action])
			end
		end
		if spec.workSound then
			needSound(here, "workSound", spec.workSound)
		end
		local group = spec.fluid and spec.fluid.group
		if group and fluidNames[group] == nil then
			fail(`{here}: fluid.group names unknown fluid {group}{hint(group, fluidNames)}`)
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
		if spec.lit then
			needName(here, "lit", spec.lit, true)
			if blocks[blockAt[spec.lit]].fuse == nil then
				fail(`{here}: lit names {spec.lit}, which has no fuse (the ticks it burns before its blast)`)
			end
		end
		if spec.fuse and not (spec.fuse >= 1 and spec.fuse == math.floor(spec.fuse)) then
			fail(`{here}: fuse must be whole ticks, 1 at least, not {spec.fuse}`)
		end
	end
	for _, spec in items do
		local here = whereOf("items", spec.name)
		if spec.places then
			needName(here, "places", spec.places, true)
		end
		if spec.equipSound then
			needSound(here, "equipSound", spec.equipSound)
		end
		if spec.food and spec.food.sound then
			needSound(here, "food sound", spec.food.sound)
		end
		if spec.fills then
			needName(here, "fills", spec.fills)
		end
		if spec.drink and spec.drink.purified then
			needName(here, "drink purified", spec.drink.purified)
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
	-- Former names (`formerly`): each claimed by one entry, none a name an entry has now.
	local formerOf: { [string]: string } = {}
	for _, entry in entries do
		local here = whereOf(if blockAt[entry.name] then "blocks" else "items", entry.name)
		for _, old in (entry.formerly or {}) :: { string } do
			if names[old] then
				local now = whereOf(if blockAt[old] then "blocks" else "items", old)
				fail(`{here}: formerly names {old}, which is a name now ({now})`)
			elseif formerOf[old] then
				fail(`{here}: formerly names {old}, which {formerOf[old]} formerly was too`)
			end
			formerOf[old] = here
		end
	end
	for _, potion in potions do
		needIngredient(whereOf("potions", potion.name), "ingredient", potion.ingredient)
	end
	for index, recipe in recipes do
		local here = recipeWhere(index)
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
	-- An Age's milestones: a key or a count each, a key of what its category counts (an item
	-- crafted or smelted, a block mined, a biome visited, an Age reached; a mob killed is
	-- Progression/Ages' to check, the mobs being no content).
	for _, age in ages do
		local here = whereOf("ages", age.id)
		for index, milestone in age.milestones do
			local key, category = milestone.key, milestone.category
			if (key == nil) == (milestone.count == nil) then
				fail(`{here}: milestone {index} needs a key or a count (one of them)`)
			elseif key and (category == "craft" or category == "smelt") then
				needName(here, `milestone {category}`, key)
			elseif key and category == "mine" then
				needName(here, "milestone mine", key, true)
			elseif key and category == "biome" and biomeAt[key] == nil then
				fail(`{here}: milestone biome names unknown biome {key}{hint(key, biomeAt)}`)
			elseif key and category == "age" and not ageIds[key] then
				fail(`{here}: milestone age names unknown Age {key}{hint(key, ageIds)}`)
			end
		end
	end
	for name in lore do
		needName(whereOf("lore", name), "lore", name)
	end
	for tag, ticks in fuel do
		if tags[tag] == nil then
			fail(`{whereOf("fuel", tag)}: names unknown tag #{tag}{hint(tag, tags)}`)
		elseif ticks <= 0 then
			fail(`{whereOf("fuel", tag)}: burns for {ticks} ticks`)
		end
	end
	-- A biome's plants: single plants or the lower halves of tall ones.
	local function needPlants(here: string, what: string, list: { Schema.Weighted }?)
		for _, entry in (list or {}) :: { Schema.Weighted } do
			local name = entry[1] :: string
			needName(here, what, name, true)
			local plant = blocks[blockAt[name]].plant
			if plant == nil or plant.bottom ~= nil then
				fail(`{here}: {what} grows {name}, which is no plant (or the upper half of one)`)
			end
		end
	end
	for _, biome in biomes do
		local here = whereOf("biomes", biome.name)
		-- (A patched biome, whole: its patches may have left out what it needs.)
		if #patched.biomes[biome.name] > 0 then
			local problem = Schema.check("biomes", biome)
			if problem then
				fail(`{here}: {problem}`)
			end
		end
		for _, field in { "top", "filler", "steep", "underwater", "beach" } do
			local name = (biome :: any)[field]
			if name then
				needName(here, field, name, true)
			end
		end
		if biome.patches then
			needName(here, "patches", biome.patches.block, true)
		end
		local foliage = biome.foliage
		if foliage then
			needPlants(here, "foliage.plants", foliage.plants)
			needPlants(here, "foliage.flowers", foliage.flowers and foliage.flowers.species)
			needPlants(here, "foliage.herbs", foliage.herbs and foliage.herbs.species)
		end
	end

	-- The skills: their Ages and icons, one node to an Age's row (the skill tree screen's cell),
	-- their prerequisites (known, of their Age or an earlier one, never in a loop); then the skills
	-- entries name.
	local ageAt: { [string]: number } = {}
	for index, age in ages do
		ageAt[age.id] = index
	end
	-- (An Age's place and row, "3 2" -> the id of the node there.)
	local cellOf: { [string]: string } = {}
	for _, skill in skills do
		local here = whereOf("skills", skill.id)
		if not ageIds[skill.age] then
			fail(`{here}: age names unknown Age {skill.age}{hint(skill.age, ageIds)}`)
		end
		needName(here, "icon", skill.icon)
		local cell = `{ageAt[skill.age]} {skill.row}`
		local other = cellOf[cell]
		if other then
			fail(
				`{here}: row {skill.row} of the {ages[ageAt[skill.age]].name} is {whereOf("skills", other)}'s (an Age's nodes take a row each)`
			)
		end
		cellOf[cell] = skill.id
	end
	for _, skill in skills do
		local here = whereOf("skills", skill.id)
		for _, required in (skill.requires or {}) :: { string } do
			local at = skillAt[required]
			if at == nil then
				fail(`{here}: requires names unknown skill {required}{hint(required, skillAt)}`)
			end
			local before = skills[at]
			if ageAt[before.age] > ageAt[skill.age] then
				fail(`{here}: requires {required}, a node of a later Age ({ages[ageAt[before.age]].name})`)
			end
		end
	end
	-- (Depth first along `requires`: a node met again while its own prerequisites are being
	-- followed closes a loop.)
	local state: { [string]: number } = {}
	local path: { string } = {}
	local function follow(id: string)
		if state[id] == 2 then
			return
		elseif state[id] == 1 then
			local from = table.find(path, id) :: number
			local loop = table.concat(path, ", ", from) .. `, {id}`
			fail(`{whereOf("skills", id)}: its requires go round in a loop ({loop})`)
		end
		state[id] = 1
		table.insert(path, id)
		for _, required in (skills[skillAt[id]].requires or {}) :: { string } do
			follow(required)
		end
		table.remove(path)
		state[id] = 2
	end
	for _, skill in skills do
		follow(skill.id)
	end
	for _, entry in entries do
		local id = entry.skill
		if id and skillAt[id] == nil then
			local kind = if blockAt[entry.name] then "blocks" else "items"
			fail(`{whereOf(kind, entry.name)}: skill names unknown skill {id}{hint(id, skillAt)}`)
		end
	end

	-- Structures: each template's text (it reads, under the name it holds) and its palette's
	-- blocks; the templates pools give, their fallbacks; the structures' start pools and biomes.
	local templateNames: { string } = {}
	for name in templates do
		table.insert(templateNames, name)
	end
	table.sort(templateNames)
	-- Is `name` a pool: an explicit one, a template's name, or the templates named "<name>/..."
	-- (Structures/Library's lookup)?
	local function isPool(name: string): boolean
		if templatePools[name] or templates[name] then
			return true
		end
		local prefix = name .. "/"
		for _, template in templateNames do
			if string.sub(template, 1, #prefix) == prefix then
				return true
			end
		end
		return false
	end
	for _, name in templateNames do
		local here = whereOf("templates", name)
		local head, problem = TemplateText.head(templates[name])
		if head == nil then
			fail(`{here}: {problem}`)
		else
			if head.name ~= name then
				fail(`{here}: its text is the template {head.name} (a template goes under the name its text holds)`)
			end
			for _, block in head.blocks do
				needName(here, "palette", block, true)
			end
		end
	end
	local poolNames: { string } = {}
	for name in templatePools do
		table.insert(poolNames, name)
	end
	table.sort(poolNames)
	for _, name in poolNames do
		local here = whereOf("pools", name)
		local pool = templatePools[name]
		for index, element in pool.elements do
			local template = element.template
			if template and templates[template] == nil then
				fail(`{here}: element {index} names unknown template {template}{hint(template, templates)}`)
			end
		end
		local fallback = pool.fallback
		if fallback and not Schema.EMPTY_POOLS[fallback] and not isPool(fallback) then
			fail(`{here}: fallback names unknown pool {fallback}{hint(fallback, templatePools)}`)
		end
	end
	for _, structure in structures do
		local here = whereOf("structures", structure.name)
		local start = structure.startPool
		if not isPool(start) then
			local near = hint(start, templatePools)
			fail(
				`{here}: startPool names unknown pool {start} (no pool, template or templates named {start}/...){near}`
			)
		end
		-- (By their exact names, as every other name; left out: every biome.)
		local grows = structure.biomes
		if grows and #grows == 0 then
			fail(`{here}: biomes is empty, so it would grow nowhere (leave biomes out for every biome)`)
		end
		for _, biome in (grows or {}) :: { string } do
			if biomeAt[biome] == nil then
				fail(`{here}: biomes names unknown biome {biome}{hint(biome, biomeAt)}`)
			end
		end
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
		skills = skills,
		lore = lore,
		fuel = fuel,
		biomes = biomes,
		effects = effects,
		potions = potions,
		templates = templates,
		pools = templatePools,
		structures = structures,
		sounds = sounds,
		music = music,
		blockId = blockId,
		itemId = itemId,
		effectId = effectId,
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
	function content.biome(name: string): BiomeSpec?
		local index = biomeAt[name]
		return if index then biomes[index] else nil
	end
	-- `kind`: Schema.SINGULAR's word ("block", "item", "texture", "loot table"...) or the kind.
	local kindOfWord: { [string]: string } = {}
	for kind, word in SINGULAR do
		kindOfWord[word] = kind
		kindOfWord[kind] = kind
	end
	function content.where(kind: string, name: string | number): string
		local plural = kindOfWord[kind]
		if plural == "recipes" then
			-- (A recipe by its name or its place in content.recipes, as Content's own messages
			-- name it.)
			local at = if type(name) == "number" then name else recipeAt[name]
			return if at and recipeFrom[at] then recipeWhere(at) else `recipe {name}`
		end
		return if plural and type(name) == "string" then whereOf(plural, name) else `{kind} {name}`
	end
	-- (Each pack's place in load order, to give a tag's packs in that order.)
	local packAt: { [string]: number } = {}
	for index, info in packs do
		packAt[info.name] = index
	end
	function content.origin(kind: string, name: string | number): Origin?
		local plural = kindOfWord[kind]
		if plural == "recipes" then
			local at = if type(name) == "number" then name else recipeAt[name]
			local from = if at then recipeFrom[at] else nil
			if from == nil then
				return nil
			end
			local by: { Patch } = {}
			local patchers: { string } = {}
			for _, patch in from.overrides do
				table.insert(by, table.clone(patch))
				table.insert(patchers, patch.pack)
			end
			return { pack = from.pack, file = from.file, patched = patchers, overrides = by, index = from.index }
		elseif plural == "tags" then
			local by = if type(name) == "string" then tagPacks[name] else nil
			if by == nil then
				return nil
			end
			local order: { string } = {}
			for pack in by do
				table.insert(order, pack)
			end
			table.sort(order, function(a: string, b: string): boolean
				return packAt[a] < packAt[b]
			end)
			local first = table.remove(order, 1) :: string
			local adding: { Patch } = {}
			for _, pack in order do
				table.insert(adding, { pack = pack, file = by[pack].file })
			end
			return { pack = first, file = by[first].file, patched = order, overrides = adding }
		elseif plural == nil or type(name) ~= "string" or made[plural][name] == nil then
			return nil
		end
		local by: { Patch } = {}
		for _, patch in overrides[plural][name] do
			table.insert(by, table.clone(patch))
		end
		return {
			pack = made[plural][name],
			file = madeIn[plural][name],
			patched = table.clone(patched[plural][name]),
			overrides = by,
		}
	end
	return content
end

--[[
	`folder`'s children sorted by name, each a name once (`place`: "pack P", "pack P, blocks/stone"
	or the packs' folder, for the message). Rojo keeps both of two files of one name (`blocks.luau`
	beside `blocks.json`, `recipes.luau` beside a `recipes` folder), and which one a script finds by
	the name is not said: a client and the server could load different ones.
]]
local function childrenOf(folder: Instance, place: string): { Instance }
	local children = folder:GetChildren()
	table.sort(children, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)
	for index = 2, #children do
		local a, b = children[index - 1], children[index]
		if a.Name == b.Name then
			fail(
				`{place} has two things named {b.Name} (a {a.ClassName} and a {b.ClassName}: {b.Name}.luau beside {b.Name}.json, or a module beside a folder of that name?); keep one`
			)
		end
	end
	return children
end

--[[
	What a pack holds that Rojo makes into something no pack reads (`child` at `path` in pack
	`pack`, a module or a folder), as an error: a name with a dot (Rojo makes `ores.old.luau` the
	module "ores.old"), and a module with modules in it (a folder holding an `init.luau`: Rojo makes
	the folder that module, and its other files would never load).
]]
local function checkChild(pack: string, child: Instance, path: string)
	if string.find(child.Name, ".", 1, true) then
		fail(
			`pack {pack} has {path}, a name with a dot (Rojo makes {child.Name}.luau a module of that name, which no pack reads): rename it, or move it out of the pack`
		)
	elseif child:IsA("ModuleScript") and #child:GetChildren() > 0 then
		fail(
			`pack {pack} has {path}, a module with modules in it (a folder holding an init.luau): a kind folder has no init, its files merge by their names, so give it a name of its own ({path}/init.luau -> {path}/main.luau)`
		)
	end
end

-- A pack module's data (`place`: "pack P's blocks", "pack P, blocks/stone"): its value, or what its
-- function makes with Content/Define. An error in it names the place too; nothing (nil) is one.
local function loadModule(module: Instance, place: string): any
	local ok, data = pcall(function(): any
		local value = (require :: any)(module)
		return if type(value) == "function" then value(Define) else value
	end)
	if not ok then
		fail(`{place} does not load: {data}`)
	elseif data == nil then
		fail(
			`{place} gives nothing (nil): a module returns its data, a function its list (does it end with "return list"?)`
		)
	end
	return data
end

--[[
	A kind folder's modules (`folder`, at `path` in pack `pack`: "blocks"), loaded in their names'
	order, the folders inside it in their place among them (depth first), into `into`.
]]
local function loadFolder(pack: string, folder: Instance, path: string, into: { PackFile })
	for _, child in childrenOf(folder, `pack {pack}, {path}`) do
		local file = `{path}/{child.Name}`
		checkChild(pack, child, file)
		if string.sub(child.Name, 1, 1) == "_" then
			fail(`pack {pack} has {file}: a helper goes at the pack's top, not in a kind folder`)
		elseif child:IsA("ModuleScript") then
			table.insert(into, { file = file, data = loadModule(child, `pack {pack}, {file}`) })
		elseif child:IsA("Folder") then
			loadFolder(pack, child, file, into)
		else
			fail(
				`pack {pack} has {file}, a {child.ClassName}, which is no module or folder (a pack's data is .luau and .json files)`
			)
		end
	end
end

--[[
	The packs in `root` (a folder of pack folders), loaded and merged (`build`). A pack folder holds
	its `pack` manifest and its kinds, each a module (Luau or JSON) or a kind folder of them;
	modules named "_..." are its own helpers, left alone.
]]
function Content.load(root: Instance): Content
	local packs: { PackData } = {}
	for _, folder in childrenOf(root, root.Name) do
		if not folder:IsA("Folder") then
			fail(`{root.Name}/{folder.Name} is no pack folder`)
		end
		local manifest: any = nil
		local kinds: { [string]: any } = {}
		local folders: { [string]: { PackFile } } = {}
		local pack = folder.Name
		for _, module in childrenOf(folder, `pack {pack}`) do
			local name = module.Name
			if string.sub(name, 1, 1) == "_" then
				continue
			end
			checkChild(pack, module, name)
			if module:IsA("Folder") then
				if SINGULAR[name] == nil then
					fail(`pack {pack} has a folder {name}, which is no kind{hint(name, SINGULAR)}`)
				end
				local files: { PackFile } = {}
				loadFolder(pack, module, name, files)
				folders[name] = files
			elseif not module:IsA("ModuleScript") then
				fail(
					`pack {pack} has {name}, a {module.ClassName}, which is no module (a pack's data is .luau and .json files; a helper's name starts with "_")`
				)
			elseif name == "pack" then
				manifest = loadModule(module, `pack {pack}'s manifest`)
			elseif SINGULAR[name] then
				kinds[name] = loadModule(module, `pack {pack}'s {name}`)
			else
				fail(
					`pack {pack} has a module {name}, which is no kind{hint(name, SINGULAR)} (a helper's name starts with "_")`
				)
			end
		end
		if manifest == nil then
			fail(`pack {pack} has no manifest (a module named pack)`)
		end
		table.insert(packs, { name = pack, manifest = manifest, kinds = kinds, folders = folders })
	end
	return Content.build(packs)
end

-- The game's packs (Content/Packs), loaded once.
Content.default = Content.load(script.Packs)

return Content
