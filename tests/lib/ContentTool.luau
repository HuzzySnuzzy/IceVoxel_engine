--[[
	The content tool's workings (tests/content), pure: given a View of the game (lib/ContentGame:
	the merged content packs, where each entry came from and what the registries make of them)
	it finds what a pack's author likely forgot, lists and shows entries, and writes a new pack's
	modules as text. It reads no file and prints nothing: tests/content does that, and
	tests/spec/ContentTool runs it on fixture packs.

	  check(view)       the findings (Finding: pack, level, check, subject, text), pack by pack in
	                    load order:
	    lore      warning  a block that is an item, or an item, without a lore line where the game
	                       finds one (Items/LoreList: its entry's `lore`, a pack's `lore`; a brewed
	                       potion item's: its potion's `lore`, by the item's form)
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
	                       wants that `age` (a brewed potion item: its potion's `age`, by form).
	                       (A result no Age names is no mistake by itself: the first Age is every
	                       result's unless an Age names it.)
	    recipe    warning  a crafting recipe that never crafts: its own grid (one of each key or
	                       ingredient, a tag's first name, from the top left of the 3 x 3 grid)
	                       makes something else, since Crafting.match takes the first recipe that
	                       fits (every shaped one before any shapeless one); and a smelting recipe
	                       that never smelts, as an earlier one takes its input (or one of its
	                       tag's items: Crafting/Smelting takes the first recipe for an input).
	                       The finding names the recipe that wins, and when it is an earlier
	                       pack's how to replace it: an override of its name (name = "Stone",
	                       override = true)
	    loot      warning  a loot table nothing rolls: no block's `loot` names it and it is no
	                       chest's (the View's `chests`: the ruins', bunkers' and mineshafts')
	    requires  warning  a pack naming entries of a pack that loads before it (its own modules'
	                       names, `references`, and its potions' brewed recipes'), which it does
	                       not require, directly or through the packs it requires: a finding per
	                       pack named, with the first names and the `requires` to write
	              info     the same of a pack loading after it, which no `requires` can say (a
	                       pack's requires load first): the two stand only together
	    survival  info     an item survival play never gives (`reach`), and why: the first thing
	                       on its way that nothing gives (a block that alone drops it, which the
	                       world never makes; an item no recipe, loot table, drop, mob drop,
	                       structure or other way gives), followed through its recipes rather than
	                       round a loop of items made from each other. Creative only items, the
	                       creative tier's machines (a machine kind with `creative`: Mekanism's
	                       creative energy cube, which no recipe makes by design), fluids' blocks
	                       (buckets carry those) and blocks the world makes (found there, even when
	                       they break into something else: ores, grass, ice) are left out
	  report(view, findings)    the check's lines: a summary per pack, the findings, the counts
	  summary(view)             a line per pack: its order and how much of each kind it holds
	  count(findings, level), verdict(findings)   how many of a level; what `new` says ("1 finding")
	  list(view, kind?, pack?)  lines of entries (id, name, pack), of one kind, of one pack (a sound
	                            event with its number, a track with its set, a recipe by its place
	                            and name, every lore line the game has, fuel by tag and by entry);
	                            nil and why for a kind or pack it has not, with the nearest ("no
	                            kind or pack block (did you mean blocks?)")
	  show(view, name)          lines about everything named `name` (a block, item, recipe,
	                            texture, loot table, tag, ore feature, Age, skill, biome, effect,
	                            potion, structure template, pool, structure, sound event or
	                            track): its merged fields (whole: a long one over several lines,
	                            `valueLines`), id, pack and the overrides that patched it (each
	                            one's pack, and its file in a kind folder: "Patch's
	                            blocks/stone"), and what the registries made of it (every way
	                            survival gets an item in its first Age; a recipe's place; a
	                            skill's cell, the nodes needing it, the entries it gates and their
	                            recipes; a potion's brewed items; a template's size and palette;
	                            an event's number and the entries naming it; a cave mood's event);
	                            nil and the nearest names when nothing has the name
	  reach(view)               when survival play first gives each item (an Age index), how, and
	                            every way it does then
	  references(kind, data, file, add, head?)   every name one pack module gives of another
	                            thing, as the pack wrote it (the `requires` check's)
	  scaffold(view, name, order)   a new pack's modules, { { path, text } }: one block, one item,
	                            a shaped and a smelting recipe, a texture and a loot table, each
	                            field explained, its header naming a module of the game's packs to
	                            copy for each other kind and saying where `order` puts it, ready to
	                            load and to pass `check`, however many new packs there are
	  scaffoldGrid(view)        the grid of cobblestone around a coal its recipe takes: one no
	                            recipe takes yet
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
	  variants(potion) a potion's items (Effects/PotionList.variants)
	  templateHead(text)   a structure template's name, size and palette (Structures/TemplateText
	                   .head; optional)
	  chests           the loot tables the game's code rolls into chests, by name (optional: no
	                   `loot` check without it)
	  packData         each pack's own modules' data, before merging (ContentGame's; optional: no
	                   `requires` check without it)

	Where an entry comes from is the loader's own record (content.origin): the pack and file that
	made it, the packs whose overrides patched it, a recipe's place in its file and its name, the
	packs that put names in a tag. A potion's brewed items and recipes are its pack's, their file
	"potion <Name>" (as the loader names them).
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
	-- (A recipe never crafted or never smelted.)
	{ id = "recipe", label = "never used" },
	{ id = "loot", label = "unused loot" },
	{ id = "requires", label = "requires" },
	{ id = "survival", label = "out of reach" },
})

-- The grid recipes are tried in (a crafting table's).
ContentTool.GRID = 3
-- The widest line `show` writes: a longer field's table goes over several lines, an element or
-- a field a line, lists of names and sentences wrap (nothing is cut; a string longer than the
-- line stays whole on its own).
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

--[[
	`head .. value .. tail` as lines no wider than WIDTH where it can be: on one line when it fits,
	else a table opened on the first line, an element or a field a line (the same way, one indent
	deeper), closed under `indent`. Nothing is cut: a string longer than a line stays whole.
]]
local function valueLines(head: string, value: any, indent: string, tail: string): { string }
	local one = head .. inline(value) .. tail
	if #one <= ContentTool.WIDTH or type(value) ~= "table" or next(value) == nil then
		return { one }
	end
	local lines = { head .. "{" }
	local inner = indent .. "    "
	local function add(each: { string })
		table.move(each, 1, #each, #lines + 1, lines)
	end
	if isList(value) then
		for _, element in value do
			add(valueLines(inner, element, inner, ","))
		end
	else
		for _, key in sortedKeys(value) do
			local name = if type(key) == "string" and identifier(key) then key else `[{inline(key)}]`
			add(valueLines(`{inner}{name} = `, value[key], inner, ","))
		end
	end
	table.insert(lines, indent .. "}" .. tail)
	return lines
end
ContentTool.valueLines = valueLines

-- `head .. text` wrapped at WIDTH between words, the lines after the first under the text's start.
local function prose(head: string, text: string): { string }
	local lines = {}
	local line = head
	local indent = string.rep(" ", #head)
	for word in string.gmatch(text, "%S+") do
		if #line + 1 + #word > ContentTool.WIDTH and line ~= head and line ~= indent then
			table.insert(lines, line)
			line = indent
		end
		line ..= (if line == head or line == indent then "" else " ") .. word
	end
	table.insert(lines, line)
	return lines
end
ContentTool.prose = prose

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
local function patchedBy(view: any, kind: string, name: string | number): { string }
	local origin = view.content.origin(kind, name)
	return if origin then origin.patched else {}
end

-- The same, each override's pack and its kind folder's file when it is one ("Patch's
-- blocks/stone", "Gamma"), as the loader's `where` names them.
local function overridesOf(view: any, kind: string, name: string | number): { string }
	local origin = view.content.origin(kind, name)
	local list = {}
	for _, patch in if origin then origin.overrides or {} else {} do
		table.insert(list, if patch.file then `{patch.pack}'s {patch.file}` else patch.pack)
	end
	return list
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

-- A merged recipe's name (the loader gives each one: its own, else its result's).
local function recipeName(recipe: any): string
	return recipe.name or recipe.result
end

-- "recipe #3 (Torch)": as the loader names it, by the recipe's place in its pack (or file) and
-- its name.
local function recipeSubject(view: any, index: number): string
	local _, place = recipeFrom(view, index)
	return `{place} ({recipeName(view.content.recipes[index])})`
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
	-- Item name -> how ("breaking Stone (found in the world)", "pack Minecraft, recipe ...", "loot
	-- table house"): the first of `ways`.
	how: { [string]: string },
	-- Item name -> every way that gives it in that Age: breaking blocks first (those found the same
	-- way in one: "breaking OakLeaves and BirchLeaves (found in the world)"), then recipes, then
	-- what turns one item into another, then chests and mobs.
	ways: { [string]: { string } },
}

-- The order `ways` lists them in.
local BREAKING, RECIPE, CONVERT, FOUND = 1, 2, 3, 4

--[[
	When survival play first gives each item, and how: what needs nothing (`view.found`: loot
	tables, chests, mobs' drops) in the first Age; breaking a block the world makes, in the first
	Age, or one an item placed, once that item is had; a recipe once every ingredient is had (a
	tag: any of its names) and its result's Age is reached (results no Age names: the first);
	`view.converts` once their item (and the block they need in the world) is had. The least
	fixed point: each item's earliest Age over all its ways, and every way giving it then.
]]
function ContentTool.reach(view: any): Reach
	if view.__reach then
		return view.__reach
	end
	local content = view.content
	local age: { [string]: number } = {}
	-- Item name -> its ways in its earliest Age, and how each ranks (BREAKING...); a block broken,
	-- its name and why it is there.
	type Way = { rank: number, why: string, block: string?, note: string? }
	local found: { [string]: { Way } } = {}
	local function give(name: string, at: number, why: string, rank: number, block: string?, note: string?): boolean
		local now = age[name] or INF
		local way = { rank = rank, why = why, block = block, note = note }
		if at < now then
			age[name] = at
			found[name] = { way }
			return true
		elseif at == now then
			-- (Another way in the same Age: kept, once, for `show`.)
			for _, other in found[name] do
				if other.why == why then
					return false
				end
			end
			table.insert(found[name], way)
		end
		return false
	end
	for _, name in sortedKeys(view.found) do
		give(name, 1, view.found[name], FOUND)
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
					local note = blockWhy[spec.name]
					if give(item, at, `breaking {spec.name} ({note})`, BREAKING, spec.name, note) then
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
				if give(recipe.result, at, `pack {pack}, {place} ({recipeText(recipe)})`, RECIPE) then
					changed = true
				end
			end
		end
		for _, convert in view.converts do
			local at = age[convert.from] or INF
			if convert.needs then
				at = math.max(at, blockAt[convert.needs] or INF)
			end
			if at < INF and give(convert.to, at, convert.why, CONVERT) then
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
	local how: { [string]: string } = {}
	local ways: { [string]: { string } } = {}
	for name, list in found do
		-- (By rank, in the order they were found within one.)
		local order: { [any]: number } = {}
		for index, way in list do
			order[way] = index
		end
		table.sort(list, function(a, b): boolean
			if a.rank ~= b.rank then
				return a.rank < b.rank
			end
			return order[a] < order[b]
		end)
		-- (The blocks broken for it the same way, in one: "breaking A and B (found in the world)".)
		local texts: { string } = {}
		local broken: { [string]: { string } } = {}
		local notes: { string } = {}
		for _, way in list do
			if way.block and way.note then
				if broken[way.note] == nil then
					broken[way.note] = {}
					table.insert(notes, way.note)
					table.insert(texts, way.note)
				end
				table.insert(broken[way.note], way.block)
			else
				table.insert(texts, way.why)
			end
		end
		for index, text in texts do
			local blocks = broken[text]
			if blocks and table.find(notes, text) then
				local last = table.remove(blocks) :: string
				local named = if #blocks > 0 then `{table.concat(blocks, ", ")} and {last}` else last
				texts[index] = `breaking {named} ({text})`
			end
		end
		ways[name] = texts
		how[name] = list[1].why
	end
	local result = { age = age, how = how, ways = ways }
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

--[[ What a pack names (the `requires` check) ]]

--[[
	Every name one module of a pack gives of another thing, as the pack wrote it (before merging:
	an override's own fields, not the entry it patches): `add(space, name, where)` for each, where
	`space` is what the name is looked up among ("entry": a block's or an item's name, "block",
	"tag", "texture", "loot", "sound", "effect", "biome", "skill", "age", "template", "pool",
	"potion", "structure", "track", "recipe") and `where` the entry giving it ("block OilHeater",
	"recipes/fire, recipe #2 (Tnt)"). An override names the entry it patches (a recipe's, or a
	recipe's removal, the recipe of its name: a removed one's pack is no longer known, so it counts
	for none). Joining a tag names no pack (an entry's `tags`, a `tags` module's tag: the Ores
	pack's ores join the Minecraft pack's "ores", which would be theirs alone without it); the
	names a tags module lists do, and so does a "#tag" an ingredient takes (its first pack's).
	`kind` is the module's kind, `data` its data, `file` its kind folder's file (nil: the kind's
	module); `head(text)` reads a template's palette (Structures/TemplateText.head; nil: templates
	name nothing here).
]]
function ContentTool.references(
	kind: string,
	data: any,
	file: string?,
	add: (space: string, name: string, where: string) -> (),
	head: ((string) -> any)?
)
	if type(data) ~= "table" then
		return
	end
	-- A name or "#tag" (recipes and potions take both).
	local function ingredient(name: any, where: string)
		if type(name) ~= "string" then
			return
		end
		if string.sub(name, 1, 1) == "#" then
			add("tag", string.sub(name, 2), where)
		else
			add("entry", name, where)
		end
	end
	local function pools(list: any, where: string)
		for _, pool in if type(list) == "table" then list else {} do
			for _, entry in pool.entries or {} do
				if type(entry[1]) == "string" then
					add("entry", entry[1], where)
				end
			end
		end
	end
	-- The effects a food or a drink gives or cures, its sound and its empty container.
	local function consumed(entry: any, where: string)
		for _, field in { "food", "drink" } do
			local use = entry[field]
			if type(use) == "table" then
				for _, given in use.effects or {} do
					add("effect", given.effect, where)
				end
				for _, cured in use.cures or {} do
					add("effect", cured, where)
				end
				if type(use.aftermath) == "table" then
					add("effect", use.aftermath.effect, where)
				end
				if use.sound then
					add("sound", use.sound, where)
				end
				for _, other in { use.empty, use.purified } do
					add("entry", other, where)
				end
			end
		end
	end
	-- A pool or the templates under a name (a fallback, a start pool: Structures/Library's lookup).
	local function pool(name: any, where: string)
		if type(name) == "string" then
			add("pool", name, where)
		end
	end
	local function entries(singular: string, nameField: string, each: (entry: any, where: string) -> ())
		for _, entry in data do
			if type(entry) == "table" then
				local name = entry[nameField]
				local where = `{singular} {name}`
				if entry.override == true then
					add(if singular == "ore feature" then "ore" else singular, name, where)
				end
				each(entry, where)
			end
		end
	end
	local function blockOrItem(entry: any, where: string)
		for _, field in { "drops", "shearDrops", "item", "fills" } do
			if type(entry[field]) == "string" then
				add("entry", entry[field], where)
			end
		end
		for _, field in { "caveTwin", "places", "lit" } do
			if type(entry[field]) == "string" then
				add("block", entry[field], where)
			end
		end
		if type(entry.plant) == "table" then
			for _, field in { "top", "bottom" } do
				if entry.plant[field] then
					add("block", entry.plant[field], where)
				end
			end
		end
		if type(entry.toggle) == "table" then
			add("block", entry.toggle.to, where)
			if entry.toggle.sound then
				add("sound", entry.toggle.sound, where)
			end
		end
		for _, sound in if type(entry.sounds) == "table" then entry.sounds else {} do
			add("sound", sound, where)
		end
		for _, field in { "workSound", "equipSound" } do
			if type(entry[field]) == "string" then
				add("sound", entry[field], where)
			end
		end
		for _, texture in if type(entry.texture) == "table" then entry.texture else {} do
			add("texture", texture, where)
		end
		if type(entry.loot) == "string" then
			add("loot", entry.loot, where)
		else
			pools(entry.loot, where)
		end
		if type(entry.age) == "string" then
			add("age", entry.age, where)
		end
		if type(entry.skill) == "string" then
			add("skill", entry.skill, where)
		end
		consumed(entry, where)
	end
	if kind == "blocks" then
		entries("block", "name", blockOrItem)
	elseif kind == "items" then
		entries("item", "name", blockOrItem)
	elseif kind == "recipes" then
		for index, recipe in data do
			local name = recipe.name or recipe.result
			local where = `{if file then `{file}, ` else ""}recipe #{index} ({name})`
			-- (An override or a removal names the recipe it replaces.)
			if recipe.override == true or recipe.remove == true then
				add("recipe", name, where)
			end
			if recipe.result then
				add("entry", recipe.result, where)
			end
			for _, name in recipe.ingredients or {} do
				ingredient(name, where)
			end
			for _, name in recipe.key or {} do
				ingredient(name, where)
			end
			ingredient(recipe.input, where)
		end
	elseif kind == "tags" then
		for tag, names in data do
			for _, name in names do
				add("entry", name, `tag {tag}`)
			end
		end
	elseif kind == "textures" then
		for name, texture in data do
			if texture.override == true then
				add("texture", name, `texture {name}`)
			end
			if type(texture.Tint) == "string" then
				add("block", texture.Tint, `texture {name}`)
			end
		end
	elseif kind == "loot" then
		for name, list in data do
			pools(list, `loot table {name}`)
		end
	elseif kind == "ores" then
		entries("ore feature", "name", function(ore, where)
			add("block", ore.block, where)
		end)
	elseif kind == "ages" then
		entries("Age", "id", function(age, where)
			for _, milestone in age.milestones or {} do
				if milestone.key and (milestone.category == "craft" or milestone.category == "smelt") then
					add("entry", milestone.key, where)
				elseif milestone.key and milestone.category == "mine" then
					add("block", milestone.key, where)
				end
			end
		end)
	elseif kind == "skills" then
		entries("skill", "id", function(skill, where)
			if skill.age then
				add("age", skill.age, where)
			end
			if skill.icon then
				add("entry", skill.icon, where)
			end
			for _, required in skill.requires or {} do
				add("skill", required, where)
			end
		end)
	elseif kind == "lore" then
		for name in data do
			add("entry", name, `lore {name}`)
		end
	elseif kind == "fuel" then
		for tag in data do
			add("tag", tag, `fuel {tag}`)
		end
	elseif kind == "biomes" then
		entries("biome", "name", function(biome, where)
			for _, field in { "top", "filler", "steep", "underwater", "beach" } do
				if type(biome[field]) == "string" then
					add("block", biome[field], where)
				end
			end
			if type(biome.patches) == "table" and biome.patches.block then
				add("block", biome.patches.block, where)
			end
			local foliage = if type(biome.foliage) == "table" then biome.foliage else {}
			for _, list in
				{ foliage.plants or {}, (foliage.flowers or {}).species or {}, (foliage.herbs or {}).species or {} }
			do
				for _, weighted in list do
					add("block", weighted[1], where)
				end
			end
		end)
	elseif kind == "effects" then
		entries("effect", "name", function() end)
	elseif kind == "potions" then
		entries("potion", "name", function(potion, where)
			ingredient(potion.ingredient, where)
			if potion.effect then
				add("effect", potion.effect, where)
			end
		end)
	elseif kind == "templates" then
		for name, text in data do
			local read = if head and type(text) == "string" then head(text) else nil
			for _, block in if read then read.blocks else {} do
				add("block", block, `template {name}`)
			end
		end
	elseif kind == "pools" then
		for name, entry in data do
			local where = `pool {name}`
			if entry.override == true then
				add("pool", name, where)
			end
			for _, element in entry.elements or {} do
				if element.template then
					add("template", element.template, where)
				end
			end
			pool(entry.fallback, where)
		end
	elseif kind == "structures" then
		entries("structure", "name", function(structure, where)
			pool(structure.startPool, where)
			for _, biome in structure.biomes or {} do
				add("biome", biome, where)
			end
		end)
	elseif kind == "sounds" then
		entries("sound", "name", function() end)
	elseif kind == "music" then
		entries("track", "name", function() end)
	end
end

-- ContentTool.references' spaces and the kinds they are (an "entry" is a block's or an item's).
local SPACES = table.freeze({
	block = "blocks",
	item = "items",
	tag = "tags",
	texture = "textures",
	loot = "loot",
	sound = "sounds",
	effect = "effects",
	biome = "biomes",
	skill = "skills",
	age = "ages",
	Age = "ages",
	template = "templates",
	potion = "potions",
	structure = "structures",
	track = "music",
	ore = "ores",
	recipe = "recipes",
})

-- The pack that made what `name` names among `space` (ContentTool.references'), nil when none
-- did (the names of things no pack makes: a fallback "minecraft:empty", a tree builder).
local function ownerOf(view: any, space: string, name: string): string?
	local content = view.content
	local origin
	if space == "entry" then
		origin = content.origin("blocks", name) or content.origin("items", name)
	elseif space == "pool" then
		-- (A pool, or a template by that name, or the templates under it: their first's pack.)
		origin = content.origin("pool", name) or content.origin("template", name)
		if origin == nil then
			for _, template in sortedKeys(content.templates) do
				if string.sub(template, 1, #name + 1) == name .. "/" then
					origin = content.origin("template", template)
					break
				end
			end
		end
	else
		origin = content.origin(SPACES[space] or space, name)
	end
	return if origin then origin.pack else nil
end

--[[
	The `requires` check (the header's): for each pack, the packs whose entries it names (its own
	modules' data, the View's `packData`, and its potions' brewed recipes) that it does not require,
	directly or through the packs it requires. A pack loading before it: a warning (`requires`
	says so: add it); one loading after: an info (no `requires` can, as a pack's requires load
	first: the two packs stand only together). One finding per pack and pack named, with the first
	few names.
]]
local function requiresFindings(view: any): { Finding }
	local findings: { Finding } = {}
	if view.packData == nil then
		return findings
	end
	local content = view.content
	local packIndex = packIndexOf(view)
	local requiresOf: { [string]: { string } } = {}
	for _, pack in view.packs do
		requiresOf[pack.name] = pack.requires or {}
	end
	-- Every pack `pack` requires, directly or through them.
	local function closure(pack: string): { [string]: boolean }
		local all: { [string]: boolean } = {}
		local function visit(name: string)
			for _, required in requiresOf[name] or {} do
				if not all[required] then
					all[required] = true
					visit(required)
				end
			end
		end
		visit(pack)
		return all
	end
	local SHOWN = 3
	for _, info in view.packs do
		local pack = info.name
		local data = view.packData[pack]
		if data == nil then
			continue
		end
		local required = closure(pack)
		-- Owner -> the names given of its, each once, and where each was first given.
		local named: { [string]: { string } } = {}
		local firstWhere: { [string]: { [string]: string } } = {}
		local owners: { string } = {}
		local function add(space: string, name: string, where: string)
			if type(name) ~= "string" then
				return
			end
			local owner = ownerOf(view, space, name)
			if owner == nil or owner == pack or required[owner] then
				return
			end
			local list = named[owner]
			if list == nil then
				list = {}
				named[owner] = list
				firstWhere[owner] = {}
				table.insert(owners, owner)
			end
			if firstWhere[owner][name] == nil then
				firstWhere[owner][name] = where
				table.insert(list, name)
			end
		end
		for _, kind in view.kinds do
			ContentTool.references(kind, data.kinds[kind], nil, add, view.templateHead)
			for _, each in (data.folders[kind] or {}) :: { any } do
				ContentTool.references(kind, each.data, each.file, add, view.templateHead)
			end
		end
		-- (Its potions' brewed recipes: the loader makes them, from its potions.)
		for index, recipe in content.recipes do
			local origin = content.origin("recipe", index)
			if origin and origin.pack == pack and origin.file and string.sub(origin.file, 1, 7) == "potion " then
				ContentTool.references("recipes", { recipe }, origin.file, function(space, name, _where)
					add(space, name, `{origin.file}, recipe #{origin.index} ({recipeName(recipe)})`)
				end)
			end
		end
		table.sort(owners, function(a: string, b: string): boolean
			return (packIndex[a] or INF) < (packIndex[b] or INF)
		end)
		for _, owner in owners do
			local list = named[owner]
			local texts = {}
			for index = 1, math.min(#list, SHOWN) do
				table.insert(texts, `{list[index]} ({firstWhere[owner][list[index]]})`)
			end
			local shown = table.concat(texts, ", ")
			local more = if #list > SHOWN then ` and {#list - SHOWN} more` else ""
			local before = (packIndex[owner] or INF) < (packIndex[pack] or INF)
			local text
			if before then
				local wanted = table.clone(info.requires or {})
				table.insert(wanted, owner)
				for index, name in wanted do
					wanted[index] = quote(name)
				end
				text =
					`it names pack {owner}'s {shown}{more}, but requires neither {owner} nor a pack requiring it: requires = \{ {table.concat(
						wanted,
						", "
					)} }?`
			else
				text =
					`it names pack {owner}'s {shown}{more}, and {owner} loads after it, so no requires can say so: {pack} stands only with {owner}`
			end
			table.insert(findings, {
				pack = pack,
				level = if before then "warning" else "info",
				check = "requires",
				subject = "requires",
				text = text,
			})
		end
	end
	return findings
end

--[[
	A brewed potion item's potion and its form ("base", "strong", "long": its key in the potion's
	`lore`, `icon` and `age`), from where it came from (the loader's "potion <Name>"); nil for any
	other item.
]]
local function brewedFrom(view: any, name: string): (string?, string?)
	local origin = view.content.origin("item", name)
	local potion = if origin and origin.file then string.match(origin.file, "^potion (.+)$") else nil
	if potion == nil then
		return nil, nil
	end
	for _, spec in view.content.potions or {} do
		if spec.name == potion and view.variants then
			for _, variant in view.variants(spec) do
				if variant.item == name then
					return potion, variant.form
				end
			end
		end
	end
	return potion, "base"
end

-- "A", "A and B", "A, B and C".
local function joined(names: { string }, word: string?): string
	if #names <= 1 then
		return names[1] or ""
	end
	return `{table.concat(names, ", ", 1, #names - 1)} {word or "and"} {names[#names]}`
end

--[[
	Why survival never gives an item: a function of its name to a phrase. It follows the item's
	recipes to the first thing on the way that nothing gives for a reason of its own, rather than
	round a loop of items each made from the other (Raw Tin from a Raw Tin Block, the block from
	Raw Tin): a block that would drop it which the world never makes (no ore feature, biome or
	structure places it, nor an item survival has), or an item nothing makes at all.
]]
local function outOfReach(view: any, reach: Reach, recipesOf: { [string]: { number } }): (string) -> string
	local content = view.content
	-- Item name -> the blocks whose breaking gives it (none of them breaks in survival, or it
	-- would be had).
	local droppedBy: { [string]: { string } }? = nil
	local function droppers(item: string): { string }
		if droppedBy == nil then
			local map: { [string]: { string } } = {}
			for _, spec in content.blocks do
				for _, dropped in if view.drops then view.drops(spec.name) else {} do
					if dropped ~= spec.name then
						map[dropped] = map[dropped] or {}
						table.insert(map[dropped], spec.name)
					end
				end
			end
			droppedBy = map
		end
		return (droppedBy :: any)[item] or {}
	end
	-- What `item` (`word`: "it" or its name) lacks itself.
	local function reason(item: string, word: string): string
		local blocks = droppers(item)
		if #blocks > 0 then
			local them = if #blocks > 1 then "them" else "it"
			return `only breaking {joined(blocks, "or")} gives {word}, and the world never makes {them} (no ore feature, biome or structure places {them}, nor an item survival has)`
		end
		local text = `no recipe, loot table, drop, mob drop or structure gives {word}`
		if content.block(item) and not view.world[item] then
			return `the world never makes {word} and {text}`
		end
		return text
	end
	-- The first item on `item`'s way out of reach for a reason of its own (nil: only loops).
	local function root(item: string, seen: { [string]: boolean }): string?
		if seen[item] then
			return nil
		end
		seen[item] = true
		local list = recipesOf[item]
		if #droppers(item) > 0 or list == nil then
			return item
		end
		for _, index in list do
			for _, ingredient in ingredientsOf(content.recipes[index]) do
				if ingredientAge(view, reach.age, ingredient) == INF then
					local names = if string.sub(ingredient, 1, 1) == "#"
						then content.tags[string.sub(ingredient, 2)] or {}
						else { ingredient }
					for _, name in names do
						local found = root(name, seen)
						if found then
							return found
						end
					end
				end
			end
		end
		return nil
	end
	return function(name: string): string
		local cause = root(name, {})
		if cause == name then
			return reason(name, "it")
		end
		local list = recipesOf[name] or {}
		local recipes = if #list == 1 then "its recipe needs" else "its recipes need"
		if cause == nil then
			return `{recipes} items made only from each other (a loop nothing leads into)`
		end
		-- (Straight in a recipe of its, or further on the way.)
		local direct = false
		for _, index in list do
			for _, ingredient in ingredientsOf(content.recipes[index]) do
				direct = direct or takes(view, ingredient, cause)
			end
		end
		return `{recipes} {cause}{if direct then "" else " (on the way)"}, which survival never gives: {reason(
			cause,
			cause
		)}`
	end
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
			-- (A brewed potion item's line is its potion's, by its form.)
			local potion, form = brewedFrom(view, spec.name)
			add(
				pack,
				"warning",
				"lore",
				subject,
				if potion
					then `no lore line (lore = \{ {form} = "..." } on potion {potion}, which brews it)`
					else `no lore line (lore = "..." on its entry)`
			)
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
				-- (A brewed potion item's Age is its potion's, by its form.)
				local potion, form = brewedFrom(view, name)
				local fix = if potion
					then `age = \{ {form} = "{record.id}" } on potion {potion}, which brews it?`
					else `age = "{record.id}"?`
				add(
					packOf(view, kind, name),
					"warning",
					"age",
					`{if kind == "blocks" then "block" else "item"} {name}`,
					`no Age names it, so the {ages[1].name} opens it, but {because}: {fix}`
				)
			end
		end
	end

	-- How a recipe that never works replaces the one winning over it (merged place `winner`), when
	-- that one is a pack's loading before its own: by an override of its name (a recipe's override
	-- replaces it whole, in its place: Content).
	local loadsAt = packIndexOf(view)
	local function replacing(pack: string, winner: number): string
		local winnerPack = recipeFrom(view, winner)
		if (loadsAt[winnerPack] or INF) >= (loadsAt[pack] or INF) then
			return ""
		end
		return `: to replace that recipe, override it (name = "{recipeName(content.recipes[winner])}", override = true)`
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
			local winner, fix = "another recipe", ""
			if #winners == 1 then
				local otherPack, otherPlace = recipeFrom(view, winners[1])
				winner = `pack {otherPack}'s {otherPlace} ({recipeName(content.recipes[winners[1]])})`
				fix = replacing(pack, winners[1])
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
					else `never crafted: its own grid makes {what}, as {winner} fits first (shaped recipes before shapeless){fix}`
			)
		end
	end
	-- Smelting recipes that never smelt: a furnace takes the first recipe for an input
	-- (Crafting/Smelting), so one for an input an earlier recipe takes is never used.
	local smeltedBy: { [string]: number } = {}
	for index, recipe in content.recipes do
		if recipe.type ~= "smelting" then
			continue
		end
		local input = recipe.input :: string
		local inputs = if string.sub(input, 1, 1) == "#" then content.tags[string.sub(input, 2)] or {} else { input }
		local taken: { string } = {}
		for _, name in inputs do
			if smeltedBy[name] then
				table.insert(taken, name)
			else
				smeltedBy[name] = index
			end
		end
		if #taken > 0 then
			local name = taken[1]
			local first = smeltedBy[name]
			local pack = recipeFrom(view, index)
			local otherPack, otherPlace = recipeFrom(view, first)
			add(
				pack,
				"warning",
				"recipe",
				recipeSubject(view, index),
				`never smelted{if #taken < #inputs then ` from {name}` else ""}: {name} smelts into {content.recipes[first].result}, as pack {otherPack}'s {otherPlace} ({recipeName(
					content.recipes[first]
				)}) comes first (a furnace takes the first recipe for an input){replacing(pack, first)}`
			)
		end
	end

	-- Unused loot tables: none a block's `loot` names that is no chest's (the View's `chests`).
	if view.chests then
		local named: { [string]: boolean } = {}
		for _, spec in content.blocks do
			if type(spec.loot) == "string" then
				named[spec.loot] = true
			end
		end
		for _, name in sortedKeys(content.loot) do
			if not named[name] and not view.chests[name] then
				add(
					packOf(view, "loot", name),
					"warning",
					"loot",
					`loot table {name}`,
					"nothing rolls it: no block's loot names it, and it is no chest's (the game's chests roll Generation/ScavengeLoot.NAMES' tables and the mineshafts')"
				)
			end
		end
	end

	-- Requires: the packs a pack names entries of.
	for _, finding in requiresFindings(view) do
		table.insert(findings, finding)
	end

	-- Survival's reach: what it never gives, and why (the first thing on the way that nothing
	-- gives, `outOfReach`, not a loop of items each made from the other).
	local why = outOfReach(view, reach, recipesOf)
	for _, entry in content.entries do
		local name = entry.name
		if not view.isItem[name] or view.creativeOnly[name] or view.creativeMachines[name] or reach.age[name] then
			continue
		end
		local block = content.block(name)
		if block and (view.world[name] or block.render == "Fluid" or block.fluid) then
			continue
		end
		local kind = if block then "blocks" else "items"
		add(
			packOf(view, kind, name),
			"info",
			"survival",
			`{if block then "block" else "item"} {name}`,
			`survival never gives it: {why(name)}`
		)
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
	if
		kind == "blocks"
		or kind == "items"
		or kind == "ores"
		or kind == "biomes"
		or kind == "effects"
		or kind == "potions"
		or kind == "structures"
		or kind == "sounds"
		or kind == "music"
	then
		for _, entry in content[kind] or {} do
			table.insert(names, entry.name)
		end
	elseif kind == "ages" or kind == "skills" then
		for _, record in content[kind] do
			table.insert(names, record.id)
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

-- What `new` says of a new pack's findings: that it passes, or how many ("1 finding").
function ContentTool.verdict(findings: { Finding }): string
	if #findings == 0 then
		return "it loads and passes the check"
	end
	return `{#findings} finding{if #findings == 1 then "" else "s"}`
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
	made or patched): blocks and items with their ids, recipes by their merged place with their
	names (and the overrides that replaced them, by pack and file), biomes by their index
	(Shared/Biomes) with their bands, lore lines (every one the game has: an entry's own or a
	pack's `lore`) and fuel (a tag's, an entry's own) by name with their pack, the rest by name;
	nil and why when the kind or the pack is unknown (with the nearest kind or pack: `list block`
	is no kind, but "blocks?").
]]
function ContentTool.list(view: any, kind: string?, pack: string?): ({ string }?, string?)
	local content = view.content
	local packNames = {}
	for _, info in view.packs do
		table.insert(packNames, info.name)
	end
	-- " (did you mean x?)" for a word near one of `names`.
	local function near(word: string, names: { string }): string
		local set = {}
		for _, name in names do
			set[name] = true
		end
		local hint = if view.suggest then view.suggest(word, set) else nil
		return if hint then ` (did you mean {hint}?)` else ""
	end
	if kind and not table.find(view.kinds, kind) then
		return nil, `no kind {kind}{near(kind, view.kinds)} (kinds: {table.concat(view.kinds, ", ")})`
	end
	if pack and packIndexOf(view)[pack] == nil then
		-- (One word, no kind: it may be either.)
		if kind == nil then
			local both = table.clone(view.kinds)
			table.move(packNames, 1, #packNames, #both + 1, both)
			return nil,
				`no kind or pack {pack}{near(pack, both)} (kinds: {table.concat(view.kinds, ", ")}; packs: {table.concat(
					packNames,
					", "
				)})`
		end
		return nil, `no pack {pack}{near(pack, packNames)} (packs: {table.concat(packNames, ", ")})`
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
			-- (Its merged place, its name, what it is, where it is from: made or patched there.)
			right[1] = true
			for index, recipe in content.recipes do
				local from, place = recipeFrom(view, index)
				local by = overridesOf(view, "recipes", index)
				if pack == nil or from == pack or table.find(patchedBy(view, "recipes", index), pack) then
					local patches = if #by > 0 then ` (patched by {table.concat(by, ", ")})` else ""
					table.insert(
						rows,
						{ `#{index}`, recipeName(recipe), recipeText(recipe), `{from}{patches}, {place}` }
					)
				end
			end
		elseif each == "ores" then
			for _, ore in content.ores do
				if listed(view, each, ore.name, pack) then
					table.insert(rows, { ore.name, ore.block, packOf(view, each, ore.name) })
				end
			end
		elseif each == "structures" then
			for _, structure in content.structures do
				if listed(view, each, structure.name, pack) then
					table.insert(rows, { structure.name, structure.startPool, madeText(view, each, structure.name) })
				end
			end
		elseif each == "ages" then
			right[1] = true
			for index, age in content.ages do
				if listed(view, each, age.id, pack) then
					table.insert(rows, { tostring(index), age.id, age.name, packOf(view, each, age.id) })
				end
			end
		elseif each == "skills" then
			-- (Its place, the protocol's; its id and name; its cell on the skill tree screen.)
			right[1] = true
			for index, skill in content.skills or {} do
				if listed(view, each, skill.id, pack) then
					table.insert(rows, {
						tostring(index),
						skill.id,
						skill.name,
						`{skill.age} row {number(skill.row)}`,
						madeText(view, each, skill.id),
					})
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
		elseif each == "effects" then
			right[1] = true
			for _, effect in content.effects or {} do
				if listed(view, each, effect.name, pack) then
					local id = tostring(content.effectId[effect.name])
					table.insert(rows, { id, effect.name, effect.category, madeText(view, each, effect.name) })
				end
			end
		elseif each == "potions" then
			for _, potion in content.potions or {} do
				if listed(view, each, potion.name, pack) then
					local n = 1 + (if potion.strong then 1 else 0) + (if potion.long then 1 else 0)
					table.insert(rows, {
						potion.name,
						`{potion.effect}, {n} item{if n == 1 then "" else "s"}`,
						madeText(view, each, potion.name),
					})
				end
			end
		elseif each == "sounds" then
			-- (An event's number is its place: the cave moods' events come after, the tracks'.)
			right[1] = true
			for index, spec in content.sounds do
				if listed(view, each, spec.name, pack) then
					table.insert(rows, { `#{index}`, spec.name, madeText(view, each, spec.name), spec.category or "" })
				end
			end
		elseif each == "music" then
			for _, spec in content.music do
				if listed(view, each, spec.name, pack) then
					table.insert(rows, { spec.name, spec.set, madeText(view, each, spec.name), spec.title or "" })
				end
			end
		elseif each == "lore" then
			-- (Every line the game has, Items/LoreList: an entry's own, by the pack that made the
			-- entry, or a pack's `lore`.)
			for _, name in sortedKeys(view.lore or content.lore) do
				local from = if content.lore[name]
					then packOf(view, "lore", name)
					else packOf(view, if content.block(name) then "blocks" else "items", name)
				if pack == nil or from == pack then
					table.insert(rows, { name, from })
				end
			end
		elseif each == "fuel" then
			-- (A tag's, then every entry's own `fuel`, which beats its tag's.)
			right[2] = true
			for _, tag in sortedKeys(content.fuel) do
				if listed(view, each, tag, pack) then
					table.insert(rows, { `#{tag}`, `{number(content.fuel[tag])} ticks`, packOf(view, each, tag) })
				end
			end
			for _, entry in content.entries do
				local ticks = (entry :: any).fuel
				if type(ticks) == "number" then
					local kind = if content.block(entry.name) then "blocks" else "items"
					if listed(view, kind, entry.name, pack) then
						table.insert(rows, { entry.name, `{number(ticks)} ticks`, madeText(view, kind, entry.name) })
					end
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
					local note = if each == "textures" and map[name].Color == ""
						then "blank"
						elseif each == "pools" then `{#map[name].elements} elements`
						else ""
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

-- An entry's merged fields, sorted, a line each ("    hardness = 1.5") or more (a long table:
-- `valueLines`).
local function fieldLines(entry: { [string]: any }, skip: { [string]: boolean }?): { string }
	local lines = {}
	for _, key in sortedKeys(entry) do
		if not (skip and skip[key]) then
			for _, line in valueLines(`    {key} = `, entry[key], "    ", "") do
				table.insert(lines, line)
			end
		end
	end
	return lines
end

-- The recipes that make `name` and the ones that use it, a line each ("pack Minecraft,
-- recipes/lights, recipe #1 (Torch): shaped Torch x4": where, its name, what it is).
local function recipeLines(view: any, name: string): { string }
	local content = view.content
	local makes, uses = {}, {}
	for index, recipe in content.recipes do
		local from = recipeFrom(view, index)
		local text = `pack {from}, {recipeSubject(view, index)}: {recipeText(recipe)}`
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

-- The most ways `show` lists of how survival gets an item (the rest are counted).
local SHOWN_WAYS = 6

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
		-- (Every way that gives it in its first Age, a recipe too where a chest gives it as well,
		-- the first few: the rest counted.)
		local reach = ContentTool.reach(view)
		local at = reach.age[name]
		local text = "never"
		if at then
			local ways = table.clone(reach.ways[name] or { reach.how[name] })
			local more = #ways - SHOWN_WAYS
			if more > 0 then
				ways = table.move(ways, 1, SHOWN_WAYS, 1, {})
				table.insert(ways, `and {more} more way{if more == 1 then "" else "s"}`)
			end
			text = `from the {if ages[at] then ages[at].name else `Age {at}`}: {table.concat(ways, "; ")}`
		elseif isBlock and view.world[name] then
			text = `never as an item (the world makes it: {view.world[name]})`
		end
		for _, line in prose("    survival: ", text) do
			table.insert(lines, line)
		end
	end
	for _, line in recipeLines(view, name) do
		table.insert(lines, line)
	end
	return lines
end

--[[
	The structure kinds' lines for `name`: each thing's head line (no indent), then its own lines
	(indented). A template (its size and palette, the pools holding it), a pool (its fields and
	elements, or the templates under its name when it has no entry, and the structures starting
	from it), a structure (its fields).
]]
local function structureLines(view: any, name: string): { string }
	local content = view.content
	local lines = {}
	local function patches(kind: string)
		local by = overridesOf(view, kind, name)
		if #by > 0 then
			table.insert(lines, `  patched by: {table.concat(by, ", ")}`)
		end
	end
	-- The templates a pool draws from (an explicit one's elements, else the templates under it).
	local function members(pool: string): { string }
		local list = {}
		local entry = content.pools[pool]
		if entry then
			for _, element in entry.elements do
				if element.template and not table.find(list, element.template) then
					table.insert(list, element.template)
				end
			end
		elseif content.templates[pool] then
			table.insert(list, pool)
		else
			for _, template in sortedKeys(content.templates) do
				if string.sub(template, 1, #pool + 1) == pool .. "/" then
					table.insert(list, template)
				end
			end
		end
		return list
	end
	-- The structures whose start pool is `pool`.
	local function starting(pool: string): { string }
		local list = {}
		for _, structure in content.structures do
			if structure.startPool == pool then
				table.insert(list, structure.name)
			end
		end
		return list
	end
	local text = content.templates[name]
	if text then
		table.insert(lines, `template {name}: pack {packOf(view, "templates", name)}`)
		local head = if view.templateHead then view.templateHead(text) else nil
		if head then
			table.insert(lines, `  size {head.size[1]} x {head.size[2]} x {head.size[3]}, {#text} characters of text`)
			for _, line in wrap("  palette: ", head.blocks) do
				table.insert(lines, line)
			end
		end
		-- (The explicit pools naming it, and the pool its name puts it in when that has no entry.)
		local pools = {}
		for _, pool in sortedKeys(content.pools) do
			if table.find(members(pool), name) then
				table.insert(pools, pool)
			end
		end
		local parent = string.match(name, "^(.+)/[^/]+$")
		if parent and content.pools[parent] == nil and content.templates[parent] == nil then
			table.insert(pools, parent)
		end
		for _, line in wrap("  in pools: ", if #pools > 0 then pools else { "none (its own name's alone)" }) do
			table.insert(lines, line)
		end
	end
	local pool = content.pools[name]
	local implicit = pool == nil and content.templates[name] == nil and #members(name) > 0
	if pool then
		table.insert(lines, `pool {name}: pack {packOf(view, "pools", name)}`)
		patches("pools")
		table.insert(lines, "  fields:")
		for _, line in fieldLines(pool, { elements = true }) do
			table.insert(lines, line)
		end
		local rows = {}
		for _, element in pool.elements do
			table.insert(rows, {
				element.template or "(empty)",
				`weight {element.weight or 1}`,
				element.projection or "",
			})
		end
		table.insert(lines, "    elements:")
		for _, line in columns(rows, "      ") do
			table.insert(lines, (string.gsub(line, "%s+$", "")))
		end
	elseif implicit then
		table.insert(lines, `pool {name}: the templates named {name}/... (no entry of its own)`)
		for _, line in wrap("  templates: ", members(name)) do
			table.insert(lines, line)
		end
	end
	if pool or implicit or text then
		local users = starting(name)
		if #users > 0 then
			for _, line in wrap("  starts: ", users) do
				table.insert(lines, line)
			end
		end
	end
	for _, structure in content.structures do
		if structure.name == name then
			table.insert(lines, `structure {name}: pack {packOf(view, "structures", name)}`)
			patches("structures")
			table.insert(lines, "  fields:")
			for _, line in fieldLines(structure, { name = true }) do
				table.insert(lines, line)
			end
		end
	end
	return lines
end

--[[
	Lines about everything named `name`: its kind, id and pack, the overrides that patched it (each
	one's pack and file), its merged fields, and for blocks and items what the registries made of
	it. nil and the nearest names when nothing has the name.
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
	-- (Each override's pack and file: "Patch's blocks/stone".)
	local function patches(kind: string, key: (string | number)?)
		local by = overridesOf(view, kind, key or name)
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
	-- A recipe by its name (its own, or its result's: Content), its place among every recipe and in
	-- its file.
	for index, recipe in content.recipes do
		if recipeName(recipe) == name then
			local from, place = recipeFrom(view, index)
			section(`recipe {name}: #{index} of {#content.recipes}, pack {from}, {place}`)
			patches("recipes", index)
			table.insert(lines, "  fields:")
			for _, line in fieldLines(recipe, { name = true }) do
				table.insert(lines, line)
			end
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
			for _, line in valueLines(`  pool {index}: `, pool, "  ", "") do
				table.insert(lines, line)
			end
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
	for _, line in structureLines(view, name) do
		if line == "" or string.sub(line, 1, 1) ~= " " then
			section(line)
		else
			table.insert(lines, line)
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
	for index, skill in content.skills or {} do
		if skill.id == name then
			section(
				`skill {name}: {skill.name}, node {index} of {#content.skills}, pack {packOf(view, "skills", name)}`
			)
			patches("skills")
			table.insert(lines, "  fields:")
			for _, line in fieldLines(skill, { id = true }) do
				table.insert(lines, line)
			end
			table.insert(lines, "  derived:")
			local ageName = skill.age
			for _, age in content.ages do
				if age.id == skill.age then
					ageName = age.name
				end
			end
			table.insert(lines, `    cell: the {ageName}'s column, row {number(skill.row)}`)
			local neededBy = {}
			for _, other in content.skills do
				if table.find(other.requires or {}, name) then
					table.insert(neededBy, other.id)
				end
			end
			for _, line in wrap("    needed by: ", if #neededBy > 0 then neededBy else { "no node" }) do
				table.insert(lines, line)
			end
			-- What it gates: the entries naming it, and the recipes making them.
			local gated, recipes = {}, {}
			for _, entry in content.entries do
				if entry.skill == name then
					table.insert(gated, entry.name)
				end
			end
			for at, recipe in content.recipes do
				if table.find(gated, recipe.result) then
					local from = recipeFrom(view, at)
					table.insert(recipes, `      pack {from}, {recipeSubject(view, at)}: {recipeText(recipe)}`)
				end
			end
			for _, line in wrap("    gates: ", if #gated > 0 then gated else { "nothing (no entry names it)" }) do
				table.insert(lines, line)
			end
			if #recipes > 0 then
				table.insert(lines, "    gated recipes:")
				for _, line in recipes do
					table.insert(lines, line)
				end
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
				for _, line in valueLines(`    foliage.{key} = `, foliage[key], "    ", "") do
					table.insert(lines, line)
				end
			end
		end
	end
	for _, effect in content.effects or {} do
		if effect.name == name then
			section(`effect {name}: id {content.effectId[name]}, pack {packOf(view, "effects", name)}`)
			patches("effects")
			table.insert(lines, "  fields:")
			for _, line in fieldLines(effect, { name = true }) do
				table.insert(lines, line)
			end
			local potions = {}
			for _, potion in content.potions or {} do
				if potion.effect == name then
					table.insert(potions, potion.name)
				end
			end
			if #potions > 0 then
				for _, line in wrap("  potions: ", potions) do
					table.insert(lines, line)
				end
			end
		end
	end
	for _, potion in content.potions or {} do
		if potion.name == name then
			section(`potion {name}: pack {packOf(view, "potions", name)}`)
			patches("potions")
			table.insert(lines, "  fields:")
			for _, line in fieldLines(potion, { name = true }) do
				table.insert(lines, line)
			end
			if view.variants then
				table.insert(lines, "  items (brewed):")
				for _, variant in view.variants(potion) do
					local id = content.itemId[variant.item]
					local text =
						`{variant.displayName}, {variant.effect} {variant.amplifier + 1} for {variant.ticks} ticks, {variant.from} + {variant.with}`
					for _, line in prose(`    {variant.item} (id {id}): `, text) do
						table.insert(lines, line)
					end
				end
			end
		end
	end
	-- A sound event, and what names it (blocks' and items' sound fields).
	for index, spec in content.sounds or {} do
		if spec.name == name then
			section(`sound {name}: number {index}, pack {packOf(view, "sounds", name)}`)
			patches("sounds")
			table.insert(lines, "  fields:")
			for _, line in fieldLines(spec, { name = true }) do
				table.insert(lines, line)
			end
			local users = {}
			for _, block in content.blocks do
				local own = block.sounds or {}
				for _, action in sortedKeys(own) do
					if own[action] == name then
						table.insert(users, `{block.name} ({action})`)
					end
				end
				if block.workSound == name then
					table.insert(users, `{block.name} (working)`)
				end
				if block.toggle and block.toggle.sound == name then
					table.insert(users, `{block.name} (toggled)`)
				end
			end
			for _, item in content.items do
				if item.equipSound == name then
					table.insert(users, `{item.name} (put on)`)
				end
				if item.food and item.food.sound == name then
					table.insert(users, `{item.name} (used)`)
				end
			end
			if #users > 0 then
				for _, line in wrap("  named by: ", users) do
					table.insert(lines, line)
				end
			end
		end
	end
	-- A track (and a cave mood's event by its name: ambient.cave.<track>).
	local moodName = string.match(name, "^ambient%.cave%.(.+)$")
	for _, spec in content.music or {} do
		if spec.name == name or (spec.set == "mood" and spec.name == moodName) then
			section(`track {spec.name}: {spec.set}, pack {packOf(view, "music", spec.name)}`)
			patches("music", spec.name)
			table.insert(lines, "  fields:")
			for _, line in fieldLines(spec, { name = true }) do
				table.insert(lines, line)
			end
			if spec.set == "mood" then
				table.insert(lines, `  event: ambient.cave.{spec.name} (a cave mood, after every pack's sounds)`)
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
	for _, recipe in content.recipes do
		names[recipeName(recipe)] = true
	end
	for _, map in { content.textures, content.loot, content.tags, content.templates, content.pools } do
		for key in map do
			names[key] = true
		end
	end
	for _, list in { content.ores, content.structures } do
		for _, each in list do
			names[each.name] = true
		end
	end
	for _, age in content.ages do
		names[age.id] = true
	end
	for _, skill in content.skills or {} do
		names[skill.id] = true
	end
	for _, biome in content.biomes or {} do
		names[biome.name] = true
	end
	for _, list in { content.effects or {}, content.potions or {} } do
		for _, entry in list do
			names[entry.name] = true
		end
	end
	for _, list in { content.sounds or {}, content.music or {} } do
		for _, spec in list do
			names[spec.name] = true
		end
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
	if ContentTool.scaffoldGrid(view) == nil then
		return "every grid of cobblestone around a coal is some recipe's already: the example recipe has none left"
	end
	return nil
end

--[[
	The shaped recipe's grid for a new pack's block (rows of "S", cobblestone, and "C", a coal):
	the first of these that no recipe of the game takes yet (the View's `craft` makes nothing of
	it), so each new pack's example crafts, however many there are. The nicer shapes first, then
	every other set of cobblestone around the coal. nil: every one is taken.
]]
local NICE_GRIDS = {
	{ "S S", " C ", "S S" },
	{ " S ", "SCS", " S " },
	{ "S S", "SCS", "S S" },
	{ "SSS", " C ", "SSS" },
	{ "S S", "SCS", " S " },
	{ "SSS", "SC ", "S  " },
}
function ContentTool.scaffoldGrid(view: any): { string }?
	local candidates = table.clone(NICE_GRIDS)
	-- (Every set of two or more of the eight cells around the coal, the fullest first: rows and
	-- columns left empty are trimmed, as a pattern fits anywhere in the grid.)
	local masks = {}
	for mask = 0, 255 do
		local cells = 0
		for bit = 0, 7 do
			cells += bit32.extract(mask, bit)
		end
		if cells >= 2 then
			table.insert(masks, { mask = mask, cells = cells })
		end
	end
	table.sort(masks, function(a, b)
		return if a.cells ~= b.cells then a.cells > b.cells else a.mask < b.mask
	end)
	-- (The eight cells around the centre, as grid places 1..9.)
	local AROUND = { 1, 2, 3, 4, 6, 7, 8, 9 }
	for _, each in masks do
		local cells = { " ", " ", " ", " ", "C", " ", " ", " ", " " }
		for bit = 0, 7 do
			if bit32.extract(each.mask, bit) == 1 then
				cells[AROUND[bit + 1]] = "S"
			end
		end
		local rows = {}
		for y = 0, 2 do
			table.insert(rows, table.concat(cells, "", y * 3 + 1, y * 3 + 3))
		end
		-- (Trimmed: empty rows, then empty columns.)
		while rows[1] and string.match(rows[1], "^%s*$") do
			table.remove(rows, 1)
		end
		while rows[#rows] and string.match(rows[#rows], "^%s*$") do
			table.remove(rows)
		end
		for _, side in { "left", "right" } do
			local empty = true
			while empty do
				for _, row in rows do
					local char = if side == "left" then string.sub(row, 1, 1) else string.sub(row, -1)
					empty = empty and char == " "
				end
				if empty then
					for index, row in rows do
						rows[index] = if side == "left" then string.sub(row, 2) else string.sub(row, 1, -2)
					end
				end
			end
		end
		table.insert(candidates, rows)
	end
	local key = { S = "#stone_crafting_materials", C = "#coals" }
	for _, pattern in candidates do
		local grid = gridOf(view, { type = "shaped", pattern = pattern, key = key })
		if grid and view.craft(grid, ContentTool.GRID) == nil then
			return pattern
		end
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
	$Pack: one feature's content in one pack. `lune run tests/content new $Pack` made it with an
	example of five kinds to rename, edit or delete: a block (blocks), an item (items), a shaped
	and a smelting recipe (recipes), a texture (textures) and a loot table (loot). Every other
	kind's example is a module of the game's packs, to copy from: tags, ages and fuel Core's;
	ore features Ores/ores.luau; biomes Minecraft/biomes.luau (and an override of them,
	Survival/biomes.luau); effects and potions Minecraft/effects.luau and potions.luau; skills
	Survival/skills.luau; sounds Ores/sounds.luau; structures Minecraft/templates, pools.luau and
	structures.luau. Each entry carries its own lore, texture, icon and Age (Content/Schema's
	per-entry fields), so nothing outside the pack needs an edit. `lune run tests/content` checks
	it; `lune run tests/content show $Block` shows what the game makes of an entry.

	Packs load by `order`, then by name (Shared/Content), and every id is a place in that order:
	$placement `requires` names the packs that must load before it: Core, whose Ages and base tags
	its entries name (a pack whose entries it names goes there too: `lune run tests/content` says
	when one is missing).
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
	a recipe whose grid an earlier one takes never crafts: `lune run tests/content` says so. A
	recipe's name is its result's (or its `name`, which a second recipe for a result needs); with
	`override = true` a recipe replaces an earlier pack's of its name, and { name = "Torch",
	remove = true } removes one. (A module may also be `return function(define) ... end`,
	building recipes with Content/Define's `define.shaped`, `define.shapeless`, `define.smelting`,
	`define.named` and `define.storage`, as the Ores pack's does.)
]]

local Schema = require(script.Parent.Parent.Parent.Schema)

return {
	-- Cobblestone around a coal, two $BlockSpaced blocks: a shape no other recipe took when the
	-- pack was made (a grid makes the first recipe it fits).
	{
		type = "shaped",
		pattern = $pattern,
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

-- `text` (a module) with its comment lines that run past the 100th column (a tab is 4) wrapped,
-- the header's and the `--` ones: the words past it begin the next line when that line goes on
-- with the sentence (the same start, then a word), else a line of their own.
local function fit(text: string): string
	local lines = string.split(text, "\n")
	local header = true
	local index = 1
	while index <= #lines do
		local line = lines[index]
		-- (What each line of the comment starts with: the header's tabs, or tabs and "-- ".)
		local start = if header then string.match(line, "^\t+") else string.match(line, "^\t*%-%- ")
		local tabs = #(string.match(line, "^\t*") :: string)
		if start and #line + tabs * 3 > 100 then
			local cut: number? = nil
			for at = 101 - tabs * 3, #start + 1, -1 do
				if string.sub(line, at, at) == " " then
					cut = at
					break
				end
			end
			if cut then
				local rest = string.sub(line, cut + 1)
				lines[index] = string.sub(line, 1, cut - 1)
				local following = lines[index + 1]
				if
					following
					and string.sub(following, 1, #start) == start
					and string.match(following, "^%S", #start + 1)
				then
					lines[index + 1] = start .. rest .. " " .. string.sub(following, #start + 1)
				else
					table.insert(lines, index + 1, start .. rest)
				end
			end
		end
		header = header and line ~= "]]"
		index += 1
	end
	return table.concat(lines, "\n")
end

--[[
	A new pack's modules in `view`'s game: { { path = "pack.luau", text = ... }, ... } (paths inside
	the pack's folder), each a commented example to edit, in the Ores pack's style. Its header
	says where `order` puts it (after every pack, or before some, whose ids then move up), its
	shaped recipe takes the first grid no recipe takes (scaffoldGrid; scaffoldProblem says when
	there is none).
]]
function ContentTool.scaffold(view: any, pack: string, order: number): { { path: string, text: string } }
	local values = ContentTool.scaffoldNames(pack)
	values.order = number(order)
	-- (The packs it loads before: the same order and a later name, or a higher order.)
	local later: { string } = {}
	for _, info in view.packs do
		if info.order > order or (info.order == order and info.name > pack) then
			table.insert(later, info.name)
		end
	end
	values.placement = if #later == 0
		then `at {values.order}, after every other pack, so making it moved no other pack's id.`
		else `at {values.order}, before {joined(later)}, so its blocks and items take the ids theirs had and theirs move up (saves keep names, so a world still loads; a pack with no reason to load early goes after every other, as \`new\` puts it without --order).`
	local grid = ContentTool.scaffoldGrid(view) or { "S S", " C ", "S S" }
	local rows = {}
	for _, row in grid do
		table.insert(rows, quote(row))
	end
	values.pattern = `\{ {table.concat(rows, ", ")} }`
	local files = {}
	for _, template in TEMPLATES do
		local text = string.gsub(template.text, "%$(%a+)", function(key: string): string
			return assert(values[key], `scaffold: no value for ${key}`)
		end)
		text = fit(text)
		table.insert(files, { path = template.path, text = text })
	end
	return files
end

return ContentTool
