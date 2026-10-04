--[[
	Runs every spec in tests/spec.

	    lune run tests/run

	Each spec receives (t, shared, require, server, client): the test context, the fake
	ReplicatedStorage.IceVoxel, ServerScriptService.IceVoxel and StarterPlayerScripts.IceVoxel
	folders, and a require for them. Only client modules that use no Roblox APIs can be required.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Loader = require("./lib/Loader")
local Test = require("./lib/Test")

local env = Loader.new()
local shared = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
local server = env.mount("src/server", "ServerScriptService", "IceVoxel")
local client = env.mount("src/client", "StarterPlayerScripts", "IceVoxel")
local t, results = Test.new()

local specs = fs.readDir("tests/spec")
table.sort(specs)
for _, file in specs do
	if string.sub(file, -5) == ".luau" then
		print(`{file}`)
		local spec = require(`./spec/{string.sub(file, 1, -6)}`)
		spec(t, shared, env.require, server, client)
	end
end

local passed, failed = results()
print(`\n{passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
