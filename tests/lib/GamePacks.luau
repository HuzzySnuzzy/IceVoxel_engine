--[[
	The game's content packs as the specs need them, so that a spec holds whatever packs an author
	adds (src/shared/Content/Packs is theirs to add to):

	  SHIPPED                         the packs the game ships, by name. A spec pinning what they
	                                  make (a generation digest) mounts the game with these alone:
	                                  an author's ore feature or biome then moves nothing it pins.
	                                  A pack the game ships from now on goes here.
	  shippedOnly(packs)              takes every other pack out of a mounted Content/Packs folder
	                                  (before anything in its environment requires Content); the
	                                  names it took, sorted
	  mountShipped()                  a fresh environment with src/shared mounted and its packs the
	                                  shipped ones alone: the environment and the shared root
	  orderAfter(env, packs, wanted)  an order after every pack in `packs`: `wanted` when it is, else
	                                  the whole number after the highest
	  graftLast(env, dir, packs, name)   grafts the fixture pack at `dir` into `packs` as `name`, its
	                                  manifest's order raised past every other pack's when it is
	                                  not already (orderAfter), so its entries load last, as the
	                                  specs grafting it say, whatever order an author's packs take

	A fixture pack grafted into the game names what it makes with "Fixture" (FixtureMarsh,
	FixtureLuck, fixture_blasting...), which no pack of the game or an author's would take.
]]

local Loader = require("./Loader")

local GamePacks = {}

GamePacks.SHIPPED = table.freeze({
	"Core",
	"Minecraft",
	"Mekanism",
	"Survival",
	"Terraria",
	"Apocalypse",
	"Turrets",
	"Ores",
})

function GamePacks.shippedOnly(packs: Loader.Node): { string }
	local children = rawget(packs :: any, "__children")
	local taken: { string } = {}
	for name in children do
		if not table.find(GamePacks.SHIPPED, name) then
			table.insert(taken, name)
		end
	end
	table.sort(taken)
	for _, name in taken do
		children[name] = nil
	end
	return taken
end

function GamePacks.mountShipped(): (Loader.Environment, any)
	local env = Loader.new()
	local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
	GamePacks.shippedOnly((root :: any).Content.Packs)
	return env, root
end

-- The order a pack folder's manifest gives (nil: none it can read).
local function orderOf(env: Loader.Environment, folder: any): number?
	local manifest = folder:FindFirstChild("pack")
	if manifest == nil then
		return nil
	end
	local data = env.require(manifest)
	return if type(data) == "table" and type(data.order) == "number" then data.order else nil
end

function GamePacks.orderAfter(env: Loader.Environment, packs: Loader.Node, wanted: number, except: string?): number
	local highest = -math.huge
	for name, folder in rawget(packs :: any, "__children") do
		if name ~= except then
			highest = math.max(highest, orderOf(env, folder) or -math.huge)
		end
	end
	return if wanted > highest then wanted else math.floor(highest) + 1
end

function GamePacks.graftLast(env: Loader.Environment, dir: string, packs: Loader.Node, name: string): Loader.Node
	local folder = env.graft(dir, packs, name)
	local manifest = table.clone(env.require((folder :: any).pack))
	manifest.order = GamePacks.orderAfter(env, packs, manifest.order, name)
	env.module(folder, "pack", manifest)
	return folder
end

return GamePacks
