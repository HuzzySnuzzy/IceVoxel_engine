--[[
	The Lune loader (tests/lib/Loader): it builds the tree Rojo 7.7 builds from the same files
	(tests/fixtures/loader/rules: every rule the content packs meet; checked against `rojo build`
	of that folder, which gives the same classes and names but for the .model.json the loader
	leaves out), reads JSON as Rojo does (comments, trailing commas), and refuses what Roblox's
	require refuses (tests/fixtures/loader/broken: a module without a value), naming the file of
	anything that does not decode.
]]

local Loader = require("../lib/Loader")

local RULES = "tests/fixtures/loader/rules"
local BROKEN = "tests/fixtures/loader/broken"

return function(t, _shared, _require, _server, _client)
	-- "Class Name" of every child of `node`, sorted.
	local function children(node: any): string
		local list = {}
		for _, child in node:GetChildren() do
			table.insert(list, `{child.ClassName} {child.Name}`)
		end
		table.sort(list)
		return table.concat(list, ", ")
	end

	t.test("loader: Rojo's rules: .lua, init.lua, JSON and JSONC, TOML, YAML, dotted names, text", function()
		local env = Loader.new()
		local root = env.mount(RULES, "ReplicatedStorage", "Rules")
		t.eq(
			children(root),
			table.concat({
				"Folder folder",
				"LocalizationTable strings",
				"ModuleScript data",
				"ModuleScript list",
				"ModuleScript more",
				"ModuleScript old",
				"ModuleScript ores.old",
				"ModuleScript plain",
				"ModuleScript table",
				"ModuleScript twice",
				"ModuleScript twice",
				"ModuleScript withinit",
				"Script boot",
				"StringValue notes",
			}, ", "),
			"as `rojo build` makes them (thing.model.json aside)"
		)
		t.eq(env.require(root.plain), "plain")
		t.eq(env.require(root.old), "lua", "a .lua file is a module")
		t.eq(env.require(root:FindFirstChild("ores.old")), "dotted", "a dotted name keeps its dot")
		t.eq(env.require(root.withinit), "init", "init.lua makes its folder a module")
		t.eq(children(root.withinit), "ModuleScript child")
		t.eq(env.require(root.withinit.child), "child")
		t.eq(env.require(root.folder.inner), "inner")
		-- JSON with comments and trailing commas, as Rojo reads a .json and a .jsonc file.
		local data = env.require(root.data)
		t.eq(table.concat(data.list, " "), "1 2 3", "a trailing comma")
		t.eq(data.text, 'a // not a comment, /* nor this */, "quoted"', "a string's slashes and quotes kept")
		t.eq(data.none, nil, "null is nil")
		t.eq(env.require(root.more).flag, true, "a .jsonc file")
		t.eq(env.require(root.table).count, 3, "TOML")
		t.eq(table.concat(env.require(root.list).items, " "), "1 2", "YAML")
		-- Text, a localization table and a script: there, but no modules.
		t.ok(not pcall(env.require, root.notes), "a StringValue is no module")
		t.ok(not pcall(env.require, root.boot), "a script is never run")
	end)

	t.test("loader: two files of one name are both kept, as Rojo keeps them", function()
		local env = Loader.new()
		local root = env.mount(RULES, "ReplicatedStorage", "Rules")
		local found = {}
		for _, child in root:GetChildren() do
			if child.Name == "twice" then
				table.insert(found, env.require(child))
			end
		end
		table.sort(found)
		t.eq(table.concat(found, " "), "json luau", "both listed, each its own module")
		t.ok(root.twice ~= nil, "the name finds one")
		-- A spec's own module replaces what had its name, both of them.
		env.module(root, "twice", "mine")
		t.eq(children(root):match("ModuleScript twice, ModuleScript twice"), nil, "one left")
		t.eq(env.require(root.twice), "mine")
	end)

	t.test("loader: a module without a value and a file that does not decode, named", function()
		local env = Loader.new()
		local root = env.mount(BROKEN, "ReplicatedStorage", "Broken")
		local ok, err = pcall(env.require, root.none)
		t.ok(
			not ok and string.find(tostring(err), "none.luau: Module code did not return exactly one value", 1, true),
			err
		)
		ok, err = pcall(env.require, root.bad)
		t.ok(not ok and string.find(tostring(err), "bad.json: not valid JSON", 1, true), err)
		-- (A value made in memory, nil or not, is what its module gives.)
		local folder = env.folder(root, "memory")
		t.eq(env.require(env.source(folder, "empty", "return nil")), nil, "return nil is one value")
	end)
end
