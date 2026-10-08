--[[
	Distant storms (client Weather/DistantStorms, pure; SoundRules.acquireQuietest; the sounds they
	add): the schedule is the same for every client that evaluates it (the same flashes from the
	same seed and period, wherever each camera is), its rate follows the thunder (none below
	MinThunder, none in clear weather or with the weather off), the PerMinute cap thins a busy sky
	(Fast's flashes a subset of Fancy's), no bolt strikes near players (an in-cloud flash instead)
	or where it does not rain, the share of bolts; on a real seed every flash stands in thunder and
	the rate matches the plan's own expectation; how bolt width and brightness, the sky's flash,
	thunder's volume, delay, pitch and muffling scale with distance; the distant voices' cap; the
	distant rain's hiss and its blend with the rain here; and what sampling and planning cost.
]]

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Sounds = require(shared.Sounds)
	local SoundList = require(shared.Sounds.SoundList)
	local Weather = require(shared.Weather)
	local DistantStorms = require(client.Weather.DistantStorms)
	local LightningBolt = require(client.Weather.LightningBolt)
	local SoundRules = require(client.Audio.SoundRules)

	local SEED = 12345
	local FANCY, FAST = 2, 1
	local field = Weather.new(SEED)

	-- A sampler giving thunder `thunder` (and that much rain) everywhere.
	local function constant(thunder: number)
		return function(_x0: number, _z0: number, _step: number, cols: number, rows: number): buffer
			local out = buffer.create(cols * rows * 3)
			local byte = math.floor(thunder * 255 + 0.5)
			for i = 0, cols * rows - 1 do
				buffer.writeu8(out, i * 3, byte)
				buffer.writeu8(out, i * 3 + 1, byte)
				buffer.writeu8(out, i * 3 + 2, 255)
			end
			return out
		end
	end

	-- Checks for a constant thunder: rain everywhere, nobody near.
	local function flat(thunder: number): DistantStorms.Checks
		return {
			thunder = function()
				return thunder
			end,
			rains = function()
				return true
			end,
			guarded = function()
				return false
			end,
		}
	end

	-- The real field at server time `now` of `state`: its sampler and checks.
	local function real(state: Weather.State, now: number)
		local moment = Weather.momentAt(state, now)
		local sampler = function(x0: number, z0: number, step: number, cols: number, rows: number): buffer
			return field:grid(moment, x0, z0, step, cols, rows)
		end
		local checks: DistantStorms.Checks = {
			thunder = function(x: number, z: number): number
				local _, thunder = field:at(x, z, moment)
				return thunder
			end,
			rains = function()
				return true
			end,
			guarded = function()
				return false
			end,
		}
		return sampler, checks
	end

	-- The flashes of period `period` around (x, z).
	local function flashes(
		settings: DistantStorms.Settings,
		sampler: DistantStorms.Sampler,
		checks: DistantStorms.Checks,
		period: number,
		x: number,
		z: number
	): ({ DistantStorms.Event }, number)
		local grid = DistantStorms.newGrid()
		DistantStorms.prepare(grid, settings, period, x, z)
		local rounds = 0
		while not DistantStorms.fill(grid, settings, sampler, 128) do
			rounds += 1
			assert(rounds < 10000, "the grid fills")
		end
		local out = {}
		local _, perMinute = DistantStorms.plan(settings, grid, SEED, x, z, checks, out)
		return out, perMinute
	end

	local function key(event: DistantStorms.Event): string
		return `{event.time}:{event.x}:{event.z}:{event.seed}:{event.flashes}`
	end

	-- A state with `kind` (/weather) everywhere from server time 10 on.
	local function overridden(kind: string): Weather.State
		local state = Weather.newState(1000, 0, true, true)
		Weather.setOverride(state, kind :: any, 1e7, 10)
		return state
	end

	--[[ Schedule ]]

	t.test("distant storms: the same flashes for every client, wherever its camera", function()
		local settings = DistantStorms.settings(FANCY, 2048, false)
		settings.perPeriod = math.huge
		local state = overridden(Weather.THUNDER)
		local shared, total = 0, 0
		for period = 100, 140 do
			local sampler, checks = real(state, period * settings.period)
			local a = flashes(settings, sampler, checks, period, 0, 0)
			local again = flashes(settings, sampler, checks, period, 0, 0)
			t.eq(#again, #a, "evaluated twice: the same")
			for i, event in a do
				t.eq(key(again[i]), key(event))
				t.ok(
					event.time >= period * settings.period and event.time < (period + 1) * settings.period,
					"in its period"
				)
			end
			-- Another client 1000 blocks off sees the same flashes where both reach.
			local b = flashes(settings, sampler, checks, period, 1000, 300)
			local seen: { [string]: boolean } = {}
			for _, event in b do
				seen[key(event)] = true
			end
			for _, event in a do
				local dx, dz = event.x - 1000, event.z - 300
				if math.sqrt(dx * dx + dz * dz) <= settings.reach then
					total += 1
					if seen[key(event)] then
						shared += 1
					end
				end
			end
		end
		t.ok(total > 50, `flashes both see ({total})`)
		t.eq(shared, total, "every flash in both reaches is the same for both")
		-- Another world, other flashes.
		local sampler, checks = real(state, 100 * settings.period)
		local grid = DistantStorms.newGrid()
		DistantStorms.prepare(grid, settings, 100, 0, 0)
		while not DistantStorms.fill(grid, settings, sampler, 4096) do
		end
		local mine, theirs = {}, {}
		DistantStorms.plan(settings, grid, SEED, 0, 0, checks, mine)
		DistantStorms.plan(settings, grid, SEED + 1, 0, 0, checks, theirs)
		local same = 0
		local keys = {}
		for _, event in mine do
			keys[key(event)] = true
		end
		for _, event in theirs do
			if keys[key(event)] then
				same += 1
			end
		end
		t.eq(same, 0, "another seed's flashes are its own")
	end)

	t.test("distant storms: the rate follows the thunder: Rate a minute per km^2 at full", function()
		local settings = DistantStorms.settings(FANCY, 2048, false)
		settings.perPeriod = math.huge
		local area = math.pi * settings.reach * settings.reach / 1e6
		local periods = 150
		local function perMinute(thunder: number): (number, number)
			local count, expected = 0, 0
			for period = 1, periods do
				local list, planned = flashes(settings, constant(thunder), flat(thunder), period, 0, 0)
				count += #list
				expected += planned
			end
			return count / (periods * settings.period / 60), expected / periods
		end
		local full, plannedFull = perMinute(1)
		local wanted = Config.Weather.Distant.Rate * area
		t.ok(math.abs(full - wanted) / wanted < 0.1, `full thunder: {full} a minute (wanted {wanted})`)
		t.ok(math.abs(plannedFull - wanted) / wanted < 0.03, `the plan expects {plannedFull}`)
		local half = (Config.Weather.Distant.MinThunder + 1) / 2
		local partial = perMinute(half)
		t.ok(math.abs(partial / full - 0.5) < 0.1, `half the weight, half the flashes ({partial / full})`)
		t.eq((perMinute(Config.Weather.Distant.MinThunder)), 0, "none at MinThunder")
		t.eq((perMinute(0)), 0, "none without thunder")
		t.eq(DistantStorms.weight(settings, 1), 1)
		t.eq(DistantStorms.weight(settings, 0.1), 0)
		t.near(DistantStorms.weight(settings, half), 0.5, 1e-9)
	end)

	t.test("distant storms: none in clear weather, rain without thunder or with the weather off", function()
		local settings = DistantStorms.settings(FANCY, 4096, false)
		for _, state in
			{
				overridden(Weather.CLEAR),
				overridden(Weather.RAIN),
				Weather.newState(1000, 0, true, false),
			}
		do
			local count = 0
			for period = 50, 80 do
				local sampler, checks = real(state, period * settings.period)
				count += #flashes(settings, sampler, checks, period, 5000, -7000)
			end
			t.eq(count, 0, "no flashes")
		end
	end)

	t.test("distant storms: a busy sky is capped at PerMinute, Fast's flashes are Fancy's", function()
		local fancy = DistantStorms.settings(FANCY, 2048, false)
		local fast = DistantStorms.settings(FAST, 2048, false)
		t.ok(fast.perPeriod < fancy.perPeriod and fast.bolts < fancy.bolts, "Fast: fewer")
		local state = overridden(Weather.THUNDER)
		local fancyCount, fastCount, inside = 0, 0, 0
		local periods = 200
		for period = 1000, 1000 + periods - 1 do
			local sampler, checks = real(state, period * fancy.period)
			local many, planned = flashes(fancy, sampler, checks, period, 0, 0)
			local few = flashes(fast, sampler, checks, period, 0, 0)
			t.near(planned, Config.Weather.Distant.PerMinute, 1e-6, "the plan expects the cap")
			local keys = {}
			for _, event in many do
				keys[key(event)] = true
			end
			for _, event in few do
				if keys[key(event)] then
					inside += 1
				end
			end
			fancyCount += #many
			fastCount += #few
		end
		local minutes = periods * fancy.period / 60
		t.ok(
			math.abs(fancyCount / minutes - Config.Weather.Distant.PerMinute) < 3,
			`Fancy {fancyCount / minutes} a minute under thunder everywhere`
		)
		t.ok(
			math.abs(fastCount / minutes - Config.Weather.Distant.FastPerMinute) < 2,
			`Fast {fastCount / minutes} a minute`
		)
		t.eq(inside, fastCount, "every one of Fast's flashes is one of Fancy's")
	end)

	t.test("distant storms: no bolt near players or the camera, or where it does not rain", function()
		local settings = DistantStorms.settings(FANCY, 2048, false)
		settings.perPeriod = math.huge
		local player = { x = 300, z = -200 }
		local checks = flat(1)
		checks.guarded = function(x: number, z: number): boolean
			local dx, dz = x - player.x, z - player.z
			return dx * dx + dz * dz <= settings.guard * settings.guard
		end
		local ground, cloud, nearPlayer, nearCamera = 0, 0, 0, 0
		local cloudNear = 0
		for period = 1, 600 do
			for _, event in flashes(settings, constant(1), checks, period, 0, 0) do
				local dp = math.sqrt((event.x - player.x) ^ 2 + (event.z - player.z) ^ 2)
				local dc = math.sqrt(event.x ^ 2 + event.z ^ 2)
				if event.ground then
					ground += 1
					if dp <= settings.guard then
						nearPlayer += 1
					end
					if dc < settings.minDistance then
						nearCamera += 1
					end
				else
					cloud += 1
					if dp <= settings.guard or dc < settings.minDistance then
						cloudNear += 1
					end
				end
			end
		end
		t.eq(nearPlayer, 0, "no bolt within the guard of a player in thunder")
		t.eq(nearCamera, 0, "none within MinDistance of the camera")
		t.ok(cloudNear > 0, "they flash in the cloud there instead")
		local share = ground / (ground + cloud)
		t.ok(math.abs(share - Config.Weather.Distant.GroundShare) < 0.04, `{share} of them are bolts (GroundShare)`)
		t.eq(settings.guard, Config.Weather.Lightning.Radius + Config.Weather.Distant.Margin)
		-- No rain there (snow, a desert): no bolts at all.
		local dry = flat(1)
		dry.rains = function()
			return false
		end
		local bolts = 0
		for period = 1, 100 do
			for _, event in flashes(settings, constant(1), dry, period, 0, 0) do
				if event.ground then
					bolts += 1
				end
			end
		end
		t.eq(bolts, 0, "no bolt where no rain falls")
	end)

	t.test("distant storms: on a real seed every flash stands in thunder, as often as planned", function()
		local settings = DistantStorms.settings(FANCY, 2048, false)
		local state = Weather.newState(0, 0, true, true)
		local count, expected, periods, worst = 0, 0, 0, -math.huge
		local state32 = 99
		local function nextNumber(a: number, b: number): number
			state32 = (state32 * 1103515245 + 12345) % 2147483648
			return a + (b - a) * state32 / 2147483648
		end
		-- (Places and times with thunder near: a storm's lightning, not clear skies' none.)
		while periods < 300 do
			local x, z = nextNumber(-100000, 100000), nextNumber(-100000, 100000)
			local period = math.floor(nextNumber(0, 24000 * 40 / 20 / settings.period))
			local now = period * settings.period
			local moment = Weather.momentAt(state, now)
			local _, thunder = field:at(x + 600, z, moment)
			if thunder < 0.3 then
				continue
			end
			periods += 1
			local sampler, checks = real(state, now)
			-- (Over several periods while the storm stands about there.)
			for step = 0, 9 do
				local list, planned = flashes(settings, sampler, checks, period + step, x, z)
				count += #list
				expected += planned * settings.period / 60
				for _, event in list do
					local _, there = field:at(event.x, event.z, moment)
					worst = math.max(worst, settings.minThunder - there)
					local d = math.sqrt((event.x - x) ^ 2 + (event.z - z) ^ 2)
					t.ok(d <= settings.reach, "within reach")
				end
			end
		end
		t.ok(worst < 0, `every flash where the thunder is over MinThunder ({worst})`)
		-- (The plan's expectation is its bound's; the flashes follow the thunder at the point, a
		-- little less.)
		t.ok(count > 0.6 * expected and count <= 1.05 * expected, `{count} flashes, {expected} planned`)
		print(
			string.format(
				"    real seed: %d flashes in %d minutes of storms in view (%.1f a minute)",
				count,
				periods * 10 * settings.period / 60,
				count / (periods * 10 * settings.period / 60)
			)
		)
	end)

	t.test("distant storms: reach, view and hearing by the device and setting", function()
		local desktop = DistantStorms.settings(FANCY, 2048, false)
		t.eq(desktop.reach, 2048)
		t.eq(desktop.hearing, Config.Weather.Distant.Hearing)
		t.eq(desktop.voices, Config.Weather.Distant.Voices)
		local ultra = DistantStorms.settings(FANCY, 4096, false)
		t.eq(ultra.reach, 4096, "Ultra sees flashes out to 4096")
		t.eq(ultra.hearing, 2048, "and hears them to 2048: heat lightning past it")
		local phone = DistantStorms.settings(FAST, 512, true)
		t.eq(phone.view, 512)
		t.eq(phone.reach, Config.Weather.Distant.MobileHearing, "heard farther than seen")
		t.eq(phone.voices, Config.Weather.Distant.MobileVoices)
		t.eq(phone.bolts, Config.Weather.Distant.FastBolts)
	end)

	--[[ Seen ]]

	t.test("distant storms: far bolts are about two pixels wide and outshine the haze", function()
		t.eq(DistantStorms.boltWidth(0), LightningBolt.WIDTH, "Minecraft's width near")
		t.eq(DistantStorms.boltWidth(100), LightningBolt.WIDTH)
		for _, distance in { 512, 1024, 2048, 4096 } do
			local pixels = DistantStorms.boltWidth(distance) / (distance * DistantStorms.PIXEL)
			t.ok(pixels >= 1.9 and pixels <= 2.2, `{pixels} px at {distance} blocks`)
		end
		t.eq(DistantStorms.brightness(1), 1, "no haze, no boost")
		t.near(DistantStorms.brightness(0.25), 4, 1e-9, "a quarter through: four times")
		t.eq(DistantStorms.brightness(0), Config.Weather.Distant.MaxBrightness, "capped")
		-- The bolt reaches the clouds.
		t.near(DistantStorms.boltScale(64, 64 + LightningBolt.HEIGHT * 2), 2, 1e-9)
		t.eq(DistantStorms.boltScale(300, 310), 0.5, "at least half Minecraft's")
	end)

	t.test("distant storms: the sky's flash fades with distance, by day and in the cloud", function()
		local near = DistantStorms.skyFlash(0, true, 0)
		t.eq(near, 1, "a bolt at night, here: the whole flash")
		t.near(DistantStorms.skyFlash(512, true, 0), 0.5, 1e-9, "half at 512 blocks")
		local last = 2
		for _, distance in { 0, 256, 1024, 2048, 4096 } do
			local value = DistantStorms.skyFlash(distance, true, 0)
			t.ok(value < last, "fainter farther")
			last = value
		end
		t.near(
			DistantStorms.skyFlash(1024, true, 1),
			DistantStorms.skyFlash(1024, true, 0) * Config.Weather.Distant.DayFlash,
			1e-9,
			"by day"
		)
		t.near(
			DistantStorms.skyFlash(1024, false, 0),
			DistantStorms.skyFlash(1024, true, 0) * Config.Weather.Distant.InCloudFlash,
			1e-9,
			"in the cloud"
		)
	end)

	--[[ Heard ]]

	t.test("distant storms: thunder comes later, fainter, lower and muffled with distance", function()
		local hearing = Config.Weather.Distant.Hearing
		t.near(Weather.thunderDelay(2048), 2048 / 343, 1e-9, "6 s from 2 km")
		t.eq(DistantStorms.thunderVolume(0, hearing), 1)
		t.near(DistantStorms.thunderVolume(Config.Weather.Distant.HalfVolume, hearing), 0.5, 1e-9, "half at HalfVolume")
		t.eq(DistantStorms.thunderVolume(hearing, hearing), 0, "gone at the hearing's edge")
		t.eq(DistantStorms.thunderVolume(hearing * 2, hearing), 0)
		local last = 2
		for distance = 0, hearing, 128 do
			local volume = DistantStorms.thunderVolume(distance, hearing)
			t.ok(volume < last or volume == 0, `fainter at {distance}`)
			last = volume
		end
		t.ok(DistantStorms.thunderVolume(256, hearing) > 0.85, "near strikes as loud as before")
		t.eq(DistantStorms.thunderPitch(0, hearing), 1)
		t.near(DistantStorms.thunderPitch(hearing, hearing), 1 - Config.Weather.Distant.Deepen, 1e-9, "lower far")
		local low, mid, high = DistantStorms.muffle(Config.Weather.Distant.Near)
		t.eq(mid, 0)
		t.eq(high, 0, "no muffling near")
		t.ok(low >= 0)
		local lastMid, lastHigh = 1, 1
		for _, distance in { 384, 512, 1024, 1536 } do
			low, mid, high = DistantStorms.muffle(distance)
			t.ok(high < lastHigh and mid < lastMid and high < mid, `highs go first at {distance}`)
			lastMid, lastHigh = mid, high
		end
		low, mid, high = DistantStorms.muffle(100000)
		t.eq(high, -Config.Weather.Distant.HighFloor)
		t.eq(mid, -Config.Weather.Distant.MidFloor)
		t.eq(low, Config.Weather.Distant.Low, "the rumble's lows")
		t.eq(DistantStorms.echoes(100), 0)
		t.eq(DistantStorms.echoes(Config.Weather.Distant.Echo.From), 1, "rolls on far off")
	end)

	t.test("distant storms: a few distant voices, the quietest giving way", function()
		local pool = SoundRules.newPool(3)
		local loudness = {}
		t.eq(SoundRules.acquireQuietest(pool, loudness, 2, 0.5, 0), 1, "a free voice")
		t.eq(SoundRules.acquireQuietest(pool, loudness, 2, 0.8, 0), 2)
		t.eq(SoundRules.acquireQuietest(pool, loudness, 2, 0.3, 0), nil, "the limit: a quieter one waits")
		t.eq(SoundRules.acquireQuietest(pool, loudness, 2, 0.6, 0), 1, "a louder one cuts the quietest")
		t.eq(loudness[1], 0.6)
		-- A rumble dies away: an old loud one gives way to a fresh quieter one.
		local later = SoundRules.DISTANT_HALF_LIFE * 2
		t.eq(SoundRules.acquireQuietest(pool, loudness, 2, 0.25, later), 1, "0.6 two half-lives on is 0.15")
		SoundRules.release(pool, 2)
		t.eq(SoundRules.acquireQuietest(pool, loudness, 2, 0.01, later), 2, "freed")
		t.eq(SoundRules.acquireQuietest(pool, loudness, 3, 0.01, later), 3, "a higher limit, a third")
	end)

	t.test("distant storms: their sounds are in the catalogue, last, played by the client", function()
		local list = SoundList.EVENTS
		t.eq(list[#list - 1].name, "entity.lightning_bolt.thunder.far")
		t.eq(list[#list].name, "weather.rain.far")
		for _, name in { "entity.lightning_bolt.thunder.far", "weather.rain.far" } do
			local event = Sounds.get(Sounds.id[name]) :: any
			t.eq(event.side, "client")
			t.eq(event.source, "ambient", "the weather's volume")
		end
		local far = Sounds.get(Sounds.id["entity.lightning_bolt.thunder.far"]) :: any
		local near = Sounds.get(Sounds.id["entity.lightning_bolt.thunder"]) :: any
		t.eq(far.category, "entity.lightning_bolt.thunder", "a developer's thunder plays far too")
		t.ok(far.pitch < near.pitch, "lower than near thunder")
		t.eq(SoundRules.capOf("weather.rain.far"), 1)
	end)

	--[[ Rain ]]

	t.test("distant storms: rain nearby hisses from its side and gives way to the rain here", function()
		local points = DistantStorms.rainPoints()
		local rain = Config.Weather.Distant.Rain
		t.eq(#points, #rain.Rings * rain.Directions)
		for _, point in points do
			t.ok(point.weight > 0 and point.weight < 1, "weighted by distance")
		end
		-- Nothing falls: silence.
		local level, dx, dz = DistantStorms.hiss(points, function()
			return 0
		end)
		t.eq(level, 0)
		t.eq(dx, 0)
		t.eq(dz, 0)
		-- Rain to the east only.
		level, dx, dz = DistantStorms.hiss(points, function(x: number)
			return if x > 30 then 1 else 0
		end)
		t.ok(level > 0, "heard")
		t.ok(dx > 0.6 and math.abs(dz) < 0.1, `from the east ({dx}, {dz})`)
		-- All around: from nowhere in particular.
		local around, ax, az = DistantStorms.hiss(points, function()
			return 1
		end)
		t.ok(around >= level, "louder all around")
		t.ok(math.sqrt(ax * ax + az * az) < 0.05, "no side")
		-- Nearer rain is louder.
		local nearLevel = DistantStorms.hiss(points, function(x: number, z: number)
			return if math.sqrt(x * x + z * z) < 30 then 1 else 0
		end)
		local farLevel = DistantStorms.hiss(points, function(x: number, z: number)
			return if math.sqrt(x * x + z * z) > 150 then 1 else 0
		end)
		t.ok(nearLevel > farLevel * 3, `near {nearLevel}, far {farLevel}`)
		-- The rain level: Minecraft's rain sound's.
		t.eq(DistantStorms.rainLevel(Weather.RAINING), 0, "not raining")
		t.eq(DistantStorms.rainLevel(0.25), 0.5)
		t.eq(DistantStorms.rainLevel(1), 1)
		-- The blend: the rain here takes over, indoors it fades.
		t.near(DistantStorms.hissVolume(1, 0, 1), rain.Volume, 1e-9, "dry here: all of it")
		t.near(DistantStorms.hissVolume(1, 0.25, 1), rain.Volume * 0.5, 1e-9, "drizzle here: half")
		t.eq(DistantStorms.hissVolume(1, 0.6, 1), 0, "a downpour here: the near rain alone")
		t.eq(DistantStorms.hissVolume(1, 0.15, 1), rain.Volume, "no rain sound yet here: all of it")
		t.eq(DistantStorms.hissVolume(1, 0, 0), 0, "underground: none")
	end)

	--[[ Cost ]]

	t.test("distant storms: sampling and planning cost", function()
		local settings = DistantStorms.settings(FANCY, 2048, false)
		local clear = overridden(Weather.CLEAR)
		local natural = Weather.newState(0, 0, true, true)
		local storm = overridden(Weather.THUNDER)
		local function measure(state: Weather.State, rounds: number): (number, number, number)
			local fill, plan, cells = 0, 0, 0
			for round = 1, rounds do
				local period = 5000 + round
				local sampler, checks = real(state, period * settings.period)
				local grid = DistantStorms.newGrid()
				DistantStorms.prepare(grid, settings, period, round * 977, -round * 613)
				cells = grid.cols * grid.rows
				local start = os.clock()
				while not DistantStorms.fill(grid, settings, sampler, 128) do
				end
				fill += os.clock() - start
				start = os.clock()
				DistantStorms.plan(settings, grid, SEED, round * 977, -round * 613, checks, {})
				plan += os.clock() - start
			end
			return fill / rounds * 1000, plan / rounds * 1000, cells
		end
		local fillClear, planClear, cells = measure(clear, 30)
		local _, planNatural = measure(natural, 30)
		local fillStorm, planStorm = measure(storm, 30)
		print(
			string.format(
				"    2048 reach, %d cells: sampling %.2f ms a period (%.2f us a cell), planning %.3f ms clear,"
					.. " %.3f ms in random weather, %.2f ms under /weather thunder",
				cells,
				fillClear,
				fillClear * 1000 / cells,
				planClear,
				planNatural,
				planStorm
			)
		)
		t.eq(cells, 35 * 35, "35 x 35 cells at a 2048 reach")
		t.ok(fillClear < 5 and fillStorm < 5, "sampling a period under 5 ms (spread over its frames)")
		t.ok(planClear < 1, "planning a clear sky under 1 ms")
		t.ok(planStorm < 15, "planning thunder everywhere under 15 ms (once a period)")
	end)
end
