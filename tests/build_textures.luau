--[[
	Turns the texture pack (src/shared/TexturePack.luau) into the files Rojo makes the game's
	textures from. Run it from the repository root after every edit of the pack:

	    lune run tests/build_textures            writes src/textures/Materials.model.json and Images.model.json
	    lune run tests/build_textures --check    only checks that they are up to date (exit 1 if not)
	    lune run tests/build_textures --list     prints the blank textures and the blocks waiting on each

	Materials.model.json becomes MaterialService.IceVoxel (a MaterialVariant "IV_<name>" per filled
	texture) and Images.model.json ReplicatedStorage.IceVoxelTextures (a Texture prototype of the
	same name per filled texture); see tests/lib/TextureBuild.luau. Rojo 7.7.1 (rokit.toml) syncs
	them into Studio while `rojo serve` runs, or builds them into the place.

	It refuses a pack with errors (exit 1, nothing written): what Blocks checks when it loads
	(unknown blocks, textures and faces, materials that cannot take a MaterialVariant), ids that
	are not "rbxassetid://<number>", unknown fields, bad averages. It warns about a normal map that
	repeats the colour map and filled textures no block uses, and every mode notes the filled
	textures still without an Average (`--list` names them; they are no error).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Loader = require("./lib/Loader")
local TextureBuild = require("./lib/TextureBuild")

local shared, sharedRequire = Loader.mount("src/shared", "IceVoxel")
-- (Blocks checks the pack as it loads: report that as an error, not a stack trace.)
local loaded, Blocks = pcall(sharedRequire, shared.Blocks)
if not loaded then
	print(`texture pack error: {Blocks}`)
	process.exit(1)
end
local Pack = sharedRequire(shared.TexturePack)

local result = TextureBuild.build(Pack, Blocks)
for _, warning in result.warnings do
	print(`warning: {warning}`)
end
if #result.errors > 0 then
	print("texture pack errors (nothing written):")
	for _, message in result.errors do
		print(`  {message}`)
	end
	process.exit(1)
end

local summary = `{#result.filled} textures filled in (a MaterialVariant and a Texture each), {#result.blank} blank`
local note = TextureBuild.unmeasuredNote(result)

if table.find(process.args, "--list") then
	print(summary)
	for _, line in TextureBuild.list(result, Blocks) do
		print(line)
	end
	if note then
		print(`note: {note}`)
	end
elseif table.find(process.args, "--check") then
	local stale = TextureBuild.stale(result, function(path)
		return if fs.isFile(path) then fs.readFile(path) else nil
	end)
	for _, path in stale do
		print(`{path} is out of date: run lune run tests/build_textures`)
	end
	if #stale > 0 then
		process.exit(1)
	end
	print(`up to date: {summary}`)
	if note then
		print(`note: {note}`)
	end
else
	if not fs.isDir("src/textures") then
		fs.writeDir("src/textures")
	end
	for _, path in { TextureBuild.MATERIALS, TextureBuild.IMAGES } do
		fs.writeFile(path, result.files[path])
		print(`wrote {path}`)
	end
	print(summary)
	if note then
		print(`note: {note}`)
	end
end
