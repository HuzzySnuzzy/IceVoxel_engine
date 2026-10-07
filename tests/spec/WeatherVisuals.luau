--[[
	The weather's looks, the pure parts (client Weather/ and Map/WeatherMap): rain and snow around
	the camera (Precipitation: Minecraft's columns, spans, alpha, roofs from chunk data, the column
	cache and edits, tickRain's sounds), the cloud rings (CloudLod: levels, windows and holes
	tiling the view once, the pattern's calibration, merging, diffs, looks, and the part counts and
	planning cost on a real seed), lightning (LightningBolt: Minecraft's shape and timing), the
	light (WeatherSky), the maps' weather mode (WeatherMap: colours, grids, the forecast cache and
	forecasts as the field later, the wind, a picture painted in bands as one and its cost), and
	the settings, key binding and sounds they add (the sounds appended at the list's end).
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Config = require(shared.Config)
	local DayCycle = require(shared.DayCycle)
	local KeyBindings = require(shared.KeyBindings)
	local PlayerSettings = require(shared.PlayerSettings)
	local Sounds = require(shared.Sounds)
	local SoundList = require(shared.Sounds.SoundList)
	local Weather = require(shared.Weather)
	local Precipitation = require(client.Weather.Precipitation)
	local CloudLod = require(client.Weather.CloudLod)
	local LightningBolt = require(client.Weather.LightningBolt)
	local WeatherSky = require(client.Weather.WeatherSky)
	local WeatherMap = require(client.Map.WeatherMap)
	local Pages = require(client.Settings.Pages)

	local B = Blocks.id
	local SEED = 12345

	-- A deterministic nextInt(n) (a small LCG).
	local function lcg(seed: number): (n: number) -> number
		local state = seed
		return function(n: number): number
			state = (state * 1103515245 + 12345) % 2147483648
			return (state // 65536) % n
		end
	end

	--[[ Precipitation ]]

	t.test("weather visuals: Minecraft's columns, nearest first, fading to the disc's edge", function()
		for _, radius in { 5, 10 } do
			local columns = Precipitation.columns(radius)
			local count = 0
			for dx = -radius, radius do
				for dz = -radius, radius do
					if dx * dx + dz * dz < radius * radius then
						count += 1
					end
				end
			end
			t.eq(#columns, count, `columns within {radius}`)
			t.eq(columns[1].dx, 0)
			t.eq(columns[1].dz, 0)
			t.eq(columns[1].edge, 1, "full alpha over the camera")
			local last = 0
			for _, column in columns do
				local d2 = column.dx * column.dx + column.dz * column.dz
				t.ok(d2 >= last, "nearest first")
				last = d2
				t.ok(column.edge > 0.5 and column.edge <= 1, "Minecraft's alpha (1 - d^2/r^2) x 0.5 + 0.5")
			end
		end
		t.eq(#Precipitation.columns(5), 69, "Fast: 69 strips")
		t.eq(#Precipitation.columns(10), 305, "Fancy: 305 strips")
		-- Alpha steps.
		t.eq(Precipitation.level(0.01, 1), 0, "nothing below VISIBLE")
		t.eq(Precipitation.level(1, 1), Precipitation.LEVELS)
		t.eq(Precipitation.level(1, 0.5), Precipitation.LEVELS / 2)
		t.eq(Precipitation.level(0.5, 0.5), 4)
	end)

	t.test("weather visuals: a column draws between the camera's reach and its roof (k2 / l2)", function()
		-- Open ground below the camera's reach: the whole span.
		local bottom, top = Precipitation.span(60, 80, 10)
		t.eq(bottom, 70)
		t.eq(top, 90)
		-- Ground within reach: from the ground up.
		bottom, top = Precipitation.span(75, 80, 10)
		t.eq(bottom, 75)
		t.eq(top, 90)
		-- A roof over the camera: nothing (no rain indoors).
		bottom, top = Precipitation.span(85, 80, 10)
		t.eq(bottom, 85)
		t.eq(top, 90, "rain above a roof still within reach shows on it")
		bottom = Precipitation.span(95, 80, 10)
		t.eq(bottom, nil, "a roof above the reach: nothing")
		bottom = Precipitation.span(90, 80, 10)
		t.eq(bottom, nil, "a roof at the reach: nothing")
	end)

	t.test("weather visuals: roofs come from chunk data; leaves, glass and water stop rain, torches don't", function()
		local height = 40
		local data = ChunkLayout.create(height)
		local lut = Precipitation.stops()
		local function set(lx: number, y: number, lz: number, block: number)
			ChunkLayout.set(data, lx, y, lz, block)
		end
		for lx = 0, 15 do
			for lz = 0, 15 do
				set(lx, 0, lz, B.Stone)
				set(lx, 1, lz, B.Stone)
			end
		end
		t.eq(Precipitation.floorOf(data, height, 3, 3, lut), 2, "on the ground")
		set(4, 20, 4, B.OakLeaves)
		t.eq(Precipitation.floorOf(data, height, 4, 4, lut), 21, "leaves shelter")
		set(5, 30, 5, B.Glass)
		t.eq(Precipitation.floorOf(data, height, 5, 5, lut), 31, "glass shelters")
		set(6, 10, 6, B.Torch)
		t.eq(Precipitation.floorOf(data, height, 6, 6, lut), 2, "a torch doesn't")
		set(7, 2, 7, B.Water)
		t.eq(Precipitation.floorOf(data, height, 7, 7, lut), 3, "rain lands on water")
		local empty = ChunkLayout.create(8)
		t.eq(Precipitation.floorOf(empty, 8, 0, 0, lut), 0, "nothing: the void")
		-- Every block's rule is Weather.blocksRain's.
		for id = 0, Blocks.count - 1 do
			t.eq(buffer.readu8(lut, id) == 1, Weather.blocksRain(id), `block {id}`)
		end
	end)

	t.test("weather visuals: the column cache follows edits and chunks", function()
		for _, column in { { 0, 0 }, { -5, 7 }, { 123456, -654321 }, { -1, -1 }, { 30000000, 30000000 } } do
			local x, z = Precipitation.unkey(Precipitation.key(column[1], column[2]))
			t.eq(x, column[1], "a key's column")
			t.eq(z, column[2])
		end
		local cache = Precipitation.newCache(100)
		Precipitation.store(cache, 3, 5, 64, 0.8)
		t.eq((Precipitation.cached(cache, 3, 5) :: any).floor, 64)
		t.ok(Precipitation.edited(cache, 3, 70, 5, B.Stone), "a roof built")
		t.eq((Precipitation.cached(cache, 3, 5) :: any).floor, 71, "raised")
		t.ok(not Precipitation.edited(cache, 3, 60, 5, B.Stone), "below the floor: nothing")
		t.ok(not Precipitation.edited(cache, 3, 75, 5, B.Torch), "a torch: nothing")
		t.ok(Precipitation.edited(cache, 3, 70, 5, Blocks.AIR), "the roof broken")
		t.eq(Precipitation.cached(cache, 3, 5), nil, "scanned again")
		t.ok(not Precipitation.edited(cache, 9, 70, 9, B.Stone), "unknown columns stay unknown")
		-- A chunk loaded again drops its columns, not its neighbours'.
		Precipitation.store(cache, 17, 2, 64, nil)
		Precipitation.store(cache, 31, 15, 64, nil)
		Precipitation.store(cache, 32, 15, 64, nil)
		Precipitation.dropChunk(cache, 1, 0)
		t.eq(Precipitation.cached(cache, 17, 2), nil)
		t.eq(Precipitation.cached(cache, 31, 15), nil)
		t.ok(Precipitation.cached(cache, 32, 15) ~= nil, "the next chunk's stays")
		t.eq(cache.count, 1)
		-- Full: starts over.
		for i = 1, 150 do
			Precipitation.store(cache, i, 1000, 1, nil)
		end
		t.ok(cache.count <= 100, "bounded")
	end)

	t.test("weather visuals: tickRain's sound: where rain lands near, every 2-3 ticks, above when roofed", function()
		local state = Precipitation.newSound()
		local nextInt = lcg(7)
		local plays, above = 0, 0
		local flat = function(_x: number, _z: number): (number?, boolean)
			return 64, true
		end
		for _ = 1, 2000 do
			local name, _x, y = Precipitation.rainSound(state, 0, 64, 0, 0, 1, flat, nextInt)
			if name then
				plays += 1
				t.eq(y, 63, "on the block the rain lands on")
				t.eq(name, "weather.rain")
			end
		end
		-- (Minecraft: nextInt(3) < ticks since the last: on average every 2.4 or so ticks.)
		t.ok(plays > 2000 / 3.2 and plays < 2000 / 1.8, `about every 2-3 ticks ({plays})`)
		-- Snow or nothing: silent.
		local snowy = function(_x: number, _z: number): (number?, boolean)
			return 64, false
		end
		for _ = 1, 200 do
			t.eq(Precipitation.rainSound(state, 0, 64, 0, 0, 1, snowy, nextInt), nil)
		end
		-- Under a roof (rain landing 5 above, the camera's column roofed): the muffled one.
		local roofed = function(_x: number, _z: number): (number?, boolean)
			return 70, true
		end
		for _ = 1, 200 do
			local name = Precipitation.rainSound(state, 0, 64, 0, 70, 1, roofed, nextInt)
			if name then
				above += 1
				t.eq(name, "weather.rain.above")
			end
		end
		t.ok(above > 0, "heard on the roof")
		-- Too far below or above the camera: nothing.
		local deep = function(_x: number, _z: number): (number?, boolean)
			return 30, true
		end
		for _ = 1, 100 do
			t.eq(Precipitation.rainSound(state, 0, 64, 0, 0, 1, deep, nextInt), nil)
		end
		t.eq(Precipitation.rainSound(state, 0, 64, 0, 0, 0, flat, nextInt), nil, "no rain, no sound")
		-- Drizzle tries fewer columns (100 x level^2): an unknown cache answers nothing.
		local unknown = function(_x: number, _z: number): (number?, boolean)
			return nil, false
		end
		t.eq(Precipitation.rainSound(state, 0, 64, 0, 0, 0.5, unknown, nextInt), nil)
	end)

	--[[ Clouds ]]

	local function settings(mode: number, view: number)
		return CloudLod.settings(mode, view)
	end

	t.test("weather visuals: cloud rings reach the view distance and tile it once", function()
		local fancy = settings(CloudLod.FANCY, 2048)
		t.eq(fancy.cells % 4, 0, "cells across a ring: a multiple of 4")
		t.eq(CloudLod.levels(fancy), 5, "16-block cells, 24 across: 192, 384, 768, 1536, 3072")
		t.eq(CloudLod.levels(settings(CloudLod.FAST, 512)), 2, "phones: two Fast rings of 32 and 64-block cells")
		t.eq(CloudLod.levels(settings(CloudLod.FANCY, 4096)), 6)
		local nextInt = lcg(3)
		for _, camera in { { 0, 0 }, { 1234.5, -987.25 }, { -40000.3, 77777.7 } } do
			local cu, cw = camera[1], camera[2]
			local levels = CloudLod.levels(fancy)
			local windows = {}
			for level = 0, levels - 1 do
				local window = CloudLod.window(fancy, level, cu, cw)
				windows[level] = window
				t.eq(window.size, fancy.cell * 2 ^ level)
				t.eq(window.u0 % window.size, 0, "on its cells")
				local hole = window.hole
				if level == 0 then
					t.eq(hole, nil)
				else
					t.ok(hole ~= nil, "a hole for the finer ring")
					local h = hole :: any
					t.eq((h.u0 - window.u0) % window.size, 0, "the hole on this ring's cell edges")
					t.ok(h.u0 >= window.u0 and h.u1 <= window.u0 + window.cols * window.size, "inside")
					t.ok(h.w0 >= window.w0 and h.w1 <= window.w0 + window.cols * window.size, "inside")
					local inner = CloudLod.window(fancy, level - 1, cu, cw)
					t.eq(h.u0, inner.u0, "the hole is the finer ring's window")
					t.eq(h.w1, inner.w0 + inner.cols * inner.size)
				end
			end
			-- Every point within the view: in exactly one ring (inside its window, outside its hole).
			for _ = 1, 400 do
				local angle = nextInt(3600) / 3600 * math.pi * 2
				local distance = nextInt(2040)
				local u, w = cu + math.cos(angle) * distance, cw + math.sin(angle) * distance
				local owners = 0
				for level = 0, levels - 1 do
					local window = windows[level]
					local span = window.cols * window.size
					local inside = u >= window.u0 and u < window.u0 + span and w >= window.w0 and w < window.w0 + span
					local hole = window.hole
					if inside and hole and u >= hole.u0 and u < hole.u1 and w >= hole.w0 and w < hole.w1 then
						inside = false
					end
					if inside then
						owners += 1
					end
				end
				t.eq(owners, 1, `({u}, {w}) in one ring`)
			end
		end
	end)

	t.test("weather visuals: the cloud pattern is about uniform, so cover is the share clouded", function()
		-- math.noise's spread, which the logistic assumes.
		local nextInt = lcg(11)
		local sum, sum2, n = 0, 0, 4000
		for _ = 1, n do
			local value = math.noise(nextInt(100000) / 97.3 + 0.31, nextInt(100000) / 89.1 + 0.67, 0.5)
			sum += value
			sum2 += value * value
		end
		local spread = math.sqrt(sum2 / n - (sum / n) ^ 2)
		t.near(spread, CloudLod.SPREAD, 0.02, `math.noise's spread {spread}`)
		local fancy = settings(CloudLod.FANCY, 2048)
		local pattern = CloudLod.pattern(SEED)
		for _, cover in { 0, 0.3, 0.6, 1 } do
			local clouded, total = 0, 0
			for i = 0, 119 do
				for j = 0, 119 do
					total += 1
					if CloudLod.cloudy(pattern, fancy, i * 16 + 8 - 960, j * 16 + 8 + 4000, 16, cover) then
						clouded += 1
					end
				end
			end
			local share = clouded / total
			local want = CloudLod.fraction(fancy, cover)
			t.near(share, want, 0.1, `cover {cover}: {share} clouded, {want} wanted`)
		end
		t.eq(CloudLod.fraction(fancy, 0), Config.Weather.Clouds.CoverBase, "fair weather keeps some")
		t.eq(CloudLod.fraction(fancy, 1), 1, "overcast")
	end)

	t.test("weather visuals: cloud looks: white fair weather, grey rain, dark towering thunder", function()
		t.eq(CloudLod.shadeOf(0, 0), 1, "white")
		t.eq(CloudLod.shadeOf(1, 1), CloudLod.SHADES, "darkest")
		local last = 1
		for i = 0, 10 do
			local shade = CloudLod.shadeOf(i / 10, 0)
			t.ok(shade >= last, "darker with rain")
			last = shade
		end
		t.ok(CloudLod.shadeOf(1, 0) < CloudLod.shadeOf(1, 1), "thunder darker than rain")
		t.eq(CloudLod.grey(1), 1)
		t.near(CloudLod.grey(CloudLod.SHADES), CloudLod.DARKEST, 1e-9)
		local fancy = settings(CloudLod.FANCY, 2048)
		local base, top = CloudLod.heights(fancy, 0, 0)
		t.eq(base, fancy.altitude)
		t.near(top, fancy.altitude + fancy.thickness, fancy.step / 2, "Minecraft-thin fair-weather clouds")
		local rainBase, rainTop = CloudLod.heights(fancy, 1, 0)
		t.eq(rainBase, fancy.altitude - fancy.drop, "rain clouds hang lower")
		t.ok(rainTop - rainBase > top - base, "and thicker")
		local _, stormTop = CloudLod.heights(fancy, 1, 1)
		t.near(stormTop - rainTop, fancy.tower, fancy.step, "thunderstorms tower")
		for _, value in { base, top, rainBase, rainTop, stormTop } do
			t.eq(value % fancy.step, 0, "on the height steps")
		end
		local fast = settings(CloudLod.FAST, 512)
		local fb, ft = CloudLod.heights(fast, 1, 1)
		t.eq(fb, fast.altitude, "Fast: one flat layer")
		t.eq(ft - fb, 1)
	end)

	t.test("weather visuals: merging covers every cloudy cell once with its own look", function()
		local nextInt = lcg(5)
		for _ = 1, 30 do
			local cols, rows = 1 + nextInt(20), 1 + nextInt(20)
			local codes = table.create(cols * rows, 0)
			for i = 1, cols * rows do
				-- Clumpy: copy a neighbour often.
				if i > 1 and nextInt(3) > 0 then
					codes[i] = codes[i - 1]
				else
					codes[i] = nextInt(4)
				end
			end
			local covered = table.create(cols * rows, 0)
			local boxes = 0
			CloudLod.merge(codes, cols, rows, function(col, row, width, height, code)
				boxes += 1
				t.ok(code ~= 0, "only clouds")
				t.ok(col + width <= cols and row + height <= rows, "inside")
				for r = row, row + height - 1 do
					for c = col, col + width - 1 do
						local i = r * cols + c + 1
						t.eq(codes[i], code, "one look a box")
						covered[i] += 1
					end
				end
			end)
			local cells = 0
			for i = 1, cols * rows do
				t.eq(covered[i], if codes[i] == 0 then 0 else 1, "each cloudy cell once")
				if codes[i] ~= 0 then
					cells += 1
				end
			end
			t.ok(boxes <= cells, "never more boxes than cells")
		end
		-- An overcast block merges into one box; at most `maxSpan` cells a side, into four.
		local full = table.create(64, 3)
		local count = 0
		CloudLod.merge(full, 8, 8, function()
			count += 1
		end)
		t.eq(count, 1)
		count = 0
		CloudLod.merge(full, 8, 8, function(_, _, width, height)
			count += 1
			t.ok(width <= 4 and height <= 4)
		end, 4)
		t.eq(count, 4)
	end)

	-- Plans every ring for a camera at world (x, z) at weather clock `clock` (no override).
	local field = Weather.new(SEED)
	local function planAll(s, x: number, z: number, clock: number): ({ { CloudLod.Box } }, number)
		local dx, dz = field:displacement(clock)
		local pattern = CloudLod.pattern(SEED)
		local sample = function(u0: number, w0: number, step: number, cols: number, rows: number): buffer
			return field:grid(clock, u0 + dx, w0 + dz, step, cols, rows)
		end
		local levels = {}
		local started = os.clock()
		for level = 0, CloudLod.levels(s) - 1 do
			levels[level + 1] = CloudLod.plan(s, pattern, level, x - dx, z - dz, sample)
		end
		return levels, os.clock() - started
	end

	t.test(
		"weather visuals: cloud plans: boxes inside their rings, storms dark and shafted, diffs keep parts",
		function()
			local fancy = settings(CloudLod.FANCY, 2048)
			-- Find a stormy moment over the spawn (the model is deterministic).
			local clock = -1
			for c = 0, 8000000, 400 do
				local p, th = field:at(0, 0, c)
				if p > 0.8 and th > 0.3 then
					clock = c
					break
				end
			end
			t.ok(clock >= 0, "a thunderstorm over the spawn")
			local levels = planAll(fancy, 0, 0, clock)
			local dx, dz = field:displacement(clock)
			local shafts, dark = 0, 0
			for index, boxes in levels do
				local window = CloudLod.window(fancy, index - 1, -dx, -dz)
				local keys = {}
				for _, box in boxes do
					t.ok(keys[box.key] == nil, "keys are unique")
					keys[box.key] = true
					t.ok(box.x0 >= window.u0 and box.x1 <= window.u0 + window.cols * window.size, "in its window")
					t.eq((box.x1 - box.x0) % window.size, 0, "whole cells")
					t.ok(box.x1 - box.x0 <= fancy.maxPart and box.z1 - box.z0 <= fancy.maxPart, "a part's size at most")
					if box.shaft then
						shafts += 1
						t.ok(index - 1 >= fancy.shaftLevel, "shafts only in far rings")
					else
						t.ok(box.top > box.base, "a cloud has height")
						if box.shade >= 3 then
							dark += 1
						end
					end
				end
			end
			t.ok(dark > 0, "the storm's clouds are dark")
			t.ok(shafts > 0, "rain shows from afar as shafts")
			-- The same plan again: nothing to add or remove; a moved camera: only what changed.
			local live = {}
			for _, box in levels[2] do
				live[box.key] = true
			end
			local added, removed = CloudLod.diff(live, levels[2])
			t.eq(#added, 0)
			t.eq(#removed, 0)
			local later = planAll(fancy, 0, 0, clock + 20 * 30)
			added, removed = CloudLod.diff(live, later[2])
			t.ok(#added < #later[2], `30 s later most boxes stay ({#added} new of {#later[2]})`)
			t.ok(#removed <= #levels[2])
		end
	)

	t.test(
		"weather visuals: cloud part counts and planning cost (seed 12345, view 2048 Fancy, phones 512 Fast)",
		function()
			local cases = {
				{ "Fancy 4096 (Ultra)", settings(CloudLod.FANCY, 4096), 600 },
				{ "Fancy 2048", settings(CloudLod.FANCY, 2048), 500 },
				{ "Fancy 1024", settings(CloudLod.FANCY, 1024), 350 },
				{ "Fast 2048", settings(CloudLod.FAST, 2048), 160 },
				{ "Fast 512 (phones)", settings(CloudLod.FAST, 512), 80 },
			}
			for _, case in cases do
				local name, s, budget = case[1], case[2], case[3]
				local worst, total, samples, slowest, shaftsMost = 0, 0, 0, 0, 0
				local perLevel = {}
				-- Every 25 minutes of weather over 2 in-game days, at the spawn and 3 km out.
				for c = 0, 2 * 24000 * 2, 30000 do
					for _, place in { { 0, 0 }, { 3000, -2000 } } do
						local levels, seconds = planAll(s, place[1], place[2], c)
						local count, shafts = 0, 0
						for index, boxes in levels do
							count += #boxes
							perLevel[index] = math.max(perLevel[index] or 0, #boxes)
							for _, box in boxes do
								if box.shaft then
									shafts += 1
								end
							end
						end
						worst = math.max(worst, count)
						shaftsMost = math.max(shaftsMost, shafts)
						total += count
						samples += 1
						slowest = math.max(slowest, seconds / #levels)
					end
				end
				print(
					string.format(
						"  clouds %-18s parts mean %d, most %d (shafts at most %d; per ring at most %s), plan %.2f ms a ring at most",
						name,
						total // samples,
						worst,
						shaftsMost,
						table.concat(perLevel, "/"),
						slowest * 1000
					)
				)
				t.ok(worst <= budget, `{name}: at most {budget} parts ({worst})`)
			end
		end
	)

	--[[ Lightning ]]

	t.test("weather visuals: lightning's shape is Minecraft's: 128 blocks, zigzags, two branches", function()
		for seed = 1, 40 do
			local segments = LightningBolt.segments(seed * 7919)
			t.eq(#segments, 8 + 3 + 3, "8 main sections, branches of 3")
			local main, branches = 0, 0
			local bottom, top
			for _, segment in segments do
				t.eq(segment.y1 - segment.y0, LightningBolt.SECTION)
				if segment.branch then
					branches += 1
					t.ok(math.abs(segment.x1 - segment.x0) <= 15 and math.abs(segment.z1 - segment.z0) <= 15)
				else
					main += 1
					t.ok(math.abs(segment.x1 - segment.x0) <= 5 and math.abs(segment.z1 - segment.z0) <= 5)
					if segment.y0 == 0 then
						bottom = segment
					end
					if segment.y1 == LightningBolt.HEIGHT then
						top = segment
					end
				end
			end
			t.eq(main, 8)
			t.eq(branches, 6)
			t.ok(bottom ~= nil and top ~= nil)
			t.eq((bottom :: any).x0, 0, "it ends on the struck point")
			t.eq((bottom :: any).z0, 0)
			-- Main sections join up; branches leave from the main bolt.
			local joints = {}
			for _, segment in segments do
				if not segment.branch then
					joints[`{segment.x1}:{segment.y1}:{segment.z1}`] = true
				end
			end
			for _, segment in segments do
				if segment.branch and segment.y1 == segment.y0 + LightningBolt.SECTION then
					-- (The first section of each branch starts at a joint of the main bolt.)
					local starts = joints[`{segment.x1}:{segment.y1}:{segment.z1}`]
					if
						segment.y1 == (LightningBolt.SECTIONS - 1) * LightningBolt.SECTION
						or segment.y1 == (LightningBolt.SECTIONS - 2) * LightningBolt.SECTION
					then
						local first = true
						for _, other in segments do
							if other.branch and other.y0 == segment.y1 and other ~= segment then
								first = false
							end
						end
						if first then
							t.ok(starts, "a branch leaves the main bolt")
						end
					end
				end
			end
		end
		-- Deterministic.
		local a, b = LightningBolt.segments(99), LightningBolt.segments(99)
		for i, segment in a do
			t.eq(segment.x0, b[i].x0)
			t.eq(segment.z1, b[i].z1)
		end
	end)

	t.test("weather visuals: lightning's timing: 1 + flashes shapes, the sky flashing while life >= 0", function()
		for seed = 1, 60 do
			for flashes = 1, 3 do
				local phases, finish = LightningBolt.timeline(seed, flashes)
				t.eq(#phases, 1 + flashes, "the first, then a new shape each flash")
				t.ok(finish > phases[#phases].start and finish <= 3 + flashes * 12, `gone after {finish} ticks`)
				local phase, flashing = LightningBolt.at(phases, finish, 0)
				t.eq(phase, phases[1])
				t.ok(flashing, "the sky flashes at once")
				t.eq(LightningBolt.at(phases, finish, finish), nil, "gone")
				for i = 2, #phases do
					t.ok(phases[i].start > phases[i - 1].start, "in order")
					local shown, again = LightningBolt.at(phases, finish, phases[i].start)
					t.eq(shown, phases[i])
					t.ok(again, "flashes again")
				end
			end
		end
	end)

	--[[ Light ]]

	t.test("weather visuals: rain and thunder dim the sky's light, not the caves'; grading fades indoors", function()
		local function environment()
			return DayCycle.environment(6000, 1)
		end
		local clear = WeatherSky.apply(environment(), 0, 0, 0, 1)
		local base = environment()
		t.eq(clear.brightness, base.brightness, "clear: unchanged")
		local storm = WeatherSky.apply(environment(), 1, 1, 1, 1)
		local dim = Weather.dimming(1, 1)
		t.near(storm.outdoorAmbient[1], base.outdoorAmbient[1] * dim, 1e-6, "Minecraft's darkening")
		t.ok(storm.brightness <= base.brightness * dim + 1e-9, "the sun dims at least as much")
		t.eq(storm.ambient[1], base.ambient[1], "caves keep their light")
		t.ok(storm.fogColor[1] < base.fogColor[1], "darker fog")
		local cave = WeatherSky.apply(environment(), 1, 1, 1, 0)
		t.eq(cave.brightness, base.brightness, "no sky, no change")
		local overcast = WeatherSky.apply(environment(), 0, 0, 1, 1)
		t.near(overcast.brightness, base.brightness * (1 - Config.Weather.Sky.CoverSun), 1e-6, "cover hides the sun")
		t.eq(overcast.outdoorAmbient[1], base.outdoorAmbient[1], "but not the sky's light")
		local saturation, contrast, tint = WeatherSky.grading(1, 1, 1)
		t.ok(saturation < 0 and contrast < 0, "greyer and flatter")
		t.ok(tint[3] >= tint[1], "cooler")
		saturation, contrast, tint = WeatherSky.grading(1, 1, 0)
		t.eq(saturation, 0)
		t.eq(contrast, 0)
		t.eq(tint[1], 1)
		t.near(WeatherSky.fog(1, 0, false, 1), Config.Weather.Fog.Rain, 1e-9)
		t.near(WeatherSky.fog(1, 0, true, 1), Config.Weather.Fog.Snow, 1e-9)
		t.eq(WeatherSky.fog(1, 1, false, 0), 1, "no sky, no weather fog")
	end)

	--[[ Maps ]]

	t.test("weather visuals: map colours: clear shows the terrain, rain blue, snow white, storms purple", function()
		local _, _, _, a = WeatherMap.colour(0, 0, 0, Weather.RAIN, 0.5)
		t.eq(a, 0, "clear: see-through")
		local cr, cg, cb, ca = WeatherMap.colour(0, 0, 0.8, Weather.RAIN, 0.5)
		t.ok(ca > 0 and ca < 128, "clouds: a light veil")
		t.ok(math.abs(cr - cb) < 40 and cg > 150, "grey")
		local r, g, b, ra = WeatherMap.colour(0.9, 0, 1, Weather.RAIN, 0.5)
		t.ok(b > r + 80 and b > g, "rain is blue")
		t.ok(ra > ca, "stronger than clouds")
		local sr, sg, sb = WeatherMap.colour(0.9, 0, 1, Weather.SNOW, 0.5)
		t.ok(sr > 220 and sg > 220 and sb > 220, "snow is white")
		local dr, dg, db, da = WeatherMap.colour(0.9, 0, 1, Weather.NONE, 0.5)
		t.eq(dr, cr + 0 * dr)
		t.ok(da <= 128 and dg == cg, "a dry biome: only the clouds")
		local _ = db
		local tr, tg, tb = WeatherMap.colour(1, 1, 1, Weather.RAIN, 0.9)
		t.ok(tr > tg and tb > tg, "thunder is purple")
		local lr, lg, lb = WeatherMap.colour(1, 1, 1, Weather.RAIN, 0.01)
		t.ok(lr > 200 and lg > 180 and lb < 120, "lightning speckles are yellow")
		-- A painted grid: one pixel a cell, RGBA.
		local samples = buffer.create(2 * 3)
		buffer.writeu8(samples, 0, 230)
		buffer.writeu8(samples, 2, 255)
		local pixels = WeatherMap.paint(samples, 0, 0, 16, 2, 1, function()
			return Weather.SNOW
		end)
		t.eq(buffer.len(pixels), 8)
		t.ok(buffer.readu8(pixels, 0) > 220 and buffer.readu8(pixels, 3) > 128, "snowing cell")
		t.eq(buffer.readu8(pixels, 7), 0, "clear cell")
	end)

	t.test("weather visuals: a map picture painted in bands is the picture painted at once; its cost", function()
		-- A thunderstorm over the spawn (the field above).
		local clock = -1
		for c = 0, 8000000, 400 do
			local p, th = field:at(0, 0, c)
			if p > 0.8 and th > 0.3 then
				clock = c
				break
			end
		end
		t.ok(clock >= 0, "a thunderstorm over the spawn")
		local function formAt(x: number, _z: number): string
			return if x < 0 then Weather.SNOW else Weather.RAIN
		end
		for _, cells in { Config.Weather.Map.MiniCells, Config.Weather.Map.WorldCells } do
			local cell = 64
			local x0, z0 = -cells * cell / 2, -cells * cell / 2
			local started = os.clock()
			local samples = field:grid(clock, x0 + cell / 2, z0 + cell / 2, cell, cells, cells)
			local whole = WeatherMap.paint(samples, x0, z0, cell, cells, cells, formAt)
			local seconds = os.clock() - started
			-- In bands of Map.CellsPerFrame cells, as Map/WeatherLayer paints it.
			local banded = buffer.create(cells * cells * 4)
			local rowsPerFrame = math.max(1, Config.Weather.Map.CellsPerFrame // cells)
			local row, frames, slowest = 0, 0, 0
			while row < cells do
				local rows = math.min(rowsPerFrame, cells - row)
				local frameStart = os.clock()
				local band = field:grid(clock, x0 + cell / 2, z0 + (row + 0.5) * cell, cell, cells, rows)
				WeatherMap.paint(band, x0, z0 + row * cell, cell, cells, rows, formAt, banded, row * cells)
				slowest = math.max(slowest, os.clock() - frameStart)
				row += rows
				frames += 1
			end
			t.eq(buffer.tostring(banded), buffer.tostring(whole), `{cells} cells: the same picture`)
			local painted = 0
			for i = 0, cells * cells - 1 do
				if buffer.readu8(whole, i * 4 + 3) > 0 then
					painted += 1
				end
			end
			t.ok(painted > 0, "a storm shows")
			print(
				string.format(
					"  map %d x %d cells: %.2f ms at once, %d frames of at most %.2f ms",
					cells,
					cells,
					seconds * 1000,
					frames,
					slowest * 1000
				)
			)
		end
	end)

	t.test("weather visuals: map grids, the forecast cache, forecasts as the field later, the wind", function()
		t.eq(WeatherMap.cellFor(384, 48), 16, "minimap at 2 blocks a pixel")
		t.eq(WeatherMap.cellFor(100, 48), WeatherMap.MIN_CELL)
		t.eq(WeatherMap.cellFor(49152, 96, 4), 1024, "the world map zoomed out")
		local x0, z0, count = WeatherMap.grid(100, -50, 384, 16)
		t.eq(x0 % 16, 0)
		t.eq(z0 % 16, 0)
		t.ok(x0 <= 100 - 192 and x0 + count * 16 >= 100 + 192, "covers the view")
		t.ok(count <= 48, "within the image")
		-- With a margin: the same grid while the view pans less than the margin.
		local cell = WeatherMap.cellFor(3072, 96, 4)
		local gx, gz, n = WeatherMap.grid(1000, 1000, 3072, cell, 4)
		t.ok(n <= 96, "fits")
		t.ok(gx <= 1000 - 1536 and gx + n * cell >= 1000 + 1536, "covers")
		local grids = {}
		local distinct = 0
		for shift = 0, 4 * cell - 1, cell / 2 do
			local px = WeatherMap.grid(1000 + shift, 1000, 3072, cell, 4)
			t.ok(px <= 1000 + shift - 1536 and px + n * cell >= 1000 + shift + 1536, "still covers")
			if not grids[px] then
				grids[px] = true
				distinct += 1
			end
		end
		t.ok(distinct <= 2, "panning by the margin samples again at most once")
		t.ok(grids[gx], "starting from the first grid")
		-- Cache: a step's picture is reused for its grid while fresh.
		local cache = WeatherMap.newCache()
		local key = WeatherMap.key(x0, z0, 16, count, count)
		local entry = {
			key = key,
			time = 100,
			pixels = buffer.create(4),
			x0 = x0,
			z0 = z0,
			cell = 16,
			cols = count,
			rows = count,
		}
		WeatherMap.put(cache, 3, entry)
		t.eq(WeatherMap.fresh(cache, 3, key, 101, 3), entry)
		t.eq(WeatherMap.fresh(cache, 3, key, 104, 3), nil, "stale")
		t.eq(WeatherMap.fresh(cache, 2, key, 101, 3), nil, "another step")
		t.eq(WeatherMap.fresh(cache, 3, WeatherMap.key(x0 + 16, z0, 16, count, count), 101, 3), nil, "moved")
		WeatherMap.clear(cache)
		t.eq(WeatherMap.fresh(cache, 3, key, 101, 3), nil, "cleared")
		-- A forecast is the deterministic field at the later moment (override included).
		local state = Weather.newState(50000, 0, true, true)
		Weather.setOverride(state, Weather.RAIN, 200, 0)
		for i, seconds in WeatherMap.STEPS do
			local moment = Weather.momentAt(state, 1000 + seconds)
			local grid = field:grid(moment, 400, -200, 64, 4, 4)
			local p, th, c = field:at(400 + 64, -200 + 64 * 2, moment)
			local index = (2 * 4 + 1) * 3
			t.near(buffer.readu8(grid, index) / 255, p, 1 / 255 + 1e-9, `step {i} precipitation`)
			t.near(buffer.readu8(grid, index + 1) / 255, th, 1 / 255 + 1e-9)
			t.near(buffer.readu8(grid, index + 2) / 255, c, 1 / 255 + 1e-9)
			t.eq(WeatherMap.LABELS[i] ~= nil, true)
		end
		-- The override ran out by +10 min: that forecast is the natural weather.
		local later = Weather.momentAt(state, 1000 + 600)
		t.eq(later.weight, 0, "the override is over by then")
		-- Wind: the arrow points where it blows (north is up, -z).
		local speed, angle = WeatherMap.wind(0, -2)
		t.eq(speed, 2)
		t.near(angle, 0, 1e-9, "north")
		local _, east = WeatherMap.wind(1, 0)
		t.near(east, 90, 1e-9, "east: clockwise")
		t.eq(WeatherMap.windText(0, 1.3), "1.3 b/s S")
		t.eq(WeatherMap.windText(1, -1), "1.4 b/s NE")
	end)

	--[[ Settings, key binding, sounds ]]

	t.test("weather visuals: Clouds and Weather settings, the Weather page, the Weather Map key", function()
		for _, key in { "clouds", "weather" } do
			local entry = PlayerSettings.entry(key)
			t.eq(entry.kind, "choice")
			t.eq(entry.page, "weather")
			t.eq(entry.min, 0)
			t.eq(entry.max, 2)
			t.ok(entry.preset, "set by the presets")
			t.eq(PlayerSettings.PRESETS[PlayerSettings.LOW][key], 1, "Low: Fast")
			for index = PlayerSettings.MEDIUM, PlayerSettings.ULTRA do
				t.eq(PlayerSettings.PRESETS[index][key], 2, "Fancy")
			end
			t.ok(table.find(PlayerSettings.EFFECT_ORDER, key) ~= nil, "its effect runs")
			t.eq(PlayerSettings.text(key, 0), `{entry.name}: OFF`)
			t.eq(PlayerSettings.text(key, 2), `{entry.name}: Fancy`)
		end
		t.eq(PlayerSettings.entry("clouds").id, 57)
		t.eq(PlayerSettings.entry("weather").id, 58)
		-- Phones start on Low: Fast.
		local phone = PlayerSettings.defaults(true)
		t.eq(phone.clouds, 1)
		t.eq(phone.weather, 1)
		-- The page, reached from the main page beside Accessibility (no new row there).
		local page = Pages.byId.weather
		t.ok(page ~= nil)
		t.eq(Pages.back("weather"), "main")
		local main = Pages.layout(Pages.byId.main)
		local accessibility, weather
		for _, placed in main.widgets do
			if placed.item.id == "accessibility" then
				accessibility = placed
			elseif placed.item.id == "weather" then
				weather = placed
			end
		end
		t.eq(weather.y, accessibility.y, "same row")
		t.eq(weather.x, 160)
		-- Key binding: B, in the Map category, conflicting with nothing.
		local action = KeyBindings.action("weatherMap")
		t.eq(action.default, "B")
		t.eq(action.category, "map")
		local values = PlayerSettings.defaults(false)
		t.eq(#KeyBindings.conflicts(values, "weatherMap"), 0)
	end)

	t.test("weather visuals: Minecraft's weather sounds are in the catalogue, played by the client", function()
		for _, name in
			{ "weather.rain", "weather.rain.above", "entity.lightning_bolt.thunder", "entity.lightning_bolt.impact" }
		do
			local event = Sounds.get(Sounds.id[name])
			t.ok(event ~= nil, name)
			t.eq((event :: any).side, "client", "each client by itself")
			t.eq((event :: any).source, "ambient", "Minecraft's WEATHER source: the ambient volume")
		end
		-- Appended at the end of the list (ids of the sounds before them unchanged).
		local list = SoundList.EVENTS
		t.eq(list[#list - 3].name, "weather.rain", "the four come last")
		t.eq(list[#list].name, "entity.lightning_bolt.impact")
		t.eq(Sounds.count, #Blocks.SOUND_TYPES * #Sounds.ACTIONS + #list)
		local volume, pitch = Weather.rainSound(1, false)
		t.near(volume, 0.2, 1e-9, "weather.rain at 0.2")
		t.eq(pitch, 1)
		volume, pitch = Weather.rainSound(1, true)
		t.near(volume, 0.1, 1e-9, "on a roof 0.1")
		t.eq(pitch, 0.5)
	end)
end
