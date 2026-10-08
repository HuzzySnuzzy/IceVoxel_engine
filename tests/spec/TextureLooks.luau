--[[
	Rendering/TextureLooks, the client's looks of the texture pack, under Lune with fake services:
	the tint maths (linear light, clamping, the Tint modes, unknown averages), what faces average
	to and the plain colours, the near and far looks per face (grass, logs, sandstone, cactus, ores,
	blank textures, ShowMissing), textures too dark for their blocks (images near, the plain colour
	far, one summary), the missing texture for a missing MaterialVariant or a failed id, sprites
	and glow lichen, the far meshes' looks (`lookOf`, `lookInfo`), the generations and the
	`changed` and `itemsChanged` signals behind the settings, and the startup checks: every map's
	id preloaded through Decals and averages measured from EditableImage pixels, printed ready to
	paste, with failures named by cause.

	Every test starts from the pack as the user keeps it, made neutral: ShowMissing off and no
	Average. A test that needs a blank texture makes it blank itself, so filling the pack's blank
	entries (or pasting averages) never breaks these tests.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Loader = require("../lib/Loader")

local Color3 = roblox.Color3
local Vector2 = roblox.Vector2
local Enum = roblox.Enum

local GLOBALS = "script, require, game, Instance, Vector2, Color3, Enum, Content, task, warn, print"
local PATH = "src/client/Rendering/TextureLooks.luau"

local function withHeader(source: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
	return table.concat(lines, "\n")
end

-- A property bag standing in for an Instance (Decals, Textures, prototypes).
local function fakeInstance(class: string): any
	local o: any = { ClassName = class, destroyed = false }
	function o.Destroy(self: any)
		self.destroyed = true
	end
	function o.IsA(_: any, name: string): boolean
		return name == class or name == "Instance"
	end
	function o.Clone(self: any): any
		local copy = table.clone(self)
		copy.cloned = true
		return copy
	end
	return o
end

--[[
	A fresh TextureLooks (and Blocks) after `edit` changed the pack and Config of their own Loader
	environment; the pack starts neutral (ShowMissing off, no Average), and `blanks` names textures
	made blank. The fake world: `variants` (true: every MaterialVariant exists; a set of names),
	`prototypes` (names of Texture prototypes in ReplicatedStorage.IceVoxelTextures), `fetch`
	(content id -> Enum.AssetFetchStatus for PreloadAsync), `images` (content id -> RGBA pixels and
	size, an error string, or false for a full memory budget, for CreateEditableImageAsync), and
	what the module warned and printed.
]]
local function newLooks(edit: ((pack: any, config: any) -> ())?, blanks: { string }?): any
	local env = Loader.new()
	local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
	local pack = env.require(root.TexturePack)
	local Config = env.require(root.Config)
	pack.ShowMissing = false
	for _, texture in pack.Textures do
		texture.Average = nil
	end
	for _, name in blanks or {} do
		assert(pack.Textures[name], `no texture "{name}"`).Color = ""
	end
	if edit then
		edit(pack, Config)
	end
	local Blocks = env.require(root.Blocks)
	local world: any = {
		Blocks = Blocks,
		Config = Config,
		pack = pack,
		variants = true,
		prototypes = {},
		fetch = {},
		images = {},
		warnings = {},
		printed = {},
		preloaded = {},
		created = {},
	}
	local folder = {
		FindFirstChild = function(_, name: string): any
			if world.prototypes[name] then
				local proto = fakeInstance("Texture")
				proto.Name = name
				proto.TextureContent = `proto:{name}`
				proto.NormalMapContent = `normal:{name}`
				return proto
			end
			return nil
		end,
	}
	local services: { [string]: any } = {
		ReplicatedStorage = {
			WaitForChild = function(_, name: string)
				assert(name == "IceVoxel")
				return root
			end,
			FindFirstChild = function(_, name: string)
				return if name == "IceVoxelTextures" then folder else nil
			end,
		},
		MaterialService = {
			GetMaterialVariant = function(_, material: any, name: string)
				world.lookups = (world.lookups or 0) + 1
				if world.variants == true or world.variants[name] then
					return { Name = name, BaseMaterial = material }
				end
				return nil
			end,
		},
		ContentProvider = {
			PreloadAsync = function(_, list: { any }, callback: (string, any) -> ())
				for _, decal in list do
					local id = decal.TextureContent
					table.insert(world.preloaded, id)
					callback(id, world.fetch[id] or Enum.AssetFetchStatus.Success)
				end
			end,
		},
		AssetService = {
			CreateEditableImageAsync = function(_, content: string): any
				local image = world.images[content]
				if type(image) == "string" then
					error(image)
				elseif image == false then
					return nil
				elseif image == nil then
					error("not allowed")
				end
				return {
					Size = image.size,
					ReadPixelsBuffer = function(_, _position: any, size: any): buffer
						assert(size == image.size)
						return image.pixels
					end,
					Destroy = function()
						image.destroyed = true
					end,
				}
			end,
		},
	}
	local game = {
		GetService = function(_, name: string)
			return assert(services[name], `no fake service {name}`)
		end,
	}
	local Instance = {
		new = function(class: string)
			local o = fakeInstance(class)
			table.insert(world.created, o)
			return o
		end,
	}
	local Content = {
		fromUri = function(uri: string): string
			return uri
		end,
	}
	local task = {
		spawn = function(fn: () -> ())
			fn()
		end,
		wait = function()
			return 0
		end,
	}
	local function warn(...)
		table.insert(world.warnings, table.concat({ ... }, " "))
	end
	local function print(...)
		table.insert(world.printed, table.concat({ ... }, " "))
	end
	local chunk = luau.load(withHeader(fs.readFile(PATH)), { debugName = PATH })
	world.Looks = chunk({}, env.require, game, Instance, Vector2, Color3, Enum, Content, task, warn, print)
	return world
end

-- Solid RGBA pixels of a `w` x `h` image.
local function solid(w: number, h: number, r: number, g: number, b: number, a: number?): any
	local pixels = buffer.create(w * h * 4)
	for i = 0, w * h - 1 do
		buffer.writeu8(pixels, i * 4, r)
		buffer.writeu8(pixels, i * 4 + 1, g)
		buffer.writeu8(pixels, i * 4 + 2, b)
		buffer.writeu8(pixels, i * 4 + 3, a or 255)
	end
	return { pixels = pixels, size = Vector2.new(w, h) }
end

local function sameColour(t: any, actual: any, expected: any, message: string, tolerance: number?)
	local tol = tolerance or 1e-6
	t.near(actual.R, expected.R, tol, `{message} (red)`)
	t.near(actual.G, expected.G, tol, `{message} (green)`)
	t.near(actual.B, expected.B, tol, `{message} (blue)`)
end

local function byteColour(c: { number }): any
	return Color3.new(c[1] / 255, c[2] / 255, c[3] / 255)
end

-- Textures these tests treat as blank (made blank by `newLooks`, whatever the pack holds).
local BLANKS = {
	"log top",
	"cut sandstone",
	"andesite",
	"bedrock",
	"stone bricks",
	"glass",
	"chest",
	"mycelium top",
	"mycelium side",
	"podzol top",
	"podzol side",
	"fern",
	"poppy",
}

return function(t)
	local base = newLooks()
	local Looks, Blocks = base.Looks, base.Blocks
	local B = Blocks.id
	-- The same with BLANKS blank.
	local blank = newLooks(nil, BLANKS)
	local BlankLooks = blank.Looks

	local function app(name: string): number
		return Blocks.get(B[name]).appearance
	end
	local function colourOf(name: string): any
		return byteColour(Blocks.get(B[name]).color)
	end
	local function imageOn(look: any, face: any): any?
		for _, image in look.images do
			if image.face == face then
				return image
			end
		end
		return nil
	end

	--[[ Colour maths ]]

	t.test("texture looks: linear light, tints, clamping and unknown averages", function()
		t.near(Looks.toLinear(0.5), 0.214041, 1e-5, "sRGB 0.5 in linear light")
		t.near(Looks.toSrgb(Looks.toLinear(0.3)), 0.3, 1e-9, "round trip")
		t.ok(Looks.toSrgb(2) > 1, "brightening values stay above 1")
		-- No target (Tint false): white, never clamped.
		local tint, clamped, did = Looks.tintOf(nil, { 10, 20, 30 })
		t.eq(tint[1] + tint[2] + tint[3], 3)
		t.eq(clamped[1] + clamped[2] + clamped[3], 3)
		t.eq(did, false)
		-- Unknown average: the target itself (a plain multiply).
		tint, clamped, did = Looks.tintOf({ 51, 102, 204 }, nil)
		t.near(tint[1], 0.2, 1e-9)
		t.near(tint[3], 0.8, 1e-9)
		t.near(clamped[2], 0.4, 1e-9)
		t.eq(did, false)
		-- Average = target: white.
		tint = Looks.tintOf({ 90, 120, 60 }, { 90, 120, 60 })
		for k = 1, 3 do
			t.near(tint[k], 1, 1e-9, "the texture already averages the target")
		end
		-- A ratio in linear light, not sRGB: 64 / 128 is 0.525, not 0.5.
		tint = Looks.tintOf({ 64, 64, 64 }, { 128, 128, 128 })
		t.near(tint[1], 0.5246, 1e-3, "linear-light ratio")
		-- A light texture tinted darker: no clamping, it averages the target exactly.
		local target, light = { 100, 70, 40 }, { 200, 190, 180 }
		tint, clamped, did = Looks.tintOf(target, light)
		t.eq(did, false)
		local shown = Looks.shownOf(light, clamped)
		for k = 1, 3 do
			t.near(shown[k] * 255, target[k], 1e-6, "averages the target")
		end
		-- A dark texture tinted lighter: the part's tint stops at 1 (darker than wanted), an
		-- image's goes above 1 and still averages the target.
		local dark = { 40, 60, 90 }
		tint, clamped, did = Looks.tintOf(target, dark)
		t.eq(did, true, "clamped")
		t.ok(tint[1] > 1 and clamped[1] == 1, "red above 1 unclamped, 1 on parts")
		t.near(Looks.shownOf(dark, tint)[1] * 255, target[1], 1e-6, "images still average the target")
		t.ok(Looks.shownOf(dark, clamped)[1] * 255 < target[1] - 1, "parts show darker")
	end)

	t.test("texture looks: averages of pixels (linear light, alpha weighted) and the paste block", function()
		-- Half white, half black: the linear mean 0.5 is sRGB 188, not 128.
		local w, h = 16, 16
		local pixels = buffer.create(w * h * 4)
		for i = 0, w * h - 1 do
			local v = if i % 2 == 0 then 255 else 0
			buffer.writeu8(pixels, i * 4, v)
			buffer.writeu8(pixels, i * 4 + 1, v)
			buffer.writeu8(pixels, i * 4 + 2, v)
			buffer.writeu8(pixels, i * 4 + 3, 255)
		end
		local average = Looks.averagePixels(pixels, w, h, 1) :: { number }
		t.eq(average[1], 188, "linear mean")
		-- Transparent texels do not count (sprites); every 8th texel each way.
		local sprite = solid(16, 16, 200, 100, 50)
		for i = 0, 16 * 16 - 1 do
			if (i // 16) % 2 == 1 then
				buffer.writeu8(sprite.pixels, i * 4, 0)
				buffer.writeu8(sprite.pixels, i * 4 + 3, 0)
			end
		end
		local seen = Looks.averagePixels(sprite.pixels, 16, 16, 8) :: { number }
		t.eq(seen[1], 200)
		t.eq(seen[2], 100)
		t.eq(Looks.averagePixels(buffer.create(4 * 4 * 4), 4, 4, 1), nil, "nothing opaque")
		-- The print: a header, then one line per texture in the pack's syntax, sorted.
		local text = Looks.formatAverages({ ["grass top"] = { 92, 158, 62 }, dirt = { 121, 85, 58 } })
		t.eq(
			text,
			"[IceVoxel] Texture averages (paste into TexturePack.Textures[...].Average):\n"
				.. '\tAverage = { 121, 85, 58 }, -- ["dirt"]\n'
				.. '\tAverage = { 92, 158, 62 }, -- ["grass top"]'
		)
		-- Its lines are valid Luau inside a pack entry.
		local line = string.split(text, "\n")[2]
		local entry = (luau.load(`return \{ Color = "", {line}\n\}`) :: any)()
		t.eq(entry.Average[3], 58)
	end)

	--[[ Looks ]]

	t.test("texture looks: grass, dry grass, dirt and packed mud near, far and plain", function()
		local grass = Looks.nearLook(app("Grass"))
		t.eq(grass.texture, "grass side", "the sides' variant covers every face")
		t.eq(grass.variant, "IV_grass_side")
		t.eq(grass.material, Enum.Material.Ground, "the texture's material, not the block's")
		sameColour(t, grass.color, Color3.new(1, 1, 1), "grass side keeps its own colours")
		t.eq(#grass.images, 1, "one image: the top")
		local top = imageOn(grass, Enum.NormalId.Top)
		t.eq(top.texture, "grass top")
		sameColour(t, top.color, colourOf("Grass"), "the top in the grass colour (unknown average)")
		t.eq(imageOn(grass, Enum.NormalId.Bottom), nil, "no bottom image (BottomFaces off)")
		local far = Looks.farLook(app("Grass"))
		t.eq(far.variant, "IV_grass_top", "far: the top's variant")
		t.eq(far.material, Enum.Material.Grass)
		sameColour(t, far.color, colourOf("Grass"), "far tint")
		t.eq(#far.images, 0, "far: no images")
		sameColour(t, Looks.plainColour(app("Grass")), colourOf("Grass"), "plain: what the top averages to")
		-- Dry grass: the same top in its own colour; its own sides (blank: its plain look, not the
		-- green fringe).
		local dry = Looks.nearLook(app("DryGrass"))
		t.eq(dry.texture, if Blocks.textureFilled("dry grass side") then "dry grass side" else nil)
		if not Blocks.textureFilled("dry grass side") then
			t.eq(dry.variant, "", "blank sides: no variant")
			sameColour(t, dry.color, colourOf("DryGrass"), "the dry grass colour")
		end
		sameColour(t, imageOn(dry, Enum.NormalId.Top).color, colourOf("DryGrass"), "dry grass top")
		sameColour(t, Looks.farLook(app("DryGrass")).color, colourOf("DryGrass"))
		-- Dirt and packed mud share a colour map, each in its own colour.
		local dirt = Looks.nearLook(app("Dirt"))
		t.eq(dirt.variant, "IV_dirt")
		sameColour(t, dirt.color, colourOf("Dirt"))
		t.eq(#dirt.images, 0)
		local mud = Looks.nearLook(app("PackedMud"))
		t.eq(mud.variant, "IV_packed_mud")
		t.eq(mud.material, Enum.Material.Mud)
		sameColour(t, mud.color, colourOf("PackedMud"))
		-- The grass bottom averages the Dirt colour (Tint "Dirt"); the sides keep their own.
		sameColour(t, Looks.averageOf(app("Grass"), "east"), colourOf("Grass"), "unknown average, Tint false")
	end)

	t.test("texture looks: logs, sandstone, cactus, ores and blank textures", function()
		for _, name in { "OakLog", "BirchLog", "SpruceLog", "AcaciaLog", "JungleLog" } do
			local look = Looks.nearLook(app(name))
			t.eq(look.texture, "log", name)
			t.eq(look.material, Enum.Material.Wood)
			sameColour(t, look.color, colourOf(name), `{name} takes its voxel colour`)
			local bare = BlankLooks.nearLook(app(name))
			t.eq(#bare.images, 0, `{name}: its blank top shows the bark`)
			t.eq(BlankLooks.farLook(app(name)).texture, "log", "far: the sides (the top is blank)")
		end
		for _, name in { "Planks", "BirchPlanks", "JunglePlanks" } do
			sameColour(t, Looks.nearLook(app(name)).color, colourOf(name), name)
		end
		local sandstone = Looks.nearLook(app("Sandstone"))
		t.eq(sandstone.texture, "sandstone side")
		t.eq(imageOn(sandstone, Enum.NormalId.Top).texture, "sandstone top")
		t.eq(Looks.farLook(app("Sandstone")).texture, "sandstone top")
		local smooth = Looks.nearLook(app("SmoothSandstone"))
		t.eq(smooth.texture, "sandstone top")
		t.eq(#smooth.images, 0, "one texture everywhere: no image")
		local cut = BlankLooks.nearLook(app("CutSandstone"))
		t.eq(cut.texture, "sandstone top", "blank sides: the top, the only filled texture")
		local cactus = Looks.nearLook(app("Cactus"))
		t.eq(cactus.texture, "cactus side")
		t.eq(imageOn(cactus, Enum.NormalId.Top).texture, "cactus top")
		for _, name in { "CoalOre", "IronOre", "GoldOre", "DiamondOre" } do
			local ore = Looks.nearLook(app(name))
			t.eq(ore.material, Enum.Material.Rock, name)
			sameColour(t, ore.color, Color3.new(1, 1, 1), `{name}: its own colours`)
			sameColour(t, Looks.plainColour(app(name)), colourOf(name), `{name}: unknown average, voxel colour`)
		end
		-- Blank textures: the block's own look everywhere.
		for _, name in { "Andesite", "Bedrock", "StoneBricks", "Glass", "Chest", "Mycelium", "Podzol" } do
			t.eq(BlankLooks.nearLook(app(name)), nil, `{name}: near`)
			t.eq(BlankLooks.farLook(app(name)), nil, `{name}: far`)
			sameColour(t, BlankLooks.plainColour(app(name)), colourOf(name), `{name}: plain`)
		end
		-- Never textured: water, torches, air.
		t.eq(Looks.nearLook(app("Water")), nil)
		t.eq(Looks.nearLook(app("Torch")), nil)
		t.eq(Looks.itemFaces(app("Water")), nil)
	end)

	t.test("texture looks: item cube faces, sprites and glow lichen", function()
		local faces = Looks.itemFaces(app("Grass")) :: { any }
		t.eq(#faces, 6, "every face of a grass item")
		local byFace = {}
		for _, image in faces do
			byFace[image.face.Name] = image
		end
		t.eq(byFace.Top.texture, "grass top")
		t.eq(byFace.Bottom.texture, "dirt")
		sameColour(t, byFace.Bottom.color, colourOf("Dirt"), "the bottom in the Dirt colour")
		t.eq(byFace.Front.texture, "grass side")
		t.eq(#(BlankLooks.itemFaces(app("OakLog")) :: { any }), 4, "a log's blank ends keep its material")
		t.eq(BlankLooks.itemFaces(app("Andesite")), nil)
		-- Sprites: tinted grass per soil tint, like its boxes.
		local sprite = Looks.spriteOf(app("ShortGrass"))
		t.eq(sprite.texture, "short grass")
		t.ok(sprite.tinted)
		local c = Blocks.get(B.ShortGrass).color
		sameColour(t, sprite.tints[1], byteColour(c), "untinted: the plant's colour")
		local m = Blocks.FOLIAGE_TINTS[1]
		sameColour(
			t,
			sprite.tints[2],
			byteColour({
				math.min(255, math.round(c[1] * m[1])),
				math.min(255, math.round(c[2] * m[2])),
				math.min(255, math.round(c[3] * m[3])),
			}),
			"on dry grass"
		)
		t.eq(#sprite.tints, #Blocks.FOLIAGE_TINTS + 1)
		t.eq(Looks.spriteOf(app("TallGrass")).texture, "tall grass bottom")
		t.eq(Looks.spriteOf(app("TallGrassTop")).texture, "tall grass top")
		t.eq(BlankLooks.spriteOf(app("Fern")), nil, "blank sprite: the boxes")
		t.eq(BlankLooks.spriteOf(app("Poppy")), nil)
		-- Glow lichen: the face away from its support, in its own colours.
		local away = {
			GlowLichen = Enum.NormalId.Top,
			GlowLichenUp = Enum.NormalId.Bottom,
			GlowLichenNorth = Enum.NormalId.Back,
			GlowLichenSouth = Enum.NormalId.Front,
			GlowLichenWest = Enum.NormalId.Right,
			GlowLichenEast = Enum.NormalId.Left,
			CaveGlowLichenWest = Enum.NormalId.Right,
		}
		for name, face in away do
			local front = Looks.frontOf(app(name))
			t.eq(front.face, face, name)
			t.eq(front.texture, "glow lichen")
			sameColour(t, front.color, Color3.new(1, 1, 1), name)
		end
		t.eq(Looks.frontOf(app("Stone")), nil)
	end)

	t.test("texture looks: textured shapes: a Front replaces the boxes, cube faces dress them", function()
		local function list(boxes: { number }?): string
			return if boxes then table.concat(boxes, ",") else "nil"
		end
		-- Pure: the plate alone with a picture; without, every box but a see-through plate.
		local ladder = Blocks.get(B.Ladder).shape
		local rungs = {}
		for i = 2, #ladder do
			table.insert(rungs, i)
		end
		t.eq(ladder[1].transparency, 1, "the ladder's plate only carries its picture")
		t.eq(list(Looks.drawnBoxesOf(ladder, 0, true)), "1", "a picture: the plate")
		t.eq(list(Looks.drawnBoxesOf(ladder, 0, false)), table.concat(rungs, ","), "no picture: rails and rungs")
		local lit = {
			{ size = { 2, 2, 2 }, offset = { 0, 0, 0 }, glow = true, transparency = 1 },
			{ size = { 4, 4, 4 }, offset = { 0, 0, 0 } },
			{ size = { 4, 4, 4 }, offset = { 0, 4, 0 } },
		}
		t.eq(Looks.plateBox(lit), 2, "the plate is the first box that does not glow")
		t.eq(list(Looks.drawnBoxesOf(lit, 0, true)), "1,2", "glowing boxes stay with a picture")
		t.eq(list(Looks.drawnBoxesOf(lit, 0, false)), "1,2,3", "a see-through light carrier stays")
		t.eq(list(Looks.drawnBoxesOf(lit, 1, false)), "1", "the block's own transparency counts")
		-- Glow lichen looks as it did: every box, its picture or not.
		local lichen = Blocks.get(B.GlowLichen).shape
		local every = {}
		for i = 1, #lichen do
			table.insert(every, i)
		end
		t.ok(Looks.frontOf(app("GlowLichen")) ~= nil, "lichen draws its picture")
		t.eq(list(Looks.drawnBoxes(app("GlowLichen"))), table.concat(every, ","), "lichen keeps its boxes")
		t.eq(list(Looks.drawnBoxesOf(lichen, 0, false)), table.concat(every, ","), "without its picture too")
		t.eq(Looks.drawnBoxes(app("Stone")), nil, "cubes have no boxes")

		-- The blocks with their textures blank, then filled.
		local blank = newLooks(nil, { "ladder", "rail", "vine", "moss block" })
		local BL, BB = blank.Looks, blank.Blocks
		local function bapp(BBlocks: any, name: string): number
			return BBlocks.get(BBlocks.id[name]).appearance
		end
		t.eq(BL.frontOf(bapp(BB, "Ladder")), nil, "a blank ladder: no picture")
		t.eq(list(BL.drawnBoxes(bapp(BB, "Ladder"))), table.concat(rungs, ","), "its rails and rungs")
		t.eq(list(BL.drawnBoxes(bapp(BB, "Rail"))), "1,2,3", "a blank rail: sleepers and bars")
		t.eq(BL.shapeLook(bapp(BB, "MossCarpet")), nil, "a blank carpet keeps its colour")
		local filled = newLooks(function(pack)
			for _, name in { "ladder", "rail", "vine", "moss block" } do
				pack.Textures[name].Color = `rbxassetid://{#name}`
			end
		end)
		local FL, FB = filled.Looks, filled.Blocks
		for _, name in { "Ladder", "LadderSouth", "LadderWest", "LadderEast" } do
			t.ok(FL.frontOf(bapp(FB, name)) ~= nil, `{name}: its picture`)
			t.eq(list(FL.drawnBoxes(bapp(FB, name))), "1", `{name}: the plate alone`)
			t.eq(list(FL.drawnBoxes(bapp(FB, name), true)), table.concat(rungs, ","), `{name}: plain`)
		end
		t.eq(FL.frontOf(bapp(FB, "Ladder")).face, Enum.NormalId.Front, "on the face away from its wall")
		t.eq(FL.frontOf(bapp(FB, "RailEastWest")).face, Enum.NormalId.Top, "a rail's on top")
		t.eq(list(FL.drawnBoxes(bapp(FB, "CaveRail"))), "1", "twins too")
		t.eq(list(FL.drawnBoxes(bapp(FB, "VineWest"))), "1", "a vine is its plate")
		-- Cube faces dress a shape: the fence post in planks, the carpet in moss.
		local fence = FL.shapeLook(bapp(FB, "OakFence"))
		t.ok(fence ~= nil, "the fence takes its planks")
		t.eq(fence.texture, "planks")
		t.eq(fence.variant, FB.variantName("planks"))
		t.eq(fence.material, Enum.Material.WoodPlanks)
		t.eq(#fence.images, 0, "no images on boxes")
		t.eq(FL.shapeLook(bapp(FB, "CaveOakFence")).texture, "planks", "and its twin")
		t.eq(FL.shapeLook(bapp(FB, "MossCarpet")).texture, "moss block", "the carpet its moss")
		t.eq(FL.shapeLook(bapp(FB, "Torch")), nil, "a torch keeps its boxes' colours")
		t.eq(FL.shapeLook(bapp(FB, "Ladder")), nil, "a picture is no cube face")
		t.eq(FL.nearLook(bapp(FB, "OakFence")), nil, "no cube look for a shape")
		-- Textures off: boxes as they are.
		FL.setStyle(false, false)
		t.eq(FL.shapeLook(bapp(FB, "OakFence")), nil, "textures off: the fence's own colour")
		t.eq(list(FL.drawnBoxes(bapp(FB, "Ladder"))), table.concat(rungs, ","), "textures off: rails and rungs")
	end)

	t.test("texture looks: images are clones of the prototypes, else new from the colour map", function()
		local world = newLooks()
		world.prototypes = { IV_grass_top = true }
		local image = world.Looks.newImage("grass top", Enum.NormalId.Top, Color3.new(0.5, 1, 0.25), 6)
		t.ok(image.cloned, "cloned prototype")
		t.eq(image.NormalMapContent, "normal:IV_grass_top", "keeps its normal map")
		t.eq(image.Face, Enum.NormalId.Top)
		t.eq(image.StudsPerTileU, 6)
		t.eq(image.StudsPerTileV, 6)
		t.eq(image.Color3, Color3.new(0.5, 1, 0.25))
		local fresh = world.Looks.newImage("dirt", Enum.NormalId.Bottom, Color3.new(1, 1, 1))
		t.eq(fresh.ClassName, "Texture")
		t.eq(fresh.TextureContent, "rbxassetid://124863036266976")
		t.eq(fresh.StudsPerTileU, 3, "one tile per block")
		local decal = world.Looks.newDecal("grass top", Enum.NormalId.Back, Color3.new(1, 1, 1))
		t.eq(decal.ClassName, "Decal")
		t.eq(decal.TextureContent, "proto:IV_grass_top", "the prototype's colour map")
	end)

	--[[ Missing textures ]]

	t.test("texture looks: a missing MaterialVariant or a failed id draws the missing texture", function()
		local world = newLooks()
		local variants = {}
		for _, name in Blocks.texturesUsed do
			variants[Blocks.variantName(name)] = true
		end
		variants.IV_grass_side = nil
		variants.IV_missing_texture = true
		world.variants = variants
		local L, BB = world.Looks, world.Blocks
		local grassApp = BB.get(BB.id.Grass).appearance
		local grass = L.nearLook(grassApp)
		t.eq(grass.variant, "IV_missing_texture", "missing variant: the missing texture")
		t.eq(grass.material, Enum.Material.SmoothPlastic)
		t.eq(grass.images[1].texture, "grass top", "images need no variant")
		local warned = table.concat(world.warnings, "\n")
		t.ok(string.find(warned, "IV_grass_side", 1, true), "the warning names the variant")
		t.ok(string.find(warned, "build_textures", 1, true), "and the fix")
		local count = #world.warnings
		L.nearLook(BB.get(BB.id.DryGrass).appearance)
		t.eq(#world.warnings, count, "warned once")
		-- Without the missing texture's variant either: the block's own material, the images stay.
		local bare = newLooks()
		bare.variants = {}
		local plain = bare.Looks.nearLook(bare.Blocks.get(bare.Blocks.id.Grass).appearance)
		t.eq(plain.variant, "")
		t.eq(plain.material, Enum.Material[bare.Blocks.get(bare.Blocks.id.Grass).material])
		t.eq(plain.images[1].texture, "grass top")
		t.eq(bare.Looks.nearLook(bare.Blocks.get(bare.Blocks.id.Dirt).appearance), nil, "dirt: plain")

		-- A failed id: parts and images draw the missing texture; the generation moves on.
		local failing = newLooks()
		local FL, FB = failing.Looks, failing.Blocks
		local before = FL.generation()
		local changes = FL.applyFailed({ "dirt", "grass top" })
		t.ok(changes.parts, "part looks changed")
		t.eq(FL.generation(), before + 1)
		t.ok(FL.isFailed("dirt"))
		t.eq(FL.nearLook(FB.get(FB.id.Dirt).appearance).variant, "IV_missing_texture")
		local g = FL.nearLook(FB.get(FB.id.Grass).appearance)
		t.eq(g.variant, "IV_grass_side")
		t.eq(g.images[1].texture, "missing texture", "the failed top image")
		t.eq(FL.farLook(FB.get(FB.id.Grass).appearance).variant, "IV_missing_texture", "far: the failed top")
	end)

	t.test("texture looks: ShowMissing draws the missing texture on every blank face", function()
		local world = newLooks(function(pack)
			pack.ShowMissing = true
		end, BLANKS)
		local L, BB = world.Looks, world.Blocks
		local function look(name: string): any
			return L.nearLook(BB.get(BB.id[name]).appearance)
		end
		t.eq(look("Andesite").variant, "IV_missing_texture", "a blank block")
		sameColour(t, look("Andesite").color, Color3.new(1, 1, 1), "in its own colours")
		local oak = look("OakLog")
		t.eq(oak.texture, "log", "the filled sides keep theirs")
		t.eq(imageOn(oak, Enum.NormalId.Top).texture, "missing texture", "the blank top shows it")
		t.eq(look("Mycelium").variant, "IV_missing_texture")
		t.eq(L.farLook(BB.get(BB.id.Andesite).appearance).variant, "IV_missing_texture", "far too")
		t.eq(L.spriteOf(BB.get(BB.id.Fern).appearance).texture, "missing texture", "blank sprites")
		t.eq(look("Grass").texture, "grass side", "filled ones unchanged")
		t.eq(L.nearLook(BB.get(BB.id.Water).appearance), nil, "never textured stays so")
	end)

	--[[ Averages ]]

	t.test("texture looks: known averages tint exactly; plain colours follow what faces show", function()
		local world = newLooks()
		local L, BB = world.Looks, world.Blocks
		local function appOf(name: string): number
			return BB.get(BB.id[name]).appearance
		end
		local grassColour = byteColour(BB.get(BB.id.Grass).color)
		-- A Tint true texture averages its block's colour either way: the plain colours stay.
		local changes = L.applyAverages({ ["grass top"] = { 150, 200, 120 } })
		t.ok(changes.parts, "the grass top's tint changed")
		t.eq(changes.plain, false, "still averages the grass colour")
		t.eq(changes.meshes, false, "far meshes keep their looks (Far Materials off)")
		local top = imageOn(L.nearLook(appOf("Grass")), Enum.NormalId.Top)
		local tint = L.tintOf(BB.get(BB.id.Grass).color, { 150, 200, 120 })
		sameColour(t, top.color, Color3.new(tint[1], tint[2], tint[3]), "target / average")
		sameColour(t, L.averageOf(appOf("Grass"), "top"), grassColour, "averages the voxel colour", 1e-6)
		sameColour(t, L.averageOf(appOf("Grass"), 2), grassColour, "by QuadMesher direction too", 1e-6)
		-- Tint false: the texture's own average is what the face shows.
		changes = L.applyAverages({ ["coal ore"] = { 70, 70, 72 } })
		t.eq(changes.parts, false, "ores keep white parts")
		t.ok(changes.plain, "their plain colour is the image's average now")
		t.ok(changes.meshes, "and the plain meshes'")
		sameColour(t, L.plainColour(appOf("CoalOre")), byteColour({ 70, 70, 72 }), "coal ore plain", 1e-6)
		-- A shared texture darker than a light block: the part's tint stops at 1, so its faces are
		-- images (unclamped) over it, and the block still averages its voxel colour.
		L.applyAverages({ log = { 60, 50, 40 } })
		local birch = L.nearLook(appOf("BirchLog"))
		t.eq(birch.color.R, 1, "clamped")
		local warned = table.concat(world.warnings, "\n")
		t.ok(string.find(warned, "BirchLog", 1, true) and string.find(warned, '"log"', 1, true), "logged")
		local birchColour = byteColour(BB.get(BB.id.BirchLog).color)
		sameColour(t, L.averageOf(appOf("BirchLog"), "north"), birchColour, "its voxel colour", 1e-6)
		-- A pack Average wins over a measured one.
		world.pack.Textures["sand"].Average = { 10, 20, 30 }
		L.applyAverages({ sand = { 200, 200, 200 } })
		t.eq(L.averageKnown("sand")[1], 10)
		world.pack.Textures["sand"].Average = nil
	end)

	t.test("texture looks: a texture too dark for its block: images near, the plain colour far", function()
		local world = newLooks(nil, { "log top" })
		local L, BB = world.Looks, world.Blocks
		local function appOf(name: string): number
			return BB.get(BB.id[name]).appearance
		end
		local function colour(name: string): any
			return byteColour(BB.get(BB.id[name]).color)
		end
		-- What an image or part of `look` shows on `face` with the texture's average.
		local function shown(look: any, face: any, average: { number }): any
			local c = look.color
			for _, image in look.images do
				if image.face == face then
					c = image.color
				end
			end
			local out = L.shownOf(average, { c.R, c.G, c.B })
			return Color3.new(out[1], out[2], out[3])
		end
		-- A bark-coloured log and oak-coloured planks (U5's averages), a green grass top.
		local log, planks, top = { 109, 85, 51 }, { 162, 131, 79 }, { 100, 150, 60 }
		local changes = L.applyAverages({ log = log, planks = planks, ["grass top"] = top })
		t.ok(changes.parts and changes.items, "part and item looks changed")

		-- Birch on the bark texture: every face an image of it in the birch colour, as its item.
		local birch = L.nearLook(appOf("BirchLog"))
		t.eq(birch.variant, "IV_log", "the variant stays under the images")
		t.eq(#birch.images, 6, "every face")
		for _, image in birch.images do
			t.eq(image.texture, "log")
			sameColour(t, shown(birch, image.face, log), colour("BirchLog"), `{image.face.Name}: birch`, 1e-6)
		end
		local item = L.itemFaces(appOf("BirchLog")) :: { any }
		sameColour(t, item[3].color, birch.images[3].color, "the item icon agrees with the world")
		sameColour(t, shown(L.nearLook(appOf("BirchPlanks")), Enum.NormalId.Front, planks), colour("BirchPlanks"))
		-- Far: the plain look in the birch colour (a part could only show the bark's).
		local far = L.farLook(appOf("BirchLog"))
		t.eq(far.variant, "", "no variant far away")
		t.eq(far.material, Enum.Material.SmoothPlastic)
		sameColour(t, far.color, colour("BirchLog"), "far: the birch colour", 1e-6)
		sameColour(t, L.plainColour(appOf("BirchLog")), colour("BirchLog"), "plain too", 1e-6)
		-- Oak is about the texture's own colour: within a step it keeps the variant alone.
		t.eq(#L.nearLook(appOf("OakLog")).images, 0, "oak: no images")
		t.eq(L.farLook(appOf("OakLog")).variant, "IV_log", "oak: its variant far away")

		-- Dry grass on a green grass top: near the top image already brightens; far away it was the
		-- grass top's variant, which cannot leave the green (U2), and is now its plain colour.
		local dry = L.nearLook(appOf("DryGrass"))
		sameColour(t, shown(dry, Enum.NormalId.Top, top), colour("DryGrass"), "near top", 1e-6)
		local dryFar = L.farLook(appOf("DryGrass"))
		t.eq(dryFar.variant, "")
		sameColour(t, dryFar.color, colour("DryGrass"), "far: the dry grass colour", 1e-6)
		L.setStyle(true, true)
		local id, r, g, b = L.lookOf(appOf("DryGrass"), 2)
		t.eq(id, L.PLAIN, "Far Materials: its mesh is plain")
		sameColour(t, Color3.new(r, g, b), colour("DryGrass"), "in the dry grass colour", 1e-6)
		local logId = L.lookOf(appOf("OakLog"), 2)
		t.eq(L.lookInfo(logId).variant, "IV_log", "oak keeps its far look")

		-- One summary, sorted, naming each block once; differences that do not show are left out.
		local text = world.warnings[#world.warnings]
		t.ok(string.find(text, "textures darker than the blocks they tint", 1, true), text)
		local logLine = string.match(text, '\t"log": ([^\n]*)') or ""
		t.ok(string.find(logLine, "BirchLog", 1, true) and string.find(logLine, "AcaciaLog", 1, true), logLine)
		t.ok(string.find(logLine, "BirchLog", 1, true) < string.find(logLine, "AcaciaLog", 1, true), "worst first")
		t.eq(string.find(logLine, "OakLog", 1, true), nil, "oak's step does not show")
		t.ok(string.find(text, "DryGrass %d+ %(far%)"), "far only")
		local count = #world.warnings
		L.setStyle(true, false)
		t.eq(#world.warnings, count, "the same list is not repeated")
		-- A difference of a step or two (stone on Stone) is not too dark.
		local stone = BB.get(BB.id.Stone).color
		L.applyAverages({ stone = { stone[1] + 1, stone[2] + 1, stone[3] - 2 } })
		t.eq(#L.nearLook(appOf("Stone")).images, 0)
		t.eq(string.find(world.warnings[#world.warnings], '"stone"', 1, true), nil)
		t.ok(L.shortfall(stone, { stone[1], stone[2], stone[3] - 2 }) <= 4, "within the visible step")
		t.ok(L.shortfall(BB.get(BB.id.BirchLog).color, log) > 100)
		t.eq(L.shortfall(nil, log), 0, "no target")
		t.eq(L.shortfall(stone, nil), 0, "unknown average")

		-- See-through blocks keep the variant (images would hide what is behind), drawn darker.
		local glassy = newLooks(function(pack)
			pack.Textures.glass.Color = "rbxassetid://1"
		end)
		local GL, GB = glassy.Looks, glassy.Blocks
		GL.applyAverages({ glass = { 20, 20, 20 } })
		local glassApp = GB.get(GB.id.Glass).appearance
		t.eq(#GL.nearLook(glassApp).images, 0, "glass: no images")
		t.eq(GL.farLook(glassApp).variant, "IV_glass")
		t.ok(string.find(glassy.warnings[#glassy.warnings], "Glass %d+ %(see%-through"), "named as see-through")
	end)

	--[[ Far meshes ]]

	t.test("texture looks: far mesh looks: plain without Far Materials, the far look with it", function()
		local world = newLooks(nil, BLANKS)
		local L, BB = world.Looks, world.Blocks
		local function appOf(name: string): number
			return BB.get(BB.id[name]).appearance
		end
		local grass = appOf("Grass")
		local id, r, g, b = L.lookOf(grass, 2)
		t.eq(id, L.PLAIN, "plain without Far Materials")
		local plain = L.plainColour(grass)
		t.near(r, plain.R, 1e-6)
		t.near(g, plain.G, 1e-6)
		t.near(b, plain.B, 1e-6)
		t.eq(L.lookInfo(L.PLAIN).material, Enum.Material.SmoothPlastic)
		local partGen, plainGen = L.partGeneration(), L.plainGeneration()
		local fired = {}
		local connection = L.changed:Connect(function(changes)
			table.insert(fired, changes)
		end)
		local changes = L.setStyle(true, true)
		t.ok(changes.meshes and not changes.parts and not changes.plain, "only the meshes' looks")
		t.eq(#fired, 1, "changed fired once")
		t.eq(L.partGeneration(), partGen, "parts keep their generation")
		t.eq(L.plainGeneration(), plainGen)
		t.ok(L.farMaterials())
		local grassLook = L.lookOf(grass, 2)
		t.eq(L.lookOf(grass, 0), grassLook, "one look per appearance (a far part has one variant)")
		local info = L.lookInfo(grassLook)
		t.eq(info.material, Enum.Material.Grass)
		t.eq(info.variant, "IV_grass_top", "the far part's look")
		t.ok(info.opaque and info.textured)
		t.eq(info.average, nil, "its texture's average is unknown")
		local _, gr, gg, gb = L.lookOf(grass, 4)
		local far = L.farLook(grass).color
		t.near(gr, far.R, 1e-6, "vertex colour: the far part's colour")
		t.near(gg, far.G, 1e-6)
		t.near(gb, far.B, 1e-6)
		local plainId, pr = L.lookOf(grass, 2, true)
		t.eq(plainId, L.PLAIN, "the plain remainder's colour on request")
		t.near(pr, plain.R, 1e-6)
		-- Untextured blocks: their BlockList material and colour; see-through ones stay so.
		local water = L.lookInfo((L.lookOf(appOf("Water"), 2)))
		t.eq(water.textured, false)
		t.eq(water.opaque, false, "water is see-through")
		t.eq(water.material, Enum.Material[BB.get(BB.id.Water).material])
		local andesite = L.lookOf(appOf("Andesite"), 2)
		t.eq(L.lookInfo(andesite).variant, "")
		t.ok(andesite ~= grassLook and andesite > 0, "small whole numbers")
		t.eq(L.lookOf(appOf("Dirt"), 3), L.lookOf(appOf("Dirt"), 3), "stable")
		t.ok(L.lookOf(appOf("Dirt"), 3) ~= grassLook)
		-- A measured average reaches the look (the "largest" remainder tints joined quads by it).
		L.applyAverages({ ["grass top"] = { 150, 200, 120 } })
		local average = L.lookInfo((L.lookOf(grass, 2))).average
		t.near(average[2], 200 / 255, 1e-9, "the look's average")
		-- Off again; a Disconnect stops the signal.
		connection:Disconnect()
		L.setStyle(true, false)
		t.eq(#fired, 2)
		t.eq((L.lookOf(grass, 2)), L.PLAIN)
	end)

	--[[ Settings ]]

	t.test("texture looks: the Textures setting and the generations", function()
		local world = newLooks()
		local L, BB = world.Looks, world.Blocks
		local grass = BB.get(BB.id.Grass).appearance
		t.ok(L.used, "the pack has textures")
		t.ok(L.enabled())
		local gen = L.generation()
		local same = L.setStyle(true, false)
		t.ok(not (same.parts or same.plain or same.meshes), "nothing changed")
		t.eq(L.generation(), gen)
		local changes = L.setStyle(false, false)
		t.ok(changes.parts, "near and far looks go")
		t.eq(changes.plain, false, "without averages the plain colours are the voxel colours either way")
		t.eq(L.generation(), gen + 1)
		t.eq(L.nearLook(grass), nil)
		t.eq(L.farLook(grass), nil)
		t.eq(L.spriteOf(BB.get(BB.id.ShortGrass).appearance), nil, "no sprites")
		t.eq(L.frontOf(BB.get(BB.id.GlowLichen).appearance), nil, "no lichen image")
		t.eq(L.itemFaces(grass), nil, "plain item cubes")
		L.setStyle(true, false)
		t.eq(L.nearLook(grass).variant, "IV_grass_side")
		-- With a measured coal ore average, Textures off changes its plain colour.
		L.applyAverages({ ["coal ore"] = { 30, 30, 30 } })
		t.ok(L.setStyle(false, false).plain, "the plain colour falls back to the voxel colour")
		-- Sprites follow Config.Textures.Sprites.
		local noSprites = newLooks(function(_, config)
			config.Textures.Sprites = false
		end)
		t.eq(noSprites.Looks.spriteOf(noSprites.Blocks.get(noSprites.Blocks.id.ShortGrass).appearance), nil)
		-- Bottom and side images.
		local images = newLooks(function(_, config)
			config.Textures.BottomFaces = true
			config.Textures.SideImages = true
		end)
		local look = images.Looks.nearLook(images.Blocks.get(images.Blocks.id.Grass).appearance)
		t.eq(look.texture, "grass top", "SideImages: the top's variant")
		t.eq(imageOn(look, Enum.NormalId.Bottom).texture, "dirt")
		t.eq(imageOn(look, Enum.NormalId.Front).texture, "grass side")
		t.eq(imageOn(look, Enum.NormalId.Left).texture, "grass side")
		t.eq(imageOn(look, Enum.NormalId.Top), nil, "the top is the variant")
		images.Config.Textures.SideImages = false
		images.Config.Textures.BottomFaces = false
	end)

	--[[ Startup ]]

	t.test("texture looks: start checks ids and measures averages in the background", function()
		local world = newLooks()
		local L, BB = world.Looks, world.Blocks
		local dirtId = "rbxassetid://124863036266976"
		world.fetch[dirtId] = Enum.AssetFetchStatus.Failure
		-- Every other colour map is a solid colour; the grass top's measures (92, 158, 62).
		for name, texture in world.pack.Textures do
			if texture.Color ~= "" and texture.Color ~= dirtId then
				world.images[texture.Color] = if name == "grass top"
					then solid(64, 64, 92, 158, 62)
					else solid(64, 64, 128, 128, 128)
			end
		end
		local fired = 0
		L.changed:Connect(function()
			fired += 1
		end)
		L.start()
		L.start()
		-- Ids: one preload per colour map (dirt and packed mud share theirs).
		local seen = {}
		for _, id in world.preloaded do
			t.ok(not seen[id], `{id} preloaded once`)
			seen[id] = true
		end
		t.ok(seen[dirtId])
		t.ok(L.isFailed("dirt") and L.isFailed("packed mud"), "both textures of the failed id")
		local warned = table.concat(world.warnings, "\n")
		t.ok(string.find(warned, '"dirt"', 1, true) and string.find(warned, "Decal id", 1, true), "the cause")
		t.ok(string.find(warned, "Grass", 1, true), "and the blocks using it")
		for _, decal in world.created do
			if decal.ClassName == "Decal" then
				t.ok(decal.destroyed, "temporary decals destroyed")
			end
		end
		-- Averages: measured, printed once as a block to paste, applied.
		t.eq(#world.printed, 1)
		local printed = world.printed[1]
		t.ok(string.find(printed, L.AVERAGES_HEADER, 1, true) == 1, "the header first")
		t.ok(string.find(printed, 'Average = { 92, 158, 62 }, -- ["grass top"]', 1, true), "grass top")
		t.eq(string.find(printed, '["dirt"]', 1, true), nil, "failed ones are not measured")
		t.eq(L.averageKnown("grass top")[2], 158)
		t.eq(L.averageKnown("stone")[1], 128)
		for id, image in world.images do
			t.eq(image.destroyed, true, `{id}: measured and destroyed`)
		end
		t.eq(fired, 2, "one change for the failed ids, one for the averages")
		t.eq(L.nearLook(BB.get(BB.id.Dirt).appearance).variant, "IV_missing_texture")

		-- No Mesh / Image APIs: one warning, nothing printed, nothing changes.
		local locked = newLooks()
		locked.Looks.start()
		t.eq(#locked.printed, 0)
		local lockedWarned = table.concat(locked.warnings, "\n")
		t.ok(string.find(lockedWarned, "Enable Mesh / Image APIs", 1, true), "says what to switch on")
		t.eq(locked.Looks.generation(), 0)
		-- Measuring and checking can be switched off.
		local off = newLooks(function(_, config)
			config.Textures.ValidateIds = false
			config.Textures.MeasureAverages = false
		end)
		off.Looks.start()
		t.eq(#off.preloaded, 0)
		t.eq(#off.warnings, 0)
		off.Config.Textures.ValidateIds = true
		off.Config.Textures.MeasureAverages = true
	end)

	t.test("texture looks: start names every map that fails and every average it cannot measure, by cause", function()
		-- Every colour map measures grey; dirt's normal map fails to load.
		local function grey(world: any)
			for _, texture in world.pack.Textures do
				if texture.Color ~= "" then
					world.images[texture.Color] = solid(8, 8, 128, 128, 128)
				end
			end
		end
		local world = newLooks()
		local L = world.Looks
		local normal = world.pack.Textures.dirt.Normal
		local missingId = world.pack.Textures[world.pack.Missing].Color
		world.fetch[normal] = Enum.AssetFetchStatus.Failure
		grey(world)
		L.start()
		local seen = {}
		for _, id in world.preloaded do
			t.ok(not seen[id], `{id} preloaded once`)
			seen[id] = true
		end
		t.ok(seen[normal], "normal maps are checked too")
		local warned = table.concat(world.warnings, "\n")
		t.ok(string.find(warned, 'the normal map of texture "dirt"', 1, true), warned)
		t.ok(string.find(warned, "Decal id", 1, true), "the likely cause")
		t.eq(L.isFailed("dirt"), false, "its colour map still draws")
		-- Nothing draws the missing texture: it is not measured, and nothing is refused.
		t.eq(world.images[missingId].destroyed, nil, "the missing texture is not opened")
		t.eq(string.find(world.printed[1], '["missing texture"]', 1, true), nil)
		t.eq(string.find(warned, "could not measure", 1, true), nil, "no measuring warning")
		-- With ShowMissing it is drawn, so it is measured.
		local showing = newLooks(function(pack)
			pack.ShowMissing = true
		end, { "andesite" })
		grey(showing)
		showing.Looks.start()
		t.ok(string.find(showing.printed[1], '["missing texture"]', 1, true), "measured when drawn")

		-- A full memory budget: named as such, without the permissions advice; after three images
		-- in a row the rest are named as not measured.
		local full = newLooks()
		for _, texture in full.pack.Textures do
			if texture.Color ~= "" then
				full.images[texture.Color] = false
			end
		end
		full.Looks.start()
		local fullWarned = table.concat(full.warnings, "\n")
		t.ok(string.find(fullWarned, "memory budget", 1, true), fullWarned)
		t.eq(string.find(fullWarned, "Enable Mesh", 1, true), nil, "not a permissions problem")
		t.ok(string.find(fullWarned, "not measured:", 1, true), "the rest named")
		t.ok(string.find(fullWarned, '"stone"', 1, true), "by name")
		-- Refused images: named, with the permissions advice.
		local locked = newLooks()
		locked.Looks.start()
		local lockedWarned = table.concat(locked.warnings, "\n")
		t.ok(string.find(lockedWarned, 'could not measure the average of "', 1, true), lockedWarned)
		t.ok(string.find(lockedWarned, "Enable Mesh / Image APIs", 1, true))

		-- The missing texture's own id fails: ShowMissing and failed textures show the plain block,
		-- and the warnings say so.
		local broken = newLooks(function(pack)
			pack.ShowMissing = true
		end, { "andesite" })
		broken.fetch[missingId] = Enum.AssetFetchStatus.Failure
		broken.fetch[broken.pack.Textures.dirt.Color] = Enum.AssetFetchStatus.Failure
		grey(broken)
		local BL, BB = broken.Looks, broken.Blocks
		local andesite = BB.get(BB.id.Andesite).appearance
		t.eq(BL.nearLook(andesite).variant, "IV_missing_texture", "before the check")
		BL.start()
		local brokenWarned = table.concat(broken.warnings, "\n")
		t.ok(
			string.find(brokenWarned, "ShowMissing and textures that fail to load show the plain block", 1, true),
			brokenWarned
		)
		t.ok(string.find(brokenWarned, "the plain block (the missing texture failed too)", 1, true), "dirt's fallback")
		t.eq(string.find(brokenWarned, "nothing draw", 1, true), nil)
		t.eq(BL.nearLook(andesite), nil, "the plain block")
		t.eq(BL.nearLook(BB.get(BB.id.Dirt).appearance), nil, "dirt: the plain block too")
	end)
end
