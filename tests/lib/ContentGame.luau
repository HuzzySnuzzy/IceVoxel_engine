--[[
	The content tool's view of the game (tests/content, tests/spec/ContentTool): the content packs
	as the game loads them and what its registries make of them, gathered into one table (a
	ContentTool View) for lib/ContentTool's checks, lists and pages. It only reads.

	  load(env, shared, world?)   requires Content and every registry that builds itself from it
	                              out of a mounted tree (the game's src/shared, or one with fixture
	                              packs grafted into Content/Packs), so their load-time checks run
	                              as in the game, and returns the View; or nil and the error a pack
	                              or a registry stopped the load with (Content's names the pack,
	                              the kind and the entry). `world`: scanWorld's names.
	  readPacks(root, require, define, kinds)
	                              each pack folder's own data, as its modules give it, in load order
	                              (`order`, then name, as Content.load sorts them): what each pack
	                              made and patched, which the merged content keeps no list of. A
	                              kind (a key of `kinds`: Schema.SINGULAR) may be a module or a
	                              folder of modules, merged in name order (lists one after another,
	                              tables of names together); modules whose names start with "_"
	                              are a pack's helpers, left out.
	  scanWorld(dirs?)            the words the world's sources use outside comments (DIRS: the
	                              terrain, biomes, features and structures, the seasons' snow,
	                              blocks that grow or spread), so the View can tell which blocks the
	                              world makes (those named there, the ore features' and the
	                              structure templates'). Reads the files: run from the repository
	                              root.

	How the game gives items, as the View says it (ContentTool follows the recipes itself):
	  * the world: breaking a block it makes gives what Shared/Items says (its drop, what Shears
	    get, its `loot`, and the side rules: leaves' saplings and sticks, gravel's flint, grass's
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

local function sortedChildren(folder: any): { any }
	local children = folder:GetChildren()
	table.sort(children, function(a, b)
		return a.Name < b.Name
	end)
	return children
end

-- A module's data: its value, or what its function makes with Content/Define (as Content.load).
local function moduleData(module: any, require: (any) -> any, define: any): any
	local data = require(module)
	if type(data) == "function" then
		data = data(define)
	end
	return data
end

-- A kind's data: a module's, or a folder's modules' (and subfolders') merged in name order.
local function kindData(node: any, require: (any) -> any, define: any): any
	if node:IsA("ModuleScript") then
		return moduleData(node, require, define)
	end
	local merged: { [any]: any } = {}
	for _, child in sortedChildren(node) do
		if string.sub(child.Name, 1, 1) ~= "_" then
			local part = kindData(child, require, define)
			if type(part) == "table" then
				if #part > 0 then
					for _, entry in part do
						table.insert(merged, entry)
					end
				else
					for key, value in part do
						if merged[key] == nil then
							merged[key] = value
						end
					end
				end
			end
		end
	end
	return merged
end

export type PackData = { name: string, manifest: any, kinds: { [string]: any } }

--[[
	Each pack under `root` (a folder of pack folders) as its own modules give it, sorted as Content
	loads them. `kinds` are Content/Schema's (anything else in a pack is the loader's to refuse).
]]
function ContentGame.readPacks(root: any, require: (any) -> any, define: any, kinds: { [string]: any }): { PackData }
	local packs: { PackData } = {}
	for _, folder in sortedChildren(root) do
		if not folder:IsA("Folder") then
			continue
		end
		local manifest: any = nil
		local data: { [string]: any } = {}
		for _, child in sortedChildren(folder) do
			local name = child.Name
			if string.sub(name, 1, 1) == "_" then
				continue
			elseif name == "pack" and child:IsA("ModuleScript") then
				manifest = moduleData(child, require, define)
			elseif kinds[name] then
				data[name] = kindData(child, require, define)
			end
		end
		table.insert(packs, { name = folder.Name, manifest = manifest or {}, kinds = data })
	end
	table.sort(packs, function(a: PackData, b: PackData): boolean
		local x, y = a.manifest.order or 0, b.manifest.order or 0
		if x ~= y then
			return x < y
		end
		return a.name < b.name
	end)
	return packs
end

-- The View's parts, from the registries (see the header).
local function build(env: any, shared: any, words: { [string]: string }): any
	local require = env.require
	local Content = require(shared.Content)
	local Schema = require(shared.Content.Schema)
	local Define = require(shared.Content.Define)
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
	local Library = require(shared.Structures.Library)
	local ScavengeLoot = require(shared.Generation.ScavengeLoot)
	local Mineshafts = require(shared.Generation.Mineshafts)
	-- (The rest of the registries that build themselves from the packs, for their load-time
	-- checks: a pack's mistake one of them refuses is the game's too.)
	for _, path in
		{
			{ "Crafting", "Smelting" },
			{ "Progression" },
			{ "Machines", "MinerRules" },
			{ "Radiation" },
			{ "Generation", "Ores" },
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
	for id = 0, Blocks.count - 1 do
		local def = Blocks.get(id)
		textured[def.name] = def.textures ~= nil
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

	-- What breaking a block gives (Shared/Items: tools, Shears, its loot, the side rules).
	local shears = Items.find("Shears")
	local function zero(): number
		return 0
	end
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
		-- (The side rules at their luckiest rolls: the leaves' sapling, then their sticks.)
		add(Items.leafDrop(id, zero))
		local rolls = 0
		add(Items.leafDrop(id, function(): number
			rolls += 1
			return if rolls == 1 then 0.999 else 0
		end))
		add(Items.randomDrop(id, zero))
		add(Items.strawDrop(id, zero))
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
		packs = ContentGame.readPacks(shared.Content.Packs, require, Define, Schema.SINGULAR),
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
		itemId = function(name: string): number?
			return Items.find(name)
		end,
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
