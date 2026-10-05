--[[
	Structure data (IVS1) on the command line: what a structure block saved, readable.

	    lune run tests/structure decode <file | IVS1:... | ->  [--lua <out.luau>]
	        Prints each structure in the file (a text file, a pasted chat message or a library
	        module: every "IVS1:" in it), or in the text given, or from standard input ("-"):
	        name, size, length, block counts, the palette with each block's character, every
	        y layer as ASCII, jigsaws, data markers, containers and warnings. --lua writes the
	        (last) structure as an editable Luau table (Template.toTable) to <out.luau>.

	    lune run tests/structure encode <table.luau>  [--out <file>] [--module]
	        Reads a table file (what --lua writes, edited or written by hand) and prints its IVS1
	        text, or writes it to <file>; --module writes it as a library module
	        (`return "IVS1:..."`, for src/shared/StructureLibrary/Templates).

	The table format (Template.toTable / fromTable): `layers[1]` is y = 0 (the bottom); each layer
	is a list of rows from north (z = 0) to south, each row a string of one character per block
	from west (x = 0) to east. "." is air, " " (a space) keeps the world as it is (a structure
	void); `legend` maps the other characters to block names.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Loader = require("./lib/Loader")
local StructureText = require("./lib/StructureText")

local shared, sharedRequire = Loader.mount("src/shared", "IceVoxel")
local Blocks = sharedRequire(shared.Blocks)
local Template = sharedRequire(shared.Structures.Template)

local function usage(): never
	print("usage:")
	print("  lune run tests/structure decode <file | IVS1:... | ->  [--lua <out.luau>]")
	print("  lune run tests/structure encode <table.luau>  [--out <file>] [--module]")
	return process.exit(2)
end

-- The value after `flag` in the arguments (nil when absent), and whether `flag` is there at all.
local function option(args: { string }, flag: string): (string?, boolean)
	for i, arg in args do
		if arg == flag then
			return args[i + 1], true
		end
	end
	return nil, false
end

local function readInput(arg: string): string
	if arg == "-" then
		return stdio.readToEnd()
	elseif string.sub(arg, 1, 5) == "IVS1:" then
		return arg
	elseif fs.isFile(arg) then
		return fs.readFile(arg)
	end
	print(`No file '{arg}' (give a file, an IVS1:... text or - for standard input)`)
	return process.exit(1)
end

local function pad(text: string, width: number): string
	return text .. string.rep(" ", math.max(0, width - #text))
end

-- A Luau literal for `value` (strings, numbers, booleans and tables of them), indented.
local function literal(value: any, indent: string): string
	local kind = type(value)
	if kind == "string" then
		return string.format("%q", value)
	elseif kind ~= "table" then
		return tostring(value)
	end
	local inner = indent .. "\t"
	if #value > 0 then
		local simple = true
		for _, item in value do
			if type(item) == "table" then
				simple = false
			end
		end
		local parts = {}
		for _, item in value do
			table.insert(parts, literal(item, inner))
		end
		if simple and #value <= 4 then
			return "{ " .. table.concat(parts, ", ") .. " }"
		end
		return "{\n" .. inner .. table.concat(parts, ",\n" .. inner) .. ",\n" .. indent .. "}"
	end
	local keys = {}
	for key in value do
		table.insert(keys, key)
	end
	if #keys == 0 then
		return "{}"
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, key in keys do
		local name = if type(key) == "string" and string.find(key, "^[%a_][%w_]*$")
			then key
			else `[{literal(key, inner)}]`
		table.insert(parts, `{name} = {literal(value[key], inner)}`)
	end
	return "{\n" .. inner .. table.concat(parts, ",\n" .. inner) .. ",\n" .. indent .. "}"
end

-- The table file for `t`: a Luau module returning Template.toTable(t), layers one row per line.
local function tableFile(t: any): string
	local data = Template.toTable(t)
	local lines = {
		"-- A structure (tests/structure encode turns this back into IVS1 text).",
		"-- layers[1] is y = 0; rows run north to south, characters west to east.",
		`-- "." is air, " " keeps the world as it is; legend maps the other characters to blocks.`,
		"return {",
		`\tname = {literal(data.name, "\t")},`,
		`\tsize = {literal(data.size, "\t")},`,
		`\twidth = {data.width},`,
		`\tlegend = {literal(data.legend, "\t")},`,
		"\tlayers = {",
	}
	for y, rows in data.layers do
		table.insert(lines, `\t\t\{ -- y = {y - 1}`)
		for _, row in rows do
			table.insert(lines, `\t\t\t{string.format("%q", row)},`)
		end
		table.insert(lines, "\t\t},")
	end
	table.insert(lines, "\t},")
	table.insert(lines, `\tjigsaws = {literal(data.jigsaws, "\t")},`)
	table.insert(lines, `\tmarkers = {literal(data.markers, "\t")},`)
	table.insert(lines, `\tcontainers = {literal(data.containers, "\t")},`)
	table.insert(lines, "}")
	return table.concat(lines, "\n") .. "\n"
end

local function report(text: string, t: any, warnings: { string }?)
	local sx, sy, sz = t.size[1], t.size[2], t.size[3]
	print(`Structure "{t.name}": {sx} x {sy} x {sz} ({sx * sy * sz} cells), {#text} characters`)
	local counts, keep = Template.counts(t)
	print(`Blocks: {Template.count(t)} (not counting air), air {counts[Blocks.AIR] or 0}, keep {keep}`)

	local data = Template.toTable(t)
	local symbolOf: { [string]: string } = {}
	for symbol, name in data.legend do
		symbolOf[if name == false then "(keep)" else name :: string] = symbol
	end
	local rows = {}
	for id, n in counts do
		table.insert(rows, { name = Blocks.get(id).name, n = n })
	end
	if keep > 0 then
		table.insert(rows, { name = "(keep)", n = keep })
	end
	table.sort(rows, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		end
		return a.name < b.name
	end)
	print("Palette (character, block, cells):")
	for _, row in rows do
		local symbol = symbolOf[row.name] or "?"
		print(`  '{symbol}'  {pad(row.name, 24)} {row.n}`)
	end

	print("Layers, y = 0 (the bottom) first; rows north to south, columns west to east:")
	local border = "  +" .. string.rep("-", sx * data.width) .. "+"
	for y, layer in data.layers do
		print(`  y = {y - 1}`)
		print(border)
		for _, row in layer do
			print(`  |{row}|`)
		end
		print(border)
	end

	print(`Jigsaws ({#t.jigsaws}):`)
	for _, j in data.jigsaws do
		print(
			`  ({j.x}, {j.y}, {j.z}) front {j.front}, top {j.top}: name "{j.name}", target "{j.target}", pool "{j.pool}", final state {j.finalState}, {j.joint}`
		)
	end
	print(`Data markers ({#t.markers}):`)
	for _, m in data.markers do
		print(`  ({m.x}, {m.y}, {m.z}) "{m.data}"`)
	end
	print(`Containers ({#t.containers}):`)
	for _, c in data.containers do
		local block = Template.get(t, c.x, c.y, c.z)
		local items = {}
		for _, item in c.items do
			local damage = if item.damage > 0 then `, wear {item.damage}` else ""
			table.insert(items, `slot {item.slot} {item.item} x{item.count}{damage}`)
		end
		local name = if block then Blocks.get(block).name else "keep"
		print(`  ({c.x}, {c.y}, {c.z}) {name}: {table.concat(items, "; ")}`)
	end
	if warnings and #warnings > 0 then
		print("Warnings:")
		for _, warning in warnings do
			print(`  {warning}`)
		end
	end
end

local args = process.args
local command = args[1]
if command == "decode" then
	local input = args[2] or usage()
	local source = readInput(input)
	local texts = StructureText.findTexts(source)
	if #texts == 0 then
		print("No structure data (IVS1:...) found")
		process.exit(1)
	end
	local last = nil
	local failed = false
	for i, text in texts do
		if i > 1 then
			print("")
		end
		local t, err, warnings, used = StructureText.decodeLoose(Template.decode, text)
		if t then
			report(used, t, warnings)
			last = t
		else
			print(`Structure {i}: {err}`)
			failed = true
		end
	end
	local out = option(args, "--lua")
	if out and last then
		fs.writeFile(out, tableFile(last))
		print(`\nWrote {out}`)
	end
	process.exit(if failed then 1 else 0)
elseif command == "encode" then
	local path = args[2] or usage()
	if not fs.isFile(path) then
		print(`No file '{path}'`)
		process.exit(1)
	end
	local ok, data = pcall(function()
		return luau.load(fs.readFile(path), { debugName = path, environment = {} })()
	end)
	if not ok then
		print(`{path}: {data}`)
		process.exit(1)
	end
	local t, err = Template.fromTable(data)
	if t == nil then
		print(`{path}: {err}`)
		process.exit(1)
	end
	local text = Template.encode(t)
	local out = option(args, "--out")
	local _, module = option(args, "--module")
	local content = if module
		then `-- {t.name} ({t.size[1]} x {t.size[2]} x {t.size[3]}), made with tests/structure encode.\nreturn "{text}"\n`
		else text .. "\n"
	if out then
		fs.writeFile(out, content)
		print(`Wrote {out}: "{t.name}", {#text} characters`)
	else
		stdio.write(content)
	end
else
	usage()
end
