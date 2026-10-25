--[[
	The content tool's view of the game (tests/content, tests/spec/ContentTool): the content packs
	as the game loads them and what its registries make of them, gathered into one table (a
	ContentTool View) for lib/ContentTool's checks, lists and pages. It only reads.

	  load(env, shared, world?)   requires Content and every registry that builds itself from it
	                              out of a mounted tree (the game's src/shared, or one with fixture
	                              packs grafted into Content/Packs), so their load-time checks run
	                              as in the game, and returns the View; or nil and the error a pack
	                              or a registry stopped the load with (Content's names the pack,
	                              the kind and the entry). `world`: scanWorld's names. Where each
	                              entry came from is the content's own record (`content.origin`).
	  scanWorld(dirs?)            the words the world's sources use outside comments (DIRS: the
	                              terrain, biomes, features and structures, the seasons' snow,
	                              blocks that grow or spread), so the View can tell which blocks the
	                              world makes (those named there, the ore features', the biomes'
	                              ground and plants, and the structure templates'). Reads the
	                              files: run from the repository root.

	How the game gives items, as the View says it (ContentTool follows the recipes itself):
	  * the world: breaking a block it makes gives what Shared/Items says (its drop, what Shears
	    get, everything its `loot` may give: leaves' saplings and sticks, gravel's flint, grass's
	    straw), and so does breaking a block an item placed (`places`);
	  * `found`: what needs nothing first: the chests' loot tables (the ruins' and bunkers',
	    Generation/ScavengeLoot.NAMES, and the mineshafts'), the structure templates' chests, the
	    mobs' drops (Entities/MobList) and the Fallen Stars (server Players/FallenStars); a loot
	    table only a block names gives as that block breaks, and one nothing names gives nothing;
	  * `converts`: one item into another: raw meat a burning mob drops cooked (Foods.COOKED), an
	    empty Bucket at a carriable fluid's source (Fluids/FluidList), an empty bottle, bowl or
	    canteen at water (ToughAsNails/Drinks.FILLS).
]]

local fs = require("@lune/fs")

local ContentGame = {}

-- The world's sources (scanWorld): what the generators place and the structures they build in
-- code, the seasons' snow and what grows, spreads or flows (server Behaviours). (The structure
-- library's templates are data the View reads through Structures/Library instead.)
ContentGame.DIRS = table.freeze({
	"src/shared/Generation",
	"src/shared/Biomes",
	"src/shared/Seasons",
	"src/server/Behaviours",
	"src/server/Seasons",
})
-- (The debug worlds lay every block out in a grid: none of that is found in survival.)
ContentGame.SKIP = table.freeze({ ["src/shared/Generation/DebugWorlds.luau"] = true })

-- Source text without its comments (block comments first, then line comments).
local function uncommented(text: string): string
	text = string.gsub(text, "%-%-%[(=*)%[.-%]%1%]", "")
	text = string.gsub(text, "%-%-[^\n]*", "")
	return text
end

--[[
	Every word ([A-Za-z_][A-Za-z0-9_]*) the Luau files under `dirs` (default DIRS) use outside
	comments, each with the first file using it.
]]
function ContentGame.scanWorld(dirs: { string }?): { [string]: string }
	local words: { [string]: string } = {}
	local function scan(dir: string)
		local entries = fs.readDir(dir)
		table.sort(entries)
		for _, entry in entries do
			local path = `{dir}/{entry}`
			if fs.isDir(path) then
				scan(path)
			elseif string.sub(entry, -5) == ".luau" and not ContentGame.SKIP[path] then
				for word in string.gmatch(uncommented(fs.readFile(path)), "[%a_][%w_]*") do
					if words[word] == nil then
						words[word] = path
					end
				end
			end
		end
	end
	for _, dir in dirs or ContentGame.DIRS do
		if fs.isDir(dir) then
			scan(dir)
		end
	end
	return words
end

-- The View's parts, from the registries (see the header).
local function build(env: any, shared: any, words: { [string]: string }): any
	local require = env.require
	local Content = require(shared.Content)
	local Schema = require(shared.Content.Schema)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local LoreList = require(shared.Items.LoreList)
	local TexturePack = require(shared.TexturePack)
	local Ages = require(shared.Progression.Ages)
	local Crafting = require(shared.Crafting)
	local MobList = require(shared.Entities.MobList)
	local Foods = require(shared.Items.Foods)
	local FluidList = require(shared.Fluids.FluidList)
	local Drinks = require(shared.ToughAsNails.Drinks)
	local PotionList = require(shared.Effects.PotionList)
	local Library = require(shared.Structures.Library)
	local TemplateText = require(shared.Structures.TemplateText)
	local ScavengeLoot = require(shared.Generation.ScavengeLoot)
	local Mineshafts = require(shared.Generation.Mineshafts)
	local Machines = require(shared.Machines)
	-- (The rest of the registries that build themselves from the packs, for their load-time
	-- checks: a pack's mistake one of them refuses is the game's too.)
	for _, path in
		{
			{ "Crafting", "Smelting" },
			{ "Progression" },
			{ "Machines", "MinerRules" },
			{ "Radiation" },
			{ "Generation", "Ores" },
			{ "Biomes" },
			{ "Generation", "Structures" },
			{ "Sounds" },
			{ "ToughAsNails", "Temperature" },
			{ "Items", "Tooltip" },
		}
	do
		-- (One that has moved is skipped: it is the game's checks this wants, not its layout.)
		local node = shared
		for _, name in path do
			node = node and node:FindFirstChild(name)
		end
		if node and node:IsA("ModuleScript") then
			require(node)
		end
	end

	local content = Content.default
	local function nameOf(id: number?): string?
		local def = if id then Items.get(id) else nil
		return if def then def.name else nil
	end
	-- (A food's or a drink's effects with their Shared/Effects names, for `show`.)
	local Effects = require(shared.Effects)
	local function effectNames(list: { any }?): { any }?
		if list == nil then
			return nil
		end
		local named = {}
		for _, given in list do
			local shown = table.clone(given)
			local effect = Effects.get(given.effect)
			shown.effect = if effect then effect.name else tostring(given.effect)
			table.insert(named, shown)
		end
		return named
	end

	local isItem: { [string]: boolean } = {}
	local creativeOnly: { [string]: boolean } = {}
	local places: { [string]: string } = {}
	for _, def in Items.list do
		isItem[def.name] = true
		if Items.isCreativeOnly(def.id) then
			creativeOnly[def.name] = true
		end
		if def.block then
			places[def.name] = Blocks.get(def.block).name
		end
	end
	local textured: { [string]: boolean } = {}
	-- (The creative tier's machines, Mekanism's creative energy cube: no recipe makes one, by
	-- design, though any player may hold one, so survival never giving it is no finding.)
	local creativeMachines: { [string]: boolean } = {}
	for id = 0, Blocks.count - 1 do
		local def = Blocks.get(id)
		textured[def.name] = def.textures ~= nil
		local kind = Machines.kindOf(id)
		if kind and kind.creative then
			creativeMachines[def.name] = true
		end
	end

	-- The world's blocks: the ones its sources name, the ore features' and the templates'.
	local world: { [string]: string } = {}
	for _, spec in content.blocks do
		local path = words[spec.name]
		if path then
			world[spec.name] = `named in {path}`
		end
	end
	for _, ore in content.ores do
		world[ore.block] = world[ore.block] or `ore feature {ore.name}`
	end
	-- (A biome's ground and the plants it grows.)
	for _, biome in content.biomes or {} do
		local function named(name: string?)
			if name then
				world[name] = world[name] or `biome {biome.name}`
			end
		end
		for _, field in { "top", "filler", "steep", "underwater", "beach" } do
			named(biome[field])
		end
		named(biome.patches and biome.patches.block)
		local foliage = biome.foliage or {}
		for _, list in
			{ foliage.plants or {}, (foliage.flowers or {}).species or {}, (foliage.herbs or {}).species or {} }
		do
			for _, entry in list do
				named(entry[1])
			end
		end
	end
	local found: { [string]: string } = {}
	local library = Library.load({ warn = function() end })
	for _, name in library.names do
		local template = library.templates[name]
		for _, block in template.palette do
			local blockName = Blocks.get(block).name
			world[blockName] = world[blockName] or `structure template {name}`
		end
		for _, container in template.containers do
			for _, entry in container.items do
				local item = nameOf(Items.find(entry.item))
				if item and found[item] == nil then
					found[item] = `a chest of structure template {name}`
				end
			end
		end
	end

	-- (The chests' tables: the ruins' and bunkers' and the mineshafts'. A block's table gives
	-- only as the block breaks: `drops`.)
	local chests: { [string]: boolean } = {}
	for _, name in ScavengeLoot.NAMES do
		chests[name] = true
	end
	local lootNames: { string } = {}
	for name, pools in content.loot do
		if pools == Mineshafts.LOOT then
			chests[name] = true
		end
		table.insert(lootNames, name)
	end
	table.sort(lootNames)
	for _, name in lootNames do
		if not chests[name] then
			continue
		end
		for _, pool in content.loot[name] do
			for _, entry in pool.entries do
				local item = entry[1]
				if item and found[item] == nil then
					found[item] = `loot table {name}`
				end
			end
		end
	end
	for _, kind in MobList.kinds do
		for _, drop in kind.drops do
			local item = drop.item
			if found[item] == nil then
				found[item] = `{kind.name}'s drop`
			end
		end
	end
	if isItem.FallenStar then
		found.FallenStar = found.FallenStar or "falling at night (server Players/FallenStars)"
	end

	local converts: { any } = {}
	for raw, cooked in Foods.COOKED do
		table.insert(converts, {
			from = nameOf(raw),
			to = nameOf(cooked),
			why = `cooked by fire from {nameOf(raw)} (a burning mob's drop)`,
		})
	end
	for _, fluid in FluidList do
		if fluid.carriable then
			table.insert(converts, {
				from = "Bucket",
				to = fluid.bucket,
				needs = fluid.name,
				why = `an empty Bucket on {fluid.name}`,
			})
		end
	end
	for empty, full in Drinks.FILLS do
		table.insert(converts, {
			from = nameOf(empty),
			to = nameOf(full),
			needs = "Water",
			why = `a {nameOf(empty)} filled at Water`,
		})
	end
	table.sort(converts, function(a, b)
		return a.to < b.to or (a.to == b.to and a.from < b.from)
	end)

	-- What breaking a block gives (Shared/Items: tools, Shears, everything its loot may give).
	local shears = Items.find("Shears")
	local function drops(block: string): { string }
		local id = Blocks.find(block)
		local out: { string } = {}
		local function add(stack: any)
			local name = if stack then nameOf(stack.item) else nil
			if name and not table.find(out, name) then
				table.insert(out, name)
			end
		end
		if id == nil then
			return out
		end
		add(Items.blockDrops(id))
		if shears then
			add(Items.drops(id, shears))
		end
		local spec = content.block(block)
		local loot = spec and spec.loot
		local pools = if type(loot) == "string" then content.loot[loot] else loot
		for _, pool in pools or {} do
			for _, entry in pool.entries do
				if entry[1] and not table.find(out, entry[1]) then
					table.insert(out, entry[1])
				end
			end
		end
		return out
	end

	-- A crafting grid of names (nil: empty) -> what Crafting.match makes, and how many.
	local function craft(grid: { [number]: string }, width: number): (string?, number?)
		local stacks: { [number]: any } = {}
		for slot = 1, width * width do
			local name = grid[slot]
			if name then
				local id = Items.find(name)
				if id == nil then
					return nil, nil
				end
				stacks[slot] = { item = id, count = 1 }
			end
		end
		local result = Crafting.match(stacks, width)
		if result == nil then
			return nil, nil
		end
		return nameOf(result.item), result.count
	end

	return {
		content = content,
		packs = content.packs,
		kinds = Schema.KINDS,
		suggest = Schema.suggest,
		lore = LoreList,
		isItem = isItem,
		faces = TexturePack.Blocks,
		textured = textured,
		icons = TexturePack.Icons,
		missingTexture = TexturePack.Missing,
		ageOf = Ages.names(),
		craft = craft,
		world = world,
		drops = drops,
		places = places,
		found = found,
		converts = converts,
		creativeOnly = creativeOnly,
		creativeMachines = creativeMachines,
		variants = PotionList.variants,
		itemId = function(name: string): number?
			return Items.find(name)
		end,
		food = function(name: string): any?
			local food = Foods.of(Items.find(name))
			if food == nil then
				return nil
			end
			local shown = table.clone(food) :: any
			shown.useTicks = Foods.useTicks(food)
			shown.medical = Foods.isMedical(food)
			shown.effects = effectNames(food.effects)
			shown.aftermath = if food.aftermath then effectNames({ food.aftermath })[1] else nil
			return shown
		end,
		drink = function(name: string): any?
			local id = Items.find(name)
			local entry = Drinks.entry(id)
			if entry == nil then
				return nil
			end
			local shown = table.clone(entry.drink) :: any
			shown.effects = effectNames(entry.drink.effects)
			shown.potion = Drinks.isPotion(entry.drink)
			shown.empty = nameOf(entry.empty)
			shown.sips = if entry.sips then (Items.get(id :: number) :: any).durability else nil
			return shown
		end,
		templateHead = TemplateText.head,
	}
end

--[[
	The View of the game mounted in `env` at `shared`, or nil and the error that stopped its load.
	`world`: scanWorld's words (none: only the ore features and templates make world blocks).
]]
function ContentGame.load(env: any, shared: any, world: { [string]: string }?): (any?, string?)
	local ok, result = pcall(build, env, shared, world or {})
	if ok then
		return result, nil
	end
	return nil, tostring(result)
end

return ContentGame
