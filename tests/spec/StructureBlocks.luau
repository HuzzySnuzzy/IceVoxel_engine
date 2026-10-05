--[[
	Structure blocks, structure voids, jigsaw blocks and glow lichen as blocks: their place in
	BlockList, creative only rules (no survival mining, no drops), structure block modes, jigsaw
	orientations and Minecraft's placement rule, turning blocks with a structure (Blocks.rotate),
	glow lichen and its cave twins (variants, light, shears, cave air for the mesher), their faces
	(BlockDecor), and the settings and network messages of structure blocks and jigsaws
	(Structures/Settings, Net/Protocol).
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local Mining = require(shared.Mining)
	local Config = require(shared.Config)
	local Hash = require(shared.Util.Hash)
	local Protocol = require(shared.Net.Protocol)
	local Settings = require(shared.Structures.Settings)
	local BlockDecor = require(client.Rendering.BlockDecor)

	local id = Blocks.id
	local AIR, STONE = Blocks.AIR, id.Stone
	local SIDES = { "North", "South", "West", "East" }

	local function find(name: string): number?
		return Blocks.find(name)
	end

	-- A sparse world: unset blocks are stone below y = 10 and air above.
	local function world(blocks: { [string]: number }?)
		return function(x: number, y: number, z: number): number?
			local b = blocks and blocks[`{x},{y},{z}`]
			if b then
				return b
			end
			return if y < 10 then STONE else AIR
		end
	end

	--[[ Blocks ]]

	t.test("structure blocks: appended after the plants in Minecraft's order", function()
		local names =
			{ "StructureBlock", "StructureBlockLoad", "StructureBlockCorner", "StructureBlockData", "StructureVoid" }
		table.insert(names, "Jigsaw")
		for _, o in { "SouthUp", "WestUp", "EastUp", "UpNorth", "UpSouth", "UpWest", "UpEast" } do
			table.insert(names, "Jigsaw" .. o)
		end
		for _, o in { "DownNorth", "DownSouth", "DownWest", "DownEast" } do
			table.insert(names, "Jigsaw" .. o)
		end
		for _, prefix in { "GlowLichen", "CaveGlowLichen" } do
			table.insert(names, prefix)
			for _, side in { "Up", "North", "South", "West", "East" } do
				table.insert(names, prefix .. side)
			end
		end
		local first = id.RedMushroom + 1
		for i, name in names do
			t.eq(find(name), first + i - 1, name)
		end
		t.eq(Blocks.count, first + #names, "nothing after them")
		t.eq(Blocks.find("NoSuchBlock"), nil)
		t.eq(Blocks.find(42 :: any), nil)
	end)

	t.test("creative only: survival can't mine or get them, creative places them from the inventory", function()
		local creativeOnly = {}
		for block = 0, Blocks.count - 1 do
			local def = Blocks.get(block)
			if def.creativeOnly then
				table.insert(creativeOnly, def.name)
				t.eq(Mining.progressPerTick(block, true, false, nil), 0, def.name)
				t.eq(Mining.progressPerTick(block, true, false, Items.id.DiamondPickaxe), 0, def.name)
				t.eq(Mining.ticks(block, true, false, nil), math.huge)
				t.ok(not Mining.mayBreak(block, 1000, nil, nil), "never in survival")
				t.eq(Items.drops(block, nil), nil, `{def.name} drops nothing`)
				t.eq(Items.drops(block, Items.id.Shears), nil)
				t.eq(Items.blockDrops(block), nil)
				t.ok(def.breakable and def.hardness >= 0, "creative players break it at once")
				t.ok(Blocks.isCreativeOnly(block))
				t.eq(buffer.readu8(Blocks.creativeOnlyLut, block), 1)
			end
		end
		t.eq(#creativeOnly, 4 + 1 + 12, "structure blocks, the void and the jigsaws")
		t.ok(not Blocks.isCreativeOnly(id.GlowLichen) and not Blocks.isCreativeOnly(STONE))
		t.ok(not Blocks.isCreativeOnly(-1) and not Blocks.isCreativeOnly(1.5))
		-- Their items are in the creative inventory (and JEI); variants and twins are not.
		local listed: { [string]: boolean } = {}
		for _, item in Items.list do
			listed[item.name] = true
		end
		for _, name in { "StructureBlock", "StructureVoid", "Jigsaw", "GlowLichen" } do
			t.ok(listed[name], `{name} is an item`)
		end
		for _, name in { "StructureBlockLoad", "JigsawUpNorth", "GlowLichenNorth", "CaveGlowLichen" } do
			t.ok(not listed[name], `{name} is no item of its own`)
		end
		t.ok(Items.isCreativeOnly(Items.id.StructureBlock) and Items.isCreativeOnly(Items.id.Jigsaw))
		t.ok(Items.isCreativeOnly(Items.id.StructureVoid))
		t.ok(not Items.isCreativeOnly(Items.id.GlowLichen) and not Items.isCreativeOnly(Items.id.Stick))
		t.ok(not Items.isCreativeOnly(nil))
		t.eq(Items.ofBlock(id.StructureBlockData), Items.id.StructureBlock, "pick block gives the item")
		t.eq(Items.ofBlock(id.JigsawDownWest), Items.id.Jigsaw)
	end)

	t.test("structure blocks: one block per mode, placed in SAVE mode, opening their screen", function()
		for _, mode in Settings.MODES do
			local block = Blocks.structureBlock(mode)
			assert(block)
			t.eq(Blocks.structureMode(block), mode)
			t.ok(Blocks.isStructureBlock(block))
			local def = Blocks.get(block)
			t.eq(def.menu, "StructureBlock")
			t.eq(def.decor, `StructureBlock{string.upper(string.sub(mode, 1, 1))}{string.sub(mode, 2)}`)
			t.eq(def.displayName, "Structure Block")
			t.ok(def.solid and Blocks.isOpaque(block), "a full opaque cube")
			-- Whichever mode, placing the item makes a SAVE block.
			t.eq(Blocks.placementFor(block, 0, 1, 0, 0, -1, 0, world(), 0, 10, 0), id.StructureBlock)
			t.eq(Blocks.variantFor(block, 1, 0, 0), id.StructureBlock)
		end
		t.eq(Blocks.structureBlock("save"), id.StructureBlock)
		t.eq(Blocks.structureBlock("nonsense"), nil)
		t.eq(Blocks.structureMode(STONE), nil)
		t.eq(#Blocks.variants(id.StructureBlock), 4)
		-- The structure void: a small see-through box, not solid, replaceable.
		local void = Blocks.get(id.StructureVoid)
		t.ok(not void.solid and void.replaceable and void.placeable)
		t.eq(void.render, "Transparent")
		t.ok(void.shape and #void.shape == 1 and void.shape[1].size[1] == 6)
		local outline = Blocks.outline(id.StructureVoid)
		assert(outline)
		t.near(outline[1], 5 / 16, 1e-9)
		t.near(outline[5], 11 / 16, 1e-9)
		t.eq(Blocks.obstruction(id.StructureVoid), nil, "players walk through it")
		t.eq(Blocks.placementFor(id.StructureVoid, 0, 1, 0, 0, -1, 0, world(), 0, 10, 0), id.StructureVoid)
	end)

	t.test("jigsaws: twelve orientations, Minecraft's placement from the clicked face and the look", function()
		local seen = 0
		for _, front in { "North", "South", "West", "East", "Up", "Down" } do
			for _, top in { "North", "South", "West", "East", "Up", "Down" } do
				local block = Blocks.jigsawBlock(front, top)
				local horizontal = table.find(SIDES, front) ~= nil
				local valid = if horizontal then top == "Up" else table.find(SIDES, top) ~= nil
				t.eq(block ~= nil, valid, `{front} {top}`)
				if block then
					seen += 1
					local f, tp = Blocks.jigsawOrientation(block)
					t.eq(f, front)
					t.eq(tp, top)
					t.ok(Blocks.isJigsaw(block))
					t.eq(Blocks.get(block).menu, "Jigsaw")
					t.eq(Blocks.get(block).decor, `Jigsaw{front}{top}`)
				end
			end
		end
		t.eq(seen, 12)
		t.eq(Blocks.jigsawBlock("North", "Up"), id.Jigsaw, "the item faces north")
		t.eq(Blocks.jigsawOrientation(STONE), nil)
		t.ok(not Blocks.isJigsaw(STONE))
		-- Minecraft's Direction.fromYRot.
		t.eq(Blocks.horizontalFacing(0, -1), "North")
		t.eq(Blocks.horizontalFacing(0, 1), "South")
		t.eq(Blocks.horizontalFacing(1, 0), "East")
		t.eq(Blocks.horizontalFacing(-1, 0), "West")
		t.eq(Blocks.horizontalFacing(0.3, -1), "North")
		t.eq(Blocks.horizontalFacing(0, 0), "South", "straight down")
		local w = world()
		-- A side face: the front faces out of it, top up, whatever the look.
		t.eq(Blocks.placementFor(id.Jigsaw, 0, 0, 1, 0.2, -0.3, -1, w, 0, 10, 1), id.JigsawSouthUp)
		t.eq(Blocks.placementFor(id.Jigsaw, -1, 0, 0, 1, 0, 0.1, w, -1, 10, 0), id.JigsawWestUp)
		-- The floor: front up, top the opposite of where the player looks.
		t.eq(Blocks.placementFor(id.Jigsaw, 0, 1, 0, 0, -0.8, -0.6, w, 0, 10, 0), id.JigsawUpSouth)
		t.eq(Blocks.placementFor(id.Jigsaw, 0, 1, 0, 0.9, -0.4, 0.1, w, 0, 10, 0), id.JigsawUpWest)
		-- A ceiling: front down.
		t.eq(Blocks.placementFor(id.Jigsaw, 0, -1, 0, 0, 0.7, 0.7, w, 0, 12, 0), id.JigsawDownNorth)
		-- No face: the front faces back along the look.
		t.eq(Blocks.placementFor(id.Jigsaw, 0, 0, 0, 1, 0.1, 0, w, 0, 12, 0), id.JigsawWestUp)
		-- A variant's item places like the item.
		t.eq(Blocks.placementFor(id.JigsawDownEast, 0, 0, -1, 0, 0, 1, w, 0, 10, -1), id.Jigsaw)
		t.eq(Blocks.variantFor(id.Jigsaw, 0, 1, 0), id.JigsawUpNorth, "looking straight down: top north")
		t.eq(Blocks.jigsawPlacement(1, 0, 0, -1, 0, 0), id.JigsawEastUp)
	end)

	t.test("turning: wall torches, glow lichen and jigsaws face the turned way, the rest stays", function()
		t.eq(Blocks.turnDirection("North", 1, "none"), "East")
		t.eq(Blocks.turnDirection("North", 2), "South")
		t.eq(Blocks.turnDirection("West", 3, "none"), "South")
		t.eq(Blocks.turnDirection("Up", 1, "leftRight"), "Up")
		t.eq(Blocks.turnDirection("North", 0, "leftRight"), "South", "left-right flips Z")
		t.eq(Blocks.turnDirection("East", 0, "frontBack"), "West", "front-back flips X")
		t.eq(Blocks.turnDirection("North", 1, "leftRight"), "West", "mirror first, then turn")
		t.eq(Blocks.turnDirection("North", -1), "West")
		t.eq(Blocks.rotate(id.WallTorchNorth, 1, "none"), id.WallTorchEast)
		t.eq(Blocks.rotate(id.WallTorchNorth, 0, "leftRight"), id.WallTorchSouth)
		t.eq(Blocks.rotate(id.Torch, 1, "none"), id.Torch)
		t.eq(Blocks.rotate(id.HangingLantern, 3, "frontBack"), id.HangingLantern)
		t.eq(Blocks.rotate(id.GlowLichenNorth, 1, "none"), id.GlowLichenEast)
		t.eq(Blocks.rotate(id.CaveGlowLichenWest, 2, "none"), id.CaveGlowLichenEast, "twins stay twins")
		t.eq(Blocks.rotate(id.GlowLichenUp, 1, "frontBack"), id.GlowLichenUp)
		t.eq(Blocks.rotate(id.Jigsaw, 1, "none"), id.JigsawEastUp)
		t.eq(Blocks.rotate(id.JigsawUpNorth, 3, "none"), id.JigsawUpWest)
		t.eq(Blocks.rotate(id.JigsawDownEast, 0, "frontBack"), id.JigsawDownWest)
		t.eq(Blocks.rotate(id.Jigsaw, 0, "frontBack"), id.Jigsaw, "a north front is not on the X axis")
		t.eq(Blocks.rotate(STONE, 1, "leftRight"), STONE)
		t.eq(Blocks.rotate(id.Chest, 2, "none"), id.Chest)
		t.eq(Blocks.rotate(Blocks.count + 5, 1, "none"), Blocks.count + 5, "unknown ids come back")
		t.eq(Blocks.rotate(id.WallTorchNorth, 1, "sideways"), id.WallTorchEast, "an unknown mirror is none")
		for block = 0, Blocks.count - 1 do
			local def = Blocks.get(block)
			-- Four quarter turns, and two mirrors, are no turn; turns add up.
			local b = block
			for _ = 1, 4 do
				b = Blocks.rotate(b, 1, "none")
			end
			t.eq(b, block, `{def.name} turned four times`)
			for _, mirror in Blocks.MIRRORS do
				t.eq(Blocks.rotate(Blocks.rotate(block, 0, mirror), 0, mirror), block, `{def.name} mirrored twice`)
				for r = 0, 3 do
					local turned = Blocks.rotate(block, r, mirror)
					t.eq(buffer.readu16(Blocks.rotateLut(r, mirror), block * 2), turned, "the lookup table agrees")
					t.eq(Blocks.rotate(Blocks.rotate(block, 0, mirror), r, "none"), turned, "mirror, then turn")
					-- The turned block hangs on, and faces, the turned sides.
					local after = Blocks.get(turned)
					if def.support then
						t.eq(after.support, Blocks.turnDirection(def.support, r, mirror), `{def.name} support`)
					end
					if def.jigsaw then
						local front, top = Blocks.jigsawOrientation(turned)
						t.eq(front, Blocks.turnDirection(def.jigsaw.front, r, mirror))
						t.eq(top, Blocks.turnDirection(def.jigsaw.top, r, mirror))
					end
					t.eq(Blocks.isCaveTwin(turned), Blocks.isCaveTwin(block))
					t.eq(Items.ofBlock(turned), Items.ofBlock(block), "the same item")
				end
			end
		end
	end)

	t.test("glow lichen: Minecraft's light 7, hardness 0.2, shears, on every face of a sturdy block", function()
		local sides = { Down = "", Up = "Up", North = "North", South = "South", West = "West", East = "East" }
		for support, suffix in sides do
			for _, prefix in { "GlowLichen", "CaveGlowLichen" } do
				local block = id[prefix .. suffix]
				local def = Blocks.get(block)
				t.eq(def.support, support, def.name)
				t.eq(def.light, 7)
				t.eq(def.hardness, 0.2)
				t.eq(def.tool, "axe")
				t.ok(not def.solid and def.replaceable and def.brokenByFluid, "not solid, replaceable, washed away")
				t.eq(def.behaviour, "Attached")
				t.eq(def.item, if prefix == "GlowLichen" and support == "Down" then nil else "GlowLichen")
				t.eq(Items.ofBlock(block), Items.id.GlowLichen)
				t.eq(Items.drops(block, nil), nil, "nothing by hand")
				t.eq(Items.drops(block, Items.id.IronAxe), nil, "nothing with an axe")
				local sheared = Items.drops(block, Items.id.Shears)
				t.ok(sheared and sheared.item == Items.id.GlowLichen and sheared.count == 1, "itself with shears")
				t.eq(Items.blockDrops(block), nil, "nothing when its wall goes")
				t.eq(Mining.toolSpeed(block, Items.id.Shears), 2, "Minecraft's shears on glow lichen")
				t.eq(Mining.ticks(block, true, false, nil), 6)
				-- Two boxes (a Part each: caves hold thousands of lichen), one carrying the light,
				-- all on the face it covers.
				local shape = def.shape
				assert(shape)
				t.eq(#shape, 2, "a plate and a glowing speck: 2 parts")
				local glows = 0
				local d = Blocks.DIRECTIONS[support]
				for _, box in shape do
					if box.glow then
						glows += 1
						t.eq(box.material, "Neon")
					end
					for k = 1, 3 do
						local lo, hi = box.offset[k] - box.size[k] / 2, box.offset[k] + box.size[k] / 2
						t.ok(lo >= -8 and hi <= 8, "inside the cell")
						if d[k] ~= 0 then
							local face = d[k] * 8
							local far = if d[k] < 0 then hi - face else face - lo
							local near = if d[k] < 0 then lo - face else face - hi
							t.ok(near > 0 and far <= 1, `{def.name}: within a pixel of its face`)
						end
					end
				end
				t.eq(glows, 1, "one light box")
				local outline = Blocks.outline(block)
				assert(outline)
				for k = 1, 3 do
					local size = outline[k + 3] - outline[k]
					t.near(size, if d[k] ~= 0 then 1 / 16 else 1, 1e-9, "a pixel thick plate over the face")
				end
				t.ok(Blocks.canSurvive(block, world(), 0, 10, 0) == (support == "Down"), "needs a sturdy block")
			end
		end
		-- Placing: the clicked face's lichen, the wall of the clicked side.
		local w = world({ ["1,11,0"] = STONE, ["0,12,0"] = STONE })
		t.eq(Blocks.placementFor(id.GlowLichen, 0, 1, 0, 0, -1, 0, w, 0, 10, 0), id.GlowLichen, "on the floor")
		t.eq(Blocks.placementFor(id.GlowLichen, -1, 0, 0, 1, 0, 0, w, 0, 11, 0), id.GlowLichenEast, "on a wall")
		t.eq(Blocks.placementFor(id.GlowLichen, 0, -1, 0, 0, 1, 0, w, 0, 11, 0), id.GlowLichenUp, "under a ceiling")
		t.eq(#Blocks.variants(id.GlowLichen), 6, "six sides, no twins")
		t.ok(not Items.isReplacedBy(id.GlowLichen, Items.id.GlowLichen), "not by its own item")
		t.ok(Items.isReplacedBy(id.GlowLichenNorth, Items.id.Stone))
	end)

	t.test("cave twins: look and drop like their twin, are cave air for hidden caves, never placed", function()
		local twins = 0
		for block = 0, Blocks.count - 1 do
			local twin = Blocks.caveTwinOf(block)
			t.eq(buffer.readu8(Blocks.caveTwinLut, block), if twin then 1 else 0)
			if twin then
				twins += 1
				local def, twinDef = Blocks.get(block), Blocks.get(twin)
				t.eq(Blocks.caveTwinFor(twin), block)
				t.ok(Blocks.isCaveTwin(block) and not Blocks.isCaveTwin(twin))
				t.eq(def.appearance, twinDef.appearance, "the same look")
				t.eq(def.light, twinDef.light)
				t.ok(not def.placeable)
				t.eq(Blocks.surfaceForm(block), twin)
				t.eq(buffer.readu8(Blocks.cullLutHiddenCaves, block), 1, "cave air while caves are hidden")
				t.eq(buffer.readu8(Blocks.cullLut, block), 0, "but hides nothing otherwise")
				t.eq(buffer.readu8(Blocks.cullLutHiddenCaves, twin), 0, "its twin is no cave air")
				t.eq(table.find(Blocks.variants(Items.ofBlock(block) :: number), block), nil, "no variant")
				t.eq(Blocks.placementFor(block, 0, 1, 0, 0, -1, 0, world(), 0, 10, 0), nil, "nothing places it")
				local sheared = Items.drops(block, Items.id.Shears)
				t.ok(sheared and sheared.item == Items.id.GlowLichen)
			end
		end
		t.eq(twins, 6)
		t.eq(Blocks.surfaceForm(Blocks.CAVE_AIR), AIR)
		t.eq(Blocks.surfaceForm(STONE), STONE)
		t.eq(Blocks.caveTwinFor(STONE), nil)
		t.eq(Blocks.caveTwinFor(id.GlowLichen), id.CaveGlowLichen)
	end)

	--[[ Faces ]]

	t.test("faces: structure blocks show their mode's sigil on all six faces", function()
		local seen: { [string]: boolean } = {}
		for _, mode in { "Save", "Load", "Corner", "Data" } do
			local faces = BlockDecor.faces(`StructureBlock{mode}`)
			assert(faces)
			local front = faces.Front
			for _, face in BlockDecor.FACES do
				t.eq(faces[face], front, "the same on every face")
			end
			local key = {}
			for _, r in front do
				table.insert(key, `{r.x},{r.y},{r.w},{r.h},{r.colour[1]}`)
			end
			local text = table.concat(key, ";")
			t.ok(not seen[text], `{mode} looks like no other mode`)
			seen[text] = true
			t.eq(front[1].colour[1], 16, "a black field")
		end
	end)

	t.test("faces: a jigsaw's front, lock, back and arrows point the block's way on every face", function()
		local pictures = BlockDecor.JIGSAW_PICTURES
		local vectors = {
			North = { 0, 0, -1 },
			South = { 0, 0, 1 },
			West = { -1, 0, 0 },
			East = { 1, 0, 0 },
			Up = { 0, 1, 0 },
			Down = { 0, -1, 0 },
		}
		local faceDirection = {
			Front = "North",
			Back = "South",
			Left = "West",
			Right = "East",
			Top = "Up",
			Bottom = "Down",
		}
		local function dot(a: { number }, b: { number }): number
			return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
		end
		local function turn(rects: { any }, turns: number): { any }
			local out = {}
			for i, r in rects do
				local x, y, w, h = r.x, r.y, r.w, r.h
				for _ = 1, turns do
					x, y, w, h = 16 - y - h, x, h, w
				end
				out[i] = { x = x, y = y, w = w, h = h, colour = r.colour }
			end
			return out
		end
		local function same(a: { any }, b: { any }): boolean
			if #a ~= #b then
				return false
			end
			for i, r in a do
				local o = b[i]
				if r.x ~= o.x or r.y ~= o.y or r.w ~= o.w or r.h ~= o.h or r.colour ~= o.colour then
					return false
				end
			end
			return true
		end
		for block = 0, Blocks.count - 1 do
			local front, top = Blocks.jigsawOrientation(block)
			if front and top then
				local faces = BlockDecor.faces(`Jigsaw{front}{top}`)
				assert(faces)
				for _, face in BlockDecor.FACES do
					local direction = faceDirection[face]
					local kind, towards
					if direction == front then
						kind, towards = "front", top
					elseif direction == Blocks.opposite(front) then
						kind, towards = "back", nil
					elseif direction == top then
						kind, towards = "lock", front
					else
						kind, towards = "side", front
					end
					local picture = faces[face]
					if towards == nil then
						t.ok(same(picture, pictures.back), `{front}/{top} {face}: the back`)
					else
						-- The picture's up, turned k times clockwise, points at `towards` in the world.
						local _, right, up = BlockDecor.basis(face)
						local found = false
						for k = 0, 3 do
							local pictureUp = ({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } })[k + 1]
							local v = vectors[towards]
							if dot(v, right) == pictureUp[1] and -dot(v, up) == pictureUp[2] then
								found = same(picture, turn(pictures[kind], k))
							end
						end
						t.ok(found, `{front}/{top} {face}: the {kind} pointing {towards}`)
					end
				end
			end
		end
		-- The item, seen as Minecraft draws it: the lock's bar touches the top face's north edge,
		-- and the arrows on the west and east faces point north.
		local item = BlockDecor.faces("JigsawNorthUp")
		assert(item)
		local bar = item.Top[#item.Top]
		t.eq(bar.y + bar.h, 16, "the bar starts at the picture's bottom edge: north on the top face")
		local _, right = BlockDecor.basis("Left")
		t.eq(right[3], 1, "on the west face, right is south: the arrow points left")
	end)

	--[[ Settings ]]

	t.test("settings: Minecraft's defaults and ranges, clamped from anything", function()
		local s = Settings.defaultStructure()
		t.eq(s.mode, "save")
		t.eq(s.name, "")
		t.eq(s.offset[2], 1, "the region starts above the block")
		t.eq(s.size[1], 5)
		t.eq(s.integrity, 1)
		t.ok(s.showBoundingBox and not s.showInvisible)
		t.eq(Settings.defaultStructure("data").mode, "data")
		t.eq(Settings.defaultStructure("bogus").mode, "save")
		local c = Settings.clampStructure({
			mode = "load",
			name = string.rep("a", 200),
			offset = { 100, -100, 3.7 },
			size = { -4, 49, 0 / 0 },
			rotation = 7,
			mirror = "upDown",
			integrity = 3,
			seed = 1e300,
			showBoundingBox = false,
			showInvisible = "yes",
			metadata = 5,
		})
		t.eq(c.mode, "load")
		t.eq(#c.name, Settings.MAX_NAME)
		t.eq(c.offset[1], Config.Structures.MaxOffset)
		t.eq(c.offset[2], -Config.Structures.MaxOffset)
		t.eq(c.offset[3], 3)
		t.eq(c.size[1], 0)
		t.eq(c.size[2], Config.Structures.MaxSize)
		t.eq(c.size[3], 5, "NaN is the default")
		t.eq(c.rotation, 3)
		t.eq(c.mirror, "none")
		t.eq(c.integrity, 1)
		t.eq(c.seed, Settings.MAX_SEED)
		t.eq(c.showBoundingBox, false)
		t.eq(c.showInvisible, false)
		t.eq(c.metadata, "")
		for _, junk in { nil, 5, "x", { offset = "no", size = { "a" } } } do
			local ok, value = pcall(Settings.clampStructure, junk)
			t.ok(ok and value.mode == "save", "never errors")
		end
		-- Jigsaws: the default joint follows the front.
		t.eq(Settings.defaultJigsaw("North").joint, "aligned")
		t.eq(Settings.defaultJigsaw("Up").joint, "rollable")
		t.eq(Settings.defaultJigsaw().joint, "rollable")
		t.eq(Settings.defaultJigsaw().name, "empty")
		t.eq(Settings.defaultJigsaw().finalState, "Air")
		local j = Settings.clampJigsaw({ name = 3, pool = string.rep("p", 300), joint = "loose" }, "East")
		t.eq(j.name, "empty")
		t.eq(#j.pool, Settings.MAX_NAME)
		t.eq(j.joint, "aligned")
	end)

	t.test("settings: names are resource locations, metadata is short text, final states are blocks", function()
		for _, good in { "", "house", "village/houses/hut_1", "minecraft:empty", "A-Z.a_z/0:9", string.rep("x", 128) } do
			t.ok(Settings.validName(good), good)
		end
		for _, bad in { "my house", "house!", "hüt", string.rep("x", 129), 5 } do
			t.ok(not Settings.validName(bad), tostring(bad))
		end
		t.ok(Settings.validMetadata("chest: 3 diamonds, café"))
		t.ok(not Settings.validMetadata("a\nb"))
		t.ok(not Settings.validMetadata(string.rep("m", 129)))
		t.ok(not Settings.validMetadata("\255\254"))
		local s = Settings.defaultStructure()
		t.eq(Settings.checkStructure(s), nil)
		s.name = "my house"
		local problem = Settings.checkStructure(s)
		t.ok(problem and string.find(problem, "Invalid structure name"), problem)
		s.name = "house"
		s.metadata = "tab\there"
		t.ok(Settings.checkStructure(s) ~= nil)
		local j = Settings.defaultJigsaw("North")
		t.eq(Settings.checkJigsaw(j), nil)
		j.finalState = "Planks"
		t.eq(Settings.checkJigsaw(j), nil)
		j.finalState = "Plank"
		local unknown = Settings.checkJigsaw(j)
		t.ok(unknown and string.find(unknown, "Unknown block"), unknown)
		j.finalState = "Air"
		j.pool = "village streets"
		local pool = Settings.checkJigsaw(j)
		t.ok(pool and string.find(pool, "pool"), pool)
		-- Cutting never splits a character.
		t.eq(Settings.cut("aé", 2), "a")
		t.eq(Settings.cut("abc", 5), "abc")
	end)

	t.test("settings: the wire format round trips and refuses malformed bytes", function()
		local s = Settings.clampStructure({
			mode = "load",
			name = "village/houses/hut_1",
			offset = { -48, 1, 48 },
			size = { 48, 0, 7 },
			rotation = 2,
			mirror = "frontBack",
			integrity = 0.3,
			seed = -123456789012,
			showBoundingBox = false,
			showInvisible = true,
			metadata = "loot: café",
		})
		local b = buffer.create(Settings.structureBytes(s) + 3)
		local after = Settings.writeStructure(b, 3, s)
		t.eq(after, buffer.len(b))
		local ok, back, o = Settings.readStructure(b, 3, buffer.len(b))
		t.ok(ok and back and Settings.sameStructure(s, back), "a structure block's settings")
		t.eq(o, buffer.len(b))
		for cut = 3, buffer.len(b) - 1 do
			t.ok(not (Settings.readStructure(b, 3, cut)), `cut at {cut}`)
		end
		local j = {
			name = "door",
			target = "street",
			pool = "village/streets",
			finalState = "Cobblestone",
			joint = "rollable",
		}
		local jb = buffer.create(Settings.jigsawBytes(j))
		Settings.writeJigsaw(jb, 0, j)
		local jok, jback = Settings.readJigsaw(jb, 0, buffer.len(jb))
		t.ok(jok and jback and Settings.sameJigsaw(j, jback), "a jigsaw's settings")
		for cut = 0, buffer.len(jb) - 1 do
			t.ok(not (Settings.readJigsaw(jb, 0, cut)), `jigsaw cut at {cut}`)
		end
		-- Unknown codes and NaN.
		local function patched(offset: number, write: (buffer, number) -> ()): boolean
			local copy = buffer.create(buffer.len(b))
			buffer.copy(copy, 0, b)
			write(copy, offset)
			return (Settings.readStructure(copy, 3, buffer.len(copy)))
		end
		local nameEnd = 3 + 1 + 1 + #s.name
		t.ok(not patched(3, function(c, at)
			buffer.writeu8(c, at, 9)
		end), "an unknown mode")
		t.ok(not patched(nameEnd + 6, function(c, at)
			buffer.writeu8(c, at, 4)
		end), "rotation 4")
		t.ok(not patched(nameEnd + 7, function(c, at)
			buffer.writeu8(c, at, 3)
		end), "an unknown mirror")
		t.ok(not patched(nameEnd + 8, function(c, at)
			buffer.writef64(c, at, 0 / 0)
		end), "NaN integrity")
		t.ok(not patched(nameEnd + 24, function(c, at)
			buffer.writeu8(c, at, 4)
		end), "an unknown flag")
		t.ok(
			patched(nameEnd, function(c, at)
				buffer.writei8(c, at, 100)
			end),
			"an offset beyond the range is clamped"
		)
		-- Random bytes never raise.
		local rng = Hash.rng(77)
		for _ = 1, 300 do
			local junk = buffer.create(rng:int(0, 60))
			for i = 0, buffer.len(junk) - 1 do
				buffer.writeu8(junk, i, rng:int(0, 255))
			end
			t.ok(pcall(Settings.readStructure, junk, 0, buffer.len(junk)))
			t.ok(pcall(Settings.readJigsaw, junk, 0, buffer.len(junk)))
		end
	end)

	--[[ Protocol ]]

	t.test("protocol: StructureBlock and Jigsaw requests round trip; malformed ones are nil", function()
		local s = Settings.clampStructure({ mode = "save", name = "house", size = { 9, 6, 9 } })
		for _, op in Protocol.StructureOp do
			local request =
				{ x = -1000, y = 300, z = 999999, op = op, settings = if op == "open" then nil else s, transfer = 77 }
			local b = Protocol.encodeStructureBlock(request :: any)
			local back = Protocol.decodeStructureBlock(b)
			assert(back)
			t.eq(back.op, op)
			t.eq(back.x, -1000)
			t.eq(back.y, 300)
			t.eq(back.z, 999999)
			t.eq(back.settings ~= nil, op ~= "open")
			if back.settings then
				t.ok(Settings.sameStructure(back.settings, s))
			end
			t.eq(back.transfer, if op == "load" then 77 else 0, "only a load names a transfer")
			for cut = 0, buffer.len(b) - 1 do
				local short = buffer.create(cut)
				buffer.copy(short, 0, b, 0, cut)
				t.eq(Protocol.decodeStructureBlock(short), nil, `{op} cut at {cut}`)
			end
			local long = buffer.create(buffer.len(b) + 1)
			buffer.copy(long, 0, b)
			t.eq(Protocol.decodeStructureBlock(long), nil, "a byte too many")
		end
		local b = Protocol.encodeStructureBlock({ x = 0, y = 0, z = 0, op = "open", transfer = 0 })
		buffer.writeu8(b, 10, 9)
		t.eq(Protocol.decodeStructureBlock(b), nil, "an unknown op")
		local far =
			Protocol.encodeStructureBlock({ x = Protocol.MAX_COORDINATE + 1, y = 0, z = 0, op = "open", transfer = 0 })
		t.eq(Protocol.decodeStructureBlock(far), nil, "too far out")

		local j = { name = "door", target = "street", pool = "village/streets", finalState = "Air", joint = "aligned" }
		for _, op in Protocol.JigsawOp do
			local request = {
				x = 5,
				y = 6,
				z = -7,
				op = op,
				settings = if op == "open" then nil else j,
				levels = 7,
				keepJigsaws = true,
			}
			local encoded = Protocol.encodeJigsaw(request :: any)
			local back = Protocol.decodeJigsaw(encoded)
			assert(back)
			t.eq(back.op, op)
			t.eq(back.settings ~= nil, op ~= "open")
			if back.settings then
				t.ok(Settings.sameJigsaw(back.settings, j))
			end
			t.eq(back.levels, if op == "generate" then 7 else 0)
			t.eq(back.keepJigsaws, op == "generate")
			for cut = 0, buffer.len(encoded) - 1 do
				local short = buffer.create(cut)
				buffer.copy(short, 0, encoded, 0, cut)
				t.eq(Protocol.decodeJigsaw(short), nil, `{op} cut at {cut}`)
			end
		end
		local generate = Protocol.encodeJigsaw({
			x = 0,
			y = 0,
			z = 0,
			op = "generate",
			settings = j,
			levels = 3,
			keepJigsaws = false,
		})
		local n = buffer.len(generate)
		buffer.writeu8(generate, n - 2, 8)
		t.eq(Protocol.decodeJigsaw(generate), nil, "levels beyond 7")
		buffer.writeu8(generate, n - 2, 7)
		buffer.writeu8(generate, n - 1, 2)
		t.eq(Protocol.decodeJigsaw(generate), nil, "keepJigsaws beyond 1")
		local clamped = Protocol.decodeJigsaw(Protocol.encodeJigsaw({
			x = 0,
			y = 0,
			z = 0,
			op = "generate",
			settings = j,
			levels = 99,
			keepJigsaws = false,
		}))
		t.eq(clamped and clamped.levels, 7, "encoding clamps the levels")
	end)

	t.test("protocol: StructureBlocks and Jigsaws records, with removals and the open flag", function()
		local s = Settings.clampStructure({ mode = "corner", name = "house" })
		local records = {
			{ x = 1, y = 2, z = 3, settings = s },
			{ x = -4, y = 5, z = -6, settings = nil },
			{ x = 7, y = 8, z = 9, settings = Settings.defaultStructure("data") },
		}
		local b = Protocol.encodeStructureBlocks(records, true)
		local back, open = Protocol.decodeStructureBlocks(b)
		assert(back)
		t.ok(open)
		t.eq(#back, 3)
		t.ok(back[1].settings and Settings.sameStructure(back[1].settings, s))
		t.eq(back[2].settings, nil, "a removal")
		t.eq(back[2].x, -4)
		t.eq(back[3].settings and back[3].settings.mode, "data")
		local _, closed = Protocol.decodeStructureBlocks(Protocol.encodeStructureBlocks(records))
		t.ok(not closed)
		for cut = 0, buffer.len(b) - 1 do
			local short = buffer.create(cut)
			buffer.copy(short, 0, b, 0, cut)
			t.eq((Protocol.decodeStructureBlocks(short)), nil, `cut at {cut}`)
		end
		-- A huge count in a small message, a bad present byte, bad flags.
		local lying = buffer.create(5)
		buffer.writeu32(lying, 1, 4000000000)
		t.eq((Protocol.decodeStructureBlocks(lying)), nil)
		local bad = Protocol.encodeStructureBlocks({ { x = 0, y = 0, z = 0, settings = nil } })
		buffer.writeu8(bad, 15, 2)
		t.eq((Protocol.decodeStructureBlocks(bad)), nil)
		local flags = Protocol.encodeStructureBlocks({})
		buffer.writeu8(flags, 0, 2)
		t.eq((Protocol.decodeStructureBlocks(flags)), nil)
		local empty = Protocol.decodeStructureBlocks(Protocol.encodeStructureBlocks({}))
		t.eq(empty and #empty, 0)

		local j = Settings.defaultJigsaw("Up")
		local jigsaws =
			Protocol.encodeJigsaws({ { x = 1, y = 1, z = 1, settings = j }, { x = 2, y = 2, z = 2, settings = nil } })
		local jback = Protocol.decodeJigsaws(jigsaws)
		assert(jback)
		t.ok(jback[1].settings and Settings.sameJigsaw(jback[1].settings, j))
		t.eq(jback[2].settings, nil)
	end)

	t.test("protocol: structure text travels in pieces and comes back whole, in any order", function()
		local piece = Protocol.STRUCTURE_PIECE
		t.eq(piece, Config.Structures.DataPieceChars)
		t.eq(Protocol.MAX_STRUCTURE_PIECES, math.ceil(Config.Structures.MaxDataChars / piece))
		local rng = Hash.rng(11)
		local chars = {}
		for i = 1, Config.Structures.MaxDataChars do
			chars[i] = string.char(rng:int(65, 90))
		end
		local text = "IVS1:" .. string.sub(table.concat(chars), 6)
		local pieces = Protocol.splitStructureData(9, text)
		t.eq(#pieces, Protocol.MAX_STRUCTURE_PIECES)
		-- Shuffled, through the wire.
		for i = #pieces, 2, -1 do
			local k = rng:int(1, i)
			pieces[i], pieces[k] = pieces[k], pieces[i]
		end
		local assemblies = {}
		local whole: string? = nil
		for i, p in pieces do
			local b = Protocol.encodeStructureData(p)
			t.ok(buffer.len(b) <= piece + 10, "a piece stays small")
			local decoded = Protocol.decodeStructureData(b)
			assert(decoded)
			local done, err = Protocol.joinStructureData(assemblies, decoded)
			t.eq(err, nil)
			if i < #pieces then
				t.eq(done, nil, "not yet")
			else
				whole = done
			end
		end
		t.eq(whole, text, "the whole text")
		t.eq(next(assemblies), nil, "the transfer is forgotten")
		local short = Protocol.splitStructureData(3, "IVS1:abc")
		t.eq(#short, 1)
		t.eq((Protocol.joinStructureData({}, short[1])), "IVS1:abc")
		t.eq(#Protocol.splitStructureData(3, ""), 1, "an empty text is one empty piece")
		t.eq(
			#Protocol.splitStructureData(3, string.rep("x", Config.Structures.MaxDataChars * 2)),
			Protocol.MAX_STRUCTURE_PIECES,
			"cut to the cap"
		)
		-- Mixed up transfers are refused and dropped.
		local mixed = {}
		t.eq((Protocol.joinStructureData(mixed, { transfer = 1, index = 0, count = 3, text = "a" })), nil)
		local done, err = Protocol.joinStructureData(mixed, { transfer = 1, index = 1, count = 4, text = "b" })
		t.ok(done == nil and err ~= nil, "another count")
		t.eq(mixed[1], nil, "dropped")
		Protocol.joinStructureData(mixed, { transfer = 2, index = 0, count = 2, text = "a" })
		done, err = Protocol.joinStructureData(mixed, { transfer = 2, index = 0, count = 2, text = "a" })
		t.ok(done == nil and err ~= nil, "a piece twice")
		local huge = {}
		for i = 0, Protocol.MAX_STRUCTURE_PIECES - 1 do
			done, err = Protocol.joinStructureData(
				huge,
				{ transfer = 5, index = i, count = Protocol.MAX_STRUCTURE_PIECES, text = string.rep("x", piece) }
			)
		end
		t.ok(done ~= nil or err ~= nil, "a full upload ends")
		-- Abandoned uploads don't pile up.
		local abandoned = {}
		for transfer = 1, 10 do
			Protocol.joinStructureData(abandoned, { transfer = transfer, index = 0, count = 2, text = "x" })
		end
		local open = 0
		for _ in abandoned do
			open += 1
		end
		t.ok(open <= Protocol.MAX_OPEN_TRANSFERS, `{open} half received`)
		t.ok(abandoned[10] ~= nil, "the newest stays")
		-- Malformed pieces.
		local function malformed(transfer: number, index: number, count: number, length: number, extra: number?)
			local b = buffer.create(10 + length + (extra or 0))
			buffer.writeu32(b, 0, transfer)
			buffer.writeu16(b, 4, index)
			buffer.writeu16(b, 6, count)
			buffer.writeu16(b, 8, length)
			return Protocol.decodeStructureData(b)
		end
		t.ok(malformed(1, 0, 1, 10) ~= nil, "a good piece")
		t.eq(malformed(0, 0, 1, 10), nil, "transfer 0")
		t.eq(malformed(1, 1, 1, 10), nil, "index beyond the count")
		t.eq(malformed(1, 0, 0, 0), nil, "no pieces")
		t.eq(malformed(1, 0, Protocol.MAX_STRUCTURE_PIECES + 1, 10), nil, "too many pieces")
		t.eq(malformed(1, 0, 1, piece + 1), nil, "a piece too long")
		t.eq(malformed(1, 0, 1, 10, 1), nil, "a length that lies")
		t.eq(Protocol.decodeStructureData(buffer.create(9)), nil, "too short")
	end)

	t.test("protocol: random bytes never raise in any structure decoder", function()
		local rng = Hash.rng(2024)
		local decoders = {
			Protocol.decodeStructureBlock,
			Protocol.decodeJigsaw,
			Protocol.decodeStructureBlocks,
			Protocol.decodeJigsaws,
			Protocol.decodeStructureData,
		}
		local good = {
			Protocol.encodeStructureBlock({
				x = 1,
				y = 2,
				z = 3,
				op = "load",
				settings = Settings.defaultStructure(),
				transfer = 4,
			}),
			Protocol.encodeJigsaw({
				x = 1,
				y = 2,
				z = 3,
				op = "generate",
				settings = Settings.defaultJigsaw(),
				levels = 2,
				keepJigsaws = true,
			}),
			Protocol.encodeStructureBlocks({ { x = 0, y = 0, z = 0, settings = Settings.defaultStructure() } }),
			Protocol.encodeJigsaws({ { x = 0, y = 0, z = 0, settings = Settings.defaultJigsaw() } }),
			Protocol.encodeStructureData({ transfer = 1, index = 0, count = 1, text = "IVS1:abc" }),
		}
		for i, decode in decoders do
			for _ = 1, 300 do
				local b
				if rng:chance(0.5) then
					b = buffer.create(buffer.len(good[i]))
					buffer.copy(b, 0, good[i])
					for _ = 1, rng:int(1, 4) do
						buffer.writeu8(b, rng:int(0, buffer.len(b) - 1), rng:int(0, 255))
					end
				else
					b = buffer.create(rng:int(0, 80))
					for k = 0, buffer.len(b) - 1 do
						buffer.writeu8(b, k, rng:int(0, 255))
					end
				end
				local ok, err = pcall(decode, b)
				t.ok(ok, `decoder {i} raised: {err}`)
			end
		end
	end)

	t.test("config: the Structures section", function()
		local c = Config.Structures
		t.ok(c.Permission == true or c.Permission == false or type(c.Permission) == "table")
		t.eq(c.MaxSize, 48)
		t.eq(c.MaxOffset, 48)
		t.eq(c.DetectRange, 80)
		t.ok(c.LoadBlocksPerFrame >= 1)
		t.eq(c.MaxDataChars, 200000, "a StringValue's limit")
		t.ok(c.DataPieceChars >= 1000 and c.DataPieceChars <= 60000)
		t.ok(c.DataPiecesPerSecond >= 1)
		t.eq(type(c.Generate), "boolean")
	end)
end
