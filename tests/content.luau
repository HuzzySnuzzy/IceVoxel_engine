--[[
	The content packs' tool (Shared/Content: the packs under src/shared/Content/Packs). It loads the
	game's content as tests/run does (tests/lib/Loader running the game's own modules), so it sees
	what the game sees. Run it from the repository root:

	    lune run tests/content [check] [--strict]    load every pack: a summary of each, then what
	                                                 an author likely forgot (exit 1 when a pack
	                                                 fails to load; --strict: on a warning too)
	    lune run tests/content list [kind] [pack]    entries (id, name, pack), of one kind (blocks,
	                                                 items, recipes, tags, textures, loot, ores,
	                                                 ages, skills, lore, fuel, biomes, effects,
	                                                 potions, templates, pools, structures, sounds,
	                                                 music), of one pack (one word: a kind, else a
	                                                 pack)
	    lune run tests/content show <name>           an entry's merged fields, its id and pack, the
	                                                 packs that patched it, and what the registries
	                                                 made of it (lore, faces or icon, Age, recipes;
	                                                 a skill's cell and the recipes it gates;
	                                                 a template's size and palette, a pool's
	                                                 elements, what starts from it)
	    lune run tests/content new <Pack> [--order n]
	                                                 a new pack, src/shared/Content/Packs/<Pack>/
	                                                 (never over a folder that is there), with an
	                                                 example of five kinds: a block, an item, a
	                                                 shaped and a smelting recipe, a texture and a
	                                                 loot table (its pack.luau names a module of
	                                                 the game's packs to copy for each other
	                                                 kind); checked once written. Its order: n, or
	                                                 after every pack's

	The checks, lists, pages and the new pack's text are tests/lib/ContentTool's (its header lists
	every check); what the game makes of the packs is tests/lib/ContentGame's.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local ContentGame = require("./lib/ContentGame")
local ContentTool = require("./lib/ContentTool")
local Loader = require("./lib/Loader")

local PACKS = "src/shared/Content/Packs"

local USAGE = table.concat({
	"usage: lune run tests/content [check] [--strict]",
	"       lune run tests/content list [kind] [pack]",
	"       lune run tests/content show <name>",
	"       lune run tests/content new <Pack> [--order n]   (a block, an item, two recipes, a texture, a loot table)",
}, "\n")

local function fail(text: string): never
	print(text)
	process.exit(1)
	error(text)
end

-- The command, its words and the flags.
local words: { string } = {}
local strict = false
local order: number? = nil
do
	local args = process.args
	local i = 1
	while i <= #args do
		local arg = args[i]
		if arg == "--strict" then
			strict = true
		elseif arg == "--order" then
			order = tonumber(args[i + 1])
			if order == nil then
				fail(`--order needs a number\n{USAGE}`)
			end
			i += 1
		elseif string.sub(arg, 1, 2) == "--" then
			fail(`unknown flag {arg}\n{USAGE}`)
		else
			table.insert(words, arg)
		end
		i += 1
	end
end
local command = table.remove(words, 1) or "check"

-- The game, freshly loaded, as a View (a load error, which names its pack, kind and entry, is
-- printed and exits 1).
local function load(): any
	local env = Loader.new()
	local shared = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
	local view, problem = ContentGame.load(env, shared, ContentGame.scanWorld())
	if view == nil then
		fail(`content error: {problem}`)
	end
	return view
end

if command == "check" then
	local view = load()
	local findings = ContentTool.check(view)
	for _, line in ContentTool.report(view, findings) do
		print(line)
	end
	if strict and ContentTool.count(findings, "warning") > 0 then
		process.exit(1)
	end
elseif command == "list" then
	local view = load()
	local kind, pack = words[1], words[2]
	-- (One word: a kind, else a pack.)
	if kind and pack == nil and not table.find(view.kinds, kind) then
		kind, pack = nil, kind
	end
	local lines, problem = ContentTool.list(view, kind, pack)
	if lines == nil then
		fail(problem :: string)
	end
	for _, line in lines :: { string } do
		print(line)
	end
elseif command == "show" then
	local name = words[1]
	if name == nil then
		fail(USAGE)
	end
	local view = load()
	local lines, near = ContentTool.show(view, name)
	if lines == nil then
		local nearest = near or {}
		fail(`nothing is named {name}{if #nearest > 0 then ` (did you mean {nearest[1]}?)` else ""}`)
	end
	for _, line in lines :: { string } do
		print(line)
	end
elseif command == "new" then
	local pack = words[1]
	if pack == nil then
		fail(USAGE)
	end
	local dir = `{PACKS}/{pack}`
	if fs.isDir(dir) or fs.isFile(dir) then
		fail(`{dir} is there already: a new pack never writes over one`)
	end
	local view = load()
	local problem = ContentTool.scaffoldProblem(view, pack)
	if problem then
		fail(problem)
	end
	local at = order or ContentTool.nextOrder(view)
	fs.writeDir(dir)
	for _, file in ContentTool.scaffold(view, pack, at) do
		fs.writeFile(`{dir}/{file.path}`, file.text)
		print(`wrote {dir}/{file.path}`)
	end
	-- The game again, with the new pack: what the check says of it.
	local after = load()
	local findings = {}
	for _, finding in ContentTool.check(after) do
		if finding.pack == pack then
			table.insert(findings, finding)
		end
	end
	for _, line in ContentTool.summary(after) do
		if string.sub(line, 1, #pack + 1) == pack .. " " then
			print(line)
		end
	end
	for _, finding in findings do
		print(`{finding.level}  {finding.subject}: {finding.text}`)
	end
	print(ContentTool.verdict(findings))
else
	fail(`unknown command {command}\n{USAGE}`)
end
