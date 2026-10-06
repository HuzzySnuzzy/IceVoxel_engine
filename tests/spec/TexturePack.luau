--[[
	The texture pack (Shared/TexturePack) and what Blocks makes of it: the pack's shape, an entry
	for every block that can carry a texture and none for the rest, the user's sheet as
	transcribed (with its two typo fixes), face resolution (All / Sides / Top / Bottom, cave twins,
	variant groups), appearances keyed by their textures, `textured`, `variantTexture` and
	`alignLut`, the checks Blocks makes when it loads, and the generator (tests/build_textures):
	its output, its refusals and the committed src/textures files being up to date.

	Filling in a blank texture, turning ShowMissing on or following the pack's own hints never
	breaks these specs (tests that make up packs run on each: BASES); replacing one of the sheet's
	ids means updating SHEET below, and every pack edit means running `lune run tests/build_textures`.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Loader = require("../lib/Loader")
local TextureBuild = require("../lib/TextureBuild")

-- A fresh Blocks loaded after `edit` changed its own copy of the pack (and of BlockList): true and
-- Blocks, or false and the error Blocks raised.
local function withPack(edit: (pack: any, list: any) -> ()): (boolean, any)
	local env = Loader.new()
	local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
	local pack = env.require(root.TexturePack)
	local list = env.require(root.Blocks.BlockList)
	edit(pack, list)
	return pcall(env.require, root.Blocks)
end

-- A copy of the pack whose tables can be changed.
local function copyPack(pack: any): any
	local textures, blocks = {}, {}
	for name, texture in pack.Textures do
		textures[name] = table.clone(texture)
	end
	for name, faces in pack.Blocks do
		blocks[name] = table.clone(faces)
	end
	return {
		StudsPerTile = pack.StudsPerTile,
		ShowMissing = pack.ShowMissing,
		Missing = pack.Missing,
		Textures = textures,
		Blocks = blocks,
	}
end

--[[
	What the user does to the pack while making textures: fill in blanks and turn ShowMissing on.
	Tests that make up packs start from each, and set what they rely on themselves, so they never
	lean on a texture the pack ships blank.
]]
local BASES: { { name: string, edit: (pack: any) -> () } } = {
	{ name = "the pack as shipped", edit = function(_pack: any) end },
	{
		name = "every blank filled in",
		edit = function(pack: any)
			for _, texture in pack.Textures do
				if texture.Color == "" then
					texture.Color = "rbxassetid://1"
				end
			end
		end,
	},
	{
		name = "ShowMissing on",
		edit = function(pack: any)
			pack.ShowMissing = true
		end,
	},
}

-- Is every name in `b` in `a`?
local function includes(a: { string }, b: { string }): boolean
	for _, x in b do
		if not table.find(a, x) then
			return false
		end
	end
	return true
end

local function sameSet(a: { string }, b: { string }): boolean
	local seen = {}
	for _, x in a do
		seen[x] = (seen[x] or 0) + 1
	end
	for _, x in b do
		if not seen[x] then
			return false
		end
		seen[x] -= 1
	end
	for _, n in seen do
		if n ~= 0 then
			return false
		end
	end
	return true
end

--[[
	The user's sheet: texture, colour map, normal map (nil: none), Material, Tint (true for the
	default) and the blocks using it (at least: more may, like the crafting table's bottom with the
	pack's planks hint). Leaves' and packed mud's normal maps repeated their colour maps (typos):
	leaves have none, packed mud takes dirt's.
]]
local SHEET = {
	{
		"dirt",
		"124863036266976",
		"72051511434165",
		"Ground",
		"Dirt",
		{ "Dirt", "Grass", "DryGrass", "Podzol", "Mycelium" },
	},
	{ "grass top", "108277463750403", "99507506732683", "Grass", true, { "Grass", "DryGrass" } },
	{ "grass side", "86851679897399", "73522726802574", "Ground", false, { "Grass" } },
	{ "stone", "140181032881606", "99380706817425", "Slate", true, { "Stone" } },
	{ "cobblestone", "75251272775135", "84237009727338", "Cobblestone", true, { "Cobblestone" } },
	{ "bricks", "78619102429227", "126476239211015", "Brick", true, { "Brick" } },
	{
		"cracked stone bricks",
		"102677558753560",
		"121416480343872",
		"Brick",
		true,
		{ "CrackedStoneBricks" },
	},
	{ "sand", "71309589762284", "128379135184493", "Sand", true, { "Sand" } },
	{ "gravel", "80041848472885", "81186281605960", "Pebble", true, { "Gravel" } },
	{ "snow", "93188919600084", "105336294076212", "Snow", true, { "Snow" } },
	{ "diorite", "136661436562468", "125518917530320", "Limestone", true, { "Diorite" } },
	{ "calcite", "127261168995224", "99380706817425", "Marble", true, { "Calcite" } },
	{ "obsidian", "124134462736797", "82694772111598", "Basalt", true, { "Obsidian" } },
	{ "ice", "108401137755740", nil, "Glacier", true, { "Ice" } },
	{ "packed ice", "95721302530570", nil, "Ice", true, { "PackedIce" } },
	{ "packed mud", "124863036266976", "72051511434165", "Mud", true, { "PackedMud" } },
	{ "coal ore", "123190628695822", "126178156614120", "Rock", false, { "CoalOre" } },
	{ "iron ore", "105117991053609", "78336303508336", "Rock", false, { "IronOre" } },
	{ "gold ore", "120488738320366", "84056217279698", "Rock", false, { "GoldOre" } },
	{ "diamond ore", "118816817484302", "112898008799573", "Rock", false, { "DiamondOre" } },
	{
		"log",
		"120423551204729",
		"109169967309613",
		"Wood",
		true,
		{ "OakLog", "BirchLog", "SpruceLog", "AcaciaLog", "JungleLog" },
	},
	{
		"planks",
		"118497034160890",
		"129159801834926",
		"WoodPlanks",
		true,
		{ "Planks", "BirchPlanks", "SprucePlanks", "AcaciaPlanks", "JunglePlanks" },
	},
	{
		"leaves",
		"17327831454",
		nil,
		"LeafyGrass",
		true,
		{ "OakLeaves", "BirchLeaves", "SpruceLeaves", "AcaciaLeaves", "JungleLeaves" },
	},
	{ "cactus side", "108038569607208", nil, "Grass", true, { "Cactus" } },
	{ "cactus top", "107644713378212", nil, "Grass", true, { "Cactus" } },
	{ "sandstone side", "100157928191004", "140637300323961", "Sandstone", true, { "Sandstone" } },
	{
		"sandstone top",
		"127212881957834",
		"140637300323961",
		"Sandstone",
		true,
		{ "Sandstone", "SmoothSandstone", "CutSandstone" },
	},
	{
		"glow lichen",
		"81026875222604",
		nil,
		"SmoothPlastic",
		false,
		{
			"GlowLichen",
			"GlowLichenUp",
			"GlowLichenNorth",
			"GlowLichenSouth",
			"GlowLichenWest",
			"GlowLichenEast",
			"CaveGlowLichen",
			"CaveGlowLichenUp",
			"CaveGlowLichenNorth",
			"CaveGlowLichenSouth",
			"CaveGlowLichenWest",
			"CaveGlowLichenEast",
		},
	},
	{ "short grass", "113127329313443", nil, "SmoothPlastic", true, { "ShortGrass" } },
	{ "tall grass bottom", "100266742601250", nil, "SmoothPlastic", true, { "TallGrass" } },
	{ "tall grass top", "104285260856645", nil, "SmoothPlastic", true, { "TallGrassTop" } },
	{ "missing texture", "925810526", nil, "SmoothPlastic", false, {} },
}

-- The textures waiting to be made (blank when added), and the blocks using them.
local BLANKS = {
	{ "bedrock", { "Bedrock" } },
	{ "coarse dirt", { "CoarseDirt" } },
	{ "podzol top", { "Podzol" } },
	{ "podzol side", { "Podzol" } },
	{ "mycelium top", { "Mycelium" } },
	{ "mycelium side", { "Mycelium" } },
	{ "dry grass side", { "DryGrass" } },
	{ "andesite", { "Andesite" } },
	{ "granite", { "Granite" } },
	{ "polished andesite", { "PolishedAndesite" } },
	{ "polished diorite", { "PolishedDiorite" } },
	{ "polished granite", { "PolishedGranite" } },
	{ "smooth stone", { "SmoothStone" } },
	{ "stone bricks", { "StoneBricks" } },
	{ "emerald ore", { "EmeraldOre" } },
	{ "osmium ore", { "OsmiumOre" } },
	{ "coal block", { "CoalBlock" } },
	{ "iron block", { "IronBlock" } },
	{ "gold block", { "GoldBlock" } },
	{ "diamond block", { "DiamondBlock" } },
	{ "emerald block", { "EmeraldBlock" } },
	{ "raw iron block", { "RawIronBlock" } },
	{ "raw gold block", { "RawGoldBlock" } },
	{ "osmium block", { "OsmiumBlock" } },
	{ "raw osmium block", { "RawOsmiumBlock" } },
	{ "tnt side", { "Tnt", "LitTnt" } },
	{ "tnt top", { "Tnt", "LitTnt" } },
	{ "tnt bottom", { "Tnt", "LitTnt" } },
	{ "nuke side", { "Nuke", "LitNuke" } },
	{ "nuke top", { "Nuke", "LitNuke" } },
	{ "blue ice", { "BlueIce" } },
	{ "cut sandstone", { "CutSandstone" } },
	{ "sandstone bottom", { "Sandstone" } },
	{ "log top", { "OakLog", "BirchLog", "SpruceLog", "AcaciaLog", "JungleLog" } },
	{ "glass", { "Glass" } },
	{ "chest", { "Chest" } },
	{ "crafting table top", { "CraftingTable" } },
	{ "crafting table side", { "CraftingTable" } },
	{ "furnace top", { "Furnace" } },
	{ "furnace side", { "Furnace" } },
	{ "fern", { "Fern" } },
	{ "large fern bottom", { "LargeFern" } },
	{ "large fern top", { "LargeFernTop" } },
	{ "dead bush", { "DeadBush" } },
	{ "dandelion", { "Dandelion" } },
	{ "poppy", { "Poppy" } },
	{ "blue orchid", { "BlueOrchid" } },
	{ "allium", { "Allium" } },
	{ "azure bluet", { "AzureBluet" } },
	{ "red tulip", { "RedTulip" } },
	{ "orange tulip", { "OrangeTulip" } },
	{ "white tulip", { "WhiteTulip" } },
	{ "pink tulip", { "PinkTulip" } },
	{ "oxeye daisy", { "OxeyeDaisy" } },
	{ "cornflower", { "Cornflower" } },
	{ "lily of the valley", { "LilyOfTheValley" } },
	{ "sunflower bottom", { "Sunflower" } },
	{ "sunflower top", { "SunflowerTop" } },
	{ "lilac bottom", { "Lilac" } },
	{ "lilac top", { "LilacTop" } },
	{ "rose bush bottom", { "RoseBush" } },
	{ "rose bush top", { "RoseBushTop" } },
	{ "peony bottom", { "Peony" } },
	{ "peony top", { "PeonyTop" } },
	{ "brown mushroom", { "BrownMushroom" } },
	{ "red mushroom", { "RedMushroom" } },
	{ "mint", { "Mint" } },
	{ "wild ginger", { "WildGinger" } },
}

return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local Pack = require(shared.TexturePack)
	local Config = require(shared.Config)
	local B = Blocks.id

	local FACES = Blocks.TEXTURE_FACES
	local CUBE = { "top", "bottom", "north", "south", "east", "west" }

	-- Blocks that never carry a texture: not drawn, fluids, torches and lanterns, transmitters,
	-- tanks, machines (the solar panel too), structure blocks, structure voids, jigsaws and the
	-- Glow Block.
	local never: { [number]: boolean } = {}
	-- (Fire: its animated flames are drawn by its own renderer, not the pack.)
	for _, base in { B.Torch, B.Lantern, B.Fire } do
		for _, id in Blocks.variants(base) do
			never[id] = true
		end
	end
	for id, def in Blocks.defs do
		if
			def.kind == Blocks.KIND_NONE
			or def.kind == Blocks.KIND_FLUID
			or def.transmitter
			or def.tank
			or def.machine
			or def.structureMode
			or def.jigsaw
			or def.name == "StructureVoid"
			or def.name == "GlowBlock"
		then
			never[id] = true
		end
	end

	t.test("texture pack: shape", function()
		t.eq(Pack.StudsPerTile, 3, "one tile per block face")
		t.eq(Pack.StudsPerTile, Config.BlockSize, "StudsPerTile is a block")
		-- (The user turns it on to see what is left to make: either is fine here.)
		t.eq(type(Pack.ShowMissing), "boolean", "ShowMissing")
		t.eq(Pack.Missing, "missing texture")
		t.ok(Pack.Textures[Pack.Missing], "the missing texture is in the pack")
		local materials = {}
		for _, name in Blocks.VARIANT_MATERIALS do
			materials[name] = true
		end
		for _, refused in { "Neon", "Glass", "ForceField", "Air", "Water" } do
			t.ok(not materials[refused], `{refused} takes no variant`)
		end
		for name, texture in Pack.Textures do
			t.ok(
				string.match(name, "^[a-z][a-z ]*[a-z]$") and not string.find(name, "  ", 1, true),
				`"{name}": lower case words with spaces`
			)
			t.ok(type(texture.Color) == "string", `{name}: Color`)
			t.ok(
				texture.Color == "" or string.match(texture.Color, "^rbxassetid://%d+$"),
				`{name}: Color is an id or blank`
			)
			for _, map in { "Normal", "Roughness", "Metalness" } do
				local value = (texture :: any)[map]
				t.ok(
					value == nil or value == "" or string.match(value, "^rbxassetid://%d+$"),
					`{name}: {map} is an id, blank or none`
				)
			end
			t.ok(materials[texture.Material], `{name}: Material {texture.Material} takes a variant`)
			local tint = texture.Tint
			t.ok(
				tint == nil or type(tint) == "boolean" or Blocks.find(tint :: string) ~= nil,
				`{name}: Tint is a boolean or a block`
			)
			t.ok(texture.Align == nil or type(texture.Align) == "boolean", `{name}: Align`)
			t.eq(Blocks.textureOf(name), texture, `textureOf {name}`)
			t.eq(Blocks.textureFilled(name), texture.Color ~= "", `textureFilled {name}`)
		end
		t.eq(Blocks.textureOf("no such texture"), nil, "unknown texture")
		t.eq(Blocks.textureFilled("no such texture"), false)
		t.eq(Blocks.textureFilled(nil), false)
		local faceKeys = { All = true, Sides = true, Top = true, Bottom = true, Front = true, Sprite = true }
		for name, faces in Pack.Blocks do
			t.ok(Blocks.find(name), `{name} is a block`)
			for face, texture in faces :: any do
				t.ok(faceKeys[face], `{name}: face {face}`)
				t.ok(Pack.Textures[texture], `{name}: {face} texture {texture}`)
			end
		end
	end)

	t.test("texture pack: every block that can carry a texture has an entry, the others none", function()
		local textured, untextured = 0, 0
		for id, def in Blocks.defs do
			if never[id] then
				untextured += 1
				t.eq(def.textures, nil, `{def.name} is never textured`)
				t.eq(Pack.Blocks[def.name], nil, `{def.name} has no entry`)
			else
				textured += 1
				t.ok(def.textures ~= nil, `{def.name} has textures (blank or filled)`)
				local own = Pack.Blocks[def.name] ~= nil
				local twin = Blocks.caveTwinOf(id)
				local base = Blocks.variants(id)[1]
				t.ok(
					own or twin ~= nil or (base ~= id and Pack.Blocks[Blocks.get(base).name] ~= nil),
					`{def.name}: its own entry, its twin's or its variant group's`
				)
				if twin then
					t.ok(not own, `cave twin {def.name} has no entry of its own`)
				end
			end
		end
		t.eq(textured + untextured, Blocks.count)
		t.ok(textured >= 100, `{textured} blocks can carry a texture`)
		-- Spot checks of the never-textured kinds.
		for _, name in { "Air", "CaveAir", "Water", "Lava", "CaveLava", "Torch", "WallTorchEast", "HangingLantern" } do
			t.ok(never[B[name]], `{name} is never textured`)
		end
		for _, name in { "BasicUniversalCable", "UltimateFluidTank", "SolarPanel", "HeatGenerator", "StructureBlock" } do
			t.ok(never[B[name]], `{name} is never textured`)
		end
		for _, name in { "StructureVoid", "JigsawUpEast", "GlowBlock", "OilRefinery" } do
			t.ok(never[B[name]], `{name} is never textured`)
		end
	end)

	t.test("texture pack: the sheet's ids, with the two typo fixes", function()
		-- The sheet's blocks use its textures (in `blocks`, Blocks loaded from some pack).
		local function sheetUsers(blocks: any, what: string)
			for _, row in SHEET do
				local name, users = row[1], row[6]
				t.ok(
					includes(blocks.textureUsers(name), users),
					`{what}: {name} is used by {table.concat(users, ", ")}`
				)
			end
		end
		for _, row in SHEET do
			local name, color, normal, material, tint = row[1], row[2], row[3], row[4], row[5]
			local texture = Pack.Textures[name]
			t.ok(texture, `{name} is in the pack`)
			t.eq(texture.Color, `rbxassetid://{color}`, `{name} colour map`)
			t.eq(texture.Normal, if normal then `rbxassetid://{normal}` else nil, `{name} normal map`)
			t.eq(texture.Material, material, `{name} material`)
			t.eq(if texture.Tint == nil then true else texture.Tint, tint, `{name} tint`)
		end
		sheetUsers(Blocks, "the pack")
		-- The pack's hint (Minecraft's crafting table bottom) is taken up without breaking this.
		local hinted, Hinted = withPack(function(pack)
			pack.Blocks.CraftingTable.Bottom = "planks"
		end)
		t.ok(hinted, `the hinted pack loads: {Hinted}`)
		sheetUsers(Hinted, "with the crafting table hint")
		t.eq(Hinted.get(Hinted.id.CraftingTable).textures.bottom, "planks", "the hint gives the bottom planks")
		-- The typos: leaves' normal map was its colour map (dropped), packed mud's too (dirt's).
		t.eq(Pack.Textures.leaves.Normal, nil, "leaves have no normal map")
		t.eq(Pack.Textures.leaves.Align, false, "leaves are noise: never aligned")
		t.eq(Pack.Textures["packed mud"].Color, Pack.Textures.dirt.Color, "packed mud is dirt's image")
		t.eq(Pack.Textures["packed mud"].Normal, Pack.Textures.dirt.Normal, "with dirt's normal map")
		-- "Darker dirt": tinted towards a colour darker than dirt's in every channel, so packed mud
		-- never shows lighter than dirt (a part's tint only darkens) and darker unless the image is.
		local function target(texture: string, block: string): { number }
			local tint = Pack.Textures[texture].Tint
			return Blocks.get(B[if type(tint) == "string" then tint else block]).color
		end
		local mud, dirt = target("packed mud", "PackedMud"), target("dirt", "Dirt")
		for k = 1, 3 do
			t.ok(mud[k] < dirt[k], `packed mud is darker than dirt (channel {k}: {mud[k]} < {dirt[k]})`)
		end
		for name, texture in Pack.Textures do
			t.ok(texture.Color == "" or texture.Normal ~= texture.Color, `{name}: normal map is not the colour map`)
		end
	end)

	t.test("texture pack: the blank entries waiting to be made", function()
		for _, row in BLANKS do
			local name, users = row[1], row[2]
			t.ok(Pack.Textures[name], `{name} is in the pack`)
			t.ok(sameSet(Blocks.textureUsers(name), users), `{name} is used by {table.concat(users, ", ")}`)
		end
		-- Plant sprites keep their pictures' colours, except grass and ferns (their soil's foliage)
		-- and saplings (one black and white picture in each sapling's own colour).
		for id, def in Blocks.defs do
			local sprite = def.textures and def.textures.sprite
			if sprite then
				t.ok(def.plant ~= nil, `{def.name}: only plants have sprites`)
				local sapling = string.sub(def.name, -7) == "Sapling"
				t.eq(
					Pack.Textures[sprite].Tint ~= false,
					def.tinted or sapling,
					`{def.name}: sprite tinted like the plant`
				)
				if sapling then
					t.ok(not def.tinted, `{def.name}: its own green, not its soil's`)
				end
				t.eq(Pack.Textures[sprite].Material, "SmoothPlastic", `{def.name}: sprite material`)
			end
			if def.plant then
				t.ok(sprite ~= nil, `plant {def.name} has a sprite`)
			end
		end
		-- Every texture is used by a block (or is the missing texture).
		for name in Pack.Textures do
			t.ok(name == Pack.Missing or #Blocks.textureUsers(name) > 0, `{name} is used`)
		end
		local used = Blocks.texturesUsed
		for i = 2, #used do
			t.ok(used[i - 1] < used[i], "texturesUsed is sorted")
		end
		t.ok(table.find(used, "log top") and table.find(used, "dirt"), "texturesUsed")
		t.ok(not table.find(used, Pack.Missing), "no block uses the missing texture")
		t.eq(#Blocks.textureUsers("no such texture"), 0)
	end)

	t.test("texture pack: face resolution", function()
		local function faces(name: string): any
			return Blocks.get(B[name]).textures
		end
		local function expect(name: string, want: { [string]: string })
			local got = faces(name)
			for _, face in FACES do
				t.eq(got[face], want[face], `{name} {face}`)
			end
		end
		local function cube(top: string, bottom: string, side: string): { [string]: string }
			return { top = top, bottom = bottom, north = side, south = side, east = side, west = side }
		end
		expect("Dirt", cube("dirt", "dirt", "dirt"))
		expect("Grass", cube("grass top", "dirt", "grass side"))
		expect("DryGrass", cube("grass top", "dirt", "dry grass side"))
		expect("Podzol", cube("podzol top", "dirt", "podzol side"))
		expect("OakLog", cube("log top", "log top", "log"))
		expect("JungleLog", cube("log top", "log top", "log"))
		expect("Cactus", cube("cactus top", "cactus top", "cactus side"))
		expect("Sandstone", cube("sandstone top", "sandstone bottom", "sandstone side"))
		expect("SmoothSandstone", cube("sandstone top", "sandstone top", "sandstone top"))
		-- No Bottom: it falls back to the sides.
		expect("CutSandstone", cube("sandstone top", "cut sandstone", "cut sandstone"))
		-- (Its bottom is the pack's choice: the sides, or the planks of its hint.)
		local crafting = faces("CraftingTable")
		t.eq(crafting.top, "crafting table top", "CraftingTable top")
		for _, side in { "north", "south", "east", "west" } do
			t.eq(crafting[side], "crafting table side", `CraftingTable {side}`)
		end
		expect("Furnace", cube("furnace top", "furnace top", "furnace side"))
		expect("OakLeaves", cube("leaves", "leaves", "leaves"))
		expect("ShortGrass", { sprite = "short grass" })
		expect("TallGrass", { sprite = "tall grass bottom" })
		expect("TallGrassTop", { sprite = "tall grass top" })
		-- Glow lichen: one entry for the variant group, its cave twins take their twin's (the same
		-- table, so they can never differ).
		for _, id in Blocks.variants(B.GlowLichen) do
			local name = Blocks.get(id).name
			expect(name, { front = "glow lichen" })
			local twin = Blocks.caveTwinFor(id)
			t.ok(twin ~= nil, `{name} has a cave twin`)
			t.ok(rawequal(Blocks.get(twin :: number).textures, faces(name)), `{name}'s twin shares its textures`)
			t.eq(Blocks.get(twin :: number).appearance, Blocks.get(id).appearance, `{name}'s twin's appearance`)
		end
		t.eq(#Blocks.variants(B.GlowLichen), 6)
		t.ok(table.isfrozen(faces("Grass")), "read only")

		-- The rules on made up entries: All, then Sides; a variant group's entry, a member's own.
		local ok, Fresh = withPack(function(pack)
			pack.Blocks.Andesite = { Sides = "andesite", Top = "granite" }
			pack.Blocks.Granite = { All = "granite", Sides = "andesite", Bottom = "bedrock" }
			pack.Blocks.GlowLichen = nil
			pack.Blocks.GlowLichenUp = { Front = "glow lichen" }
			pack.Blocks.GlowLichenWest = { Front = "andesite" }
		end)
		t.ok(ok, `the made up pack loads: {Fresh}`)
		local function freshFaces(name: string): any
			return Fresh.get(Fresh.id[name]).textures
		end
		local a = freshFaces("Andesite")
		t.eq(a.top, "granite")
		t.eq(a.bottom, "andesite", "no Bottom, no All: the sides")
		t.eq(a.north, "andesite")
		local g = freshFaces("Granite")
		t.eq(g.top, "granite", "no Top: All")
		t.eq(g.bottom, "bedrock")
		t.eq(g.east, "andesite", "Sides over All")
		t.eq(
			freshFaces("GlowLichen").front,
			"glow lichen",
			"the first listed entry of the group covers its first block"
		)
		t.eq(freshFaces("GlowLichenNorth").front, "glow lichen", "and the other variants")
		t.eq(freshFaces("GlowLichenWest").front, "andesite", "a variant's own entry wins")
		t.eq(freshFaces("CaveGlowLichenWest").front, "andesite", "and its cave twin follows it")
	end)

	t.test("texture pack: appearances are keyed by textures", function()
		t.eq(
			#Blocks.appearances,
			169,
			"no appearance split or merged (157, the 5 saplings and fire, TNT and the Nuke lit and not, the 2 herbs)"
		)
		-- Blocks share an appearance only as before: a fluid's levels, a cave twin and its twin.
		local members: { [number]: { number } } = {}
		for id, def in Blocks.defs do
			if def.appearance > 0 then
				members[def.appearance] = members[def.appearance] or {}
				table.insert(members[def.appearance], id)
			end
		end
		for appearance, ids in members do
			local info = Blocks.appearances[appearance]
			local first = Blocks.get(ids[1])
			for _, id in ids do
				local def = Blocks.get(id)
				t.ok(rawequal(def.textures, info.textures), `{def.name}: its appearance's textures`)
				t.ok(
					id == ids[1]
						or (def.fluid ~= nil and first.fluid ~= nil and def.fluid.group == first.fluid.group)
						or Blocks.caveTwinOf(id) == ids[1],
					`{def.name} shares appearance {appearance} with {first.name} only as a level or twin`
				)
			end
			t.eq(Blocks.textureFaces(appearance), info.textures, `textureFaces({appearance})`)
			t.eq(Blocks.textureFaces(info), info.textures, "textureFaces(appearance table)")
			t.eq(info.sprite, if info.textures then info.textures.sprite else nil, `appearance {appearance} sprite`)
			local filled = false
			for _, face in FACES do
				filled = filled or Blocks.textureFilled(info.textures and (info.textures :: any)[face])
			end
			t.eq(
				info.textured,
				filled or (info.textures ~= nil and Pack.ShowMissing),
				`appearance {appearance} textured`
			)
		end
		t.eq(Blocks.textureFaces(0), nil, "air")
		t.ok(Blocks.appearances[Blocks.get(B.Stone).appearance].textured, "stone is textured")
		t.ok(Blocks.appearances[Blocks.get(B.ShortGrass).appearance].textured, "short grass has a sprite")
		t.ok(not Blocks.appearances[Blocks.get(B.Water).appearance].textured, "water is not")

		-- Blocks drawn alike that differ only in their textures get their own appearances.
		local function lookAlike(pack: any, list: any, texture: string)
			for _, spec in list do
				if spec.name == "Andesite" then
					spec.material, spec.color = "Slate", { 125, 125, 128 }
				end
			end
			pack.Blocks.Andesite = { All = texture }
		end
		local ok, Apart = withPack(function(pack, list)
			lookAlike(pack, list, "andesite")
		end)
		t.ok(ok, `loads: {Apart}`)
		t.ok(Apart.get(Apart.id.Andesite).appearance ~= Apart.get(Apart.id.Stone).appearance, "different textures")
		local ok2, Together = withPack(function(pack, list)
			lookAlike(pack, list, "stone")
		end)
		t.ok(ok2, `loads: {Together}`)
		t.eq(Together.get(Together.id.Andesite).appearance, Together.get(Together.id.Stone).appearance, "same textures")

		-- A blank texture leaves its blocks untextured (ShowMissing off); ShowMissing shows them all.
		for _, base in BASES do
			local ok3, Blank = withPack(function(pack)
				base.edit(pack)
				pack.ShowMissing = false
				pack.Textures.stone.Color = ""
			end)
			t.ok(ok3, `{base.name}: loads: {Blank}`)
			t.ok(
				not Blank.appearances[Blank.get(Blank.id.Stone).appearance].textured,
				`{base.name}: blank stone is untextured`
			)
			t.eq(Blank.get(Blank.id.Stone).appearance, Blocks.get(B.Stone).appearance, "and keeps its appearance")
		end
		local ok4, Missing = withPack(function(pack)
			pack.ShowMissing = true
		end)
		t.ok(ok4, `loads: {Missing}`)
		for _, info in Missing.appearances do
			t.eq(info.textured, info.textures ~= nil, `ShowMissing: appearance {info.id}`)
		end
	end)

	t.test("texture pack: variantTexture and alignLut", function()
		local function variant(name: string): string?
			return Blocks.variantTexture(Blocks.get(B[name]).appearance)
		end
		t.eq(variant("Stone"), "stone")
		t.eq(variant("Grass"), "grass side", "the sides' texture")
		t.eq(variant("OakLog"), "log")
		t.eq(variant("Sandstone"), "sandstone side")
		t.eq(variant("ShortGrass"), nil, "plants draw images")
		t.eq(variant("GlowLichen"), nil, "lichen draws an image")
		t.eq(Blocks.variantName("grass top"), "IV_grass_top")
		t.eq(Blocks.variantName("missing texture"), "IV_missing_texture")
		t.eq(Blocks.variantName("lily of the valley"), "IV_lily_of_the_valley")

		local lut = Blocks.alignLut
		t.eq(buffer.len(lut), #Blocks.appearances + 1, "one byte per appearance")
		t.eq(buffer.readu8(lut, 0), 0, "air")
		for _, info in Blocks.appearances do
			local texture = Blocks.variantTexture(info.id)
			local want = info.kind == Blocks.KIND_OPAQUE
				and info.shape == nil
				and buffer.readu8(Blocks.singleLut, info.id) == 0
				and texture ~= nil
				and Blocks.textureFilled(texture)
				and Pack.Textures[texture :: string].Align ~= false
			t.eq(buffer.readu8(lut, info.id), if want then 1 else 0, `alignLut[{info.id}]`)
		end
		local function align(name: string): number
			return buffer.readu8(lut, Blocks.get(B[name]).appearance)
		end
		for _, name in { "Stone", "Dirt", "Grass", "OakLog", "Planks", "Sand", "CoalOre", "Obsidian" } do
			t.eq(align(name), 1, `{name} is aligned`)
		end
		for _, name in { "OakLeaves", "JungleLeaves" } do
			t.eq(align(name), 0, `{name}: Align = false`)
		end
		for _, name in { "Water", "Lava", "ShortGrass", "GlowLichen", "Torch", "GlowBlock" } do
			t.eq(align(name), 0, `{name} is no textured cube`)
		end

		-- The rules on made up packs: blank textures, the top as the variant, ShowMissing, singles.
		-- (Each edit blanks what it needs and sets ShowMissing itself, so it holds on every base.)
		for _, base in BASES do
			local ok, Fresh = withPack(function(pack)
				base.edit(pack)
				pack.ShowMissing = false
				pack.Textures.stone.Color = ""
				pack.Textures["cut sandstone"].Color = ""
				pack.Textures.bedrock.Color = ""
				pack.Textures.chest.Color = "rbxassetid://1"
				pack.Blocks.Bedrock = { Top = "dirt", Sides = "bedrock", Bottom = "sand" }
			end)
			t.ok(ok, `{base.name}: loads: {Fresh}`)
			local function freshVariant(name: string): string?
				return Fresh.variantTexture(Fresh.get(Fresh.id[name]).appearance)
			end
			local function freshAlign(name: string): number
				return buffer.readu8(Fresh.alignLut, Fresh.get(Fresh.id[name]).appearance)
			end
			t.eq(freshVariant("Stone"), nil, `{base.name}: blank: no variant`)
			t.eq(freshAlign("Stone"), 0, "blank: not aligned")
			t.eq(freshVariant("CutSandstone"), "sandstone top", "blank sides: the top, the only filled texture")
			t.eq(freshAlign("CutSandstone"), 1)
			t.eq(freshVariant("Bedrock"), nil, `{base.name}: blank sides and another filled texture below: none`)
			t.eq(freshVariant("Chest"), "chest")
			t.eq(freshAlign("Chest"), 0, "decorated blocks are single boxes")
			local ok2, Missing = withPack(function(pack)
				base.edit(pack)
				pack.ShowMissing = true
				pack.Textures.bedrock.Color = ""
			end)
			t.ok(ok2, `{base.name}: loads: {Missing}`)
			t.eq(
				Missing.variantTexture(Missing.get(Missing.id.Bedrock).appearance),
				"missing texture",
				`{base.name}: ShowMissing on blank bedrock`
			)
			t.eq(buffer.readu8(Missing.alignLut, Missing.get(Missing.id.Bedrock).appearance), 1, "missing is aligned")
			t.eq(Missing.variantTexture(Missing.get(Missing.id.Grass).appearance), "grass side", "filled first")
		end
	end)

	t.test("texture pack: Blocks refuses a bad pack, naming the mistake", function()
		local function refuses(what: string, needle: string, edit: (pack: any) -> ())
			local ok, err = withPack(edit)
			t.ok(not ok, `{what} is refused`)
			t.ok(string.find(tostring(err), needle, 1, true), `{what}: "{err}" names {needle}`)
		end
		refuses("an unknown block", "Stonne", function(pack)
			pack.Blocks.Stonne = { All = "stone" }
		end)
		refuses("an unknown texture", "stoen", function(pack)
			pack.Blocks.Stone = { All = "stoen" }
		end)
		refuses("an unknown face", "top", function(pack)
			pack.Blocks.Stone = { top = "stone" }
		end)
		refuses("Neon", "Neon", function(pack)
			pack.Textures.stone.Material = "Neon"
		end)
		refuses("Glass", "Glass", function(pack)
			pack.Textures.glass.Material = "Glass"
		end)
		refuses("a made up material", "Stonish", function(pack)
			pack.Textures.stone.Material = "Stonish"
		end)
		refuses("a tint of an unknown block", "Dirtt", function(pack)
			pack.Textures.dirt.Tint = "Dirtt"
		end)
		refuses("a cave twin's entry", "CaveGlowLichen", function(pack)
			pack.Blocks.CaveGlowLichen = { Front = "glow lichen" }
		end)
		refuses("a fluid's entry", "Water", function(pack)
			pack.Blocks.Water = { All = "ice" }
		end)
		refuses("an unknown missing texture", "nothing here", function(pack)
			pack.Missing = "nothing here"
		end)
	end)

	t.test("texture pack: the generator's files are up to date", function()
		local result = TextureBuild.build(Pack, Blocks)
		t.eq(#result.errors, 0, `no errors: {table.concat(result.errors, "; ")}`)
		t.eq(#result.warnings, 0, `no warnings: {table.concat(result.warnings, "; ")}`)
		local stale = TextureBuild.stale(result, function(path)
			return if fs.isFile(path) then fs.readFile(path) else nil
		end)
		t.eq(#stale, 0, `{table.concat(stale, ", ")} out of date: run lune run tests/build_textures`)
		-- A Windows checkout (Git's text=auto writes CRLF) is up to date too; a changed file is not.
		local crlf = TextureBuild.stale(result, function(path)
			local text = result.files[path]
			return if text then (string.gsub(text, "\n", "\r\n")) else nil
		end)
		t.eq(#crlf, 0, `CRLF line endings are no change: {table.concat(crlf, ", ")}`)
		local edited = TextureBuild.stale(result, function(path)
			return result.files[path] .. "\n"
		end)
		t.eq(#edited, 2, "an edited file is out of date")
		t.eq(#TextureBuild.stale(result, function()
			return nil
		end), 2, "a missing file is out of date")
		local again = TextureBuild.build(Pack, Blocks)
		for path, text in result.files do
			t.eq(again.files[path], text, `{path} is deterministic`)
		end
	end)

	t.test("texture pack: the generator's output", function()
		local result = TextureBuild.build(Pack, Blocks)
		local filledCount = 0
		for _, texture in Pack.Textures do
			if texture.Color ~= "" then
				filledCount += 1
			end
		end
		t.eq(#result.filled, filledCount)
		t.eq(#result.filled + #result.blank, #(function()
			local names = {}
			for name in Pack.Textures do
				table.insert(names, name)
			end
			return names
		end)())

		local materials = serde.decode("json", result.files[TextureBuild.MATERIALS])
		local images = serde.decode("json", result.files[TextureBuild.IMAGES])
		t.eq(materials.className, "Folder")
		t.eq(images.className, "Folder")
		t.eq(#materials.children, filledCount, "a variant per filled texture")
		t.eq(#images.children, filledCount, "a prototype per filled texture")
		local byName = {}
		for _, name in result.filled do
			byName[Blocks.variantName(name)] = Pack.Textures[name]
		end
		for index, variant in materials.children do
			local texture = byName[variant.name]
			t.ok(texture, `{variant.name} is a filled texture's`)
			t.eq(variant.className, "MaterialVariant")
			local p = variant.properties
			t.eq(p.BaseMaterial, texture.Material, `{variant.name} BaseMaterial`)
			t.eq(p.ColorMapContent, texture.Color, `{variant.name} colour`)
			t.eq(p.NormalMapContent, if texture.Normal ~= "" then texture.Normal else nil, `{variant.name} normal`)
			t.eq(p.StudsPerTile, Pack.StudsPerTile)
			t.eq(p.MaterialPattern, "Regular")
			t.eq(p.AlphaMode, nil, "no AlphaMode")
			local image = images.children[index]
			t.eq(image.name, variant.name, "prototypes in the same order")
			t.eq(image.className, "Texture")
			t.eq(image.properties.TextureContent, texture.Color, `{image.name} image`)
			t.eq(image.properties.NormalMapContent, p.NormalMapContent, `{image.name} normal`)
			t.eq(image.properties.StudsPerTileU, Pack.StudsPerTile)
			t.eq(image.properties.StudsPerTileV, Pack.StudsPerTile)
			if index > 1 then
				t.ok(materials.children[index - 1].name < variant.name, "sorted by name")
			end
		end
		t.ok(byName.IV_grass_top and byName.IV_missing_texture, "grass top and the missing texture")
		for path, text in result.files do
			t.ok(not string.find(text, '""', 1, true), `{path}: no empty values (Rojo would store an empty Uri)`)
			t.eq(string.sub(text, -2), "}\n", `{path} ends with a newline`)
		end

		-- The filled textures without an Average (their distant colours are a guess until it is
		-- measured and pasted in), sorted.
		local unmeasured = {}
		for _, name in result.filled do
			if Pack.Textures[name].Average == nil then
				table.insert(unmeasured, name)
			end
		end
		t.eq(#result.unmeasured, #unmeasured, "every filled texture without an Average")
		for index, name in unmeasured do
			t.eq(result.unmeasured[index], name)
		end
		local measuredPack = copyPack(Pack)
		measuredPack.Textures.dirt.Average = { 121, 85, 58 }
		measuredPack.Textures.andesite.Color = ""
		local measured = TextureBuild.build(measuredPack, Blocks)
		t.ok(not table.find(measured.unmeasured, "dirt"), "an Average takes it off the list")
		t.ok(not table.find(measured.unmeasured, "andesite"), "blank textures are not on it")

		-- --list: every blank texture and the blocks waiting on it, then the textures still
		-- waiting for an Average.
		local lines = TextureBuild.list(result, Blocks)
		t.eq(#lines, #result.blank + 1 + (if #unmeasured > 0 then #unmeasured + 1 else 0))
		for index, name in result.blank do
			local line = lines[index + 1]
			t.ok(string.find(line, name, 1, true), `list line for {name}`)
			for _, user in Blocks.textureUsers(name) do
				t.ok(string.find(line, user, 1, true), `{name} lists {user}`)
			end
		end
		for index, name in unmeasured do
			t.ok(string.find(lines[#result.blank + 2 + index], name, 1, true), `list line for {name}'s Average`)
		end
		local note = TextureBuild.unmeasuredNote(result)
		t.eq(note == nil, #unmeasured == 0, "a note while any Average is missing")
		t.ok(note == nil or string.find(note, "--list", 1, true), "it points at --list")
		t.eq(TextureBuild.unmeasuredNote({ unmeasured = {} } :: any), nil, "no note once all are measured")
	end)

	t.test("texture pack: the generator refuses bad ids and materials, and warns", function()
		local function errorsFor(edit: (pack: any) -> ()): ({ string }, { string })
			local pack = copyPack(Pack)
			edit(pack)
			local result = TextureBuild.build(pack, Blocks)
			if #result.errors > 0 then
				t.eq(next(result.files), nil, "nothing to write")
			end
			return result.errors, result.warnings
		end
		local function has(list: { string }, needle: string): boolean
			for _, line in list do
				if string.find(line, needle, 1, true) then
					return true
				end
			end
			return false
		end
		for _, material in { "Neon", "Glass", "ForceField", "Air" } do
			local errors = errorsFor(function(pack)
				pack.Textures.stone.Material = material
			end)
			t.ok(has(errors, material), `{material} is refused`)
		end
		local errors = errorsFor(function(pack)
			pack.Textures.stone.Color = "12345"
			pack.Textures.dirt.Normal = "rbxasset://textures/dirt.png"
			pack.Textures.sand.Normals = "rbxassetid://1"
			pack.Textures.snow.Average = { 300, 0, 0 }
		end)
		t.ok(has(errors, '"stone"'), "a colour map that is no asset id")
		t.ok(has(errors, '"dirt"'), "a normal map that is no asset id")
		t.ok(has(errors, "Normals"), "an unknown field")
		t.ok(has(errors, '"snow"'), "an average out of range")
		local ok, warnings = errorsFor(function(pack)
			pack.Textures.stone.Normal = pack.Textures.stone.Color
			pack.Textures["lonely"] = { Color = "rbxassetid://5", Material = "Rock" }
		end)
		t.eq(#ok, 0, "warnings are no errors")
		t.ok(has(warnings, '"stone"'), "a normal map repeating the colour map")
		t.ok(has(warnings, '"lonely"'), "a filled texture no block uses")
		local fine = errorsFor(function(pack)
			pack.Textures.andesite.Color = "rbxassetid://42"
			pack.Textures.andesite.Average = { 120, 121, 122 }
		end)
		t.eq(#fine, 0, "a filled blank is fine")
	end)
end
