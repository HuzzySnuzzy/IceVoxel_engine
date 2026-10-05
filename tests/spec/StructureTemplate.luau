--[[
	Structure templates (Structures/Template): the in-memory model, the IVS1 text (base64url,
	varints, run length or packed cells, CRC-32) and its round trip over random templates, what
	decode says about cut, mistyped, damaged and hand-made bad data (never erroring), unknown
	blocks and items, capturing the world with the structure block's SAVE rules, the editable
	ASCII tables, how long typical structures are as text, and how tests/structure finds and
	decodes data pasted into a chat message (tests/lib/StructureText).
]]

local StructureText = require("../lib/StructureText")

return function(t, shared, require)
	local Blocks = require(shared.Blocks)
	local Hash = require(shared.Util.Hash)
	local Template = require(shared.Structures.Template)
	local Settings = require(shared.Structures.Settings)
	local Protocol = require(shared.Net.Protocol)

	local id = Blocks.id
	local AIR = Blocks.AIR

	-- A random template: size up to `maxSize`, a few kinds of blocks (some "keep"), and jigsaws,
	-- markers and containers.
	local function randomTemplate(rng: any, maxSize: number, noisy: boolean): any
		local size = { rng:int(1, maxSize), rng:int(1, maxSize), rng:int(1, maxSize) }
		local tpl = Template.new(`random/{rng:int(0, 99999)}`, size)
		local kinds = {}
		for _ = 1, rng:int(1, 12) do
			local block = rng:int(0, Blocks.count - 1)
			if Blocks.get(block).jigsaw == nil then
				table.insert(kinds, block)
			end
		end
		table.insert(kinds, AIR)
		local current: number? = kinds[1]
		for y = 0, size[2] - 1 do
			for z = 0, size[3] - 1 do
				for x = 0, size[1] - 1 do
					-- Runs of the same block, or noise.
					if noisy or rng:chance(0.15) then
						current = if rng:chance(0.1) then nil else kinds[rng:int(1, #kinds)]
					end
					Template.set(tpl, x, y, z, current)
				end
			end
		end
		local used: { [number]: boolean } = {}
		local function freeCell(): (number, number, number)
			for _ = 1, 50 do
				local x, y, z = rng:int(0, size[1] - 1), rng:int(0, size[2] - 1), rng:int(0, size[3] - 1)
				local index = Template.index(tpl, x, y, z)
				if not used[index] then
					used[index] = true
					return x, y, z
				end
			end
			return -1, -1, -1
		end
		local orientations = {
			{ "North", "Up" },
			{ "East", "Up" },
			{ "Up", "South" },
			{ "Down", "West" },
		}
		for _ = 1, rng:int(0, 4) do
			local x, y, z = freeCell()
			if x >= 0 then
				local o = orientations[rng:int(1, #orientations)]
				Template.set(tpl, x, y, z, Blocks.jigsawBlock(o[1], o[2]))
				table.insert(tpl.jigsaws, {
					x = x,
					y = y,
					z = z,
					front = o[1],
					top = o[2],
					name = `j{rng:int(0, 9)}`,
					target = "minecraft:empty",
					pool = `pool/{rng:int(0, 9)}`,
					finalState = "Planks",
					joint = if rng:chance(0.5) then "rollable" else "aligned",
				})
			end
		end
		for _ = 1, rng:int(0, 3) do
			local x, y, z = freeCell()
			if x >= 0 then
				table.insert(tpl.markers, { x = x, y = y, z = z, data = `chest {rng:int(0, 100)} ünïcode` })
			end
		end
		for _ = 1, rng:int(0, 3) do
			local x, y, z = freeCell()
			if x >= 0 then
				Template.set(tpl, x, y, z, id.Chest)
				table.insert(tpl.containers, {
					x = x,
					y = y,
					z = z,
					items = {
						{ slot = 1, item = "Torch", count = rng:int(1, 64), damage = 0 },
						{ slot = 27, item = "IronPickaxe", count = 1, damage = rng:int(0, 200) },
					},
				})
			end
		end
		return tpl
	end

	-- A payload with a right length and checksum around `body` (bytes as a list), as IVS1 text.
	local function varint(out: { number }, value: number)
		while value >= 128 do
			table.insert(out, value % 128 + 128)
			value = value // 128
		end
		table.insert(out, value)
	end
	local function str(out: { number }, s: string)
		varint(out, #s)
		for i = 1, #s do
			table.insert(out, string.byte(s, i))
		end
	end
	local function wrap(body: { number }, version: number?): string
		local head = {}
		varint(head, version or 1)
		varint(head, #body)
		local all = table.clone(head)
		for _, byte in body do
			table.insert(all, byte)
		end
		local b = buffer.create(#all + 4)
		for i, byte in all do
			buffer.writeu8(b, i - 1, byte)
		end
		buffer.writeu32(b, #all, Template.crc32(b, 0, #all))
		return Template.PREFIX .. Template.base64(b)
	end
	-- A 1 x 1 x 1 stone template's body, with the rest given by `tail` (records).
	local function stoneBody(name: string?, tail: { number }?): { number }
		local body = {}
		str(body, name or "test/one")
		varint(body, 1)
		varint(body, 1)
		varint(body, 1)
		varint(body, 1)
		str(body, "Stone")
		varint(body, 0) -- runs
		varint(body, 1)
		varint(body, 1)
		for _, byte in tail or { 0, 0, 0 } do
			table.insert(body, byte)
		end
		return body
	end

	t.test("templates: new holds keep, set and get go through the palette, count leaves air out", function()
		local tpl = Template.new("test/box", { 3, 2, 4 })
		t.eq(buffer.len(tpl.cells), 3 * 2 * 4 * 2)
		t.eq(Template.get(tpl, 0, 0, 0), nil, "keep")
		Template.set(tpl, 2, 1, 3, id.Stone)
		Template.set(tpl, 0, 0, 0, AIR)
		Template.set(tpl, 1, 0, 0, id.Stone)
		t.eq(Template.get(tpl, 2, 1, 3), id.Stone)
		t.eq(#tpl.palette, 2, "stone and air, each once")
		t.eq(Template.index(tpl, 2, 1, 3), (1 * 4 + 3) * 3 + 2, "x fastest, then z, then y")
		t.eq(buffer.readu16(tpl.cells, Template.index(tpl, 2, 1, 3) * 2), tpl.palette[1] == id.Stone and 1 or 2)
		t.eq(Template.count(tpl), 2, "air and keep don't count")
		local counts, keep = Template.counts(tpl)
		t.eq(counts[id.Stone], 2)
		t.eq(counts[AIR], 1)
		t.eq(keep, 24 - 3)
		-- Outside: nothing happens, nothing is there.
		Template.set(tpl, 3, 0, 0, id.Stone)
		Template.set(tpl, -1, 0, 0, id.Stone)
		t.eq(Template.get(tpl, 3, 0, 0), nil)
		t.eq(Template.get(tpl, 0.5, 0, 0), nil)
		Template.set(tpl, 2, 1, 3, nil)
		t.eq(Template.get(tpl, 2, 1, 3), nil, "back to keep")
		t.eq(Template.check(tpl), nil)
	end)

	t.test("bytes: CRC-32 and base64url match their standards", function()
		local b = buffer.fromstring("123456789")
		t.eq(Template.crc32(b, 0, 9), 0xCBF43926, "the CRC-32 check value")
		t.eq(Template.crc32(b, 0, 0), 0)
		local vectors = {
			[""] = "",
			f = "Zg",
			fo = "Zm8",
			foo = "Zm9v",
			foob = "Zm9vYg",
			fooba = "Zm9vYmE",
			foobar = "Zm9vYmFy",
			["\251\255"] = "-_8",
			["\255\255\255"] = "____",
		}
		for raw, encoded in vectors do
			t.eq(Template.base64(buffer.fromstring(raw)), encoded, `base64 of {#raw} bytes`)
			local back = Template.unbase64(encoded)
			t.eq(back and buffer.tostring(back), raw)
		end
		local spaced = Template.unbase64(" Zm9v\n Ym\r\nFy\t")
		t.eq(spaced and buffer.tostring(spaced), "foobar", "whitespace is skipped")
		local bad, message = Template.unbase64("Zm9v+")
		t.eq(bad, nil, "+ is standard base64, not base64url")
		t.ok(message and string.find(message, "'+'", 1, true), message)
	end)

	t.test("round trip: random templates decode to what was encoded, and encode alike again", function()
		local rng = Hash.rng(8123)
		for i = 1, 160 do
			local tpl = randomTemplate(rng, if i % 20 == 0 then 24 else 9, i % 3 == 0)
			t.eq(Template.check(tpl), nil, "a valid template")
			local text = Template.encode(tpl)
			t.eq(string.sub(text, 1, 5), "IVS1:")
			t.ok(string.find(string.sub(text, 6), "^[%w%-_]*$") ~= nil, "only base64url characters")
			local back, err, warnings = Template.decode(text)
			t.ok(back ~= nil, err)
			assert(back)
			t.eq(warnings and #warnings, 0)
			local same, why = Template.equal(tpl, back)
			t.ok(same, `template {i}: {why}`)
			t.eq(Template.check(back), nil)
			t.eq(Template.encode(back), text, "encoding is deterministic")
			-- Unused palette entries are left out.
			local counts = Template.counts(back)
			for _, block in back.palette do
				t.ok(counts[block] ~= nil, "every palette entry is used")
			end
		end
	end)

	t.test("round trip: runs for builds, packed cells for noise, both smaller than the other", function()
		local runs = Template.new("test/runs", { 20, 20, 20 })
		for y = 0, 19 do
			for z = 0, 19 do
				for x = 0, 19 do
					Template.set(runs, x, y, z, if y < 10 then id.Stone else AIR)
				end
			end
		end
		local rng = Hash.rng(3)
		local noise = Template.new("test/noise", { 20, 20, 20 })
		local kinds = { id.Stone, id.Dirt, id.Planks, AIR }
		for y = 0, 19 do
			for z = 0, 19 do
				for x = 0, 19 do
					Template.set(noise, x, y, z, kinds[rng:int(1, 4)])
				end
			end
		end
		local runText, noiseText = Template.encode(runs), Template.encode(noise)
		t.ok(#runText < 80, `two runs: {#runText} characters`)
		-- 8000 cells of 4 kinds (indices 1..4, 0 being keep): 3 bits each (3000 bytes), not a run per
		-- cell (about 2 bytes each).
		t.ok(#noiseText > 3000 * 4 / 3 and #noiseText < 3100 * 4 / 3, `packed: {#noiseText} characters`)
		for _, tpl in { runs, noise } do
			local back = Template.decode(Template.encode(tpl))
			t.ok(back and Template.equal(tpl, back))
		end
	end)

	t.test("decode: wrapped, indented and quoted pastes decode alike", function()
		local tpl = randomTemplate(Hash.rng(77), 8, false)
		local text = Template.encode(tpl)
		local wrapped = string.gsub(text, "(" .. string.rep(".", 50) .. ")", "%1\n    ")
		local variants = {
			"  " .. text .. "  \n",
			'"' .. text .. '"',
			"`" .. text .. "`",
			"'" .. wrapped .. "'",
			string.gsub(text, "(" .. string.rep(".", 64) .. ")", "%1\r\n"),
			"\tIVS1:" .. string.gsub(string.sub(text, 6), "(.)", "%1 ") .. "\n",
		}
		for i, variant in variants do
			local back, err = Template.decode(variant)
			t.ok(back ~= nil, `variant {i}: {err}`)
			t.ok(back and Template.equal(tpl, back), `variant {i}`)
		end
	end)

	t.test("decode: cut, mistyped, damaged and joined pastes are reported, never raised", function()
		local tpl = randomTemplate(Hash.rng(5), 10, true)
		local text = Template.encode(tpl)
		-- Cut anywhere after the prefix.
		for cut = 6, #text - 1, math.max(1, #text // 40) do
			local back, err = Template.decode(string.sub(text, 1, cut))
			t.eq(back, nil, `cut at {cut}`)
			t.ok(type(err) == "string" and err ~= "", "a message")
		end
		local _, cutMessage = Template.decode(string.sub(text, 1, #text - 20))
		t.ok(cutMessage and string.find(cutMessage, "cut off"), cutMessage)
		-- One character changed: the checksum catches it (or the structure no longer makes sense).
		local rng = Hash.rng(9)
		local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
		for _ = 1, 60 do
			local at = rng:int(8, #text - 8)
			local old = string.sub(text, at, at)
			local new = old
			while new == old do
				local k = rng:int(1, 64)
				new = string.sub(alphabet, k, k)
			end
			local back, err = Template.decode(string.sub(text, 1, at - 1) .. new .. string.sub(text, at + 1))
			t.eq(back, nil, `changed at {at}`)
			t.ok(type(err) == "string", "a message")
		end
		local middle = #text // 2
		local flipped = string.sub(text, 1, middle - 1)
			.. (if string.sub(text, middle, middle) == "A" then "B" else "A")
			.. string.sub(text, middle + 1)
		local _, damaged = Template.decode(flipped)
		t.ok(damaged and string.find(damaged, "checksum"), damaged)
		local _, joined = Template.decode(text .. string.sub(text, 6))
		t.ok(joined and string.find(joined, "extra"), joined)
		local _, prefix = Template.decode("Hello! " .. text)
		t.ok(prefix and string.find(prefix, "IVS1"), prefix)
		local _, character = Template.decode(string.sub(text, 1, 20) .. "!" .. string.sub(text, 21))
		t.ok(character and string.find(character, "'!'", 1, true), character)
		local _, newer = Template.decode("IVS2:AAAA")
		t.ok(newer and string.find(newer, "newer"), newer)
		t.eq((Template.decode(wrap(stoneBody(), 2))), nil, "a newer format")
		t.eq((Template.decode(wrap(stoneBody(), 0))), nil, "format 0")
		for _, junk in { "", "IVS1:", "IVS1:A", "IVS1:AA", "IVS1:____", 42, nil, {}, "IVS1:" .. string.rep("A", 5000) } do
			local ok, back = pcall(Template.decode, junk)
			t.ok(ok, "never raises")
			t.eq(back, nil)
		end
		local _, long = Template.decode("IVS1:" .. string.rep("A", Template.MAX_TEXT))
		t.ok(long and string.find(long, "too long"), long)
	end)

	t.test("decode: a long whitespace run inside the text takes linear time", function()
		-- (A pasted LOAD is decoded on the server thread: a pattern anchored at the text's end
		-- rescanned every interior whitespace run to its end, minutes for 200,000 characters.)
		local cap = Protocol.MAX_STRUCTURE_TEXT
		local tpl = randomTemplate(Hash.rng(31), 6, false)
		local text = Template.encode(tpl)
		for _, filler in { " ", "\n", "\r\n", "\t \"'`" } do
			local run = string.rep(filler, (cap - #text - 4) // #filler)
			local hostile = string.sub(text, 1, 10) .. run .. string.sub(text, 11) .. "\n "
			t.ok(#hostile <= cap, "within what a player may upload")
			local start = os.clock()
			local back, err = Template.decode(hostile)
			local seconds = os.clock() - start
			t.ok(seconds < 0.5, `{#hostile} characters decoded in {string.format("%.3f", seconds)} s`)
			if filler == "\t \"'`" then
				t.eq(back, nil, "quotes inside the text are not whitespace")
				t.ok(err and string.find(err, "doesn't belong", 1, true), err)
			else
				t.ok(back ~= nil and Template.equal(tpl, back), `{string.format("%q", filler)}: {err}`)
			end
		end
		-- Trailing quotes and whitespace still go, however many.
		local trailing = text .. string.rep("\"' \n`", (cap - #text) // 5)
		local start = os.clock()
		local back = Template.decode(trailing)
		t.ok(os.clock() - start < 0.5, "a long tail is cut in linear time")
		t.ok(back ~= nil and Template.equal(tpl, back), "and decodes")
	end)

	t.test("pasted chat: tests/structure finds and decodes data among words, wrapped or quoted", function()
		local hut = randomTemplate(Hash.rng(41), 7, false)
		hut.name = "chat/hut"
		local tower = randomTemplate(Hash.rng(42), 7, true)
		tower.name = "chat/tower"
		local text, other = Template.encode(hut), Template.encode(tower)
		t.ok(#text > 200, "long enough to wrap")
		local function wrapAt(data: string, width: number, newline: string): string
			local lines = {}
			for at = 1, #data, width do
				table.insert(lines, string.sub(data, at, at + width - 1))
			end
			return table.concat(lines, newline)
		end
		-- Each message, and the names of the structures found in it, in order.
		local cases: { { any } } = {
			{
				"wrapped at 80, words around",
				`hey claude, here is my hut:\n\n{wrapAt(text, 80, "\n")}\n\nThanks for the help`,
				{ "chat/hut" },
			},
			{ "CRLF line breaks", `Here:\r\n{wrapAt(text, 64, "\r\n")}\r\n`, { "chat/hut" } },
			{ "words on the same line", `my hut {text} what do you think`, { "chat/hut" } },
			{ "words on the next line", `{text}\nit has a door on the east side`, { "chat/hut" } },
			{ "punctuation after it", `Look: {text}. Neat, right?`, { "chat/hut" } },
			{ "a dash and words after it", `{text} - built in creative`, { "chat/hut" } },
			{ "a code fence", `\`\`\`\n{text}\n\`\`\``, { "chat/hut" } },
			{
				"two in one message",
				`the hut {text} and the tower\n{wrapAt(other, 80, "\n")}\nbye`,
				{ "chat/hut", "chat/tower" },
			},
			{ "a quoted module line", `-- chat/hut (7 x 5 x 7)\nreturn "{text}"\n`, { "chat/hut" } },
			{ "a list module", `return \{\n\t"{text}",\n\t"{other}",\n\}\n`, { "chat/hut", "chat/tower" } },
		}
		for _, case in cases do
			local label, message, names = case[1], case[2], case[3]
			local texts = StructureText.findTexts(message)
			t.eq(#texts, #names, `{label}: structures found`)
			for i, found in texts do
				local back, err, _, used = StructureText.decodeLoose(Template.decode, found)
				t.ok(back ~= nil, `{label} #{i}: {err}`)
				if back then
					t.eq(back.name, names[i], label)
					t.ok(Template.equal(back, if i == 1 then hut else tower), `{label}: the same structure`)
					t.ok(string.sub(used, 1, 5) == "IVS1:", `{label}: the part decoded`)
				end
			end
		end
		-- A paste cut short says so, wrapped or not, words after it or not.
		local cut = string.sub(text, 1, #text - 30)
		for _, message in { cut, wrapAt(cut, 80, "\n") .. "\nsorry it is long", `{cut} thanks` } do
			local texts = StructureText.findTexts(message)
			t.eq(#texts, 1)
			local back, err = StructureText.decodeLoose(Template.decode, texts[1])
			t.eq(back, nil, "a cut paste does not decode")
			t.ok(err and string.find(err, "cut off", 1, true), err)
		end
		t.eq(#StructureText.findTexts("no data here, only IVS words"), 0)
		-- (Linear on long runs of whitespace too.)
		local start = os.clock()
		local padded = StructureText.findTexts(text .. string.rep(" \n", 50000) .. "x")
		t.ok(os.clock() - start < 0.5 and #padded == 1, "a long run of whitespace")
	end)

	t.test("decode: random bytes with a right checksum never raise", function()
		local rng = Hash.rng(1234)
		local accepted = 0
		for _ = 1, 400 do
			local body = {}
			if rng:chance(0.5) then
				body = stoneBody()
				for _ = 1, rng:int(1, 6) do
					body[rng:int(1, #body)] = rng:int(0, 255)
				end
			else
				for _ = 1, rng:int(0, 60) do
					table.insert(body, rng:int(0, 255))
				end
			end
			local ok, back, err = pcall(Template.decode, wrap(body))
			t.ok(ok, `raised: {back}`)
			if back then
				accepted += 1
				t.eq(Template.check(back), nil, "whatever decodes is a valid template")
			else
				t.ok(type(err) == "string", "a message")
			end
		end
		t.ok(accepted > 0, "some mutations still decode")
	end)

	t.test("decode: hand-made bad structures are refused with a reason", function()
		local function refused(body: { number }, pattern: string)
			local back, err = Template.decode(wrap(body))
			t.eq(back, nil, pattern)
			t.ok(err and string.find(err, pattern), `{pattern}: {err}`)
		end
		t.ok(Template.decode(wrap(stoneBody())) ~= nil, "the base case decodes")
		refused(stoneBody("bad name!"), "name")
		refused(stoneBody(""), "name")
		-- Size 0 and beyond the cap.
		local body = {}
		str(body, "test/size")
		varint(body, 0)
		varint(body, 1)
		varint(body, 1)
		refused(body, "size")
		body = {}
		str(body, "test/size")
		varint(body, Template.MAX_SIZE + 1)
		varint(body, 1)
		varint(body, 1)
		refused(body, "size")
		-- Runs that don't cover the box, or overshoot it, or point beyond the palette.
		local function cellsBody(runs: { number }): { number }
			local b = {}
			str(b, "test/runs")
			varint(b, 2)
			varint(b, 1)
			varint(b, 1)
			varint(b, 1)
			str(b, "Stone")
			varint(b, 0)
			for _, v in runs do
				varint(b, v)
			end
			table.insert(b, 0)
			table.insert(b, 0)
			table.insert(b, 0)
			return b
		end
		t.ok(Template.decode(wrap(cellsBody({ 1, 2 }))) ~= nil, "two cells of stone")
		refused(cellsBody({ 1, 3 }), "fill")
		refused(cellsBody({ 1, 0 }), "fill")
		refused(cellsBody({ 2, 2 }), "palette")
		refused(cellsBody({ 1, 1 }), "")
		-- Records outside the box, twice on a cell, with a bad orientation or joint.
		local jigsaw = {}
		local function jigsawRecord(out: { number }, x: number, code: number, joint: number)
			varint(out, x)
			varint(out, 0)
			varint(out, 0)
			table.insert(out, code)
			for _, s in { "a", "b", "c", "Air" } do
				str(out, s)
			end
			table.insert(out, joint)
		end
		varint(jigsaw, 1)
		jigsawRecord(jigsaw, 3, 2 * 6 + 1, 1)
		table.insert(jigsaw, 0)
		table.insert(jigsaw, 0)
		refused(stoneBody(nil, jigsaw), "outside")
		jigsaw = { 1 }
		jigsawRecord(jigsaw, 0, 2 * 6 + 2, 1)
		table.insert(jigsaw, 0)
		table.insert(jigsaw, 0)
		refused(stoneBody(nil, jigsaw), "orientation")
		jigsaw = { 1 }
		jigsawRecord(jigsaw, 0, 2 * 6 + 1, 7)
		table.insert(jigsaw, 0)
		table.insert(jigsaw, 0)
		refused(stoneBody(nil, jigsaw), "joint")
		-- A jigsaw record whose cell is stone: decoded without it, with a warning.
		jigsaw = { 1 }
		jigsawRecord(jigsaw, 0, 2 * 6 + 1, 1)
		table.insert(jigsaw, 0)
		table.insert(jigsaw, 0)
		local back, _, warnings = Template.decode(wrap(stoneBody(nil, jigsaw)))
		t.ok(back and #back.jigsaws == 0 and warnings and #warnings == 1, "a jigsaw not in its cell is left out")
		local markers = { 0, 2 }
		for _ = 1, 2 do
			varint(markers, 0)
			varint(markers, 0)
			varint(markers, 0)
			str(markers, "x")
		end
		table.insert(markers, 0)
		refused(stoneBody(nil, markers), "two data markers")
		local long = { 0, 1, 0, 0, 0 }
		str(long, string.rep("x", Template.MAX_STRING + 1))
		table.insert(long, 0)
		refused(stoneBody(nil, long), "too long")
		local many = { 0, 0 }
		varint(many, Template.MAX_CONTAINERS + 1)
		refused(stoneBody(nil, many), "too many")
		-- Containers: bad slots and stacks.
		local function container(slot: number, count: number): { number }
			local out = { 0, 0, 1, 0, 0, 0, 1 }
			varint(out, slot)
			str(out, "Torch")
			varint(out, count)
			varint(out, 0)
			return out
		end
		t.ok(Template.decode(wrap(stoneBody(nil, container(1, 64)))) ~= nil, "a good stack")
		refused(stoneBody(nil, container(0, 1)), "slot")
		refused(stoneBody(nil, container(1, 65)), "stack")
		-- Something after the records.
		local extra = stoneBody()
		table.insert(extra, 0)
		refused(extra, "understand")
		-- A varint longer than 5 bytes.
		local endless = {}
		str(endless, "test/x")
		for _ = 1, 6 do
			table.insert(endless, 255)
		end
		refused(endless, "too long")
	end)

	t.test("decode: unknown blocks become air and unknown items are left out, with warnings", function()
		local body = {}
		str(body, "test/unknown")
		varint(body, 3)
		varint(body, 1)
		varint(body, 1)
		varint(body, 3)
		str(body, "Stone")
		str(body, "MissingBlock")
		str(body, "MissingBlock2")
		varint(body, 0)
		for _, v in { 1, 1, 2, 1, 3, 1 } do
			varint(body, v)
		end
		varint(body, 0)
		varint(body, 0)
		varint(body, 1)
		for _, v in { 0, 0, 0, 2 } do
			varint(body, v)
		end
		varint(body, 1)
		str(body, "Torch")
		varint(body, 4)
		varint(body, 0)
		varint(body, 2)
		str(body, "NoSuchItem")
		varint(body, 1)
		varint(body, 0)
		local back, err, warnings = Template.decode(wrap(body))
		t.ok(back ~= nil, err)
		assert(back and warnings)
		t.eq(Template.get(back, 0, 0, 0), id.Stone)
		t.eq(Template.get(back, 1, 0, 0), AIR)
		t.eq(Template.get(back, 2, 0, 0), AIR)
		t.eq(#back.palette, 2, "the two unknown blocks merge into one air entry")
		t.eq(#warnings, 3)
		t.eq(#back.containers, 1)
		t.eq(#back.containers[1].items, 1, "the unknown item is left out")
		t.eq(back.containers[1].items[1].item, "Torch")
	end)

	t.test("capture: SAVE rules for voids, structure blocks, jigsaws, cave blocks and containers", function()
		local world: { [string]: number } = {}
		local function put(x: number, y: number, z: number, block: number)
			world[`{x},{y},{z}`] = block
		end
		-- A 4 x 2 x 1 region at (10, 20, 30).
		put(10, 20, 30, id.StructureVoid)
		put(11, 20, 30, id.StructureBlockData)
		put(12, 20, 30, id.StructureBlockCorner)
		put(13, 20, 30, id.JigsawUpEast)
		put(10, 21, 30, Blocks.CAVE_AIR)
		put(11, 21, 30, id.CaveGlowLichenNorth)
		put(12, 21, 30, id.Chest)
		-- (13, 21, 30) is not loaded: air.
		local tpl, warnings = Template.capture({
			name = "test/capture",
			x = 10,
			y = 20,
			z = 30,
			size = { 4, 2, 1 },
			getBlock = function(x, y, z)
				return world[`{x},{y},{z}`]
			end,
			jigsaw = function(x, y, z)
				t.eq(x, 13)
				return { name = "door", target = "street", pool = "village/streets", finalState = "Cobblestone" } :: any
			end,
			marker = function(x, y, z)
				t.eq(x, 11)
				return "chest_loot"
			end,
			container = function(x, y, z)
				t.eq(x, 12)
				return {
					{ slot = 3, item = "Torch", count = 5, damage = 0 },
					{ slot = 3, item = "Stick", count = 1, damage = 0 },
					{ slot = 4, item = "NoSuchItem", count = 1, damage = 0 },
					{ slot = 0, item = "Stick", count = 1, damage = 0 },
				}
			end,
		})
		t.eq(Template.get(tpl, 0, 0, 0), nil, "a structure void is keep")
		t.eq(Template.get(tpl, 1, 0, 0), AIR, "a DATA block is air")
		t.eq(Template.get(tpl, 2, 0, 0), AIR, "other structure blocks are air")
		t.eq(Template.get(tpl, 3, 0, 0), id.JigsawUpEast, "a jigsaw stays")
		t.eq(Template.get(tpl, 0, 1, 0), AIR, "cave air is saved as air")
		t.eq(Template.get(tpl, 1, 1, 0), id.GlowLichenNorth, "a cave twin is saved as its twin")
		t.eq(Template.get(tpl, 2, 1, 0), id.Chest)
		t.eq(Template.get(tpl, 3, 1, 0), AIR, "an unloaded block is air")
		t.eq(#tpl.markers, 1)
		t.eq(tpl.markers[1].data, "chest_loot")
		t.eq(tpl.markers[1].x, 1, "positions are local")
		t.eq(#tpl.jigsaws, 1)
		local j = tpl.jigsaws[1]
		t.eq(j.front, "Up")
		t.eq(j.top, "East")
		t.eq(j.pool, "village/streets")
		t.eq(j.joint, "rollable", "the default joint of a vertical front")
		t.eq(#tpl.containers, 1)
		t.eq(#tpl.containers[1].items, 1, "duplicate slots, unknown items and slot 0 are left out")
		t.eq(#warnings, 1)
		t.eq(Template.check(tpl), nil)
		local back = Template.decode(Template.encode(tpl))
		t.ok(back and Template.equal(tpl, back), "a capture round trips")
		-- Defaults when the callbacks know nothing.
		local plain = Template.capture({
			name = "test/plain",
			x = 0,
			y = 0,
			z = 0,
			size = { 1, 1, 2 },
			getBlock = function(_, _, z)
				return if z == 0 then id.Jigsaw else id.StructureBlockData
			end,
		})
		t.eq(plain.jigsaws[1].name, Settings.EMPTY)
		t.eq(plain.jigsaws[1].joint, "aligned", "the default joint of a horizontal front")
		t.eq(plain.markers[1].data, "")
	end)

	t.test("tables: ASCII layers round trip and explain what is wrong", function()
		local rng = Hash.rng(42)
		for _ = 1, 20 do
			local tpl = randomTemplate(rng, 7, false)
			local data = Template.toTable(tpl)
			t.eq(#data.layers, tpl.size[2])
			local back, err = Template.fromTable(data)
			t.ok(back ~= nil, err)
			t.ok(back and Template.equal(tpl, back), "a table round trips")
		end
		local hut = Template.fromTable({
			name = "test/hut",
			legend = { S = "Stone", P = "Planks" },
			layers = {
				{ "SSS", "SSS" },
				{ "P.P", "P P" },
			},
		})
		assert(hut)
		t.eq(hut.size[1], 3, "the size comes from the layers")
		t.eq(hut.size[2], 2)
		t.eq(hut.size[3], 2)
		t.eq(Template.get(hut, 1, 1, 0), AIR, ". is air")
		t.eq(Template.get(hut, 1, 1, 1), nil, "a space keeps")
		t.eq(Template.get(hut, 0, 1, 1), id.Planks)
		local named = Template.toTable(hut)
		t.eq(named.legend.S, "Stone", "blocks take their initial")
		t.eq(named.legend.P, "Planks")
		local function refused(source: any, pattern: string)
			local back, err = Template.fromTable(source)
			t.eq(back, nil)
			t.ok(err and string.find(err, pattern, 1, true), `{pattern}: {err}`)
		end
		refused({ name = "bad name", layers = { { "S" } }, legend = { S = "Stone" } }, "name")
		refused({ name = "a", layers = { { "SX" } }, legend = { S = "Stone" } }, "'X'")
		refused({ name = "a", layers = { { "S" } }, legend = { S = "Stoen" } }, "Stoen")
		refused({ name = "a", size = { 2, 1, 1 }, layers = { { "S" } }, legend = { S = "Stone" } }, "2 characters")
		refused({
			name = "a",
			layers = { { "S" } },
			legend = { S = "Stone" },
			jigsaws = { { x = 0, y = 0, z = 0, front = "North", top = "Up" } },
		}, "not in its cell")
		refused(42, "table")
	end)

	t.test("check: encode refuses templates that break the format's rules", function()
		local tpl = Template.new("test/check", { 2, 1, 1 })
		Template.set(tpl, 0, 0, 0, id.Jigsaw)
		table.insert(tpl.jigsaws, {
			x = 0,
			y = 0,
			z = 0,
			front = "North",
			top = "Up",
			name = "a",
			target = "b",
			pool = "c",
			finalState = "Air",
			joint = "aligned",
		})
		t.eq(Template.check(tpl), nil)
		tpl.jigsaws[1].joint = "loose"
		t.ok(Template.check(tpl) ~= nil, "a bad joint")
		t.ok(not pcall(Template.encode, tpl), "encode refuses it")
		tpl.jigsaws[1].joint = "aligned"
		tpl.jigsaws[1].front = "Up"
		t.ok(Template.check(tpl) ~= nil, "a bad orientation")
		tpl.jigsaws[1].front = "North"
		table.insert(tpl.markers, { x = 5, y = 0, z = 0, data = "" })
		t.ok(Template.check(tpl) ~= nil, "outside")
		tpl.markers = {}
		tpl.name = "Bad Name"
		t.ok(Template.check(tpl) ~= nil, "a bad name")
	end)

	t.test("lengths: typical structures as text, and a 48^3 worst case under a StringValue's limit", function()
		-- A 7 x 5 x 7 hut: a cobblestone floor, log walls with a door and windows, a plank roof,
		-- a chest and a torch.
		local hut = Template.new("village/houses/hut", { 7, 5, 7 })
		local function corner(x: number, z: number): boolean
			return (x == 0 or x == 6) and (z == 0 or z == 6)
		end
		for y = 0, 4 do
			for z = 0, 6 do
				for x = 0, 6 do
					local edge = x == 0 or x == 6 or z == 0 or z == 6
					local block = if y == 0
						then id.Cobblestone
						elseif y == 4 then id.Planks
						elseif corner(x, z) then id.OakLog
						elseif edge then id.Planks
						else AIR
					Template.set(hut, x, y, z, block)
				end
			end
		end
		Template.set(hut, 3, 1, 0, AIR)
		Template.set(hut, 3, 2, 0, AIR)
		Template.set(hut, 0, 2, 3, id.Glass)
		Template.set(hut, 6, 2, 3, id.Glass)
		Template.set(hut, 1, 1, 5, id.Chest)
		Template.set(hut, 5, 3, 5, id.WallTorchNorth)
		local hutText = Template.encode(hut)

		-- A 16 x 10 x 16 house: two floors, stone brick walls with windows every few blocks, a
		-- stepped roof of planks, a few rooms' furniture.
		local house = Template.new("village/houses/big_house", { 16, 10, 16 })
		for y = 0, 9 do
			for z = 0, 15 do
				for x = 0, 15 do
					local edge = x == 0 or x == 15 or z == 0 or z == 15
					local block = AIR
					if y == 0 or y == 4 then
						block = if edge then id.StoneBricks else id.SprucePlanks
					elseif y < 8 and edge then
						block = if y % 4 == 2 and (x + z) % 4 == 1 then id.Glass else id.StoneBricks
					elseif y >= 8 then
						local inset = y - 8
						if x >= inset and x <= 15 - inset and z >= inset and z <= 15 - inset then
							block = if x == inset or x == 15 - inset then id.SprucePlanks else id.Planks
						end
					end
					Template.set(house, x, y, z, block)
				end
			end
		end
		for _, p in { { 3, 1, 3 }, { 12, 1, 12 }, { 3, 5, 12 }, { 12, 5, 3 } } do
			Template.set(house, p[1], p[2], p[3], id.Chest)
		end
		Template.set(house, 8, 1, 8, id.CraftingTable)
		Template.set(house, 9, 1, 8, id.Furnace)
		local houseText = Template.encode(house)

		-- 48 x 48 x 48 of noise over 100 kinds of blocks: no runs at all.
		local rng = Hash.rng(48)
		local worst = Template.new("test/worst", { 48, 48, 48 })
		local kinds = {}
		for block = 0, Blocks.count - 1 do
			if #kinds < 100 and Blocks.get(block).jigsaw == nil then
				table.insert(kinds, block)
			end
		end
		for y = 0, 47 do
			for z = 0, 47 do
				for x = 0, 47 do
					Template.set(worst, x, y, z, kinds[rng:int(1, #kinds)])
				end
			end
		end
		local started = os.clock()
		local worstText = Template.encode(worst)
		local encodeMs = (os.clock() - started) * 1000
		started = os.clock()
		local back = Template.decode(worstText)
		local decodeMs = (os.clock() - started) * 1000
		t.ok(back and Template.equal(worst, back), "the worst case round trips")
		local timing = `encode {math.floor(encodeMs)} ms, decode {math.floor(decodeMs)} ms`
		print(`    lengths: 7x5x7 hut {#hutText}, 16x10x16 house {#houseText}, 48^3 noise {#worstText} ({timing})`)
		t.ok(#hutText < 400, `hut: {#hutText}`)
		t.ok(#houseText < 2000, `house: {#houseText}`)
		t.ok(#worstText < 200000, `worst case: {#worstText}`)
	end)
	t.test("renamed blocks and items: saved Glowstone data loads as the Glow Block and Glow Dust", function()
		local Items = require(shared.Items)
		local Jigsaw = require(shared.Structures.Jigsaw)
		t.eq(Blocks.find("Glowstone"), id.GlowBlock)
		t.eq(Blocks.find("GlowBlock"), id.GlowBlock)
		t.eq(Items.find("GlowstoneDust"), Items.id.GlowDust)
		t.eq(Items.find("Glowstone"), Items.id.GlowBlock)
		t.eq(Items.find("NoSuchItem"), nil)
		t.eq(Jigsaw.finalStateBlock("minecraft:glowstone"), id.GlowBlock)
		-- Data saved before the rename: the same bytes with "Glowstone" for "GlowBlock" (as long),
		-- in the palette and in a chest, checksum made again.
		local tpl = Template.new("renamed/test", { 2, 1, 1 })
		Template.set(tpl, 0, 0, 0, id.GlowBlock)
		Template.set(tpl, 1, 0, 0, id.Chest)
		tpl.containers =
			{ { x = 1, y = 0, z = 0, items = { { slot = 1, item = "GlowBlock", count = 3, damage = 0 } } } }
		local text = Template.encode(tpl)
		local payload = Template.unbase64(string.sub(text, #Template.PREFIX + 1))
		assert(payload)
		local old = string.gsub(buffer.tostring(payload), "GlowBlock", "Glowstone")
		local b = buffer.fromstring(old)
		buffer.writeu32(b, buffer.len(b) - 4, Template.crc32(b, 0, buffer.len(b) - 4))
		local decoded, err = Template.decode(Template.PREFIX .. Template.base64(b))
		assert(decoded, err)
		t.eq(Template.get(decoded, 0, 0, 0), id.GlowBlock, "the block")
		t.eq(decoded.containers[1].items[1].item, "GlowBlock", "the chest's item, by its new name")
	end)
end
