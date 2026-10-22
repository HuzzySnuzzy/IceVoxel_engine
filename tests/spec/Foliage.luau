--[[
	Foliage colours by season (Shared/Seasons/Foliage over Config.Seasons.Foliage): the seasonal
	appearances and their palettes, CIELAB and ΔE76, the steps (consecutive steps never differ by
	more than ΔE76 2.5, for every seasonal appearance and biome class, all year and across the
	year's end), keyframes wrapping, keep 1 giving the authored colours, the biome class overrides
	(dry grass yellows in summer, tropical biomes keep their colours), snow dust by class, the far
	steps and drift, and no targets at all while the foliage does not follow the seasons.
]]

return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local Calendar = require(shared.Seasons.Calendar)
	local SeasonClimate = require(shared.Seasons.SeasonClimate)
	local Foliage = require(shared.Seasons.Foliage)

	local B = Blocks.id
	local Settings = Config.Seasons.Foliage

	local function app(name: string): number
		return Blocks.get(B[name]).appearance
	end

	local function state(): any
		local s = Calendar.newState()
		s.enabled = true
		return s
	end

	local function authored(name: string): { number }
		return Blocks.get(B[name]).color
	end

	local function class(name: string): number
		return Foliage.classIndex(name)
	end

	t.test("foliage: the seasonal appearances, their kinds and palettes", function()
		t.eq(Foliage.kindOf(app("Grass")), Foliage.GRASS)
		t.eq(Foliage.kindOf(app("DryGrass")), Foliage.GRASS)
		for _, name in { "OakLeaves", "BirchLeaves", "SpruceLeaves", "AcaciaLeaves", "JungleLeaves" } do
			t.eq(Foliage.kindOf(app(name)), Foliage.LEAVES, name)
		end
		t.eq(Foliage.foliageOf(app("OakLeaves")), "deciduous")
		t.eq(Foliage.foliageOf(app("AcaciaLeaves")), "deciduous")
		t.eq(Foliage.foliageOf(app("BirchLeaves")), "birch")
		t.eq(Foliage.foliageOf(app("SpruceLeaves")), "evergreen")
		t.eq(Foliage.foliageOf(app("JungleLeaves")), "tropical")
		for _, name in { "ShortGrass", "Fern", "TallGrass", "TallGrassTop", "LargeFern", "LargeFernTop" } do
			t.eq(Foliage.kindOf(app(name)), Foliage.PLANT, name)
			t.eq(Foliage.foliageOf(app(name)), "grass", name)
		end
		t.eq(Foliage.kindOf(app("Vine")), Foliage.VINE)
		t.eq(Foliage.kindOf(app("VineNorth")), Foliage.VINE)
		for _, name in { "Stone", "Dirt", "OakLog", "Sand", "Water", "Poppy", "SnowLayer1" } do
			t.ok(not Foliage.isSeasonal(app(name)), `{name} keeps its colours`)
			t.eq(Foliage.colour(app(name), "temperate", 0.1, 0), nil)
		end
		-- Every tinted plant is seasonal; the list is sorted and complete.
		local list = Foliage.appearances()
		for i = 2, #list do
			t.ok(list[i - 1] < list[i], "ascending")
		end
		for _, info in Blocks.appearances do
			if info.tinted then
				t.ok(table.find(list, info.id) ~= nil, "tinted plants follow the grass palette")
			end
		end
	end)

	t.test("foliage: CIELAB round trips and ΔE76", function()
		for _, c in { { 0, 0, 0 }, { 255, 255, 255 }, { 92, 158, 62 }, { 210, 110, 40 }, { 236, 240, 246 } } do
			local l, a, b = Foliage.toLab(c)
			local back = Foliage.fromLab(l, a, b)
			for k = 1, 3 do
				t.near(back[k], c[k], 1e-3, "round trip")
			end
		end
		local l = Foliage.toLab({ 255, 255, 255 })
		t.near(l, 100, 1e-3, "white is L 100")
		t.near(Foliage.deltaE({ 10, 20, 30 }, { 10, 20, 30 }), 0, 1e-9)
		t.ok(Foliage.deltaE({ 0, 0, 0 }, { 255, 255, 255 }) > 99, "black to white")
	end)

	t.test("foliage: consecutive steps differ by at most ΔE76 2.5, all year and over the year's end", function()
		local s = state()
		local year = s.lengths[1] + s.lengths[2] + s.lengths[3] + s.lengths[4]
		local steps = math.round(year / Foliage.stepDays())
		t.eq(steps, 384, "BlendDays / 24 days a step: 12 a day")
		local function copy(targets: any): any
			local out = {}
			for index, colours in targets.colours do
				out[index] = {}
				for appearance, c in colours do
					out[index][appearance] = { c[1], c[2], c[3] }
				end
			end
			return out
		end
		local previous = copy(Foliage.targets(Foliage.midpoint(-1), s))
		local worst, where = 0, ""
		local moved = 0
		-- (Two years from a negative step: the year's end is crossed twice.)
		for step = 0, steps * 2 do
			local now = copy(Foliage.targets(Foliage.midpoint(step), s))
			for index, colours in now do
				for appearance, c in colours do
					local d = Foliage.deltaE(previous[index][appearance], c)
					moved += d
					if d > worst then
						worst = d
						where = `{SeasonClimate.CLASSES[index]} appearance {appearance} step {step}`
					end
				end
			end
			previous = now
		end
		t.ok(worst <= Foliage.MAX_STEP_DELTA, `worst step ΔE76 {worst} ({where})`)
		t.ok(worst > 1, "the palettes do move")
		t.ok(moved > 1000, "a year of colour")
	end)

	t.test("foliage: keyframes, keep 1, overrides by biome class, wrapping", function()
		local oak, grass, dry = app("OakLeaves"), app("Grass"), app("DryGrass")
		local temperate = class("temperate")
		-- Autumn's peak: the keyframe's colour itself (keep 0).
		local peak = (Settings.Keyframes :: any).deciduous[2]
		local c = Foliage.colour(oak, temperate, peak.at, 0) :: { number }
		t.ok(Foliage.deltaE(c, peak.colour) < 0.5, "deciduous peak")
		-- Summer: keep 1 is the authored colour.
		for _, name in { "Grass", "DryGrass", "OakLeaves", "BirchLeaves", "SpruceLeaves", "ShortGrass", "Vine" } do
			local summer = Foliage.colour(app(name), temperate, 0.82, 0) :: { number }
			t.ok(Foliage.deltaE(summer, authored(name)) < 0.5, `{name} in summer is authored`)
		end
		-- Tropical biomes keep every colour all year, and jungle leaves everywhere.
		for p = 0, 1, 0.05 do
			for _, name in { "Grass", "OakLeaves", "BirchLeaves", "SpruceLeaves", "JungleLeaves", "Fern" } do
				local kept = Foliage.colour(app(name), "tropical", p, 0) :: { number }
				t.ok(Foliage.deltaE(kept, authored(name)) < 0.5, `{name} kept at {p} in the tropics`)
			end
			local jungle = Foliage.colour(app("JungleLeaves"), temperate, p, 0) :: { number }
			t.ok(Foliage.deltaE(jungle, authored("JungleLeaves")) < 0.5, "jungle leaves keep theirs")
		end
		-- Dry biomes: grass yellows in late summer (more yellow and lighter than temperate grass).
		local dryLate = Foliage.colour(grass, "dry", 0.9, 0) :: { number }
		local temperateLate = Foliage.colour(grass, temperate, 0.9, 0) :: { number }
		local _, _, bDry = Foliage.toLab(dryLate)
		local lDry = Foliage.toLab(dryLate)
		local lTemperate, _, bTemperate = Foliage.toLab(temperateLate)
		t.ok(bDry > bTemperate and lDry > lTemperate, "dry grass yellows")
		t.ok(Foliage.colour(dry, "dry", 0.9, 0) ~= nil, "dry grass blocks too")
		-- Wrapping: just before and after the year's end the colour is continuous.
		local before = Foliage.colour(oak, temperate, 0.99999, 0) :: { number }
		local after = Foliage.colour(oak, temperate, 0.00001, 0) :: { number }
		t.ok(Foliage.deltaE(before, after) < 0.1, "continuous over the year's end")
		t.ok(
			Foliage.deltaE(
				Foliage.colour(oak, temperate, 1.25, 0) :: { number },
				Foliage.colour(oak, temperate, 0.25, 0) :: { number }
			) < 1e-6,
			"p wraps"
		)
		-- Plants scale with the grass palette as their soil's tint does.
		local short = Foliage.colour(app("ShortGrass"), temperate, 0.3, 0) :: { number }
		local grassWinter = Foliage.colour(grass, temperate, 0.3, 0) :: { number }
		t.ok(Foliage.deltaE(short, grassWinter) < 0.5, "short grass is authored in the grass block's green")
		local fern = Foliage.colour(app("Fern"), temperate, 0.3, 0) :: { number }
		local own, base = authored("Fern"), authored("Grass")
		for k = 1, 3 do
			t.near(fern[k], math.min(255, own[k] * grassWinter[k] / base[k]), 1e-6, "fern scaled")
		end
	end)

	t.test("foliage: snow dust by class; none where it is dry or tropical", function()
		local s = state()
		local grass, spruce, oak = app("Grass"), app("SpruceLeaves"), app("OakLeaves")
		-- Mid winter: temperate snow cover 1, whiter (higher L*) than without it.
		local position = Calendar.at(Calendar.seasonStart(Calendar.WINTER, s) + 4, s)
		local p = Foliage.progress(position)
		t.near(p, 0.25 + 4 / 32, 1e-9, "season-relative progress")
		local cover = SeasonClimate.snowCover(position, "temperate")
		t.eq(cover, 1)
		for _, appearance in { grass, spruce, oak } do
			local bare = Foliage.toLab(Foliage.colour(appearance, "temperate", p, 0) :: { number })
			local dusted = Foliage.toLab(Foliage.colour(appearance, "temperate", p, cover) :: { number })
			t.ok(dusted > bare + 10, "dusted white")
		end
		-- Full cover moves each kind its Dust share of the way to the snow's colour (in CIELAB).
		local function whiten(appearance: number): number
			local bare = Foliage.colour(appearance, "temperate", p, 0) :: { number }
			local dusted = Foliage.colour(appearance, "temperate", p, 1) :: { number }
			return 1 - Foliage.deltaE(dusted, Settings.SnowColour) / Foliage.deltaE(bare, Settings.SnowColour)
		end
		t.near(whiten(grass), Settings.Dust.grass, 1e-3, "grass")
		t.near(whiten(oak), Settings.Dust.leaves, 1e-3, "leaves")
		t.near(whiten(spruce), Settings.Dust.evergreen, 1e-3, "evergreen")
		-- Targets take each class's cover: cold early, dry and tropical never.
		local lateAutumn = Calendar.seasonStart(Calendar.WINTER, s) - 0.5
		local targets = Foliage.targets(lateAutumn, s) :: any
		t.ok(targets.covers[class("cold")] > 0.5, "cold biomes white before winter")
		t.eq(targets.covers[class("temperate")], 0)
		local midWinter = Foliage.targets(Calendar.seasonStart(Calendar.WINTER, s) + 4, s) :: any
		t.eq(midWinter.covers[class("dry")], 0)
		t.eq(midWinter.covers[class("tropical")], 0)
		t.ok(
			Foliage.deltaE(midWinter.colours[class("tropical")][grass], authored("Grass")) < 0.5,
			"tropical grass green in winter"
		)
		t.ok(
			Foliage.toLab(midWinter.colours[class("temperate")][grass])
				> Foliage.toLab(midWinter.colours[class("dry")][grass]) + 10,
			"temperate grass white, dry grass not"
		)
	end)

	t.test("foliage: steps, far steps and drift", function()
		local s = state()
		t.near(Foliage.stepDays(), Config.Seasons.BlendDays / 24, 1e-12)
		t.eq(Foliage.stepOf(0), 0)
		t.eq(Foliage.stepOf(Foliage.stepDays() * 3.5), 3)
		t.near(Foliage.midpoint(3), Foliage.stepDays() * 3.5, 1e-12)
		t.eq(Foliage.stepOf(-0.0001), -1)
		t.near(Foliage.farStepDays(), Settings.FarStepDays, 1e-12)
		t.eq(Foliage.farStepOf(Settings.FarStepDays * 2.2), 2)
		t.near(Foliage.farMidpoint(2), Settings.FarStepDays * 2.5, 1e-12)
		local autumn = Foliage.targets(Foliage.farMidpoint(5), s)
		local summer = Foliage.targets(Calendar.seasonStart(Calendar.SUMMER, s) + 4, s)
		t.eq(Foliage.drift(nil, nil), 0)
		t.eq(Foliage.drift(autumn, autumn), 0)
		t.ok(Foliage.drift(autumn, summer) > Settings.FarDeltaE, "autumn to summer drifts")
		t.ok(Foliage.drift(nil, autumn) > Settings.FarDeltaE, "autumn is not")
		t.eq(Foliage.drift(autumn, summer, { class("tropical") }), 0, "tropical classes never drift")
		-- Half a day of autumn moves the far palette far less than a whole season.
		local a1 = Foliage.targets(Foliage.farMidpoint(1), s)
		local a2 = Foliage.targets(Foliage.farMidpoint(2), s)
		t.ok(Foliage.drift(a1, a2) < 15, "a far step is small")
	end)

	t.test("foliage: no targets while the foliage does not follow the seasons", function()
		local s = state()
		t.ok(Foliage.active(s))
		t.ok(Foliage.targets(3, s) ~= nil)
		local disabled = Calendar.newState()
		disabled.enabled = false
		t.ok(not Foliage.active(disabled))
		t.eq(Foliage.targets(3, disabled), nil, "calendar off")
		Settings.Enabled = false
		local ok, err = pcall(function()
			t.ok(not Foliage.configured())
			t.eq(Foliage.targets(3, s), nil, "Config.Seasons.Foliage.Enabled false")
		end)
		Settings.Enabled = true
		Config.Seasons.Enabled = false
		local ok2, err2 = pcall(function()
			t.ok(not Foliage.configured())
			t.eq(Foliage.targets(3, s), nil, "Config.Seasons.Enabled false")
		end)
		Config.Seasons.Enabled = true
		assert(ok, err)
		assert(ok2, err2)
	end)
end
