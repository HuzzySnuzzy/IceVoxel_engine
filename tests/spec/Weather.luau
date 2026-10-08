--[[
	Weather: the field (Shared/Weather/WeatherModel: determinism, continuity, advection by the
	wind, the calibration's statistics on a seed), the clock in closed form, /weather's overrides
	(blending, replacing, doWeatherCycle holding them), the attributes and the save, what falls
	where (biomes, altitude), the sky hooks, the sampler and forecasts, the /weather command and
	/gamerule doWeatherCycle with their permissions, the server's rain (World/WeatherRules: open
	sky, roofs, leaves, glass, snow, deserts), fire in the rain (Behaviours/Fire), the undead not
	burning in rain or thunderstorms (Mobs/MobWorld), rain putting burning players and mobs out
	(Players/Burning), and lightning (World/Lightning: rate, per area however many players stand
	together, target, a pillar's top too, fires, who it hurts; the Lightning message).
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Biomes = require(shared.Biomes)
	local Config = require(shared.Config)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Protocol = require(shared.Net.Protocol)
	local Weather = require(shared.Weather)
	local WeatherModel = require(shared.Weather.WeatherModel)
	local MobList = require(shared.Entities.MobList)
	local Temperature = require(shared.ToughAsNails.Temperature)
	local WorldServer = require(server.World.WorldServer)
	local BlockTicker = require(server.World.BlockTicker)
	local Behaviours = require(server.Behaviours)
	local Fire = require(server.Behaviours.Fire)
	local WeatherRules = require(server.World.WeatherRules)
	local Lightning = require(server.World.Lightning)
	local MobWorld = require(server.Mobs.MobWorld)
	local WeatherCommand = require(server.Players.WeatherCommand)
	local TimeCommand = require(server.Players.TimeCommand)

	local B = Blocks.id
	local AIR, STONE, FIRE = Blocks.AIR, B.Stone, B.Fire
	local SEED = 12345
	local RAINING = Weather.RAINING
	local NOON = 6000

	local field = Weather.new(SEED)

	-- A deterministic random in [0, 1) (a small LCG).
	local function lcg(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	-- A random that returns `values` in turn, then `rest`.
	local function scripted(values: { number }, rest: number): () -> number
		local i = 0
		return function(): number
			i += 1
			return values[i] or rest
		end
	end

	-- A dry place (no precipitation) at clock `time`, searched along x.
	local function dryPlace(f, time: number): number
		for x = 0, 200000, 500 do
			if f:at(x, 0, time) == 0 then
				return x
			end
		end
		error("no dry place found")
	end

	-- A rainy place (precipitation over `level`) at clock `time`, searched along x.
	local function rainyPlace(f, time: number, level: number): number
		for x = 0, 400000, 250 do
			if f:at(x, 0, time) > level then
				return x
			end
		end
		error("no rainy place found")
	end

	--[[ The field ]]

	t.test("weather: the field is deterministic and differs between seeds", function()
		local again = Weather.new(SEED)
		local other = Weather.new(SEED + 1)
		local differ = 0
		for i = 0, 200 do
			local x, z, time = i * 731 - 50000, i * 397 + 1234, i * 3001
			local p, th, c = field:at(x, z, time)
			local p2, th2, c2 = again:at(x, z, time)
			t.eq(p, p2, "precipitation")
			t.eq(th, th2, "thunder")
			t.eq(c, c2, "cover")
			t.ok(
				p >= 0 and p <= 1 and th >= 0 and th <= p + 1e-9 and c >= 0 and c <= 1,
				"in range, thunder within rain"
			)
			if math.abs(field:moisture(x, z, time) - other:moisture(x, z, time)) > 1e-3 then
				differ += 1
			end
		end
		t.ok(differ > 180, `another seed, other storms ({differ} of 201 differ)`)
		local wx, wz = field:wind(5000)
		local ox, oz = other:wind(5000)
		t.ok(wx ~= ox or wz ~= oz, "and another wind")
		-- The world's field.
		t.eq(Weather.setSeed(SEED), Weather.setSeed(SEED), "one field per seed")
		local p1 = Weather.at(1000, 2000, 777)
		t.eq(p1, (field:at(1000, 2000, 777)), "the module's field is the seed's")
	end)

	t.test("weather: continuous in space and time, far from the origin and late too", function()
		local worst, worstTime = 0, 0
		for _, origin in { { 0, 0, 0 }, { 900000, -700000, 50000000 } } do
			local x0, z0, time = origin[1], origin[2], origin[3]
			local last, lastC = field:at(x0, z0, time)
			for step = 1, 3000 do
				local p, _, c = field:at(x0 + step, z0, time)
				worst = math.max(worst, math.abs(p - last), math.abs(c - lastC))
				last, lastC = p, c
			end
			last = field:at(x0, z0, time)
			for step = 1, 3000 do
				local p = field:at(x0, z0, time + step * 20)
				worstTime = math.max(worstTime, math.abs(p - last))
				last = p
			end
		end
		t.ok(worst < 0.03, `a block apart: at most {worst}`)
		t.ok(worstTime < 0.05, `a second apart: at most {worstTime}`)
	end)

	t.test("weather: storms drift with the wind", function()
		-- The wind is the displacement's rate.
		for _, time in { 0, 12345, 400000 } do
			local h = 10
			local ax, az = field:displacement(time - h)
			local bx, bz = field:displacement(time + h)
			local wx, wz = field:wind(time)
			t.near((bx - ax) / (2 * h), wx, 1e-6, "x")
			t.near((bz - az) / (2 * h), wz, 1e-6, "z")
		end
		-- A minute later the field matches itself moved with the air, not where it was.
		local moved, stayed, n = 0, 0, 0
		local carried, raining = 0, 0
		for i = 0, 400 do
			local time = 20000 + i * 4000
			local later = time + 1200
			local dx0, dz0 = field:displacement(time)
			local dx1, dz1 = field:displacement(later)
			local x, z = i * 977 - 200000, i * 571
			local before = field:moisture(x, z, time)
			moved += math.abs(field:moisture(x + dx1 - dx0, z + dz1 - dz0, later) - before)
			stayed += math.abs(field:moisture(x, z, later) - before)
			n += 1
			if field:at(x, z, time) > RAINING then
				raining += 1
				if field:at(x + dx1 - dx0, z + dz1 - dz0, later) > RAINING then
					carried += 1
				end
			end
		end
		t.ok(moved < stayed * 0.5, `moved with the wind: {moved / n} vs {stayed / n} in place`)
		t.ok(raining > 20 and carried >= raining * 0.85, `rain goes with the air ({carried} of {raining})`)
	end)

	t.test("weather: calibration on a seed (rain share, spells, storm size, thunder, wind)", function()
		local random = lcg(99)
		local STEP = 200
		local rainy, thunder, samples = 0, 0, 0
		local spells, clears = {}, {}
		for _ = 1, 64 do
			local x, z = random() * 120000 - 60000, random() * 120000 - 60000
			local raining, run = nil, 0
			for time = 0, 20 * 24000, STEP do
				local p, th = field:at(x, z, time)
				samples += 1
				local now = p > RAINING
				if now then
					rainy += 1
					if th > 0.5 then
						thunder += 1
					end
				end
				if now == raining then
					run += 1
				else
					if raining ~= nil then
						table.insert(if raining then spells else clears, run * STEP / 1200)
					end
					raining, run = now, 1
				end
			end
		end
		local function mean(list: { number }): number
			local sum = 0
			for _, v in list do
				sum += v
			end
			return sum / math.max(#list, 1)
		end
		local share = rainy / samples
		t.ok(share > 0.18 and share < 0.3, `raining {share * 100}% of the time`)
		t.ok(mean(spells) > 8 and mean(spells) < 22, `rain spells last {mean(spells)} minutes on average`)
		t.ok(mean(clears) > 20 and mean(clears) < 80, `clear stretches last {mean(clears)} minutes`)
		local thunderShare = thunder / math.max(rainy, 1)
		t.ok(thunderShare > 0.05 and thunderShare < 0.25, `thunder in {thunderShare * 100}% of the rainy time`)
		-- Storm sizes: chords along lines.
		local chords = {}
		for k = 1, 30 do
			local time, z = k * 9973, random() * 120000 - 60000
			local run = 0
			for x = -40000, 40000, 25 do
				if field:at(x, z, time) > RAINING then
					run += 25
				elseif run > 0 then
					table.insert(chords, run)
					run = 0
				end
			end
		end
		table.sort(chords)
		local median = chords[#chords // 2 + 1]
		t.ok(#chords > 50, `storms found ({#chords})`)
		t.ok(median > 500 and median < 3000, `a storm's median chord is {median} blocks`)
		t.ok(chords[#chords] > 4000, `the largest {chords[#chords]} blocks`)
		-- The wind: a few blocks a second at most.
		local fastest = 0
		for time = 0, 500000, 1000 do
			local wx, wz = field:wind(time)
			fastest = math.max(fastest, math.sqrt(wx * wx + wz * wz) * 20)
		end
		t.ok(fastest > 1.5 and fastest < 4, `the wind reaches {fastest} blocks a second`)
	end)

	t.test("weather: the grid sampler and forecasts agree with `at`", function()
		local time = 33333
		local grid = field:grid(time, -1000, 500, 37, 9, 7)
		t.eq(buffer.len(grid), 9 * 7 * 3, "3 bytes a cell")
		for row = 0, 6 do
			for col = 0, 8 do
				local p, th, c = field:at(-1000 + col * 37, 500 + row * 37, time)
				local index = (row * 9 + col) * 3
				t.eq(buffer.readu8(grid, index), math.floor(p * 255 + 0.5), "precipitation")
				t.eq(buffer.readu8(grid, index + 1), math.floor(th * 255 + 0.5), "thunder")
				t.eq(buffer.readu8(grid, index + 2), math.floor(c * 255 + 0.5), "cover")
			end
		end
		-- A buffer big enough is reused.
		t.eq(field:grid(time, 0, 0, 10, 3, 3, grid), grid, "reused")
		-- Off: nothing anywhere.
		local off = field:grid({
			time = time,
			enabled = false,
			override = "",
			weight = 0,
			previous = {},
		}, 0, 0, 10, 4, 4)
		for i = 0, 47 do
			t.eq(buffer.readu8(off, i), 0, "no weather")
		end
		local list = field:forecast(500, -700, 1000, 6, 600)
		t.eq(#list, 6, "six steps")
		for i, sample in list do
			t.eq(sample.time, 1000 + (i - 1) * 600, "every 600 ticks from now")
			t.eq(sample.precipitation, (field:at(500, -700, sample.time)), "the field then")
		end
	end)

	t.test("weather: a new world starts clear at spawn", function()
		local start = Weather.clearStart(field, 0, 0, 300)
		for time = start, start + 300 * 20, 100 do
			t.eq((field:at(0, 0, time)), 0, `dry at {time}`)
		end
		t.eq(Weather.clearStart(field, 0, 0, 0), 0, "no wait: 0")
	end)

	--[[ The clock and overrides ]]

	t.test("weather: the clock in closed form matches counting ticks", function()
		local state = Weather.newState(500, 1000, true, true)
		t.eq(state.rate, 20 * Config.Weather.Speed, "20 ticks a second")
		local ticks = 500
		for step = 1, 2000 do
			ticks += 1
			t.near(Weather.clock(state, 1000 + step / 20), ticks, 1e-6, "a tick every 1/20 s")
		end
		t.eq(Weather.clock(state, 999), 500, "never before the sync")
		-- Stopping and starting again: no jump, standing still in between.
		Weather.setCycle(state, false, 1200)
		t.near(Weather.clock(state, 1200), 500 + 200 * 20, 1e-6, "where it was")
		t.near(Weather.clock(state, 5000), 500 + 200 * 20, 1e-6, "stands still")
		Weather.setCycle(state, true, 5000)
		t.near(Weather.clock(state, 5010), 500 + 210 * 20, 1e-6, "goes on")
		Weather.setClock(state, 42, 6000)
		t.eq(Weather.clock(state, 6000), 42, "set")
	end)

	t.test("weather: /weather overrides blend in and out everywhere", function()
		local blend = Weather.blendSeconds()
		t.eq(blend, 5, "Minecraft's 5 s")
		local state = Weather.newState(1000, 0, true, true)
		local x = dryPlace(field, Weather.clock(state, 100))
		Weather.setOverride(state, Weather.RAIN, 60, 100)
		local function precipitation(now: number): number
			return (field:at(x, 0, Weather.momentAt(state, now)))
		end
		t.eq(precipitation(100), 0, "nothing at once")
		t.near(precipitation(100 + blend / 2), WeatherModel.RAIN_LEVEL / 2, 1e-6, "half way")
		t.ok(precipitation(100 + blend) >= WeatherModel.RAIN_LEVEL, "raining everywhere")
		local _, th, c = field:at(x, 0, Weather.momentAt(state, 130))
		t.eq(th, 0, "rain without thunder")
		t.eq(c, 1, "overcast")
		t.near(precipitation(160 - blend / 2), WeatherModel.RAIN_LEVEL / 2, 1e-6, "fading out")
		t.eq(precipitation(160), 0, "gone by the end")
		t.eq(Weather.overrideAt(state, 130), Weather.RAIN, "the override")
		t.ok(not Weather.expire(state, 159), "not yet run out")
		t.ok(Weather.expire(state, 160), "run out")
		t.eq(state.override, Weather.NONE, "dropped")
		-- No jumps while it blends.
		state = Weather.newState(1000, 0, true, true)
		Weather.setOverride(state, Weather.THUNDER, 20, 10)
		local last = precipitation(9)
		local worst = 0
		for step = 1, 600 do
			local p = precipitation(9 + step * 0.05)
			worst = math.max(worst, math.abs(p - last))
			last = p
		end
		t.ok(worst < 0.03, `no jumps ({worst} in 0.05 s)`)
		local _, thunder = field:at(x, 0, Weather.momentAt(state, 20))
		t.eq(thunder, 1, "thunder everywhere")
	end)

	t.test("weather: a new override blends from the old one; doWeatherCycle holds its time", function()
		local state = Weather.newState(1000, 0, true, true)
		local x = dryPlace(field, Weather.clock(state, 100))
		local function precipitation(now: number): number
			return (field:at(x, 0, Weather.momentAt(state, now)))
		end
		Weather.setOverride(state, Weather.RAIN, 600, 100)
		local before = precipitation(102)
		Weather.setOverride(state, Weather.CLEAR, 600, 102)
		t.near(precipitation(102), before, 1e-9, "no jump when it changes")
		t.eq(state.previous[1].kind, Weather.RAIN, "blending from the rain")
		t.eq(precipitation(102 + Weather.blendSeconds()), 0, "then clear")
		-- Clear keeps thin clouds at most.
		local wet = rainyPlace(field, Weather.clock(state, 200), 0.5)
		local _, _, cover = field:at(wet, 0, Weather.momentAt(state, 200))
		t.ok(cover <= WeatherModel.CLEAR_COVER + 1e-9, "thin clouds at most")

		-- The cycle stopped: the override's time stands still, its weight too.
		state = Weather.newState(1000, 0, true, true)
		Weather.setOverride(state, Weather.THUNDER, 30, 200)
		Weather.setCycle(state, false, 210)
		t.eq(state.left, 20, "20 s left")
		t.eq(Weather.momentAt(state, 5000).weight, 1, "never runs out while stopped")
		t.ok(not Weather.expire(state, 99999), "not dropped")
		Weather.setCycle(state, true, 5000)
		t.eq(state.finish, 5020, "counts down again")
		t.eq(Weather.momentAt(state, 5020).weight, 0, "and ends")
		-- Stopped while fading out: it stays where it was.
		state = Weather.newState(1000, 0, true, true)
		Weather.setOverride(state, Weather.RAIN, 10, 300)
		Weather.setCycle(state, false, 308)
		t.near(Weather.momentAt(state, 308).weight, 0.4, 1e-9, "fading")
		t.near(Weather.momentAt(state, 900).weight, 0.4, 1e-9, "held")
		-- Set while stopped: it waits for the cycle.
		state = Weather.newState(1000, 0, false, true)
		Weather.setOverride(state, Weather.RAIN, 10, 0)
		t.eq(state.left, 10)
		t.eq(Weather.momentAt(state, 1000).weight, 1, "rains on")
		-- Unknown kinds and durations are refused.
		t.ok(not pcall(Weather.setOverride, state, "storm", 10, 0), "unknown kind")
		t.ok(not pcall(Weather.setOverride, state, Weather.RAIN, 0, 0), "no duration")
	end)

	t.test("weather: overrides in quick succession and short ones never make it jump", function()
		local blend = Weather.blendSeconds()
		-- The worst change between two looks 0.05 s apart, expiring every second as the server does.
		local function worst(state: Weather.State, x: number, from: number, to: number, commands: { any }): number
			local last = (field:at(x, 0, Weather.momentAt(state, from)))
			local biggest = 0
			local nextExpire = math.floor(from) + 1
			local step = 0
			while from + step * 0.05 < to do
				step += 1
				local now = from + step * 0.05
				for _, command in commands do
					if not command.done and now >= command.at then
						command.done = true
						Weather.setOverride(state, command.kind, command.seconds, command.at)
					end
				end
				if now >= nextExpire then
					Weather.expire(state, now)
					nextExpire += 1
				end
				local p = (field:at(x, 0, Weather.momentAt(state, now)))
				biggest = math.max(biggest, math.abs(p - last))
				last = p
			end
			return biggest
		end
		-- (a) Over a dry place: thunder, then clear 2 s later, then rain 1 s later.
		local state = Weather.newState(1000, 0, true, true)
		local dry = dryPlace(field, Weather.clock(state, 100))
		local a = worst(state, dry, 99, 140, {
			{ at = 100, kind = Weather.THUNDER, seconds = 600 },
			{ at = 102, kind = Weather.CLEAR, seconds = 600 },
			{ at = 103, kind = Weather.RAIN, seconds = 600 },
		})
		t.ok(a < 0.03, `three commands in 3 s: no jump ({a} in 0.05 s)`)
		t.eq(#state.previous, 2, "blending from the clear and from the thunder under it")
		-- (b) Over natural heavy rain: clear blended in, then /weather rain 2 (shorter than the blend).
		state = Weather.newState(100000, 0, true, true)
		local wet = rainyPlace(field, Weather.clock(state, 100), 0.9)
		local b = worst(state, wet, 99, 130, {
			{ at = 100, kind = Weather.CLEAR, seconds = 600 },
			{ at = 110, kind = Weather.RAIN, seconds = 2 },
		})
		t.ok(b < 0.03, `a 2 s override: no jump at its end ({b} in 0.05 s)`)
		t.eq(state.override, Weather.NONE, "dropped once what it replaced faded out")
		t.ok(not Weather.expire(state, 200), "nothing left to drop")
		-- Dropped only after its blend: not at its finish.
		state = Weather.newState(100000, 0, true, true)
		Weather.setOverride(state, Weather.CLEAR, 600, 0)
		Weather.setOverride(state, Weather.RAIN, 2, 10)
		t.ok(not Weather.expire(state, 12.5), "the clear under it still fades")
		t.ok(Weather.expire(state, 10 + blend), "gone with it")
		-- The attribute carries the whole chain.
		state = Weather.newState(1000, 0, true, true)
		Weather.setOverride(state, Weather.THUNDER, 600, 100)
		Weather.setOverride(state, Weather.CLEAR, 600, 102)
		Weather.setOverride(state, Weather.RAIN, 600, 103)
		local copy = Weather.newState()
		Weather.decodeOverride(copy, Weather.encodeOverride(state))
		t.eq(#copy.previous, 2)
		t.eq(copy.previous[1].kind, Weather.THUNDER)
		t.eq(copy.previous[2].kind, Weather.CLEAR)
		t.near(copy.previous[1].weight, state.previous[1].weight, 1e-12)
		-- A moment reuses its entries (the client asks every frame).
		local moment = Weather.momentAt(state, 104)
		local first = moment.previous[1]
		t.eq(Weather.momentAt(state, 104.5, moment).previous[1], first, "no new tables a frame")
	end)

	t.test("weather: attributes and the save round-trip", function()
		local state = Weather.newState(12345.5, 100, true, true)
		Weather.setOverride(state, Weather.THUNDER, 300, 150)
		Weather.setOverride(state, Weather.RAIN, 60, 152)
		local attributes = {}
		Weather.writeState(state, function(name: string, value: any)
			attributes[name] = value
		end)
		t.eq(attributes[Weather.ATTRIBUTE_ENABLED], true)
		t.eq(attributes[Weather.ATTRIBUTE_RATE], 20)
		local read = Weather.readState(function(name: string): any
			return attributes[name]
		end)
		for _, now in { 150, 153, 170, 211, 213 } do
			local a, b = Weather.momentAt(state, now), Weather.momentAt(read, now)
			t.eq(b.time, a.time, "clock")
			t.eq(b.override, a.override, "override")
			t.near(b.weight, a.weight, 1e-12, "weight")
			t.eq(#b.previous, #a.previous, "previous")
			for i, earlier in a.previous do
				t.eq(b.previous[i].kind, earlier.kind, "previous kind")
				t.near(b.previous[i].weight, earlier.weight, 1e-12, "previous weight")
			end
		end
		-- Nothing published yet: no weather.
		local none = Weather.readState(function(_name: string): any
			return nil
		end)
		t.eq(none.enabled, false, "off until published")
		-- Malformed override text: none.
		local bad = Weather.newState()
		Weather.decodeOverride(bad, "storm;1;2;-1;;0")
		t.eq(bad.override, Weather.NONE, "unknown kind")
		Weather.decodeOverride(bad, "rain;x;2;-1;;0")
		t.eq(bad.override, Weather.NONE, "bad number")

		-- The save: the clock, the rule and the override with its time left, blended in at once.
		local text = Weather.encodeState(state, 170)
		local loaded = Weather.decodeState(text, 9000, true) :: Weather.State
		t.ok(loaded ~= nil, "decodes")
		t.near(Weather.clock(loaded, 9000), Weather.clock(state, 170), 1e-6, "the clock goes on from there")
		t.eq(loaded.override, Weather.RAIN, "the override")
		t.near(loaded.finish, 9000 + 42, 1e-6, "with its time left")
		t.eq(Weather.momentAt(loaded, 9000).weight, 1, "already blended in")
		Weather.setCycle(state, false, 180)
		local paused = Weather.decodeState(Weather.encodeState(state, 9999), 0, true) :: Weather.State
		t.eq(paused.cycle, false, "doWeatherCycle")
		t.eq(paused.left, 32, "time held")
		local plain = Weather.decodeState(Weather.encodeState(Weather.newState(77, 0, true, true), 0), 50, true)
		t.eq((plain :: Weather.State).override, Weather.NONE, "no override")
		-- Saved the moment it was set (not blended in yet): kept; saved after it ran out: gone.
		local fresh = Weather.newState(0, 0, true, true)
		Weather.setOverride(fresh, Weather.CLEAR, 100, 10)
		t.eq((Weather.decodeState(Weather.encodeState(fresh, 10), 0, true) :: Weather.State).override, Weather.CLEAR)
		t.eq(
			(Weather.decodeState(Weather.encodeState(fresh, 111), 0, true) :: Weather.State).override,
			Weather.NONE,
			"run out"
		)
		for _, malformed in { "", "w1;5;1;;", "w2;5;1;;-1", "w1;5;2;;-1", "w1;5;1;storm;10", "w1;nan;1;;-1", 5 } do
			t.eq(Weather.decodeState(malformed, 0, true), nil, `refuses {malformed}`)
		end
	end)

	--[[ What falls where ]]

	t.test("weather: biomes' Minecraft temperatures and precipitation", function()
		for _, biome in Biomes.list do
			t.ok(type(biome.weatherTemperature) == "number", biome.name)
			if biome.frozen then
				t.ok(biome.weatherTemperature < Weather.SNOW_BELOW, `{biome.name} is snowy`)
			end
		end
		for _, name in { "Desert", "Savanna", "WindsweptSavanna" } do
			local biome = Biomes.byName(name) :: Biomes.Biome
			t.eq(biome.precipitation, false, `nothing falls in {name}`)
			t.eq(Weather.biomeTemperature(biome.index), nil, name)
		end
		local plains = Biomes.byName("Plains") :: Biomes.Biome
		t.eq(Weather.biomeTemperature(plains.index), 0.8, "plains 0.8")
		t.eq((Biomes.byName("Taiga") :: Biomes.Biome).weatherTemperature, 0.25, "taiga 0.25")
		t.eq((Biomes.byName("Tundra") :: Biomes.Biome).weatherTemperature, 0, "snowy plains 0")
	end)

	t.test("weather: rain in the valley, snow on the peaks, nothing in deserts", function()
		t.eq(Weather.formAt(nil, 0, 64, 0), Weather.NONE, "no precipitation")
		t.eq(Weather.formAt(0, 0, 64, 0), Weather.SNOW, "snowy plains")
		t.eq(Weather.formAt(0.8, 0, 64, 0), Weather.RAIN, "plains")
		t.eq(Weather.formAt(0.25, 0, 64, 0), Weather.RAIN, "a taiga valley")
		t.eq(Weather.formAt(0.25, 0, 200, 0), Weather.SNOW, "a taiga mountain side")
		-- The plains' snow line is near y 295 (0.8 - 0.15 at 0.0029 a block above 71), a little
		-- ragged.
		for i = 0, 200 do
			local x, z = i * 13, i * 7
			t.eq(Weather.formAt(0.8, x, 280, z), Weather.RAIN, "rain below")
			t.eq(Weather.formAt(0.8, x, 310, z), Weather.SNOW, "snow above")
		end
		local ragged = {}
		for i = 0, 200 do
			local y = 260
			while Weather.formAt(0.8, i * 5, y, 0) == Weather.RAIN do
				y += 1
			end
			ragged[y] = true
		end
		local lines = 0
		for _ in ragged do
			lines += 1
		end
		t.ok(lines >= 3, `the snow line wanders ({lines} heights)`)
		t.eq(Weather.kindOf(0.15, Weather.RAIN), Weather.CLEAR, "drizzle under 0.2 doesn't count")
		t.eq(Weather.kindOf(0.5, Weather.SNOW), Weather.SNOW)
		t.eq(Weather.kindOf(0.5, Weather.NONE), Weather.CLEAR)
		Weather.setSeed(SEED)
		local wet = rainyPlace(field, 1000, 0.5)
		t.eq(Weather.kindAt(wet, 64, 0, 1000, 0.8), Weather.RAIN, "rain")
		t.eq(Weather.kindAt(wet, 500, 0, 1000, 0.8), Weather.SNOW, "snow up high")
		t.eq(Weather.kindAt(wet, 64, 0, 1000, nil), Weather.CLEAR, "desert")
		t.eq(Weather.kindAt(dryPlace(field, 1000), 64, 0, 1000, 0.8), Weather.CLEAR, "clear")
	end)

	--[[ The sky ]]

	t.test("weather: Minecraft's darkening, colours, fog and sounds", function()
		t.eq(Weather.skyDarken(NOON, 0, 0), 0, "clear noon")
		t.eq(Weather.skyDarken(NOON, 1, 0), 3, "rain: 3")
		t.eq(Weather.skyDarken(NOON, 1, 1), 5, "thunder: 5")
		t.eq(Weather.skyLight(NOON, 1, 1), 10, "sky light 10")
		t.ok(Weather.isDay(NOON, 1, 0), "day in the rain")
		t.ok(not Weather.isDay(NOON, 1, 1), "not in a thunderstorm")
		t.ok(not Weather.isDay(18000, 0, 0), "nor at night")
		t.eq(Weather.dimming(0, 0), 1)
		t.near(Weather.dimming(1, 0), 11 / 16, 1e-12, "5/16 off")
		t.near(Weather.dimming(1, 1), (11 / 16) ^ 2, 1e-12)
		t.near(Weather.sunBrightness(NOON, 0, 0), 1, 1e-9)
		t.near(Weather.sunBrightness(NOON, 1, 0), 11 / 16 * 0.8 + 0.2, 1e-9)
		local grey = Weather.skyColour({ 100, 100, 100 }, 1, 1)
		t.ok(grey[1] < 100 and math.abs(grey[1] - grey[3]) < 1e-9, "the sky greys and darkens")
		local blue = Weather.skyColour({ 120, 160, 255 }, 1, 0)
		t.ok(blue[3] - blue[1] < 135 * 0.5, "less blue in the rain")
		t.eq(Weather.skyColour({ 1, 2, 3 }, 0, 0)[2], 2, "untouched in clear weather")
		local fog = Weather.fogColour({ 200, 200, 200 }, 1, 0)
		t.eq(fog[1], 100, "fog: red and green halved")
		t.eq(fog[3], 120, "blue x 0.6")
		local cloud = Weather.cloudColour({ 255, 255, 255 }, 1, 0)
		t.ok(cloud[1] < 255 * 0.7, "grey clouds")
		t.eq(Weather.fogFactor(0, 0), 1)
		t.near(Weather.fogFactor(1, 0), Config.Weather.Fog.Rain, 1e-12)
		t.near(Weather.fogFactor(1, 0, true), Config.Weather.Fog.Snow, 1e-12)
		t.near(Weather.fogFactor(1, 1), math.min(Config.Weather.Fog.Rain, Config.Weather.Fog.Thunder), 1e-12)
		t.eq(Weather.rainSound(0.1, false), 0, "no rain, no sound")
		local volume, pitch = Weather.rainSound(1, false)
		t.eq(volume, 0.2)
		t.eq(pitch, 1)
		volume, pitch = Weather.rainSound(1, true)
		t.eq(volume, 0.1, "on the roof")
		t.eq(pitch, 0.5)
		t.near(Weather.thunderDelay(Config.Weather.SoundSpeed * 3), 3, 1e-9, "3 s")
	end)

	--[[ Commands ]]

	local function context(mayUse: boolean, enabled: boolean?, here: string?, roll: number?)
		return {
			mayUse = mayUse,
			enabled = enabled ~= false,
			here = here or Weather.CLEAR,
			random = function(): number
				return roll or 0
			end,
		}
	end

	t.test("weather command: Minecraft's syntax, answers and durations", function()
		t.ok(WeatherCommand.matches("/weather rain"))
		t.ok(WeatherCommand.matches("  /WEATHER"))
		t.ok(not WeatherCommand.matches("/weathers"))
		t.eq(WeatherCommand.run("hello", context(true)), nil, "ordinary chat")
		local result = WeatherCommand.run("/weather rain", context(true)) :: WeatherCommand.Result
		t.eq(result.kind, Weather.RAIN)
		t.eq(result.ticks, 12000, "Minecraft's shortest random rain")
		t.eq(result.feedback[1], "Set the weather to rain")
		result = WeatherCommand.run("/weather thunder 30s", context(true)) :: WeatherCommand.Result
		t.eq(result.kind, Weather.THUNDER)
		t.eq(result.ticks, 600)
		t.eq(result.feedback[1], "Set the weather to rain & thunder")
		result = WeatherCommand.run("/Weather CLEAR 1d", context(true)) :: WeatherCommand.Result
		t.eq(result.kind, Weather.CLEAR)
		t.eq(result.ticks, 24000)
		t.eq(result.feedback[1], "Set the weather to clear")
		t.eq((WeatherCommand.run("/weather rain 6000", context(true)) :: WeatherCommand.Result).ticks, 6000, "ticks")
		-- Minecraft's random durations, both ends included.
		for kind, range in WeatherCommand.DURATIONS do
			t.eq(
				WeatherCommand.randomTicks(kind, function()
					return 0
				end),
				range[1],
				kind
			)
			t.eq(
				WeatherCommand.randomTicks(kind, function()
					return 0.99999999
				end),
				range[2],
				kind
			)
		end
		t.eq(WeatherCommand.DURATIONS[Weather.THUNDER][2], 15600, "thunder 3600-15600")
	end)

	t.test("weather command: permissions, queries and refusals", function()
		local function says(text: string, ctx): string
			local result = WeatherCommand.run(text, ctx) :: WeatherCommand.Result
			t.eq(result.kind, nil, text)
			t.eq(#result.feedback, 1, text)
			return result.feedback[1]
		end
		t.eq(says("/weather rain", context(false)), WeatherCommand.DENIED, "operators only")
		t.eq(says("/weather query", context(false, true, Weather.SNOW)), "Weather state is: snow", "anyone may ask")
		t.eq(says("/weather query", context(false, false, Weather.RAIN)), "Weather state is: clear", "no weather")
		t.eq(says("/weather rain", context(true, false)), WeatherCommand.NO_WEATHER, "a world without weather")
		t.eq(says("/weather", context(true)), WeatherCommand.USAGE)
		t.eq(says("/weather storm", context(true)), WeatherCommand.USAGE)
		t.eq(says("/weather rain 10 more", context(true)), WeatherCommand.USAGE)
		t.eq(says("/weather query here", context(true)), WeatherCommand.USAGE)
		t.ok(string.find(says("/weather rain 0", context(true)), "must not be less than 1", 1, true), "at least a tick")
		t.ok(string.find(says("/weather rain -5", context(true)), "must not be less than 0", 1, true))
		t.ok(string.find(says("/weather rain 5x", context(true)), "Invalid unit", 1, true))
	end)

	t.test("gamerule: doWeatherCycle", function()
		local function ctx(mayUse: boolean, weatherCycle: boolean?)
			return { mayUse = mayUse, dayTime = 1000, gameTime = 0, cycle = true, weatherCycle = weatherCycle }
		end
		local result = TimeCommand.run("/gamerule doWeatherCycle false", ctx(true)) :: any
		t.eq(result.weatherCycle, false)
		t.eq(result.cycle, nil, "the day goes on")
		t.eq(result.feedback[1], "Gamerule doWeatherCycle is now set to: false")
		result = TimeCommand.run("/gamerule doweathercycle true", ctx(true, false)) :: any
		t.eq(result.weatherCycle, true, "any case")
		result = TimeCommand.run("/gamerule doWeatherCycle", ctx(false, false)) :: any
		t.eq(result.weatherCycle, nil, "a query")
		t.eq(result.feedback[1], "Gamerule doWeatherCycle is currently set to: false")
		result = TimeCommand.run("/gamerule doWeatherCycle false", ctx(false)) :: any
		t.eq(result.weatherCycle, nil)
		t.eq(result.feedback[1], TimeCommand.DENIED_RULES, "operators only")
		result = TimeCommand.run("/gamerule keepInventory true", ctx(true)) :: any
		t.ok(string.find(result.feedback[1], "doDaylightCycle, doWeatherCycle", 1, true), "lists both")
	end)

	--[[ Rain on the server ]]

	local FLOOR = 10
	local CROP = 32
	local flat = {
		generate = function(level: number, nx: number, nz: number)
			local data = ChunkLayout.create(CROP)
			for y = 0, FLOOR - 1 do
				for i = 0, ChunkLayout.LAYER - 1 do
					buffer.writeu16(data, (y * ChunkLayout.LAYER + i) * 2, STONE)
				end
			end
			return {
				data = data,
				level = level,
				nx = nx,
				nz = nz,
				height = CROP,
				solidBelow = FLOOR,
				emptyAbove = FLOOR,
			}
		end,
		column = function()
			return FLOOR, 1, 0, STONE
		end,
		findSpawn = function()
			return 0, FLOOR, 0
		end,
	}

	local function newWorld()
		local world = WorldServer.new(flat :: any)
		local ticker = BlockTicker.new(world, Behaviours.byId, 100000)
		world.onChanged = function(x, y, z)
			ticker:blockChanged(x, y, z)
		end
		for cx = -2, 2 do
			for cz = -2, 2 do
				world:getChunk(cx, cz)
			end
		end
		return world, ticker
	end

	t.test("rain: open sky, roofs, leaves, glass, torches, water, snow and deserts", function()
		local world = newWorld()
		local function raining(x: number, z: number, precipitation: number?, temperature: number?): boolean
			return WeatherRules.rainingAt(world, x, FLOOR, z, precipitation or 1, temperature)
		end
		t.eq(WeatherRules.top(world, 0, 0), FLOOR, "the top of the stone")
		t.ok(raining(0, 0, 1, 0.8), "the open sky")
		t.ok(not raining(0, 0, 0.15, 0.8), "drizzle under 0.2 isn't rain")
		t.ok(not raining(0, 0, 1, 0), "snow instead")
		t.ok(not raining(0, 0, 1, nil), "nothing falls in a desert")
		world:setBlock(1, FLOOR + 5, 0, STONE)
		world:setBlock(2, FLOOR + 5, 0, B.OakLeaves)
		world:setBlock(3, FLOOR + 5, 0, B.Glass)
		world:setBlock(4, FLOOR + 5, 0, B.Torch)
		world:setBlock(5, FLOOR + 5, 0, Blocks.fluidId("Water", 0))
		t.ok(not raining(1, 0, 1, 0.8), "under a roof")
		t.ok(not raining(2, 0, 1, 0.8), "under leaves")
		t.ok(not raining(3, 0, 1, 0.8), "under glass")
		t.ok(raining(4, 0, 1, 0.8), "a torch lets it through")
		t.ok(not raining(5, 0, 1, 0.8), "under water")
		t.eq(WeatherRules.top(world, 2, 0), FLOOR + 6, "the crown")
		t.ok(WeatherRules.rainingAt(world, 2, FLOOR + 6, 0, 1, 0.8), "on top of the leaves")
		t.eq(WeatherRules.top(world, 1000, 1000), nil, "not loaded")
		t.ok(not WeatherRules.rainingAt(world, 1000, FLOOR, 1000, 1, 0.8), "never rains there")
		t.ok(WeatherRules.blocksRain(B.Stone) and not WeatherRules.blocksRain(B.ShortGrass), "plants let it through")
		-- Rain makes a body wet, as water does (Tough As Nails' -3 steps).
		local env = {
			climate = 0.1,
			y = 64,
			surface = 64,
			skyOpen = true,
			night = false,
			wet = true,
			sprinting = false,
			heated = false,
			nearHeat = false,
			cooled = false,
			burning = false,
			armorWarmth = 0,
			armorCooling = 0,
		}
		local wetTarget = Temperature.target(env :: any)
		env.wet = false
		t.eq(wetTarget, Temperature.target(env :: any) + Temperature.MODIFIERS.wet, "wet: 3 steps colder")
	end)

	t.test("rain: puts fire out under the sky, not under a roof, and stops it spreading", function()
		local world, ticker = newWorld()
		local precipitation = 1
		Fire.setRain(function(w: any, x: number, y: number, z: number): boolean
			return WeatherRules.rainingAt(w, x, y, z, precipitation, 0.8)
		end)
		-- A fire by a plank in the rain goes out (0.2 + age x 0.03).
		world:setBlock(1, FLOOR, 0, B.Planks)
		world:setBlock(0, FLOOR, 0, FIRE)
		-- (The first roll is the next tick's delay.)
		Fire.tick(world, ticker, 0, FLOOR, 0, scripted({ 0.5, 0.19 }, 0.99))
		t.eq(world:peekBlock(0, FLOOR, 0), AIR, "out in the rain")
		world:setBlock(0, FLOOR, 0, FIRE)
		Fire.tick(world, ticker, 0, FLOOR, 0, scripted({ 0.5, 0.21 }, 0.99))
		t.eq(world:peekBlock(0, FLOOR, 0), FIRE, "a roll over 0.2 keeps it")
		-- Under a roof over it and its four neighbours it burns on.
		world:setBlock(10, FLOOR, 10, B.Planks)
		world:setBlock(9, FLOOR, 10, FIRE)
		for x = 8, 10 do
			for z = 9, 11 do
				world:setBlock(x, FLOOR + 4, z, STONE)
			end
		end
		Fire.tick(world, ticker, 9, FLOOR, 10, scripted({}, 0))
		t.eq(world:peekBlock(9, FLOOR, 10), FIRE, "sheltered")
		t.ok(Fire.nearRain(world, 0, FLOOR, 0), "near rain in the open")
		t.ok(not Fire.nearRain(world, 9, FLOOR, 10), "not under the roof")
		t.ok(Fire.nearRain(world, 11, FLOOR, 10), "but beside the roof's edge it is")
		-- Spreading: with rolls that light everything they can, the rain stops it.
		local function spread(): number
			local w, tk = newWorld()
			w:setBlock(-20, FLOOR, 0, B.Planks)
			w:setBlock(-21, FLOOR, 0, FIRE)
			-- (The delay, stay, age and six burn-outs: 0.99; then every spread roll lights.)
			Fire.tick(w, tk, -21, FLOOR, 0, scripted({ 0.99, 0.99, 0.99, 0.99, 0.99, 0.99, 0.99, 0.99, 0.99 }, 0))
			local count = 0
			for x = -24, -17 do
				for z = -3, 3 do
					for y = FLOOR, FLOOR + 5 do
						if w:peekBlock(x, y, z) == FIRE then
							count += 1
						end
					end
				end
			end
			return count
		end
		precipitation = 0
		local dry = spread()
		precipitation = 1
		local wet = spread()
		t.ok(dry > 1, `it spreads in dry weather ({dry} fires)`)
		t.eq(wet, 1, "not in the rain")
		Fire.setRain(nil)
	end)

	t.test("rain: zombies don't burn in the rain or a thunderstorm's daylight", function()
		local function getBlock(_x: number, y: number, _z: number): number?
			return if y < FLOOR then STONE else AIR
		end
		local function always(): boolean
			return true
		end
		local function run(rain: boolean, day: boolean): number
			local world = MobWorld.new(getBlock, { maxMobs = 10, forgetTicks = 6000, random = lcg(5) })
			local id = world:spawn(MobList.find("Zombie") :: number, 0.5, FLOOR, 0.5)
			local ctx = {
				players = {},
				dayTime = NOON,
				skyOpen = always,
				skyClear = always,
				active = always,
				rainingAt = function(): boolean
					return rain
				end,
				isDay = function(): boolean
					return day
				end,
			}
			for _ = 1, 200 do
				local mob = world:get(id)
				if mob then
					mob.ai.goal = "idle"
					mob.body.x, mob.body.z = 0.5, 0.5
				end
				world:tick(ctx :: any)
			end
			return (world:get(id) :: MobWorld.Mob).health
		end
		t.ok(run(false, true) < 20, "burns in the sun")
		t.eq(run(true, true), 20, "not in the rain")
		t.eq(run(false, false), 20, "not in a thunderstorm's gloom")
	end)

	--[[ Lightning ]]

	t.test("lightning: the rate near players and where a strike lands", function()
		t.eq(Lightning.chance(0, 20, 1), 0, "no thunder, no strikes")
		t.near(Lightning.chance(1, 20, 1), 0.05, 1e-12, "full thunder: every 20 s")
		t.near(Lightning.chance(0.5, 20, 1), 0.025, 1e-12, "lighter, fewer")
		t.eq(Lightning.chance(1, 0, 1), 0, "off")
		-- Spread evenly within the radius.
		local random = lcg(11)
		local far, total = 0, 0
		for _ = 1, 4000 do
			local dx, dz = Lightning.pick(random, 64)
			local distance = math.sqrt(dx * dx + dz * dz)
			t.ok(distance <= 64, "within the radius")
			total += distance
			if distance > 32 then
				far += 1
			end
		end
		t.near(total / 4000, 64 * 2 / 3, 2, "evenly over the disc")
		t.near(far / 4000, 0.75, 0.03, "three quarters beyond half the radius")

		-- The column's top, or a living thing near it that sees the sky.
		local living: { Lightning.Living } = {}
		local sky = true
		local rain = true
		local view: Lightning.View = {
			top = function(_x: number, _z: number): (number, boolean)
				return 20, true
			end,
			living = function(): { Lightning.Living }
				return living
			end,
			skyOpen = function(): boolean
				return sky
			end,
			raining = function(): boolean
				return rain
			end,
		}
		local x, y, z = Lightning.target(view, 5, 7, random)
		t.eq(x, 5)
		t.eq(y, 20, "the top")
		t.eq(z, 7)
		living = { { x = 8.2, y = 20, z = 7.5, width = 0.6, height = 1.8 } }
		x, y, z = Lightning.target(view, 5, 7, random)
		t.eq(x, 8, "drawn to a player within 3 blocks")
		living = { { x = 12.2, y = 20, z = 7.5, width = 0.6, height = 1.8 } }
		x = Lightning.target(view, 5, 7, random)
		t.eq(x, 5, "not one farther")
		living = { { x = 6.5, y = 10, z = 7.5, width = 0.6, height = 1.8 } }
		x, y = Lightning.target(view, 5, 7, random)
		t.eq(y, 20, "nor one more than 3 below the top")
		living = { { x = 6.5, y = 20, z = 7.5, width = 0.6, height = 1.8 } }
		sky = false
		x = Lightning.target(view, 5, 7, random)
		t.eq(x, 5, "nor one under a roof")
		sky = true
		rain = false
		t.eq((Lightning.target(view, 5, 7, random)), nil, "no strike where it doesn't rain")
	end)

	t.test("lightning: fires by Minecraft's rules and who it hurts", function()
		local world = newWorld()
		local function getBlock(x: number, y: number, z: number): number?
			return world:peekBlock(x, y, z)
		end
		local cells = Lightning.fireCells(getBlock, 0, FLOOR, 0, 1, lcg(1))
		t.eq(#cells, 1, "easy: the struck cell only")
		t.eq(cells[1][2], FLOOR)
		local many = 0
		local random = lcg(2)
		for _ = 1, 50 do
			for _, cell in Lightning.fireCells(getBlock, 0, FLOOR, 0, 2, random) do
				t.eq(getBlock(cell[1], cell[2], cell[3]), AIR, "into air")
				t.ok(cell[2] == FLOOR, "where fire can stay (on the stone)")
				many += 1
			end
		end
		t.ok(many > 50 * 2, `normal: more cells around it ({many / 50} a strike)`)
		world:setBlock(30, FLOOR, 0, B.ShortGrass)
		t.eq(#Lightning.fireCells(getBlock, 30, FLOOR, 0, 1, lcg(1)), 0, "not into a plant's cell")
		-- Reach: x +- 3, y - 3 .. y + 9.
		t.ok(Lightning.hits(0.5, 10, 0.5, 2.5, 10, 0.5, 0.6, 1.8), "near")
		t.ok(Lightning.hits(0.5, 10, 0.5, 3.7, 10, 0.5, 0.6, 1.8), "its box just in")
		t.ok(not Lightning.hits(0.5, 10, 0.5, 4.5, 10, 0.5, 0.6, 1.8), "too far")
		t.ok(Lightning.hits(0.5, 10, 0.5, 0.5, 18, 0.5, 0.6, 1.8), "above")
		t.ok(not Lightning.hits(0.5, 10, 0.5, 0.5, 20, 0.5, 0.6, 1.8), "too high")
		t.ok(not Lightning.hits(0.5, 10, 0.5, 0.5, 5, 0.5, 0.6, 1.8), "too low")
		-- Mobs: 5 half hearts and 8 s of fire (a burning one burns a tick longer).
		local function ground(_x: number, y: number, _z: number): number?
			return if y < FLOOR then STONE else AIR
		end
		local mobs = MobWorld.new(ground, { maxMobs = 10, forgetTicks = 6000, random = lcg(3) })
		local cow = mobs:spawn(MobList.find("Cow") :: number, 1.5, FLOOR, 0.5)
		local far = mobs:spawn(MobList.find("Cow") :: number, 20.5, FLOOR, 0.5)
		t.eq(mobs:lightning(0.5, FLOOR, 0.5, Config.Weather.Lightning.Damage, 160), 1, "one reached")
		local hit = mobs:get(cow) :: MobWorld.Mob
		t.eq(hit.health, 10 - Config.Weather.Lightning.Damage, "5 half hearts")
		t.eq(hit.burn.fire, 160, "8 s of fire")
		t.eq((mobs:get(far) :: MobWorld.Mob).health, 10, "the far one untouched")
		t.eq(Config.Weather.Lightning.Damage, 5, "Minecraft's thunderHit")
	end)

	t.test("lightning: rain puts out who it set on fire; strikes are the area's; a pillar draws them", function()
		local Burning = require(server.Players.Burning)
		local SURVIVAL = "survival"
		-- A player struck in the rain: 8 s of fire set, out on the next tick (Minecraft's
		-- isInWaterRainOrBubble), so the strike costs its 5 half hearts, not 13.
		local function burnt(rain: boolean): number
			local state = Burning.newPlayer()
			Burning.hurtPlayer(state, SURVIVAL, Config.Weather.Lightning.Damage)
			Burning.ignite(state, SURVIVAL, Config.Weather.Lightning.BurnSeconds)
			local total = 0
			for _ = 1, 200 do
				local touching = if rain and state.fire > 0 then Burning.RAIN else 0
				total += Burning.tickPlayer(state, SURVIVAL, touching)
			end
			return total
		end
		t.eq(burnt(true), 0, "rain: no burning after the strike")
		t.ok(burnt(false) >= 7, `dry: it burns on ({burnt(false)} half hearts)`)
		local state = Burning.newPlayer()
		state.fire = 100
		local _, extinguished = Burning.tickPlayer(state, SURVIVAL, Burning.RAIN)
		t.eq(state.fire, 0)
		t.eq(extinguished, true, "the sizzle")
		t.ok(
			Burning.inRain(function(_x, y, _z)
				return y == 11
			end, 0.5, 10, 0.5, 1.8),
			"rain on the head counts"
		)
		-- A mob struck in the rain, and a zombie burning by day when a storm reaches it.
		local function ground(_x: number, y: number, _z: number): number?
			return if y < FLOOR then STONE else AIR
		end
		local function always(): boolean
			return true
		end
		local function context(rain: boolean, day: boolean): any
			return {
				players = {},
				dayTime = NOON,
				skyOpen = always,
				skyClear = always,
				active = always,
				rainingAt = function(): boolean
					return rain
				end,
				isDay = function(): boolean
					return day
				end,
			}
		end
		local mobs = MobWorld.new(ground, { maxMobs = 10, forgetTicks = 6000, random = lcg(3) })
		local cow = mobs:spawn(MobList.find("Cow") :: number, 0.5, FLOOR, 0.5)
		mobs:lightning(0.5, FLOOR, 0.5, Config.Weather.Lightning.Damage, 160)
		for _ = 1, 200 do
			mobs:tick(context(true, false))
		end
		local struck = mobs:get(cow) :: MobWorld.Mob
		t.eq(struck.burn.fire, 0, "out in the rain")
		t.eq(struck.health, 10 - Config.Weather.Lightning.Damage, "only the strike's 5")
		local zombies = MobWorld.new(ground, { maxMobs = 10, forgetTicks = 6000, random = lcg(4) })
		local zombie = zombies:spawn(MobList.find("Zombie") :: number, 0.5, FLOOR, 0.5)
		local burning = zombies:get(zombie) :: MobWorld.Mob
		burning.burn.fire = 160
		zombies:tick(context(true, true))
		t.eq((zombies:get(zombie) :: MobWorld.Mob).burn.fire, 0, "a storm reaching a burning zombie puts it out")

		-- Eight players at one base draw the strikes one would; two far apart, twice as many.
		local settings = Config.Weather.Lightning
		local function strikes(players: { Lightning.Roller }, seconds: number, seed: number): number
			-- (Luau's generator: the small LCG's rolls in a row are too alike for these counts.)
			math.randomseed(seed)
			local function random(): number
				return math.random()
			end
			local count = 0
			for _ = 1, seconds do
				count += #Lightning.roll(players, settings.MeanSeconds, settings.Radius, 1, random)
			end
			return count
		end
		local SECONDS = 20000
		local one = strikes({ { x = 0, z = 0, thunder = 1 } }, SECONDS, 1)
		local together = {}
		for i = 1, 8 do
			table.insert(together, { x = i * 0.7, z = -i * 0.4, thunder = 1 })
		end
		local eight = strikes(together, SECONDS, 2)
		local apart = strikes({ { x = 0, z = 0, thunder = 1 }, { x = 1000, z = 0, thunder = 1 } }, SECONDS, 3)
		print(`    strikes in {SECONDS} s: one player {one}, eight together {eight}, two apart {apart}`)
		t.near(one, SECONDS / settings.MeanSeconds, SECONDS / settings.MeanSeconds * 0.1, "one every 20 s")
		t.near(eight / one, 1, 0.15, "eight together: the same strikes per area")
		t.near(apart / one, 2, 0.25, "two apart: each their own")

		-- One standing on a 20 block pillar 2 blocks beside the column (sees the sky): struck.
		local living = { { x = 7.5, y = 40, z = 7.5, width = 0.6, height = 1.8 } }
		local view: Lightning.View = {
			top = function(): (number, boolean)
				return 20, true
			end,
			living = function(x: number, y: number, z: number, radius: number): { Lightning.Living }
				local near = {}
				for _, thing in living do
					local dx, dy, dz = thing.x - x, thing.y - y, thing.z - z
					if dx * dx + dy * dy + dz * dz <= radius * radius then
						table.insert(near, thing)
					end
				end
				return near
			end,
			skyOpen = always,
			raining = always,
		}
		local x, y = Lightning.target(view, 5, 7, lcg(9))
		t.eq(x, 7, "drawn to the one on the pillar")
		t.eq(y, 40)
		living = { { x = 7.5, y = Config.WorldHeight + 10, z = 7.5, width = 0.6, height = 1.8 } }
		x, y = Lightning.target(view, 5, 7, lcg(9))
		t.eq(y, 20, "not past the build height (Minecraft's box)")
	end)

	t.test("lightning: the Lightning message", function()
		local bolt = { x = -1234.5, y = 87, z = 999.5, seed = 4000000000, flashes = 3 }
		local decoded = Protocol.decodeLightning(Protocol.encodeLightning(bolt)) :: Protocol.LightningBolt
		t.eq(decoded.x, bolt.x)
		t.eq(decoded.y, bolt.y)
		t.eq(decoded.z, bolt.z)
		t.eq(decoded.seed, bolt.seed)
		t.eq(decoded.flashes, 3)
		t.eq(Protocol.ServerMessage.Lightning, 25, "appended")
		local function malformed(change: (buffer) -> ()): boolean
			local b = Protocol.encodeLightning(bolt)
			change(b)
			return Protocol.decodeLightning(b) == nil
		end
		t.ok(
			malformed(function(b)
				buffer.writeu8(b, 16, 0)
			end),
			"no flash"
		)
		t.ok(
			malformed(function(b)
				buffer.writeu8(b, 16, 4)
			end),
			"too many"
		)
		t.ok(
			malformed(function(b)
				buffer.writef32(b, 0, 0 / 0)
			end),
			"NaN"
		)
		t.ok(
			malformed(function(b)
				buffer.writef32(b, 8, 1e9)
			end),
			"too far"
		)
		t.eq(Protocol.decodeLightning(buffer.create(16)), nil, "short")
		local flashes, seed = Lightning.bolt(scripted({ 0.99, 0.5 }, 0))
		t.eq(flashes, 3, "1 to 3 flashes")
		t.ok(seed >= 0 and seed < 4294967296, "a u32 seed")
	end)
end
