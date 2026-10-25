--[[
	The content tool's workings (tests/content), pure: given a View of the game (lib/ContentGame:
	the merged content packs, where each entry came from and what the registries make of them)
	it finds what a pack's author likely forgot, lists and shows entries, and writes a new pack's
	modules as text. It reads no file and prints nothing: tests/content does that, and
	tests/spec/ContentTool runs it on fixture packs.

	  check(view)       the findings (Finding: pack, level, check, subject, text), pack by pack in
	                    load order:
	    lore      warning  a block that is an item, or an item, without a lore line where the game
	                       finds one (Items/LoreList: its entry's `lore`, a pack's `lore`)
	    faces     warning  a block that can carry a texture without texture-pack faces (its own
	                       entry, its cave twin's or its variant group's, as Blocks resolves them).
	                       Never textured, as the TexturePack spec has it: undrawn blocks, fluids,
	                       transmitters, tanks, machines, creative only blocks, Neon ones (no
	                       MaterialVariant) and lights built of boxes standing in their cell
	                       (torches, lanterns, lamps, the campfire)
	    icon      warning  an item that is no block without an icon entry (TexturePack.Icons; ""
	                       counts: a blank is how the pack marks a picture still to make)
	    texture   warning  a texture no block's faces use (the pack's Missing texture aside)
	    age       warning  a crafted or smelted result no Age names, which the first Age opens
	                       (Ages.ofName's default), that survival play cannot give before a later
	                       Age: every way to it needs something of that Age, so it most likely
	                       wants that `age`. (A result no Age names is no mistake by itself: the
	                       first Age is every result's unless an Age names it.)
	    recipe    warning  a crafting recipe that never crafts: its own grid (one of each key or
	                       ingredient, a tag's first name, from the top left of the 3 x 3 grid)
	                       makes something else, since Crafting.match takes the first recipe that
	                       fits (every shaped one before any shapeless one)
	    survival  info     an item survival play never gives (`reach`): no recipe, loot table,
	                       drop, mob drop, structure or other way the game has, or only recipes
	                       needing such items. Creative only items, the creative tier's machines
	                       (a machine kind with `creative`: Mekanism's creative energy cube, which
	                       no recipe makes by design), fluids' blocks (buckets carry those) and
	                       blocks the world makes (found there, even when they break into
	                       something else: ores, grass, ice) are left out
	  report(view, findings)    the check's lines: a summary per pack, the findings, the counts
	  summary(view)             a line per pack: its order and how much of each kind it holds
	  list(view, kind?, pack?)  lines of entries (id, name, pack), of one kind, of one pack
	  show(view, name)          lines about everything named `name` (a block, item, texture, loot
	                            table, tag, ore feature, Age or biome): its merged fields, id, pack
	                            and the packs that patched it, and what the registries made of it;
	                            nil and the nearest names when nothing has the name
	  reach(view)               when survival play first gives each item (an Age index) and how
	  scaffold(name, order)     a new pack's modules, { { path, text } }: one block, one item, a
	                            shaped and a smelting recipe, a texture and a loot table, each field
	                            explained, ready to load and to pass `check`
	  scaffoldProblem(view, name)   why `name` can't be a new pack (nil: it can)
	  nextOrder(view)           the order after every pack's (the next hundred)

	The View (lib/ContentGame makes it from the game; a spec may make one of its own):
	  content          the merged packs (Shared/Content's)
	  packs, kinds     content.packs ({ name, order, ... }, in load order); Schema.KINDS
	  suggest          Schema.suggest (the nearest name)
	  lore, isItem, creativeOnly, creativeMachines   Items/LoreList; every item's name (placeable
	                   blocks too); the creative only ones; the blocks whose machine kind is
	                   creative (Machines `creative`)
	  faces, textured, icons, missingTexture   TexturePack.Blocks; the blocks Blocks gives faces
	                   (their own entry's, a cave twin's, a variant group's); TexturePack.Icons and
	                   .Missing
	  ageOf            Ages.names(): result name -> the index of the Age naming it
	  craft(grid, width)   Crafting.match by names: what a grid of names makes, and how many
	  world, drops(block), places, found, converts   how survival gets items (ContentGame's header)
	  itemId(name)     the item's id
	  food(name), drink(name)   what eating and drinking it does, as Items/Foods and
	                   ToughAsNails/Drinks give it (effects by name, the empty container's name,
	                   a canteen's sips; nil: none), for `show`

	Where an entry comes from is the loader's own record (content.origin): the pack and file that
	made it, the packs whose overrides patched it, a recipe's place in its file, the packs that
	put names in a tag.
]]

local ContentTool = {}

export type Finding = {
	pack: string,
	level: "warning" | "info",
	-- lore, faces, icon, texture, age, recipe, survival (the header).
	check: string,
	-- "block Stone", "item Stick", "texture \"stone\"", "recipe #3 (Torch)".
	subject: string,
	text: string,
}

-- The checks in the order the counts list them, with what each counts.
ContentTool.CHECKS = table.freeze({
	{ id = "lore", label = "no lore" },
	{ id = "faces", label = "no faces" },
	{ id = "icon", label = "no icon" },
	{ id = "texture", label = "unused" },
	{ id = "age", label = "Age" },
	{ id = "recipe", label = "never crafted" },
	{ id = "survival", label = "out of reach" },
})

-- The grid recipes are tried in (a crafting table's).
ContentTool.GRID = 3
-- The widest line `show` writes (longer fields are cut, lists of names wrapped).
ContentTool.WIDTH = 118

local INF = math.huge

--[[ Helpers ]]

local function sortedKeys(map: { [any]: any }): { any }
	local keys = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		if type(a) == type(b) then
			return a < b
		end
		return type(a) < type(b)
	end)
	return keys
end

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

local function quote(text: string): string
	return '"' .. string.gsub(text, '[\\"\n]', { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n" }) .. '"'
end

local function number(value: number): string
	if value == math.huge or value == -math.huge then
		return if value > 0 then "math.huge" else "-math.huge"
	elseif value == math.floor(value) and math.abs(value) < 1e15 then
		return string.format("%d", value)
	end
	return tostring(value)
end

local function identifier(key: string): boolean
	return string.match(key, "^[%a_][%w_]*$") ~= nil
end

-- `value` as Luau source on one line ({ 1, 2 }, { a = 1 }, "x").
local function inline(value: any): string
	local kind = type(value)
	if kind == "string" then
		return quote(value)
	elseif kind == "number" then
		return number(value)
	elseif kind ~= "table" then
		return tostring(value)
	end
	if next(value) == nil then
		return "{}"
	end
	local parts = {}
	if isList(value) then
		for _, element in value do
			table.insert(parts, inline(element))
		end
	else
		for _, key in sortedKeys(value) do
			local name = if type(key) == "string" and identifier(key) then key else `[{inline(key)}]`
			table.insert(parts, `{name} = {inline(value[key])}`)
		end
	end
	return `\{ {table.concat(parts, ", ")} }`
end
ContentTool.inline = inline

-- `text` cut to `width` characters ("..." at the end when cut).
local function cut(text: string, width: number): string
	if #text <= width then
		return text
	end
	return string.sub(text, 1, width - 4) .. " ..."
end

-- `head` and `names`, comma separated, wrapped at WIDTH (continued under the first name).
local function wrap(head: string, names: { string }): { string }
	local lines = {}
	local line = head
	local indent = string.rep(" ", #head)
	for index, name in names do
		local piece = if index < #names then `{name},` else name
		if #line + 1 + #piece > ContentTool.WIDTH and line ~= head then
			table.insert(lines, line)
			line = indent
		end
		line ..= (if line == head or line == indent then "" else " ") .. piece
	end
	table.insert(lines, line)
	return lines
end

local function pad(text: string, width: number): string
	return text .. string.rep(" ", width - #text)
end

local function padLeft(text: string, width: number): string
	return string.rep(" ", width - #text) .. text
end

-- "IronHelmet" -> "Iron Helmet" (Items' display names).
local function spaced(name: string): string
	return (string.gsub(name, "(%l)(%u)", "%1 %2"))
end

-- Rows of cells as aligned lines (`right`: columns aligned right), indented by `indent`.
local function columns(rows: { { string } }, indent: string, right: { [number]: boolean }?): { string }
	local widths: { number } = {}
	for _, row in rows do
		for index, cell in row do
			widths[index] = math.max(widths[index] or 0, #cell)
		end
	end
	local lines = {}
	for _, row in rows do
		local cells = {}
		for index, cell in row do
			if index == #row and not (right and right[index]) then
				table.insert(cells, cell)
			elseif right and right[index] then
				table.insert(cells, padLeft(cell, widths[index]))
			else
				table.insert(cells, pad(cell, widths[index]))
			end
		end
		table.insert(lines, indent .. table.concat(cells, "  "))
	end
	return lines
end

--[[ Where things come from ]]

-- The pack that made `name` of `kind` ("blocks", "textures"...: content.origin's), else "?".
local function packOf(view: any, kind: string, name: string): string
	local origin = view.content.origin(kind, name)
	return if origin then origin.pack else "?"
end
ContentTool.packOf = packOf

-- The packs whose overrides patched `name` of `kind`, in load order.
local function patchedBy(view: any, kind: string, name: string): { string }
	local origin = view.content.origin(kind, name)
	return if origin then origin.patched else {}
end

-- The packs that put names in tag `tag`, in load order.
local function tagPacks(view: any, tag: string): { string }
	local origin = view.content.origin("tags", tag)
	if origin == nil then
		return {}
	end
	local packs = { origin.pack }
	for _, pack in origin.patched do
		table.insert(packs, pack)
	end
	return packs
end

-- Pack name -> its place in load order.
local function packIndexOf(view: any): { [string]: number }
	local index: { [string]: number } = {}
	for at, pack in view.packs do
		index[pack.name] = at
	end
	return index
end

--[[
	Merged recipe `index`'s pack and the loader's name for it in there: "recipe #3" (its place in
	its pack's recipes), "recipes/tools, recipe #3" for a kind folder's file; "?" and the merged
	place when unknown.
]]
local function recipeFrom(view: any, index: number): (string, string)
	local origin = view.content.origin("recipe", index)
	if origin == nil then
		return "?", `recipe #{index}`
	end
	local name = `recipe #{origin.index}`
	return origin.pack, if origin.file then `{origin.file}, {name}` else name
end

-- "recipe #3 (Torch)": as the loader names it, by the recipe's place in its pack (or file).
local function recipeSubject(view: any, index: number): string
	local _, place = recipeFrom(view, index)
	return `{place} ({view.content.recipes[index].result})`
end

-- What a recipe is, in short: "shaped Torch x4", "smelting RawIron -> IronIngot".
local function recipeText(recipe: any): string
	local count = if (recipe.count or 1) ~= 1 then ` x{recipe.count}` else ""
	if recipe.type == "smelting" then
		return `smelting {recipe.input} -> {recipe.result}{count}`
	end
	return `{recipe.type} {recipe.result}{count}`
end

-- The ingredients a recipe needs (names or "#tags", each once).
local function ingredientsOf(recipe: any): { string }
	local list: { string } = {}
	local function add(name: any)
		if type(name) == "string" and not table.find(list, name) then
			table.insert(list, name)
		end
	end
	if recipe.type == "shaped" then
		for _, row in recipe.pattern or {} do
			for x = 1, #row do
				local char = string.sub(row, x, x)
				if char ~= " " then
					add((recipe.key or {})[char])
				end
			end
		end
	elseif recipe.type == "shapeless" then
		for _, name in recipe.ingredients or {} do
			add(name)
		end
	else
		add(recipe.input)
	end
	return list
end

-- Does `ingredient` (a name or "#tag") take `name`?
local function takes(view: any, ingredient: string, name: string): boolean
	if string.sub(ingredient, 1, 1) == "#" then
		local tag = view.content.tags[string.sub(ingredient, 2)]
		return tag ~= nil and table.find(tag, name) ~= nil
	end
	return ingredient == name
end

-- The earliest Age `ingredient` (a name, or "#tag": any of its names) is had in, by `age`
-- (INF: never).
local function ingredientAge(view: any, age: { [string]: number }, ingredient: string): number
	if string.sub(ingredient, 1, 1) == "#" then
		local best = INF
		for _, name in view.content.tags[string.sub(ingredient, 2)] or {} do
			best = math.min(best, age[name] or INF)
		end
		return best
	end
	return age[ingredient] or INF
end

--[[ Survival's reach ]]

export type Reach = {
	-- Item name -> the index of the earliest Age survival play gives it in (none: never).
	age: { [string]: number },
	-- Item name -> how ("loot table house", "breaking Stone (found in the world)", "recipe ...").
	how: { [string]: string },
}

--[[
	When survival play first gives each item, and how: what needs nothing (`view.found`: loot
	tables, chests, mobs' drops) in the first Age; breaking a block the world makes, in the first
	Age, or one an item placed, once that item is had; a recipe once every ingredient is had (a
	tag: any of its names) and its result's Age is reached (results no Age names: the first);
	`view.converts` once their item (and the block they need in the world) is had. The least
	fixed point: each item's earliest Age over all its ways.
]]
function ContentTool.reach(view: any): Reach
	if view.__reach then
		return view.__reach
	end
	local content = view.content
	local age: { [string]: number } = {}
	local how: { [string]: string } = {}
	local function give(name: string, at: number, why: string): boolean
		if at < (age[name] or INF) then
			age[name] = at
			how[name] = why
			return true
		end
		return false
	end
	for _, name in sortedKeys(view.found) do
		give(name, 1, view.found[name])
	end
	-- Block name -> the earliest Age one can be broken in, and why it is there.
	local blockAt: { [string]: number } = {}
	local blockWhy: { [string]: string } = {}
	for _, spec in content.blocks do
		local why = view.world[spec.name]
		if why then
			blockAt[spec.name] = 1
			blockWhy[spec.name] = "found in the world"
		end
	end
	local dropsOf: { [string]: { string } } = {}
	local placers: { { item: string, block: string } } = {}
	for _, entry in content.entries do
		local block = view.places[entry.name]
		if block then
			table.insert(placers, { item = entry.name, block = block })
		end
	end
	local changed, rounds = true, 0
	while changed and rounds < 256 do
		changed = false
		rounds += 1
		for _, spec in content.blocks do
			local at = blockAt[spec.name]
			if at then
				local drops = dropsOf[spec.name]
				if drops == nil then
					drops = view.drops(spec.name)
					dropsOf[spec.name] = drops
				end
				for _, item in drops do
					if give(item, at, `breaking {spec.name} ({blockWhy[spec.name]})`) then
						changed = true
					end
				end
			end
		end
		for index, recipe in content.recipes do
			local at = view.ageOf[recipe.result] or 1
			for _, ingredient in ingredientsOf(recipe) do
				at = math.max(at, ingredientAge(view, age, ingredient))
			end
			if at < INF then
				local pack, place = recipeFrom(view, index)
				if give(recipe.result, at, `pack {pack}, {place} ({recipeText(recipe)})`) then
					changed = true
				end
			end
		end
		for _, convert in view.converts do
			local at = age[convert.from] or INF
			if convert.needs then
				at = math.max(at, blockAt[convert.needs] or INF)
			end
			if at < INF and give(convert.to, at, convert.why) then
				changed = true
			end
		end
		for _, placer in placers do
			local at = age[placer.item] or INF
			if at < (blockAt[placer.block] or INF) then
				blockAt[placer.block] = at
				blockWhy[placer.block] = `placed from {placer.item}`
				changed = true
			end
		end
	end
	local result = { age = age, how = how }
	view.__reach = result
	return result
end

--[[ Checks ]]

-- Can the block carry a texture (see the header's faces)?
local function texturable(spec: any): boolean
	if spec.render == "None" or spec.render == "Fluid" or spec.fluid then
		return false
	end
	if spec.transmitter or spec.tank or spec.machine or spec.creativeOnly then
		return false
	end
	if spec.material == "Neon" then
		return false
	end
	-- (Lights built of boxes standing in their cell: torches, lanterns, lamps, the campfire. Glow
	-- lichen, a plate other blocks replace, takes a Front texture.)
	return not (spec.shape ~= nil and spec.light ~= nil and not spec.replaceable)
end
ContentTool.texturable = texturable

-- One of each key or ingredient, a tag's first name, from the top left of the grid (nil and
-- why when it can't be built).
local function gridOf(view: any, recipe: any): ({ [number]: string }?, string?)
	local size = ContentTool.GRID
	local function first(ingredient: string): string?
		if string.sub(ingredient, 1, 1) == "#" then
			local tag = view.content.tags[string.sub(ingredient, 2)]
			return tag and tag[1]
		end
		return ingredient
	end
	local grid: { [number]: string } = {}
	if recipe.type == "shaped" then
		local pattern = recipe.pattern
		if #pattern > size then
			return nil, `its pattern has {#pattern} rows, more than the {size} x {size} grid`
		end
		for y, row in pattern do
			if #row > size then
				return nil, `its pattern's row "{row}" is wider than the {size} x {size} grid`
			end
			for x = 1, #row do
				local char = string.sub(row, x, x)
				if char ~= " " then
					local name = first(recipe.key[char] or "")
					if name == nil or name == "" then
						return nil, `its key {char} names nothing it can take`
					end
					grid[(y - 1) * size + x] = name
				end
			end
		end
	else
		if #recipe.ingredients > size * size then
			return nil, `it has {#recipe.ingredients} ingredients, more than the grid's {size * size} slots`
		end
		for slot, ingredient in recipe.ingredients do
			local name = first(ingredient)
			if name == nil then
				return nil, `its ingredient {ingredient} names nothing it can take`
			end
			grid[slot] = name
		end
	end
	return grid, nil
end

-- Crafting.match's order: every shaped recipe (in load order), then every shapeless one.
local function craftingOrder(view: any): { number }
	local order = {}
	for _, kind in { "shaped", "shapeless" } do
		for index, recipe in view.content.recipes do
			if recipe.type == kind then
				table.insert(order, index)
			end
		end
	end
	return order
end

function ContentTool.check(view: any): { Finding }
	local content = view.content
	local findings: { Finding } = {}
	local function add(pack: string, level: "warning" | "info", check: string, subject: string, text: string)
		table.insert(findings, { pack = pack, level = level, check = check, subject = subject, text = text })
	end

	-- Lore, faces, icons.
	for _, spec in content.blocks do
		local pack = packOf(view, "blocks", spec.name)
		local subject = `block {spec.name}`
		if view.isItem[spec.name] then
			local line = view.lore[spec.name]
			if type(line) ~= "string" or line == "" then
				add(pack, "warning", "lore", subject, `no lore line (lore = "..." on its entry)`)
			end
		end
		if texturable(spec) and not view.textured[spec.name] then
			add(
				pack,
				"warning",
				"faces",
				subject,
				`no texture faces (texture = \{ All = "..." }; a blank texture will do)`
			)
		end
	end
	for _, spec in content.items do
		local pack = packOf(view, "items", spec.name)
		local subject = `item {spec.name}`
		local line = view.lore[spec.name]
		if type(line) ~= "string" or line == "" then
			add(pack, "warning", "lore", subject, `no lore line (lore = "..." on its entry)`)
		end
		if view.icons[spec.name] == nil then
			add(pack, "warning", "icon", subject, `no icon entry (icon = "" marks its picture as still to make)`)
		end
	end

	-- Textures no block uses.
	local used: { [string]: boolean } = {}
	for _, faces in view.faces do
		for _, texture in faces do
			used[texture] = true
		end
	end
	for _, name in sortedKeys(content.textures) do
		if not used[name] and name ~= view.missingTexture then
			add(
				packOf(view, "textures", name),
				"warning",
				"texture",
				`texture {quote(name)}`,
				"no block's faces use it"
			)
		end
	end

	-- Ages: results no Age names that survival can't give in the first Age.
	local reach = ContentTool.reach(view)
	local recipesOf: { [string]: { number } } = {}
	for index, recipe in content.recipes do
		local list = recipesOf[recipe.result] or {}
		recipesOf[recipe.result] = list
		table.insert(list, index)
	end
	local ages = content.ages
	if #ages > 0 then
		for _, entry in content.entries do
			local name = entry.name
			local at = reach.age[name]
			if recipesOf[name] and view.ageOf[name] == nil and at and at > 1 then
				-- (What holds it back: the cheapest recipe's latest ingredient.)
				local best, culprit = INF, nil
				for _, index in recipesOf[name] do
					local worst, by = 1, nil
					for _, ingredient in ingredientsOf(content.recipes[index]) do
						local need = ingredientAge(view, reach.age, ingredient)
						if need > worst then
							worst, by = need, ingredient
						end
					end
					if worst < best then
						best, culprit = worst, by
					end
				end
				local record = ages[at]
				local kind = if content.block(name) then "blocks" else "items"
				local because = if culprit and best == at
					then `every way to make it needs {culprit}, which comes in the {record.name}`
					else `nothing gives it before the {record.name} ({reach.how[name]})`
				add(
					packOf(view, kind, name),
					"warning",
					"age",
					`{if kind == "blocks" then "block" else "item"} {name}`,
					`no Age names it, so the {ages[1].name} opens it, but {because}: age = "{record.id}"?`
				)
			end
		end
	end

	-- Recipes that never craft.
	local order = craftingOrder(view)
	for index, recipe in content.recipes do
		if recipe.type == "smelting" then
			continue
		end
		local pack = recipeFrom(view, index)
		local subject = recipeSubject(view, index)
		local grid, problem = gridOf(view, recipe)
		if grid == nil then
			add(pack, "warning", "recipe", subject, `never crafted: {problem}`)
			continue
		end
		local made, count = view.craft(grid, ContentTool.GRID)
		local want = recipe.count or 1
		if made ~= recipe.result or count ~= want then
			local what = `{made}{if (count or 1) ~= 1 then ` x{count}` else ""}`
			-- (The recipe that wins, when one other recipe could: the first in Crafting's order.)
			local winners = {}
			for _, other in order do
				if other ~= index and content.recipes[other].result == made then
					table.insert(winners, other)
				end
			end
			local winner = "another recipe"
			if #winners == 1 then
				local otherPack, otherPlace = recipeFrom(view, winners[1])
				winner = `pack {otherPack}'s {otherPlace}`
			elseif #winners > 1 then
				winner = `one of the {#winners} recipes for {made}`
			end
			add(
				pack,
				"warning",
				"recipe",
				subject,
				if made == nil
					then "never crafted: its own grid makes nothing"
					else `never crafted: its own grid makes {what}, as {winner} fits first (shaped recipes before shapeless)`
			)
		end
	end

	-- Survival's reach.
	for _, entry in content.entries do
		local name = entry.name
		if not view.isItem[name] or view.creativeOnly[name] or view.creativeMachines[name] or reach.age[name] then
			continue
		end
		local block = content.block(name)
		if block and (view.world[name] or block.render == "Fluid" or block.fluid) then
			continue
		end
		local text = "survival never gives it: no recipe, loot table, drop, mob drop or structure does"
		local list = recipesOf[name]
		if list then
			local missing = nil
			for _, ingredient in ingredientsOf(content.recipes[list[1]]) do
				if ingredientAge(view, reach.age, ingredient) == INF then
					missing = ingredient
					break
				end
			end
			text =
				`survival never gives it: {if #list == 1 then "its recipe needs" else "its recipes need"} {missing or "items"}, which survival never gives either`
		end
		local kind = if block then "blocks" else "items"
		add(packOf(view, kind, name), "info", "survival", `{if block then "block" else "item"} {name}`, text)
	end

	-- Pack by pack in load order (each check's own order within a pack).
	local packIndex = packIndexOf(view)
	local position: { [Finding]: number } = {}
	for index, finding in findings do
		position[finding] = index
	end
	table.sort(findings, function(a: Finding, b: Finding): boolean
		local x, y = packIndex[a.pack] or INF, packIndex[b.pack] or INF
		if x ~= y then
			return x < y
		end
		if a.pack ~= b.pack then
			return a.pack < b.pack
		end
		if a.level ~= b.level then
			return a.level == "warning"
		end
		return position[a] < position[b]
	end)
	return findings
end

--[[ Reports ]]

-- The names of every `kind` the content holds (a recipe's: its merged place).
local function namesOf(content: any, kind: string): { any }
	local names = {}
	if kind == "blocks" or kind == "items" or kind == "ores" or kind == "biomes" then
		for _, entry in content[kind] do
			table.insert(names, entry.name)
		end
	elseif kind == "ages" then
		for _, age in content.ages do
			table.insert(names, age.id)
		end
	elseif kind == "recipes" then
		for index in content.recipes do
			table.insert(names, index)
		end
	else
		for name in content[kind] or {} do
			table.insert(names, name)
		end
	end
	return names
end

--[[
	A line per pack: "Core  order 0    blocks 2, tags 7, ages 5", what each pack made of each kind
	(content.origin), its overrides counted apart; a tag counts for every pack putting names in it.
]]
function ContentTool.summary(view: any): { string }
	local content = view.content
	-- Pack -> kind -> how many it made, and how many it patched.
	local made: { [string]: { [string]: number } } = {}
	local patched: { [string]: { [string]: number } } = {}
	for _, pack in view.packs do
		made[pack.name], patched[pack.name] = {}, {}
	end
	local function count(into: { [string]: { [string]: number } }, pack: string, kind: string)
		local byKind = into[pack]
		if byKind then
			byKind[kind] = (byKind[kind] or 0) + 1
		end
	end
	for _, kind in view.kinds do
		for _, name in namesOf(content, kind) do
			local origin = content.origin(kind, name)
			if origin then
				count(made, origin.pack, kind)
				for _, pack in origin.patched do
					count(if kind == "tags" then made else patched, pack, kind)
				end
			end
		end
	end
	local rows = {}
	for _, pack in view.packs do
		local parts = {}
		for _, kind in view.kinds do
			local n, overrides = made[pack.name][kind] or 0, patched[pack.name][kind] or 0
			if n + overrides > 0 then
				local extra = if overrides > 0
					then ` ({overrides} override{if overrides == 1 then "" else "s"})`
					else ""
				table.insert(parts, `{kind} {n}{extra}`)
			end
		end
		table.insert(rows, {
			pack.name,
			`order {number(pack.order)}`,
			if #parts > 0 then table.concat(parts, ", ") else "nothing yet",
		})
	end
	return columns(rows, "")
end

--[[
	The check's output: the packs' summary, a blank line, the findings (a line each: level, pack,
	entry, text; a blank line between packs), then a line of counts by level and check.
]]
function ContentTool.report(view: any, findings: { Finding }): { string }
	local lines = ContentTool.summary(view)
	local counts: { [string]: { [string]: number } } = { warning = {}, info = {} }
	local last: string? = nil
	for _, finding in findings do
		if finding.pack ~= last then
			table.insert(lines, "")
			last = finding.pack
		end
		table.insert(lines, `{pad(finding.level, 7)}  pack {finding.pack}, {finding.subject}: {finding.text}`)
		local byCheck = counts[finding.level]
		byCheck[finding.check] = (byCheck[finding.check] or 0) + 1
	end
	local function tally(level: string, word: string): string
		local total, parts = 0, {}
		for _, check in ContentTool.CHECKS do
			local n = counts[level][check.id]
			if n then
				total += n
				table.insert(parts, `{n} {check.label}`)
			end
		end
		if total == 0 then
			return `no {word}s`
		end
		return `{total} {word}{if total == 1 then "" else "s"} ({table.concat(parts, ", ")})`
	end
	table.insert(lines, "")
	table.insert(
		lines,
		`{#view.packs} pack{if #view.packs == 1 then "" else "s"}: {tally("warning", "warning")}, {tally("info", "info")}`
	)
	return lines
end

-- How many findings of `level` there are.
function ContentTool.count(findings: { Finding }, level: string): number
	local n = 0
	for _, finding in findings do
		if finding.level == level then
			n += 1
		end
	end
	return n
end

--[[ Lists ]]

-- The pack of each entry of `kind` and whether it is listed under `pack` (made or patched there).
local function listed(view: any, kind: string, name: string, pack: string?): boolean
	if pack == nil then
		return true
	end
	if packOf(view, kind, name) == pack then
		return true
	end
	return table.find(patchedBy(view, kind, name), pack) ~= nil
end

local function madeText(view: any, kind: string, name: string): string
	local by = patchedBy(view, kind, name)
	local text = packOf(view, kind, name)
	if #by > 0 then
		text ..= ` (patched by {table.concat(by, ", ")})`
	end
	return text
end

--[[
	Lines listing the entries of `kind` (every kind when nil), of `pack` only when given (what it
	made or patched): blocks and items with their ids, recipes by their merged place, biomes by
	their index (Shared/Biomes) with their bands, the rest by name; nil and why when the kind or
	the pack is unknown.
]]
function ContentTool.list(view: any, kind: string?, pack: string?): ({ string }?, string?)
	local content = view.content
	if kind and not table.find(view.kinds, kind) then
		return nil, `no kind {kind} (kinds: {table.concat(view.kinds, ", ")})`
	end
	if pack and packIndexOf(view)[pack] == nil then
		local names = {}
		for _, info in view.packs do
			table.insert(names, info.name)
		end
		return nil, `no pack {pack} (packs: {table.concat(names, ", ")})`
	end
	local lines = {}
	for _, each in view.kinds do
		if kind and each ~= kind then
			continue
		end
		local rows: { { string } } = {}
		local right: { [number]: boolean } = {}
		if each == "blocks" or each == "items" then
			right[1] = true
			for _, spec in content[each] do
				if listed(view, each, spec.name, pack) then
					local id = if each == "blocks" then content.blockId[spec.name] else content.itemId[spec.name]
					table.insert(rows, { tostring(id), spec.name, madeText(view, each, spec.name) })
				end
			end
		elseif each == "recipes" then
			right[1] = true
			for index, recipe in content.recipes do
				local from, place = recipeFrom(view, index)
				if pack == nil or from == pack then
					table.insert(rows, { `#{index}`, recipeText(recipe), `{from}, {place}` })
				end
			end
		elseif each == "ores" then
			for _, ore in content.ores do
				if listed(view, each, ore.name, pack) then
					table.insert(rows, { ore.name, ore.block, packOf(view, each, ore.name) })
				end
			end
		elseif each == "ages" then
			right[1] = true
			for index, age in content.ages do
				if listed(view, each, age.id, pack) then
					table.insert(rows, { tostring(index), age.id, age.name, packOf(view, each, age.id) })
				end
			end
		elseif each == "biomes" then
			right[1] = true
			for index, biome in content.biomes or {} do
				if listed(view, each, biome.name, pack) then
					table.insert(rows, {
						tostring(index),
						biome.name,
						if #biome.bands > 0 then table.concat(biome.bands, ", ") else "(no band)",
						madeText(view, each, biome.name),
					})
				end
			end
		elseif each == "tags" then
			for _, tag in sortedKeys(content.tags) do
				local packs = tagPacks(view, tag)
				if pack == nil or table.find(packs, pack) then
					local n = #content.tags[tag]
					table.insert(rows, { `#{tag}`, `{n} name{if n == 1 then "" else "s"}`, table.concat(packs, ", ") })
				end
			end
		else
			local map = content[each]
			for _, name in sortedKeys(map) do
				if listed(view, each, name, pack) then
					local note = if each == "textures" and map[name].Color == "" then "blank" else ""
					table.insert(rows, { name, madeText(view, each, name), note })
				end
			end
		end
		table.insert(lines, `{each}: {#rows}`)
		for _, line in columns(rows, "  ", right) do
			table.insert(lines, (string.gsub(line, "%s+$", "")))
		end
	end
	return lines, nil
end

--[[ Pages ]]

-- An entry's merged fields, a line each ("  hardness = 1.5"), name first, the rest sorted.
local function fieldLines(entry: { [string]: any }, skip: { [string]: boolean }?): { string }
	local lines = {}
	for _, key in sortedKeys(entry) do
		if not (skip and skip[key]) then
			table.insert(lines, cut(`    {key} = {inline(entry[key])}`, ContentTool.WIDTH))
		end
	end
	return lines
end

-- The recipes that make `name` and the ones that use it, a line each.
local function recipeLines(view: any, name: string): { string }
	local content = view.content
	local makes, uses = {}, {}
	for index, recipe in content.recipes do
		local from, place = recipeFrom(view, index)
		local text = `pack {from}, {place}: {recipeText(recipe)}`
		if recipe.result == name then
			table.insert(makes, text)
		end
		for _, ingredient in ingredientsOf(recipe) do
			if takes(view, ingredient, name) then
				table.insert(uses, if ingredient == name then text else `{text} (as {ingredient})`)
				break
			end
		end
	end
	local lines = {}
	table.insert(lines, `    made by: {if #makes == 0 then "no recipe" else ""}`)
	for _, text in makes do
		table.insert(lines, `      {text}`)
	end
	table.insert(lines, `    used in: {if #uses == 0 then "no recipe" else ""}`)
	for _, text in uses do
		table.insert(lines, `      {text}`)
	end
	for index, line in lines do
		lines[index] = (string.gsub(line, "%s+$", ""))
	end
	return lines
end

-- A block's texture faces as the registries resolve them: its own entry, else whose it takes.
local function facesText(view: any, spec: any): string
	local faces = view.faces
	local function shown(entry: any): string
		return string.sub(inline(entry), 3, -3)
	end
	if faces[spec.name] then
		return `{shown(faces[spec.name])} (its own entry)`
	end
	if spec.caveTwin and faces[spec.caveTwin] then
		return `{shown(faces[spec.caveTwin])} (its cave twin {spec.caveTwin}'s)`
	end
	local base = spec.item or spec.name
	if spec.door and spec.door.upper and faces[base .. "Top"] then
		return `{shown(faces[base .. "Top"])} ({base}Top's: a door's upper half)`
	end
	if spec.item and faces[spec.item] then
		return `{shown(faces[spec.item])} (its variant group's, {spec.item})`
	end
	if view.textured[spec.name] then
		return "its variant group's"
	end
	return if texturable(spec) then "none" else "none (never textured)"
end

-- `value` to three places ("12.8", not 12.800000000000001), and a share as a percentage.
local function rounded(value: number): string
	return number(math.round(value * 1000) / 1000)
end
local function percent(share: number): string
	return `{rounded(share * 100)}%`
end

-- " II" for amplifier 1 (an effect's level, Minecraft's numerals), "" for 0.
local function level(amplifier: number?): string
	local numerals = { "II", "III", "IV", "V" }
	local at = amplifier or 0
	return if at <= 0 then "" else ` {numerals[at] or `{at + 1}`}`
end

-- "Speed II for 400 ticks" for each effect given.
local function givenTexts(list: { any }?): { string }
	local texts = {}
	for _, given in list or {} do
		table.insert(texts, `gives {given.effect}{level(given.amplifier)} for {number(given.ticks)} ticks`)
	end
	return texts
end

-- What eating an item does as Items/Foods gives it (the View's `food`), in pieces.
local function foodTexts(food: any): { string }
	local texts = {}
	if food.medical then
		table.insert(texts, "medicine")
	end
	table.insert(texts, `heals {number(food.heal)}{if food.nutrition then " (hunger off)" else ""}`)
	if food.nutrition then
		local adds = food.nutrition * food.saturation * 2
		table.insert(texts, `nutrition {number(food.nutrition)}`)
		table.insert(texts, `saturation {number(food.saturation)} (+{rounded(adds)})`)
	end
	table.insert(texts, `held {number(food.useTicks)} ticks`)
	local risk = food.effect
	if risk then
		local effect = if risk.kind == "hunger" then "Hunger (Thirst with hunger off)" else "Thirst"
		table.insert(texts, `{percent(risk.chance)} {effect} for {number(risk.ticks)} ticks`)
	end
	if food.cures and #food.cures > 0 then
		table.insert(texts, `cures {table.concat(food.cures, " and ")}`)
	end
	for _, text in givenTexts(food.effects) do
		table.insert(texts, text)
	end
	local aftermath = food.aftermath
	if aftermath then
		table.insert(texts, `after a cure from stage {number(aftermath.stage)} {givenTexts({ aftermath })[1]}`)
	end
	if food.setback then
		table.insert(texts, "sets an infection back a stage")
	end
	if food.sound then
		table.insert(texts, `sound {food.sound}`)
	end
	if food.burp == false then
		table.insert(texts, "no burp")
	end
	return texts
end

-- What drinking an item does as ToughAsNails/Drinks gives it (the View's `drink`), in pieces.
local function drinkTexts(drink: any): { string }
	local texts = {}
	if drink.potion then
		table.insert(texts, "a potion (drunk any time)")
	end
	if drink.thirst > 0 then
		local adds = drink.thirst * drink.hydration * 2
		table.insert(texts, `thirst {number(drink.thirst)}`)
		table.insert(texts, `hydration {number(drink.hydration)} (+{rounded(adds)})`)
	end
	if drink.chance > 0 then
		table.insert(texts, `{percent(drink.chance)} Thirst for {number(drink.effectTicks)} ticks`)
	end
	if drink.warmth then
		table.insert(texts, `warmth {number(drink.warmth)} ticks`)
	end
	if drink.chill then
		table.insert(texts, `chill {number(drink.chill)} ticks`)
	end
	for _, text in givenTexts(drink.effects) do
		table.insert(texts, text)
	end
	if drink.mana then
		table.insert(texts, `mana {number(drink.mana)}`)
	end
	if drink.sips then
		table.insert(texts, `{number(drink.sips)} sips`)
	end
	table.insert(texts, if drink.empty then `leaves {drink.empty}` else "used up")
	return texts
end

-- The derived lines of a block or an item.
local function derivedLines(view: any, entry: any, isBlock: boolean): { string }
	local content = view.content
	local lines = { "  derived:" }
	local name = entry.name
	if isBlock then
		local id = view.itemId(name)
		table.insert(
			lines,
			`    item: {if view.isItem[name]
				then `yes (id {id})`
				elseif entry.item then `no ({entry.item} places it)`
				else "no"}`
		)
	end
	if not isBlock or view.isItem[name] then
		local line = view.lore[name]
		table.insert(lines, `    lore: {if type(line) == "string" and line ~= "" then quote(line) else "none"}`)
	end
	if isBlock then
		table.insert(lines, `    texture: {facesText(view, entry)}`)
	else
		local icon = view.icons[name]
		table.insert(
			lines,
			`    icon: {if icon == nil then "none" elseif icon == "" then '"" (blank: still to make)' else quote(icon)}`
		)
		-- (A spec's own View may leave food and drink out.)
		local food = if view.food then view.food(name) else nil
		if food then
			for _, line in wrap("    food: ", foodTexts(food)) do
				table.insert(lines, line)
			end
		end
		local drink = if view.drink then view.drink(name) else nil
		if drink then
			for _, line in wrap("    drink: ", drinkTexts(drink)) do
				table.insert(lines, line)
			end
		end
	end
	local ages = content.ages
	if #ages > 0 then
		local index = view.ageOf[name]
		local age = ages[index or 1]
		table.insert(
			lines,
			`    Age: {age.name} ({if index
				then `"{age.id}"`
				else `"{age.id}": no Age names it, the first is the default`})`
		)
	end
	if view.isItem[name] then
		local reach = ContentTool.reach(view)
		local at = reach.age[name]
		local text = if at
			then `from the {if ages[at] then ages[at].name else `Age {at}`}: {reach.how[name]}`
			elseif isBlock and view.world[name] then `never as an item (the world makes it: {view.world[name]})`
			else "never"
		table.insert(lines, cut(`    survival: {text}`, ContentTool.WIDTH))
	end
	for _, line in recipeLines(view, name) do
		table.insert(lines, line)
	end
	return lines
end

--[[
	Lines about everything named `name`: its kind, id and pack, the packs that patched it, its
	merged fields, and for blocks and items what the registries made of it. nil and the nearest
	names when nothing has the name.
]]
function ContentTool.show(view: any, name: string): ({ string }?, { string }?)
	local content = view.content
	local lines = {}
	local function section(head: string)
		if #lines > 0 then
			table.insert(lines, "")
		end
		table.insert(lines, head)
	end
	local function patches(kind: string)
		local by = patchedBy(view, kind, name)
		if #by > 0 then
			table.insert(lines, `  patched by: {table.concat(by, ", ")}`)
		end
	end
	local block = content.block(name)
	if block then
		section(`block {name}: id {content.blockId[name]}, pack {packOf(view, "blocks", name)}`)
		patches("blocks")
		table.insert(lines, "  fields:")
		for _, line in fieldLines(block, { name = true }) do
			table.insert(lines, line)
		end
		for _, line in derivedLines(view, block, true) do
			table.insert(lines, line)
		end
	end
	local item = content.item(name)
	if item then
		section(`item {name}: id {content.itemId[name]}, pack {packOf(view, "items", name)}`)
		patches("items")
		table.insert(lines, "  fields:")
		for _, line in fieldLines(item, { name = true }) do
			table.insert(lines, line)
		end
		for _, line in derivedLines(view, item, false) do
			table.insert(lines, line)
		end
	end
	local texture = content.textures[name]
	if texture then
		section(`texture {quote(name)}: pack {packOf(view, "textures", name)}`)
		patches("textures")
		table.insert(lines, "  fields:")
		for _, line in fieldLines(texture) do
			table.insert(lines, line)
		end
		local users = {}
		for _, spec in content.blocks do
			local faces = view.faces[spec.name]
			if faces then
				for _, used in faces do
					if used == name then
						table.insert(users, spec.name)
						break
					end
				end
			end
		end
		for _, line in wrap("  faces of: ", if #users > 0 then users else { "no block" }) do
			table.insert(lines, line)
		end
	end
	local loot = content.loot[name]
	if loot then
		section(`loot table {name}: pack {packOf(view, "loot", name)}`)
		for index, pool in loot do
			table.insert(lines, cut(`  pool {index}: {inline(pool)}`, ContentTool.WIDTH))
		end
		local users = {}
		for _, spec in content.blocks do
			if spec.loot == name then
				table.insert(users, spec.name)
			end
		end
		if #users > 0 then
			for _, line in wrap("  blocks' loot: ", users) do
				table.insert(lines, line)
			end
		end
	end
	local tagName = if string.sub(name, 1, 1) == "#" then string.sub(name, 2) else name
	local tag = content.tags[tagName]
	if tag then
		local packs = tagPacks(view, tagName)
		section(`tag #{tagName}: from {table.concat(packs, ", ")}`)
		for _, line in wrap("  names: ", tag) do
			table.insert(lines, line)
		end
		local ticks = content.fuel and content.fuel[tagName]
		if ticks then
			table.insert(lines, `  fuel: {ticks} ticks (pack {packOf(view, "fuel", tagName)})`)
		end
	end
	-- (A biome tag: the biomes' own `tags`.)
	local tagged = {}
	for _, biome in content.biomes or {} do
		if table.find(biome.tags or {}, tagName) then
			table.insert(tagged, biome.name)
		end
	end
	if #tagged > 0 then
		section(`biome tag #{tagName}`)
		for _, line in wrap("  biomes: ", tagged) do
			table.insert(lines, line)
		end
	end
	for _, ore in content.ores do
		if ore.name == name then
			section(`ore feature {name}: pack {packOf(view, "ores", name)}`)
			table.insert(lines, "  fields:")
			for _, line in fieldLines(ore, { name = true }) do
				table.insert(lines, line)
			end
		end
	end
	for index, age in content.ages do
		if age.id == name then
			section(`Age {name}: {age.name}, Age {index} of {#content.ages}, pack {packOf(view, "ages", name)}`)
			table.insert(lines, "  fields:")
			for _, line in fieldLines(age, { id = true }) do
				table.insert(lines, line)
			end
			local opens = {}
			for _, result in sortedKeys(view.ageOf) do
				if view.ageOf[result] == index then
					table.insert(opens, result)
				end
			end
			if index == 1 then
				table.insert(opens, "(and every result no Age names)")
			end
			for _, line in wrap("  opens: ", opens) do
				table.insert(lines, line)
			end
		end
	end
	for index, biome in content.biomes or {} do
		if biome.name == name then
			section(`biome {name}: index {index} of {#content.biomes}, pack {packOf(view, "biomes", name)}`)
			patches("biomes")
			table.insert(lines, "  fields:")
			for _, line in fieldLines(biome, { name = true, foliage = true }) do
				table.insert(lines, line)
			end
			-- (Its ground plants a line each: the herbs a pack patched in are seen.)
			local foliage = biome.foliage
			for _, key in if foliage then sortedKeys(foliage) else {} do
				table.insert(lines, cut(`    foliage.{key} = {inline(foliage[key])}`, ContentTool.WIDTH))
			end
		end
	end
	if #lines > 0 then
		return lines, nil
	end
	-- (Nothing has the name: the nearest ones of every kind.)
	local names: { [string]: boolean } = {}
	for _, entry in content.entries do
		names[entry.name] = true
	end
	for _, map in { content.textures, content.loot, content.tags } do
		for key in map do
			names[key] = true
		end
	end
	for _, ore in content.ores do
		names[ore.name] = true
	end
	for _, age in content.ages do
		names[age.id] = true
	end
	for _, biome in content.biomes or {} do
		names[biome.name] = true
	end
	local near = view.suggest(name, names)
	return nil, if near then { near } else {}
end

--[[ A new pack ]]

-- The names a new pack's examples take: "DeepOres" -> DeepOresBlock, DeepOresCrystal,
-- "deep ores block" (its texture), "deep_ores_block" (its loot table).
function ContentTool.scaffoldNames(pack: string): { [string]: string }
	local words = string.lower(spaced(pack))
	return {
		Pack = pack,
		Block = `{pack}Block`,
		Item = `{pack}Crystal`,
		BlockSpaced = spaced(`{pack}Block`),
		ItemSpaced = spaced(`{pack}Crystal`),
		texture = `{words} block`,
		loot = `{string.gsub(words, " ", "_")}_block`,
	}
end

-- Why `pack` can't be a new pack's name in `view` (nil: it can).
function ContentTool.scaffoldProblem(view: any, pack: string): string?
	if not string.match(pack, "^%u%a*$") then
		return `a pack's name is a word of letters starting with a capital (Marble, DeepOres), not "{pack}"`
	end
	for _, info in view.packs do
		if info.name == pack then
			return `there is a pack {pack} already`
		end
	end
	local names = ContentTool.scaffoldNames(pack)
	local content = view.content
	for _, key in { "Block", "Item" } do
		local name = names[key]
		if content.entry(name) then
			local kind = if content.block(name) then "block" else "item"
			return `{content.where(kind, name)} has the name {name} the example needs: pick another pack name`
		end
	end
	if content.textures[names.texture] then
		return `{content.where("texture", names.texture)} has the name the example texture needs: pick another pack name`
	end
	if content.loot[names.loot] then
		return `{content.where("loot", names.loot)} has the name the example loot table needs: pick another pack name`
	end
	return nil
end

-- The order after every pack's: the next hundred.
function ContentTool.nextOrder(view: any): number
	local highest = 0
	for _, pack in view.packs do
		local order = pack.order
		if type(order) == "number" then
			highest = math.max(highest, order)
		end
	end
	return (math.floor(highest / 100) + 1) * 100
end

-- The new pack's modules ($Name is a scaffoldNames value, $order the pack's order).
local TEMPLATES = {
	{
		path = "pack.luau",
		text = [==[
--!strict
--[[
	$Pack: one feature's content in one pack. `lune run tests/content new $Pack` made it, with an
	example of each kind to rename, edit or delete: a block, an item, a shaped and a smelting
	recipe, a texture and a loot table. Each entry carries its own lore, texture, icon and Age
	(Content/Schema's per-entry fields), so nothing outside the pack needs an edit. `lune run
	tests/content` checks it; `lune run tests/content show $Block` shows what the game makes of an
	entry.

	Packs load by `order`, then by name (Shared/Content), and every id is a place in that order: at
	$order, after every other pack, this one moves no id. `requires` names the packs that must load
	before it: Core, whose Ages and base tags its entries name.
]]
return {
	order = $order,
	description = "$Pack: what the feature adds, in a line.",
	requires = { "Core" },
}
]==],
	},
	{
		path = "blocks.luau",
		text = [==[
--!strict
--[[
	$Pack's blocks: Content/Schema's BlockSpec (its BLOCK_FIELDS say what every field does). An
	entry says everything about its block, the fields other registries read included:
	  lore      the tooltip's line (every block that is an item needs one: Items/LoreList)
	  texture   its faces' textures, by the names in a pack's `textures` (All, Sides, Top, Bottom,
	            Front, Sprite: Shared/TexturePack)
	  age       the Age whose players may craft it, by id (Core's: "stone", "iron", "industrial",
	            "electric", "atomic"); left out, the Stone Age's
	  loot      a loot table's name (a pack's `loot`): what breaking it now and then gives instead
	A block's id is its place among every pack's blocks, given as the game loads, so entries may be
	added, moved or removed freely.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	-- (A CamelCase name, shown spaced: "$BlockSpaced". Mined with any pickaxe.)
	{
		name = "$Block",
		color = { 150, 150, 160 },
		material = "Slate",
		hardness = 2,
		tool = "pickaxe",
		toolLevel = 0,
		lore = "Cobblestone pressed around coal. Smelts into a $ItemSpaced.",
		texture = { All = "$texture" },
		loot = "$loot",
	},
} :: { Schema.BlockSpec }
]==],
	},
	{
		path = "items.luau",
		text = [==[
--!strict
--[[
	$Pack's items, the ones that are no blocks (a block that may be placed is an item already):
	Content/Schema's ItemSpec (its ITEM_FIELDS). `model` is the item in the hand and on the
	ground, boxes in pixels (16 to a block, `color` each box's own or the item's). The fields other
	registries read:
	  lore   the tooltip's line (Items/LoreList)
	  icon   its inventory picture, "rbxassetid://<number>", or "" until it is made (the blanks are
	         what is left to draw: Shared/TexturePack)
	  age    the Age whose players may craft or smelt it (left out: the Stone Age's)
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	{
		name = "$Item",
		color = { 196, 206, 232 },
		material = "Glass",
		model = {
			{ size = { 4, 8, 3 }, offset = { 0, 0, 0 } },
			{ size = { 2, 2, 2.5 }, offset = { 0, 5, 0 }, color = { 226, 232, 250 } },
		},
		icon = "",
		lore = "Smelted from a $BlockSpaced in the Iron Age.",
		age = "iron",
	},
} :: { Schema.ItemSpec }
]==],
	},
	{
		path = "recipes.luau",
		text = [==[
--!strict
--[[
	$Pack's recipes (Content/Schema's Recipe), after every earlier pack's. An ingredient is an
	item's name or "#tag" (Core's tags: planks, logs, coals, stone_crafting_materials...).
	  shaped     `pattern` rows (" " an empty slot), `key` each character's ingredient: it fits
	             anywhere in the grid, mirrored too; `count` of the result (default 1)
	  shapeless  `ingredients` in any slots
	  smelting   one `input` cooks into `result` in a furnace
	A crafting grid makes the first recipe it fits (every shaped one before any shapeless one), so
	a recipe whose grid an earlier one takes never crafts: `lune run tests/content` says so. (A
	module may also be `return function(define) ... end`, building recipes with Content/Define's
	`define.shaped`, `define.shapeless`, `define.smelting` and `define.storage`, as the Ores
	pack's does.)
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	-- Four cobblestone around a coal: two $BlockSpaced blocks.
	{
		type = "shaped",
		pattern = { "S S", " C ", "S S" },
		key = { S = "#stone_crafting_materials", C = "#coals" },
		result = "$Block",
		count = 2,
	},
	-- A $BlockSpaced smelts into a $ItemSpaced (once the Iron Age opens it: its `age`).
	{ type = "smelting", input = "$Block", result = "$Item" },
} :: { Schema.Recipe }
]==],
	},
	{
		path = "textures.luau",
		text = [==[
--!strict
--[[
	$Pack's textures (Shared/TexturePack's header says what each field does), by name: lower case
	words, as Minecraft names them; block entries' `texture` faces name them. Color = "" is a blank:
	the block keeps its own colour and material until the picture is made. To make it, paste the
	picture's Image asset id ("rbxassetid://<number>") into Color and run
	`lune run tests/build_textures`.
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	["$texture"] = { Color = "", Material = "Slate", Tint = false },
} :: { [string]: Schema.Texture }
]==],
	},
	{
		path = "loot.luau",
		text = [==[
--!strict
--[[
	$Pack's loot tables (Generation/ScavengeLoot's format), by name: a list of pools, each rolled
	`rolls[1]`..`rolls[2]` times, each roll one entry by weight: { item or false (nothing), weight,
	min, max }. A block's `loot` names one: breaking the block, the first item its pools roll drops
	in place of the block (none: the block itself).
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	-- One time in four, breaking a $BlockSpaced gives a $ItemSpaced instead.
	["$loot"] = {
		{ rolls = { 1, 1 }, entries = { { "$Item", 1, 1, 1 }, { false, 3, 0, 0 } } },
	},
} :: { [string]: { Schema.Pool } }
]==],
	},
}

--[[
	A new pack's modules: { { path = "pack.luau", text = ... }, ... } (paths inside the pack's
	folder), each a commented example to edit, in the Ores pack's style.
]]
function ContentTool.scaffold(pack: string, order: number): { { path: string, text: string } }
	local values = ContentTool.scaffoldNames(pack)
	values.order = number(order)
	local files = {}
	for _, template in TEMPLATES do
		local text = string.gsub(template.text, "%$(%a+)", function(key: string): string
			return assert(values[key], `scaffold: no value for ${key}`)
		end)
		table.insert(files, { path = template.path, text = text })
	end
	return files
end

return ContentTool
