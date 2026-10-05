--[[
	The client's side of structure blocks and jigsaws: the screens' forms (Ui/StructureForm: fields,
	Minecraft's parsing and filters, layouts per mode, merging the server's updates, the data and
	paste boxes), the records and outlines (World/StructureRecords: regions as Minecraft draws
	them, LOAD's turned box, pruning, the paced outbox, SAVE's text in pieces) and WAILA's lines.
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Protocol = require(shared.Net.Protocol)
	local Settings = require(shared.Structures.Settings)
	local Template = require(shared.Structures.Template)
	local StructureForm = require(client.Ui.StructureForm)
	local StructureRecords = require(client.World.StructureRecords)
	local WailaInfo = require(client.Ui.WailaInfo)

	local function settings(overrides: { [string]: any }?): any
		local s = Settings.defaultStructure()
		for key, value in overrides or {} do
			(s :: any)[key] = value
		end
		return s
	end

	--[[ Forms ]]

	t.test("structure form: fields from the block, read back as Minecraft parses them", function()
		local s = settings({ name = "village/houses/a", offset = { -3, 1, 2 }, size = { 7, 5, 9 }, integrity = 0.5 })
		local form = StructureForm.newStructure(10, 64, -5, s)
		t.eq(form.fields.name, "village/houses/a")
		t.eq(form.fields.posX, "-3")
		t.eq(form.fields.sizeZ, "9")
		t.eq(form.fields.integrity, "0.5")
		t.eq(form.fields.seed, "0")
		t.ok(Settings.sameStructure(StructureForm.structureSettings(form), Settings.clampStructure(s)), "round trip")
		-- Default integrity reads "1.0", as Minecraft's Float.toString.
		t.eq(StructureForm.newStructure(0, 0, 0, settings()).fields.integrity, "1.0")

		-- Minecraft's parsing: no number is 0 (positions, sizes, seed) or 1 (integrity); the ranges
		-- are Settings' (+-48, 0..48, 0..1).
		form.fields.posX = ""
		form.fields.posY = "-"
		form.fields.posZ = "500"
		form.fields.sizeX = "60"
		form.fields.integrity = "."
		form.fields.seed = "-12"
		local read = StructureForm.structureSettings(form)
		t.eq(read.offset[1], 0)
		t.eq(read.offset[2], 0)
		t.eq(read.offset[3], Config.Structures.MaxOffset)
		t.eq(read.size[1], Config.Structures.MaxSize)
		t.eq(read.integrity, 1)
		t.eq(read.seed, -12)
		form.fields.integrity = "0.25"
		t.eq(StructureForm.structureSettings(form).integrity, 0.25)
		form.fields.integrity = "7"
		t.eq(StructureForm.structureSettings(form).integrity, 1, "clamped")
	end)

	t.test("structure form: typing is filtered like Minecraft's fields", function()
		t.eq(StructureForm.filterName("my house/1"), "myhouse/1", "no spaces")
		t.eq(StructureForm.filterName("Hut_2.a:b-c"), "Hut_2.a:b-c")
		t.eq(#StructureForm.filterName(string.rep("a", 200)), Settings.MAX_NAME)
		t.ok(Settings.validName(StructureForm.filterName("a#b%c!d é")), "always a valid name")
		t.eq(StructureForm.filterInteger("-12a3", true), "-123")
		t.eq(StructureForm.filterInteger("-12", false), "12")
		t.eq(StructureForm.filterInteger("4-5", true), "45", "the minus only leads")
		t.eq(#StructureForm.filterInteger(string.rep("9", 40), false), StructureForm.MAX_NUMBER)
		t.eq(StructureForm.filterDecimal("0.5.3x"), "0.53")
		t.eq(StructureForm.filterMetadata("chest\n\tloot"), "chestloot")
		t.ok(Settings.validMetadata(StructureForm.filterMetadata(string.rep("x\1", 300))), "always valid metadata")
	end)

	t.test("structure form: Minecraft's mode and mirror buttons cycle", function()
		t.eq(StructureForm.nextMode("save"), "load")
		t.eq(StructureForm.nextMode("load"), "corner")
		t.eq(StructureForm.nextMode("corner"), "data")
		t.eq(StructureForm.nextMode("data"), "save")
		t.eq(StructureForm.nextMirror("none"), "leftRight")
		t.eq(StructureForm.nextMirror("leftRight"), "frontBack")
		t.eq(StructureForm.nextMirror("frontBack"), "none")
		t.eq(StructureForm.nextJoint("rollable"), "aligned")
		t.eq(StructureForm.nextJoint("aligned"), "rollable")
	end)

	t.test("structure form: server updates keep what the player typed since", function()
		local form = StructureForm.newStructure(0, 0, 0, settings({ name = "hut" }))
		-- The player types a name and presses LOAD; meanwhile types more.
		form.fields.name = "hut2"
		form.mode = "load"
		local sent = StructureForm.structureSettings(form)
		StructureForm.markSent(form, sent)
		form.fields.name = "hut23"
		-- The server stores what was sent: nothing the player typed since is undone.
		local echo = table.clone(sent)
		t.eq(StructureForm.merge(form, echo), false, "an echo changes nothing")
		t.eq(form.fields.name, "hut23")
		-- "Position prepared": the server sets the template's size.
		local prepared = table.clone(echo)
		prepared.size = { 7, 5, 7 }
		t.eq(StructureForm.merge(form, prepared), true)
		t.eq(form.fields.sizeX, "7")
		t.eq(form.fields.name, "hut23", "the name being typed stays")
		-- Another player switches the block to CORNER.
		local other = table.clone(prepared)
		other.mode = "corner"
		StructureForm.merge(form, other)
		t.eq(form.mode, "corner")
		-- DETECT's region comes back.
		form.mode = "save"
		StructureForm.markSent(form, StructureForm.structureSettings(form))
		local detected = table.clone(other)
		detected.mode = "save"
		detected.offset = { 1, 0, 1 }
		detected.size = { 12, 6, 9 }
		StructureForm.merge(form, detected)
		t.eq(form.fields.posX, "1")
		t.eq(form.fields.sizeX, "12")
		t.eq(form.fields.sizeZ, "9")
	end)

	t.test("structure form: after DETECT the actions wait for the block's new region", function()
		local form = StructureForm.newStructure(0, 64, 0, settings({ name = "hut" }))
		t.eq(StructureForm.waiting(form, 0), false)
		-- DETECT goes with the default region (0, 1, 0 / 5 x 5 x 5).
		local sent = StructureForm.structureSettings(form)
		StructureForm.markSent(form, sent)
		StructureForm.await(form, 10)
		t.eq(StructureForm.waiting(form, 10.2), true, "SAVE right after DETECT waits")
		-- The detected region comes back: the fields show it, and SAVE sends it.
		local detected = table.clone(sent)
		detected.offset = { 1, 0, 1 }
		detected.size = { 12, 6, 9 }
		StructureForm.merge(form, detected)
		t.eq(StructureForm.waiting(form, 10.3), false, "the record ends the wait")
		local save = StructureForm.structureSettings(form)
		t.eq(save.offset[1], 1)
		t.eq(save.size[1], 12)
		t.eq(save.size[3], 9)
		-- No answer (no corners found): the wait ends by itself.
		StructureForm.await(form, 20)
		t.eq(StructureForm.waiting(form, 20 + StructureForm.AWAIT_SECONDS * 0.5), true)
		t.eq(StructureForm.waiting(form, 20 + StructureForm.AWAIT_SECONDS), false)
	end)

	-- Do two widgets' rectangles overlap?
	local function overlap(a, b): boolean
		return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
	end

	t.test("structure form: each mode shows Minecraft's widgets, inside the screen, none overlapping", function()
		local expected = {
			save = {
				"name",
				"posX",
				"posY",
				"posZ",
				"sizeX",
				"sizeY",
				"sizeZ",
				"showInvisible",
				"detect",
				"save",
				"data",
			},
			load = {
				"name",
				"posX",
				"integrity",
				"seed",
				"showBoundingBox",
				"rotation0",
				"rotation3",
				"mirror",
				"load",
				"paste",
			},
			corner = { "name" },
			data = { "metadata" },
		}
		local absent = {
			save = { "load", "paste", "integrity", "mirror", "metadata" },
			load = { "save", "detect", "sizeX", "data", "metadata" },
			corner = { "posX", "sizeX", "save", "load", "detect", "data", "paste", "metadata" },
			data = { "name", "posX", "save", "load" },
		}
		for _, mode in Settings.MODES do
			local ids = {}
			local list = StructureForm.layout(mode)
			for _, w in list do
				t.ok(ids[w.id] == nil, `{mode}: {w.id} once`)
				ids[w.id] = w
				local left = StructureForm.WIDTH / 2 + w.x
				t.ok(left >= 0 and left + w.w <= StructureForm.WIDTH, `{mode}: {w.id} inside sideways`)
				t.ok(w.y >= 0 and w.y + w.h <= StructureForm.STRUCTURE_HEIGHT, `{mode}: {w.id} inside`)
			end
			for _, id in expected[mode] do
				t.ok(ids[id] ~= nil, `{mode} shows {id}`)
			end
			for _, id in absent[mode] do
				t.ok(ids[id] == nil, `{mode} hides {id}`)
			end
			for i, a in list do
				for j = i + 1, #list do
					t.ok(not overlap(a, list[j]), `{mode}: {a.id} overlaps {list[j].id}`)
				end
			end
			-- Done / Cancel and the mode button stay where they are whatever the mode.
			t.eq(ids.done.y, 240)
			t.eq(ids.mode.x, -154)
		end
		-- The same widget sits in the same place in every mode (the screen makes each once).
		local where: { [string]: any } = {}
		for _, mode in Settings.MODES do
			for _, w in StructureForm.layout(mode) do
				local seen = where[w.id]
				if seen then
					t.ok(seen.x == w.x and seen.y == w.y and seen.w == w.w and seen.h == w.h, `{w.id} moves`)
				else
					where[w.id] = w
				end
			end
		end
	end)

	t.test("jigsaw form: fields, the joint for vertical fronts, Done off for bad names", function()
		local horizontal, vertical = {}, {}
		for _, w in StructureForm.jigsawLayout("North") do
			horizontal[w.id] = true
		end
		for _, w in StructureForm.jigsawLayout("Up") do
			vertical[w.id] = true
			t.ok(w.y + w.h <= StructureForm.JIGSAW_HEIGHT, `{w.id} inside`)
		end
		t.ok(not horizontal.joint and vertical.joint, "the joint only for vertical fronts")
		for _, id in { "pool", "name", "target", "finalState", "levels", "keepJigsaws", "generate", "done", "cancel" } do
			t.ok(horizontal[id] and vertical[id], id)
		end
		local list = StructureForm.jigsawLayout("Down")
		for i, a in list do
			for j = i + 1, #list do
				t.ok(not overlap(a, list[j]), `{a.id} overlaps {list[j].id}`)
			end
		end

		local form = StructureForm.newJigsaw(1, 2, 3, "Up", "North", Settings.defaultJigsaw("Up"))
		t.eq(form.joint, "rollable", "vertical fronts default to rollable")
		t.eq(form.fields.pool, "empty")
		t.eq(form.fields.finalState, "Air")
		t.eq(form.levels, 0)
		t.eq(form.keepJigsaws, true, "Keep Jigsaws starts on, as Minecraft's screen")
		t.eq(StructureForm.jigsawProblem(form), nil)
		form.fields.finalState = "NoSuchBlock"
		t.ok(StructureForm.jigsawProblem(form) ~= nil, "a final state that is no block")
		form.fields.finalState = "Planks"
		form.fields.pool = "village/streets"
		t.eq(StructureForm.jigsawProblem(form), nil)
		local read = StructureForm.jigsawSettings(form)
		t.eq(read.pool, "village/streets")
		t.eq(read.finalState, "Planks")
		t.eq(StructureForm.newJigsaw(0, 0, 0, "East", "Up", Settings.defaultJigsaw("East")).joint, "aligned")

		-- Merging: the player's typing stays, other changes come in.
		StructureForm.markJigsawSent(form, read)
		form.fields.name = "street_end"
		local echo = table.clone(read)
		t.eq(StructureForm.mergeJigsaw(form, echo), false)
		local changed = table.clone(echo)
		changed.target = "house_door"
		t.eq(StructureForm.mergeJigsaw(form, changed), true)
		t.eq(form.fields.target, "house_door")
		t.eq(form.fields.name, "street_end")
	end)

	t.test("data box: long data comes in parts; pasted data is checked before it goes", function()
		t.eq(#StructureForm.dataParts(""), 0)
		t.eq(#StructureForm.dataParts("IVS1:abc"), 1)
		local long = string.rep("A", StructureForm.DATA_PART * 2 + 5)
		local parts = StructureForm.dataParts(long)
		t.eq(#parts, 3)
		t.eq(table.concat(parts), long, "the parts make the whole text")
		local info, hint = StructureForm.dataLines(long, #parts, 2)
		t.ok(string.find(info, "part 2 of 3", 1, true) ~= nil, info)
		t.ok(string.find(hint, "Ctrl+C", 1, true) ~= nil, hint)
		local shortInfo = StructureForm.dataLines("IVS1:abcd", 1, 1)
		t.eq(shortInfo, "9 characters")
		t.eq(StructureForm.thousands(130693), "130,693")

		-- A real structure: a 3 x 2 x 3 stone floor with a torch.
		local hut = Template.new("tests/hut", { 3, 2, 3 })
		for x = 0, 2 do
			for z = 0, 2 do
				Template.set(hut, x, 0, z, Blocks.id.Stone)
				Template.set(hut, x, 1, z, Blocks.AIR)
			end
		end
		Template.set(hut, 1, 1, 1, Blocks.id.Torch)
		local text = Template.encode(hut)
		local summary = StructureForm.pasteSummary(`  {text}\n`, Config.Structures.MaxDataChars)
		assert(summary, "a summary")
		t.ok(summary.ok, summary.text)
		t.eq(summary.name, "tests/hut")
		t.ok(string.find(summary.text, "3x2x3", 1, true) ~= nil, summary.text)
		t.ok(string.find(summary.text, "10 blocks", 1, true) ~= nil, summary.text)
		-- Wrapped by a chat window: still fine.
		local wrapped = string.sub(text, 1, 20) .. "\n" .. string.sub(text, 21)
		local again = StructureForm.pasteSummary(wrapped, Config.Structures.MaxDataChars)
		t.ok(again ~= nil and again.ok, "whitespace inside is ignored")
		-- Cut off, garbage, too long, empty.
		local cut = StructureForm.pasteSummary(string.sub(text, 1, #text - 6), Config.Structures.MaxDataChars)
		t.ok(cut ~= nil and not cut.ok, "a cut paste")
		local junk = StructureForm.pasteSummary("hello there", Config.Structures.MaxDataChars)
		t.ok(junk ~= nil and not junk.ok and junk.text ~= "", "not structure data")
		local huge = StructureForm.pasteSummary(string.rep("A", 30), 20)
		t.ok(huge ~= nil and not huge.ok, "too long")
		t.eq(StructureForm.pasteSummary("   \n ", 100), nil, "empty: LOAD uses the name")
	end)

	--[[ Records ]]

	t.test("records: messages replace and forget; stale ones are pruned", function()
		local r = StructureRecords.new()
		local s = settings({ name = "a" })
		StructureRecords.applyStructures(
			r,
			{ { x = 1, y = 2, z = 3, settings = s }, { x = 4, y = 5, z = 6, settings = s } }
		)
		t.eq(StructureRecords.structure(r, 1, 2, 3).name, "a")
		local version = r.version
		StructureRecords.applyStructures(r, { { x = 1, y = 2, z = 3, settings = nil } })
		t.eq(StructureRecords.structure(r, 1, 2, 3), nil, "forgotten")
		t.ok(r.version > version)
		StructureRecords.applyStructures(r, { { x = 0, y = 5000, z = 0, settings = s } })
		t.eq(StructureRecords.structure(r, 0, 5000, 0), nil, "outside the world")
		StructureRecords.applyJigsaws(r, { { x = 7, y = 8, z = 9, settings = Settings.defaultJigsaw("North") } })
		t.eq(StructureRecords.jigsaw(r, 7, 8, 9).pool, "empty")

		-- (4, 5, 6) is now stone, (7, 8, 9) unloaded: only the first goes.
		local removed = StructureRecords.prune(r, function(x, _y, _z)
			if x == 4 then
				return Blocks.id.Stone
			end
			return nil
		end)
		t.eq(removed, 1)
		t.eq(StructureRecords.structure(r, 4, 5, 6), nil)
		t.ok(StructureRecords.jigsaw(r, 7, 8, 9) ~= nil, "unloaded blocks keep their records")
	end)

	-- Minecraft's StructureTemplate transform of local (x, z) around the pivot 0.
	local function minecraft(x: number, z: number, rotation: number, mirror: string): (number, number)
		if mirror == "leftRight" then
			z = -z
		elseif mirror == "frontBack" then
			x = -x
		end
		for _ = 1, rotation do
			x, z = -z, x
		end
		return x, z
	end

	t.test("records: regions as Minecraft outlines them; LOAD's box is where the template goes", function()
		local save = settings({ offset = { 0, 1, 0 }, size = { 5, 4, 3 } })
		t.eq(table.concat(StructureRecords.region(10, 20, 30, save, "save") :: { number }, ","), "10,21,30,14,24,32")
		t.eq(StructureRecords.region(10, 20, 30, save, "corner"), nil, "corners draw nothing")
		t.eq(StructureRecords.region(10, 20, 30, save, "data"), nil)
		local flat = settings({ size = { 5, 0, 3 } })
		t.eq(StructureRecords.region(0, 0, 0, flat, "save"), nil, "a side of 0 draws nothing")
		local hidden = settings({ mode = "load", showBoundingBox = false })
		t.eq(StructureRecords.region(0, 0, 0, hidden, "load"), nil, "LOAD only with Show Bounding Box")
		-- SAVE always shows its box (Minecraft: SAVE or showBoundingBox).
		local saveHidden = settings({ showBoundingBox = false })
		t.ok(StructureRecords.region(0, 0, 0, saveHidden, "save") ~= nil)

		for rotation = 0, 3 do
			for _, mirror in Settings.MIRRORS do
				local s = settings({
					mode = "load",
					offset = { 2, 1, -3 },
					size = { 5, 2, 3 },
					rotation = rotation,
					mirror = mirror,
				})
				local box = StructureRecords.region(100, 50, 200, s, "load") :: { number }
				local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
				for lx = 0, 4 do
					for lz = 0, 2 do
						local x, z = minecraft(lx, lz, rotation, mirror)
						minX, maxX = math.min(minX, x), math.max(maxX, x)
						minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
					end
				end
				local where = `rotation {rotation} mirror {mirror}`
				t.eq(box[1], 102 + minX, where)
				t.eq(box[4], 102 + maxX, where)
				t.eq(box[3], 197 + minZ, where)
				t.eq(box[6], 197 + maxZ, where)
				t.eq(box[2], 51, where)
				t.eq(box[5], 52, where)
			end
		end
	end)

	t.test("records: the nearest outlined blocks, the open screen's settings first", function()
		local r = StructureRecords.new()
		local list = {}
		for i = 1, 10 do
			table.insert(list, { x = i * 10, y = 0, z = 0, settings = settings({ name = `s{i}` }) })
		end
		table.insert(list, { x = 500, y = 0, z = 0, settings = settings({ name = "far" }) })
		StructureRecords.applyStructures(r, list)
		local save, corner = Blocks.structureBlock("save"), Blocks.structureBlock("corner")
		local function getBlock(x, _y, _z)
			if x == 30 then
				return corner
			end
			return save
		end
		local found = StructureRecords.outlined(r, 0, 0, 128, 4, getBlock)
		t.eq(#found, 4, "at most the limit")
		t.eq(found[1].x, 10, "nearest first")
		t.eq(found[3].x, 40, "a corner block draws nothing")
		for _, item in StructureRecords.outlined(r, 0, 0, 128, 50, getBlock) do
			t.ok(item.x ~= 500, "out of range")
		end
		-- The screen being edited: its settings and its mode count.
		local edited = settings({ mode = "save", name = "edited", size = { 2, 2, 2 } })
		local withOverride =
			StructureRecords.outlined(r, 0, 0, 128, 50, getBlock, { x = 30, y = 0, z = 0, settings = edited })
		local hit = false
		for _, item in withOverride do
			if item.x == 30 then
				hit = true
				t.eq(item.settings.name, "edited")
			end
		end
		t.ok(hit, "a corner block switched to SAVE on its screen shows the region being edited")
	end)

	t.test("outbox: pasted data goes at the configured rate, then the request after it", function()
		local rate = Config.Structures.DataPiecesPerSecond
		local box = StructureRecords.outbox(rate)
		local messages = {}
		for i = 1, rate + 5 do
			table.insert(messages, { kind = 12, payload = buffer.create(i) })
		end
		box:push(messages)
		box:push({ { kind = 10, payload = buffer.create(0) } })
		local first = box:step(0)
		t.eq(#first, rate, "a second's worth at once")
		t.eq(buffer.len(first[1].payload), 1, "in order")
		local later = box:step(0.1)
		t.eq(#later, math.floor(rate * 0.1))
		local rest = box:step(10)
		t.eq(rest[#rest].kind, 10, "the request goes last")
		t.eq(box:pending(), 0)
		-- (Pasted text in pieces: Protocol splits and joins it.)
		local text = string.rep("IVS1", 10000)
		local pieces = Protocol.splitStructureData(7, text)
		t.eq(#pieces, math.ceil(#text / Protocol.STRUCTURE_PIECE))
	end)

	t.test("downloads: SAVE's text comes back in pieces, in any order, kept per block", function()
		local downloads = StructureRecords.downloads()
		local text = string.rep("IVS1:abcdefgh", 3000)
		local pieces = Protocol.splitStructureData(1, text)
		t.ok(#pieces > 1, "several pieces")
		downloads:expect(5, 60, -7, "hut", { 5, 5, 5 }, 0)
		local doneKey, doneText = nil, nil
		for i = #pieces, 1, -1 do
			local decoded = Protocol.decodeStructureData(Protocol.encodeStructureData(pieces[i]))
			local key, whole, err = downloads:add(decoded, 0.5)
			t.eq(err, nil)
			if key then
				doneKey, doneText = key, whole
			end
		end
		t.ok(doneKey ~= nil, "finished")
		t.eq(doneText, text)
		t.eq(downloads:text(5, 60, -7), text)
		t.eq(downloads:text(5, 61, -7), nil)
		-- Only the last few blocks keep theirs.
		for i = 1, StructureRecords.KEPT_DOWNLOADS do
			downloads:expect(i, 0, 0, "hut", { 5, 5, 5 }, 1)
			downloads:add({ transfer = 100 + i, index = 0, count = 1, text = `t{i}` }, 1)
		end
		t.eq(downloads:text(5, 60, -7), nil, "the oldest went")
		t.eq(downloads:text(1, 0, 0), "t1")
	end)

	t.test("downloads: each SAVE's text goes to the block that saved it, refused SAVEs get none", function()
		-- (Real IVS1 texts: the name and size in their head pick the SAVE they answer.)
		local function saved(name: string, size: { number }, fill: number): string
			local template = Template.new(name, size)
			for y = 0, size[2] - 1 do
				for z = 0, size[3] - 1 do
					for x = 0, size[1] - 1 do
						Template.set(template, x, y, z, if (x + y + z) % fill == 0 then Blocks.id.Stone else Blocks.AIR)
					end
				end
			end
			return Template.encode(template)
		end
		local function deliver(d: any, transfer: number, text: string, now: number, from: number?, to: number?)
			local pieces = Protocol.splitStructureData(transfer, text)
			local key, whole
			for i = from or 1, math.min(to or #pieces, #pieces) do
				local k, w, err = d:add(pieces[i], now)
				t.eq(err, nil)
				if k then
					key, whole = k, w
				end
			end
			return key, whole
		end
		local big = saved("builds/castle", { 48, 40, 48 }, 7)
		t.ok(#Protocol.splitStructureData(1, big) > 1, "the big text comes in several pieces")
		local small = saved("builds/hut", { 5, 5, 5 }, 2)

		-- Two SAVEs in flight: A's big text is still coming when B's SAVE is pressed.
		local d = StructureRecords.downloads()
		d:expect(10, 64, 10, "builds/castle", { 48, 40, 48 }, 0)
		deliver(d, 1, big, 0.1, 1, 1)
		d:expect(20, 64, 20, "builds/hut", { 5, 5, 5 }, 0.2)
		deliver(d, 1, big, 0.6, 2)
		deliver(d, 2, small, 0.7)
		t.eq(d:text(10, 64, 10), big, "A's data under A")
		t.eq(d:text(20, 64, 20), small, "B's data under B")
		t.eq(#d.expected, 0)

		-- B's SAVE is refused (no text comes): A's text is still A's, B shows nothing.
		local refused = StructureRecords.downloads()
		refused:expect(10, 64, 10, "builds/castle", { 48, 40, 48 }, 0)
		deliver(refused, 1, big, 0.1, 1, 1)
		refused:expect(20, 64, 20, "builds/hut", { 5, 5, 5 }, 0.2)
		deliver(refused, 1, big, 0.6, 2)
		t.eq(refused:text(10, 64, 10), big)
		t.eq(refused:text(20, 64, 20), nil, "a refused SAVE shows no other block's data")

		-- A refused first: B's text skips it, and the refused SAVE is forgotten.
		refused = StructureRecords.downloads()
		refused:expect(10, 64, 10, "builds/castle", { 48, 40, 48 }, 0)
		refused:expect(20, 64, 20, "builds/hut", { 5, 5, 5 }, 0.1)
		local key, whole = deliver(refused, 1, small, 0.5)
		t.eq(whole, small)
		t.eq(refused:text(20, 64, 20), small)
		t.eq(refused:text(10, 64, 10), nil)
		t.eq(#refused.expected, 0, "the SAVE before it was refused")
		t.ok(key ~= nil)

		-- The same block saved twice: its last text stays. Old expectations lapse.
		local again = StructureRecords.downloads()
		again:expect(1, 2, 3, "builds/hut", { 5, 5, 5 }, 0)
		again:expect(1, 2, 3, "builds/hut", { 5, 5, 5 }, 0.1)
		deliver(again, 1, small, 0.5)
		deliver(again, 2, small, 0.6)
		t.eq(again:text(1, 2, 3), small)
		again:expect(4, 5, 6, "builds/hut", { 5, 5, 5 }, 1)
		deliver(again, 3, small, 1 + StructureRecords.EXPECT_SECONDS + 1)
		t.eq(again:text(4, 5, 6), nil, "a SAVE that never got its text is forgotten")
	end)

	--[[ WAILA ]]

	t.test("WAILA: structure blocks' mode and name, jigsaws' name, target and pool, creative only", function()
		local function texts(block: number, context: any, extended: boolean?): string
			return table.concat(WailaInfo.texts(WailaInfo.block(block, nil, 0, 64, 0, extended == true, context)), "\n")
		end
		local save = Blocks.structureBlock("save") :: number
		local info = texts(save, { structure = settings({ name = "village/houses/a" }) })
		t.ok(string.find(info, "Mode: Save", 1, true) ~= nil, info)
		t.ok(string.find(info, "Name: village/houses/a", 1, true) ~= nil, info)
		t.ok(string.find(info, "Creative only", 1, true) ~= nil, info)
		t.ok(string.find(info, "Unbreakable", 1, true) == nil, info)
		-- Without a record yet: the mode from the block alone.
		local load = Blocks.structureBlock("load") :: number
		local bare = texts(load, nil)
		t.ok(string.find(bare, "Mode: Load", 1, true) ~= nil and string.find(bare, "Name:", 1, true) == nil, bare)
		local data = Blocks.structureBlock("data") :: number
		local marker = texts(data, { structure = settings({ mode = "data", metadata = "chest" }) })
		t.ok(string.find(marker, "Data: chest", 1, true) ~= nil, marker)

		local jigsaw = Blocks.jigsawBlock("Up", "North") :: number
		local j = Settings.defaultJigsaw("Up")
		j.name = "street"
		j.target = "house_door"
		j.pool = "village/houses"
		local jinfo = texts(jigsaw, { jigsaw = j })
		for _, line in { "Name: street", "Target: house_door", "Pool: village/houses" } do
			t.ok(string.find(jinfo, line, 1, true) ~= nil, line)
		end
		local extended = texts(jigsaw, { jigsaw = j }, true)
		t.ok(string.find(extended, "Front Up, top North", 1, true) ~= nil, extended)
		t.ok(string.find(extended, "Breaks in creative only", 1, true) ~= nil, extended)
		t.ok(string.find(extended, "Breaks in inf", 1, true) == nil, "no infinite break time")
		local voidInfo = texts(Blocks.id.StructureVoid, nil)
		t.ok(string.find(voidInfo, "Creative only", 1, true) ~= nil, voidInfo)

		-- Cave lichen is named like glow lichen.
		t.eq(WailaInfo.blockName(Blocks.id.CaveGlowLichenNorth), WailaInfo.blockName(Blocks.id.GlowLichen))
	end)
end
