--[[
	Loads IceVoxel's modules outside of Roblox (under Lune).

	Builds a fake instance tree from source folders, mirroring Rojo 7.7's rules (`rules` below):
	  * `X.luau` and `X.lua` are a module named X, dots and all (`ores.old.luau` is the module
	    "ores.old"); `init.luau` or `init.lua` turns its folder into a module;
	  * `X.json` and `X.jsonc` are Rojo's JSON module, a ModuleScript returning the decoded table
	    (both read as JSON with comments and trailing commas), and `X.toml`, `X.yaml` and `X.yml`
	    the same of their formats;
	  * `X.server.luau` is a Script, `X.client.luau` a LocalScript, `X.txt` a StringValue and `X.csv`
	    a LocalizationTable: no modules, but there, as Rojo makes them (a script is never run);
	  * two files of one name are both kept, as Rojo keeps them (`blocks.luau` beside
	    `blocks.json`): GetChildren lists both, `node.Name` finds one;
	  * Rojo's own files (`.model.json`, `.meta.json`, `.project.json`) are left out.
	Then it runs every module with its own `script` and a `require` that accepts those fake
	instances (passed in as arguments, so Luau's fast builtin calls stay on, as in Roblox: see
	`withArguments`); a module must return exactly one value, as Roblox's require has it, and a
	file that does not decode is an error naming it. Shared modules and the server's world logic
	only use pure Luau (buffer, bit32, math.noise...), so they behave exactly as in Roblox.
	`game:GetService(name)` returns the fake service folders mounted with `mount`. Specs may add
	to a mounted tree before requiring from it: a folder from elsewhere (`graft`: a fixture content
	pack into Content/Packs), or folders and modules made in memory (`folder`, `module`: a module
	whose require gives a value; `source`: a Luau module from its text, run as a file's would be,
	as the content tool's new pack is before it is written), each replacing what had its name.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

export type Node = {
	Name: string,
	Parent: Node?,
	ClassName: string,
	__path: string?,
	-- "json", "toml" or "yaml" for a data module (requiring it gives the decoded file), "value"
	-- for one made in memory (`module`), "source" for Luau text made in memory (`source`), nil
	-- for a Luau file.
	__kind: string?,
	-- The children by name (the first of a name), and the others that share a name with one.
	__children: { [string]: Node },
	__extra: { Node },
}

local Loader = {}

local methods = {
	FindFirstChild = function(self, name)
		return rawget(self, "__children")[name]
	end,
	WaitForChild = function(self, name)
		local child = rawget(self, "__children")[name]
		assert(child, `{rawget(self, "Name")} has no child '{name}' (WaitForChild would hang)`)
		return child
	end,
	IsA = function(self, class)
		return class == "Instance" or rawget(self, "ClassName") == class
	end,
	GetChildren = function(self)
		local list = {}
		for _, child in rawget(self, "__children") do
			table.insert(list, child)
		end
		for _, child in rawget(self, "__extra") do
			table.insert(list, child)
		end
		return list
	end,
	GetAttribute = function(self, name)
		return rawget(self, "__attributes")[name]
	end,
	SetAttribute = function(self, name, value)
		rawget(self, "__attributes")[name] = value
	end,
}

local nodeMeta = {
	__index = function(self, key)
		local child = rawget(self, "__children")[key]
		if child then
			return child
		end
		if methods[key] then
			return methods[key]
		end
		error(`{rawget(self, "Name")} has no child '{key}'`, 2)
	end,
}

--[[
	A node named `name` in `parent`: a module when it has a `path`, else a folder (or `class`).
	`keep`: a file's, kept beside one of the same name as Rojo keeps both; otherwise it replaces
	whatever had the name (a spec's own module or folder).
]]
local function newNode(name: string, parent: Node?, path: string?, kind: string?, class: string?, keep: boolean?): Node
	local node = setmetatable({
		Name = name,
		Parent = parent,
		ClassName = class or if path then "ModuleScript" else "Folder",
		__path = path,
		__kind = kind,
		__children = {},
		__extra = {},
		__attributes = {},
	}, nodeMeta) :: any
	if parent then
		if keep and parent.__children[name] then
			table.insert(parent.__extra, node)
		else
			parent.__children[name] = node
			for index = #parent.__extra, 1, -1 do
				if parent.__extra[index].Name == name then
					table.remove(parent.__extra, index)
				end
			end
		end
	end
	return node
end

--[[
	Rojo 7.7's rules for a file, by its name's ending: what it makes (a module's `kind`, as
	Node's; or an instance's class) and the name it gets (the rest of the file's name, dots and
	all). Earlier rules first: `.server.luau` before `.luau`, `.model.json` before `.json`; nil
	`make` leaves the file out.
]]
local rules: { { ending: string, make: { kind: string?, class: string? }? } } = {
	{ ending = ".server.luau", make = { class = "Script" } },
	{ ending = ".server.lua", make = { class = "Script" } },
	{ ending = ".client.luau", make = { class = "LocalScript" } },
	{ ending = ".client.lua", make = { class = "LocalScript" } },
	{ ending = ".model.json" },
	{ ending = ".meta.json" },
	{ ending = ".project.json" },
	{ ending = ".luau", make = {} },
	{ ending = ".lua", make = {} },
	{ ending = ".json", make = { kind = "json" } },
	{ ending = ".jsonc", make = { kind = "json" } },
	{ ending = ".toml", make = { kind = "toml" } },
	{ ending = ".yaml", make = { kind = "yaml" } },
	{ ending = ".yml", make = { kind = "yaml" } },
	{ ending = ".txt", make = { class = "StringValue" } },
	{ ending = ".csv", make = { class = "LocalizationTable" } },
}

local function scan(dir: string, node: Node)
	-- (Sorted, so of two files of one name the same one is found by the name on every run.)
	local entries = fs.readDir(dir)
	table.sort(entries)
	for _, entry in entries do
		local full = `{dir}/{entry}`
		if fs.isDir(full) then
			local init = if fs.isFile(`{full}/init.luau`)
				then `{full}/init.luau`
				elseif fs.isFile(`{full}/init.lua`) then `{full}/init.lua`
				else nil
			local child = newNode(entry, node, init, nil, nil, true)
			scan(full, child)
		elseif entry ~= "init.luau" and entry ~= "init.lua" then
			for _, rule in rules do
				local ending = rule.ending
				if #entry > #ending and string.sub(entry, -#ending) == ending then
					local make = rule.make
					if make then
						local name = string.sub(entry, 1, -#ending - 1)
						newNode(name, node, if make.class then nil else full, make.kind, make.class, true)
					end
					break
				end
			end
		end
	end
end

--[[
	JSON with comments and trailing commas, as Rojo 7.7 reads a `.json` or `.jsonc` file, made plain
	JSON for serde: `//` and `/* */` comments and a comma before `}` or `]` left out, strings kept
	as they are.
]]
local function plainJson(text: string): string
	local out: { string } = {}
	local i, n = 1, #text
	while i <= n do
		local char = string.sub(text, i, i)
		local after = string.sub(text, i + 1, i + 1)
		if char == '"' then
			local j = i + 1
			while j <= n and string.sub(text, j, j) ~= '"' do
				j += if string.sub(text, j, j) == "\\" then 2 else 1
			end
			table.insert(out, string.sub(text, i, j))
			i = j + 1
		elseif char == "/" and after == "/" then
			i = string.find(text, "\n", i, true) or n + 1
		elseif char == "/" and after == "*" then
			local _, close = string.find(text, "*/", i + 2, true)
			i = (close or n) + 1
		else
			if char == "}" or char == "]" then
				-- (The last piece that is no white space: a trailing comma goes.)
				local last = #out
				while last > 0 and string.match(out[last], "^%s+$") do
					last -= 1
				end
				if out[last] == "," then
					table.remove(out, last)
				end
			end
			table.insert(out, char)
			i += 1
		end
	end
	return table.concat(out)
end

--[[
	A module's source with `script`, `require` and `game` declared as locals taken from the chunk's
	arguments. A custom environment table (luau.load's `environment`) would be simpler, but it
	turns off Luau's fast builtin calls (buffer.*, bit32.*, math.*) for the whole module, which made
	every Lune timing 1.3-2.6x slower than the same code in Roblox. The declaration goes on the
	first line after the `--!` directives (which must stay first), so error line numbers don't move.
]]
local function withArguments(source: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	local declare = "local script, require, game = ...; "
	if lines[i] == nil then
		lines[i] = declare
	else
		lines[i] = declare .. lines[i]
	end
	return table.concat(lines, "\n")
end

export type Environment = {
	-- Mounts `dir` as `serviceName.folderName`, e.g. ("src/shared", "ReplicatedStorage", "IceVoxel").
	mount: (dir: string, serviceName: string, folderName: string) -> Node,
	-- Mounts `dir` as a folder named `name` inside `parent` (a mounted node), as if it were in the
	-- source tree there: specs add a fixture content pack to Content/Packs this way.
	graft: (dir: string, parent: Node, name: string) -> Node,
	-- An empty folder named `name` in `parent`, and a module there whose require gives `value`:
	-- specs build fixture packs in memory with them.
	folder: (parent: Node, name: string) -> Node,
	module: (parent: Node, name: string, value: any) -> Node,
	-- A Luau module named `name` in `parent` whose source is `text` (its `script` and `require`
	-- work as a file's; errors name it `<memory>/name`).
	source: (parent: Node, name: string, text: string) -> Node,
	require: (Node) -> any,
}

function Loader.new(): Environment
	local services: { [string]: Node } = {}
	local game = {
		GetService = function(_, name: string)
			local service = services[name]
			if service == nil then
				service = newNode(name, nil, nil)
				services[name] = service
			end
			return service
		end,
	}

	local cache: { [Node]: any } = {}
	local loading: { [Node]: boolean } = {}

	local function requireNode(node: Node): any
		if cache[node] ~= nil then
			return cache[node]
		end
		local path = rawget(node :: any, "__path")
		assert(path, `{node.Name} is not a module`)
		assert(not loading[node], `Cyclic require of {path}`)
		local kind = rawget(node :: any, "__kind")
		if kind == "value" then
			return rawget(node :: any, "__value")
		elseif kind == "json" or kind == "toml" or kind == "yaml" then
			-- (JSON null is nil, as in Rojo's JSON modules. A file that does not decode names
			-- itself, as Rojo's build does.)
			local text = fs.readFile(path)
			local ok, decoded = pcall(serde.decode, kind :: any, if kind == "json" then plainJson(text) else text)
			if not ok then
				error(`{path}: not valid {string.upper(kind)}: {decoded}`, 0)
			end
			cache[node] = decoded
			return decoded
		end
		loading[node] = true

		local text = if rawget(node :: any, "__kind") == "source"
			then rawget(node :: any, "__source")
			else fs.readFile(path)
		local chunk = luau.load(withArguments(text), {
			debugName = path,
			-- Set NOCODEGEN=1 to measure interpreter-only speed (Roblox clients may not use native code).
			codegenEnabled = process.env.NOCODEGEN == nil,
		})
		local results = table.pack(chunk(node, requireNode, game))
		loading[node] = nil
		-- (Roblox's require refuses a module without a value: a module that forgot its `return`.)
		if results.n ~= 1 then
			error(`{path}: Module code did not return exactly one value`, 0)
		end
		local result = results[1]
		cache[node] = result
		return result
	end

	return {
		mount = function(dir: string, serviceName: string, folderName: string): Node
			local root = newNode(folderName, game:GetService(serviceName), nil)
			scan(dir, root)
			return root
		end,
		graft = function(dir: string, parent: Node, name: string): Node
			local folder = newNode(name, parent, nil)
			scan(dir, folder)
			return folder
		end,
		folder = function(parent: Node, name: string): Node
			return newNode(name, parent, nil)
		end,
		module = function(parent: Node, name: string, value: any): Node
			local node = newNode(name, parent, `<memory>/{name}`, "value");
			(node :: any).__value = value
			return node
		end,
		source = function(parent: Node, name: string, text: string): Node
			local node = newNode(name, parent, `<memory>/{name}`, "source");
			(node :: any).__source = text
			return node
		end,
		require = requireNode,
	}
end

-- Shortcut for scripts that only need the shared modules.
function Loader.mount(dir: string, rootName: string): (Node, (Node) -> any)
	local env = Loader.new()
	return env.mount(dir, "ReplicatedStorage", rootName), env.require
end

return Loader
