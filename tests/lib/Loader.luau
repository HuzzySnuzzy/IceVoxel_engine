--[[
	Loads IceVoxel's modules outside of Roblox (under Lune).

	Builds a fake instance tree from source folders, mirroring Rojo's rules (`init.luau` turns a
	folder into a module, `X.luau` is a module named X), then runs every module with its own
	`script` and a `require` that accepts those fake instances (passed in as arguments, so Luau's
	fast builtin calls stay on, as in Roblox: see `withArguments`). Shared modules and the
	server's world logic only use pure Luau (buffer, bit32, math.noise...), so they behave exactly
	as in Roblox. `game:GetService(name)` returns the fake service folders mounted with `mount`.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

export type Node = {
	Name: string,
	Parent: Node?,
	ClassName: string,
	__path: string?,
	__children: { [string]: Node },
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

local function newNode(name: string, parent: Node?, path: string?): Node
	local node = setmetatable({
		Name = name,
		Parent = parent,
		ClassName = if path then "ModuleScript" else "Folder",
		__path = path,
		__children = {},
		__attributes = {},
	}, nodeMeta) :: any
	if parent then
		parent.__children[name] = node
	end
	return node
end

local function scan(dir: string, node: Node)
	for _, entry in fs.readDir(dir) do
		local full = `{dir}/{entry}`
		if fs.isDir(full) then
			local init = `{full}/init.luau`
			local child = newNode(entry, node, if fs.isFile(init) then init else nil)
			scan(full, child)
		elseif entry ~= "init.luau" and string.sub(entry, -5) == ".luau" then
			local name = string.sub(entry, 1, -6)
			-- `.server.luau` / `.client.luau` are scripts, not modules; skip them.
			if not string.find(name, "%.") then
				newNode(name, node, full)
			end
		end
	end
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
		loading[node] = true

		local chunk = luau.load(withArguments(fs.readFile(path)), {
			debugName = path,
			-- Set NOCODEGEN=1 to measure interpreter-only speed (Roblox clients may not use native code).
			codegenEnabled = process.env.NOCODEGEN == nil,
		})
		local result = chunk(node, requireNode, game)
		cache[node] = result
		loading[node] = nil
		return result
	end

	return {
		mount = function(dir: string, serviceName: string, folderName: string): Node
			local root = newNode(folderName, game:GetService(serviceName), nil)
			scan(dir, root)
			return root
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
