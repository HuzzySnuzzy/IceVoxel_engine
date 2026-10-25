--[[
	Radiation (Mekanism's, simplified: Shared/Radiation, server Players/RadiationRules and
	Players/Radiation, client Audio/Geiger): what is radioactive and how much (the ore, the blocks,
	the items carried by count), the falloff and the shielding (rock, lead, glass, unknown cells;
	the ray cap's mean), the Hazmat suit's shares, the dose building and decaying, the sickness's
	bands and symptoms, the Radiation Sickness effect ticking (its cadence, lethal) and its renewal
	keeping that cadence, the server's look over a fake world and inventory (how play feels: a vein
	mined, a stack carried, a Block of Uranium beside you, a vein far off; creative, the suit, off),
	the scan's bounded and measured cost, the Geiger counter's click rate (a Poisson process at the
	rate asked, capped), what is published and shown, and the dose saved in the player record
	(Save/PlayerCodec version 5) and the character (Save/CharacterCodec version 4).
]]

local fs = require("@lune/fs")

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Effects = require(shared.Effects)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Radiation = require(shared.Radiation)
	local Appearance = require(shared.Characters.Appearance)
	local Characters = require(shared.Characters)
	local EffectRules = require(server.Players.EffectRules)
	local RadiationRules = require(server.Players.RadiationRules)
	local PlayerCodec = require(server.Save.PlayerCodec)
	local CharacterCodec = require(server.Save.CharacterCodec)

	local B, I, E = Blocks.id, Items.id, Effects.id
	local settings = Config.Radiation
	local SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR

	local function stack(item: number, count: number): Items.Stack
		return Items.newStack(item, count) :: Items.Stack
	end
	local function carrying(slots: { [number]: Items.Stack? }?, armor: { [number]: Items.Stack? }?): any
		return { slots = slots or {}, armor = armor or {}, cursor = nil }
	end
	local SUIT = {
		stack(I.HazmatHelmet, 1),
		stack(I.HazmatChestplate, 1),
		stack(I.HazmatLeggings, 1),
		stack(I.HazmatBoots, 1),
	}

	--[[
		A fake world: `fill(x, y, z)` (nil: unknown) under the cells set; `set` and `get` by cell,
		`reads` counted.
	]]
	local function world(fill: (x: number, y: number, z: number) -> number?)
		local cells: { [number]: number } = {}
		local self = { reads = 0 }
		local function key(x: number, y: number, z: number): number
			return ((x + 4096) * 8192 + y + 1024) * 8192 + z + 4096
		end
		function self.set(x: number, y: number, z: number, block: number)
			cells[key(x, y, z)] = block
		end
		function self.get(x: number, y: number, z: number): number?
			self.reads += 1
			return cells[key(x, y, z)] or fill(x, y, z)
		end
		return self
	end
	local function air(): number?
		return B.Air
	end
	-- Rock below y 70, air above.
	local function rock(_x: number, y: number): number?
		return if y < 70 then B.Stone else B.Air
	end

	--[[ Sources ]]

	t.test("radiation: the uranium is radioactive, by block and by count carried", function()
		local sources = settings.Sources
		t.eq(Radiation.strength(B.UraniumOre), sources.UraniumOre, "the ore")
		t.eq(Radiation.strength(B.RawUraniumBlock), sources.RawUraniumBlock)
		t.eq(Radiation.strength(B.UraniumBlock), sources.UraniumBlock)
		t.eq(Radiation.strength(I.RawUranium), sources.RawUranium)
		t.eq(Radiation.strength(I.UraniumIngot), sources.UraniumIngot)
		t.eq(Radiation.strength(I.UraniumNugget), sources.UraniumNugget)
		t.ok(Radiation.isSource(B.UraniumOre) and Radiation.isSource(B.UraniumBlock), "sources")
		for _, name in { "Stone", "LeadBlock", "CopperOre", "IronBlock", "Air" } do
			t.ok(not Radiation.isSource(B[name]), `{name} is not`)
		end
		t.eq(Radiation.strength(I.LeadIngot), 0)
		-- The blocks are nine of their item; the ore a lump's uranium spread through rock, the
		-- refined ingot far hotter than a lump.
		t.near(sources.RawUraniumBlock, 9 * sources.RawUranium, 1e-9, "nine lumps")
		t.near(sources.UraniumBlock, 9 * sources.UraniumIngot, 1e-9, "nine ingots")
		t.near(sources.UraniumNugget, sources.UraniumIngot / 9, 0.01, "a ninth of an ingot")
		t.ok(sources.UraniumOre < sources.RawUraniumBlock, "an ore is less than a raw block")
		t.ok(sources.UraniumIngot > 10 * sources.RawUranium, "refined")
		-- Carried: slots, armor, the cursor and the open grid, each stack by its count; a block's
		-- item radiates as the block.
		local inventory = carrying({ [1] = stack(I.RawUranium, 64), [20] = stack(B.UraniumBlock, 2) })
		inventory.cursor = stack(I.UraniumNugget, 9)
		inventory.armor[2] = stack(I.IronChestplate, 1)
		local expected = 64 * sources.RawUranium + 2 * sources.UraniumBlock + 9 * sources.UraniumNugget
		t.near(Radiation.carried(inventory), expected, 1e-9, "by count")
		t.near(
			Radiation.carried(inventory, { [3] = stack(I.UraniumIngot, 4) }),
			expected + 4 * sources.UraniumIngot,
			1e-9,
			"the crafting grid too"
		)
		t.eq(Radiation.carried(carrying({ stack(I.Stick, 64) })), 0, "nothing radioactive")
	end)

	--[[ Falloff and shielding ]]

	t.test("radiation: the falloff is Mekanism's inverse square from a block in, fading to 0 at the radius", function()
		local r = settings.Radius
		local edge = 1 / (r * r)
		t.near(Radiation.falloff(0), 1 - edge, 1e-12, "a block away or nearer: all of it (less the edge)")
		t.near(Radiation.falloff(0.5), 1 - edge, 1e-12)
		t.near(Radiation.falloff(4), 0.25 - edge, 1e-12, "two blocks: a quarter")
		t.near(Radiation.falloff(16), 1 / 16 - edge, 1e-12)
		t.eq(Radiation.falloff(r * r), 0, "nothing at the radius")
		t.eq(Radiation.falloff(r * r * 4), 0, "nor beyond")
		local last = math.huge
		for d = 0, r, 0.25 do
			local share = Radiation.falloff(d * d)
			t.ok(share <= last, `falls off at {d}`)
			last = share
		end
	end)

	t.test("radiation: blocks between shield it, lead most; glass, air and unknown cells don't", function()
		local w = world(air)
		local function through(block: number?): number
			local here = world(function(x: number, y: number, z: number): number?
				if x == 2 and y == 0 and z == 0 then
					return block
				end
				return B.Air
			end)
			return Radiation.transmission(here.get, 0, 0, 0, 4.5, 0.5, 0.5)
		end
		t.eq(Radiation.transmission(w.get, 0, 0, 0, 4.5, 0.5, 0.5), 1, "air")
		t.eq(through(B.Stone), settings.Shielding.Solid, "rock: Solid")
		t.eq(through(B.Dirt), settings.Shielding.Solid, "earth")
		t.eq(through(B.LeadBlock), settings.Shielding.LeadBlock, "a Block of Lead")
		t.eq(through(B.RawLeadBlock), settings.Shielding.RawLeadBlock)
		t.ok(settings.Shielding.LeadBlock < settings.Shielding.Solid / 10, "lead stops nearly all")
		t.eq(through(B.Glass), 1, "glass lets it through")
		t.eq(through(B.Water), 1, "fluids too")
		t.eq(through(nil), 1, "an unknown cell is nothing")
		t.eq(through(B.UraniumOre), settings.Shielding.Solid, "an ore is rock")
		-- Two walls: the shares multiply. The source's own cell and the body's don't count.
		local walls = world(function(x: number, _y: number, _z: number): number?
			return if x == 1 or x == 3 or x == 0 or x == 5 then B.Stone else B.Air
		end)
		t.near(Radiation.transmission(walls.get, 0, 0, 0, 5.5, 0.5, 0.5), settings.Shielding.Solid ^ 2, 1e-12)
		-- Diagonal rays walk the cells between (at most the Manhattan distance).
		local solid = world(function(): number?
			return B.Stone
		end)
		t.eq(Radiation.transmission(solid.get, 0, 0, 0, 0.5, 0.5, 0.5), 1, "the same cell: nothing between")
		local share = Radiation.transmission(solid.get, 0, 0, 0, 3.5, 3.5, 0.5)
		t.ok(solid.reads <= 6, `a diagonal reads at most the Manhattan distance ({solid.reads})`)
		t.ok(share < 1 and share >= settings.Shielding.Solid ^ 5, "and shields by the cells it crosses")
		-- A deep wall stops it.
		t.eq(Radiation.transmission(solid.get, 0, 0, 0, 30.5, 0.5, 0.5), 0, "thirty blocks of rock")
	end)

	t.test("radiation: a look reads the sphere around the body, shields the nearest rays, at a bounded cost", function()
		local block = settings.Sources.UraniumBlock
		local open = world(air)
		open.set(3, 64, 0, B.UraniumBlock)
		local x, y, z = 0.5, 64.5, 0.5
		t.near(Radiation.scan(open.get, x, y, z), block * Radiation.falloff(9), 1e-9, "three blocks off in the open")
		open.set(2, 64, 0, B.Stone)
		t.near(
			Radiation.scan(open.get, x, y, z),
			block * Radiation.falloff(9) * settings.Shielding.Solid,
			1e-9,
			"behind rock"
		)
		open.set(2, 64, 0, B.LeadBlock)
		t.near(
			Radiation.scan(open.get, x, y, z),
			block * Radiation.falloff(9) * settings.Shielding.LeadBlock,
			1e-9,
			"behind lead"
		)
		local far = world(air)
		far.set(math.ceil(settings.Radius) + 1, 64, 0, B.UraniumBlock)
		t.eq(Radiation.scan(far.get, x, y, z), 0, "out of the radius")
		-- More sources than rays: the nearest are traced, the rest take their mean share. A wall
		-- of raw uranium behind a wall of lead: every ray crosses one or two lead cells, so the
		-- lead keeps out its share (or its square) of the whole wall, traced or not.
		local sources = 0
		local function sheet(lead: boolean)
			return world(function(bx: number, _by: number, _bz: number): number?
				if bx == 2 and lead then
					return B.LeadBlock
				elseif bx == 3 then
					return B.RawUraniumBlock
				end
				return B.Air
			end)
		end
		for by = -9, 9 do
			for bz = -9, 9 do
				local dx, dy, dz = 3.5 - x, by + 64.5 - y, bz + 0.5 - z
				if Radiation.falloff(dx * dx + dy * dy + dz * dz) > 0 then
					sources += 1
				end
			end
		end
		t.ok(sources > settings.MaxRays, `{sources} sources, more than the rays`)
		local behind = Radiation.scan(sheet(true).get, x, y, z)
		local unshielded = Radiation.scan(sheet(false).get, x, y, z)
		local lead = settings.Shielding.LeadBlock
		t.ok(behind > 0, "some")
		t.ok(
			behind / unshielded <= lead + 1e-9 and behind / unshielded >= lead * lead - 1e-9,
			`the whole wall behind lead, traced or not ({behind / unshielded})`
		)
		-- The cost: the sphere's cells and the rays, never more.
		t.ok(Radiation.OFFSETS < 4 / 3 * math.pi * (settings.Radius + 1) ^ 3, `{Radiation.OFFSETS} cells`)
		local veins = world(rock)
		for i = 0, 63 do
			veins.set(i % 8 - 4, 60 + i // 16, i // 8 % 2 * 3 - 1, B.UraniumOre)
		end
		veins.reads = 0
		local looks = 50
		local started = os.clock()
		for _ = 1, looks do
			Radiation.scan(veins.get, x, 64.9, z)
		end
		local ms = (os.clock() - started) * 1000 / looks
		local reads = veins.reads / looks
		t.ok(reads <= Radiation.readsBound(), `{reads} reads a look, at most {Radiation.readsBound()}`)
		t.ok(reads > Radiation.OFFSETS, "the sphere and the rays")
		-- (Under Lune, about 0.5 ms a look; a player is looked at once a second.)
		t.ok(ms < 25, `{string.format("%.2f", ms)} ms a look`)
		print(`         (a look: {Radiation.OFFSETS} cells, {reads} reads, {string.format("%.2f", ms)} ms)`)
	end)

	--[[ The Hazmat suit ]]

	t.test("radiation: past the traced rays, a lead wall on one side hides no heap in the open on the other", function()
		-- Every source within the radius traced (no MaxRays), to compare.
		local function everyRay(get: (number, number, number) -> number?, x: number, y: number, z: number): number
			local total = 0
			for bx = math.floor(x) - 10, math.floor(x) + 10 do
				for by = math.floor(y) - 10, math.floor(y) + 10 do
					for bz = math.floor(z) - 10, math.floor(z) + 10 do
						local s = Radiation.strength(get(bx, by, bz) or 0)
						if s > 0 then
							local dx, dy, dz = bx + 0.5 - x, by + 0.5 - y, bz + 0.5 - z
							local share = Radiation.falloff(dx * dx + dy * dy + dz * dz)
							if share > 0 then
								total += s * share * Radiation.transmission(get, bx, by, bz, x, y, z)
							end
						end
					end
				end
			end
			return total
		end
		-- 36 Blocks of Raw Uranium behind a lead wall 2.5 to 4 blocks east (more sources than
		-- rays), and four Blocks of Uranium in the open 5.5 blocks west.
		local w = world(air)
		for by = 58, 72 do
			for bz = -6, 7 do
				w.set(2, by, bz, B.LeadBlock)
			end
		end
		for by = 62, 67 do
			for bz = -2, 3 do
				w.set(3, by, bz, B.RawUraniumBlock)
			end
		end
		for _, c in { { -5, 64, 0 }, { -5, 65, 0 }, { -5, 64, 1 }, { -5, 65, 1 } } do
			w.set(c[1], c[2], c[3], B.UraniumBlock)
		end
		local x, y, z = 0.5, 64.9, 0.5
		local scanned, full = Radiation.scan(w.get, x, y, z), everyRay(w.get, x, y, z)
		t.ok(scanned >= full * 0.95 and scanned <= full * 1.05, `as every ray says ({scanned} against {full} Sv/h)`)
	end)

	t.test("radiation: the Hazmat suit keeps out Mekanism's shares, the whole suit all of it", function()
		t.eq(Radiation.shielding({}), 0, "bare")
		t.eq(Radiation.shielding({ stack(I.HazmatHelmet, 1) }), 0.25, "the mask")
		t.eq(Radiation.shielding({ nil, stack(I.HazmatChestplate, 1) }), 0.4, "the gown")
		t.eq(Radiation.shielding({ nil, nil, stack(I.HazmatLeggings, 1) }), 0.2, "the pants")
		t.eq(Radiation.shielding({ nil, nil, nil, stack(I.HazmatBoots, 1) }), 0.15, "the boots")
		t.near(Radiation.shielding(SUIT), 1, 1e-12, "all of it")
		t.eq(Radiation.shielding({ stack(I.IronHelmet, 1), stack(I.DiamondChestplate, 1) }), 0, "other armor: none")
		t.eq(Radiation.exposure(10, 1), 0, "a suit: nothing")
		t.near(Radiation.exposure(10, 0.4), 6, 1e-9, "the gown alone")
		t.eq(Radiation.exposure(settings.MinRate / 2, 0), 0, "below MinRate: none")
	end)

	--[[ The dose ]]

	t.test("radiation: the dose builds while exposed and decays by halves", function()
		local half = settings.HalfLife
		t.near(Radiation.dose(0, 3600, 1), 1, 0.01, "a second at 3600 Sv/h is about a sievert")
		t.near(Radiation.dose(1, 0, half), 0.5, 1e-9, "halves every HalfLife")
		t.near(Radiation.dose(1, 0, 2 * half), 0.25, 1e-9)
		local settled = Radiation.settled(10)
		t.near(settled, 10 * half / (3600 * math.log(2)), 1e-9, "rate x HalfLife / (3600 ln 2)")
		t.near(Radiation.dose(0, 10, half * 40), settled, 1e-6, "settles there")
		-- Exact over any step: one long step is many short ones.
		local stepped = 0
		for _ = 1, 600 do
			stepped = Radiation.dose(stepped, 5, 1)
		end
		t.near(stepped, Radiation.dose(0, 5, 600), 1e-9, "a minute in one or in sixty")
		t.eq(Radiation.dose(1e-7, 0, 1), 0, "a trace is none")
		t.eq(Radiation.dose(-1, 0, 1), 0, "never below 0")
	end)

	--[[ Sickness ]]

	t.test("radiation: Mekanism's 0.1, 1 and 10 Sv bands bring Radiation Sickness I, II and III", function()
		t.eq(Radiation.level(0), 0)
		t.eq(Radiation.level(0.099), 0)
		t.eq(Radiation.level(0.1), 1)
		t.eq(Radiation.level(0.99), 1)
		t.eq(Radiation.level(1), 2)
		t.eq(Radiation.level(10), 3)
		t.eq(Radiation.level(1e5), 3, "no level beyond the last band")
		t.eq(#Radiation.symptoms(0), 0, "none")
		local one = Radiation.symptoms(1)
		t.eq(#one, 1)
		t.eq(one[1].effect, E.RadiationSickness)
		t.eq(one[1].amplifier, 0, "I")
		local two = Radiation.symptoms(2)
		t.eq(#two, 2)
		t.eq(two[1].amplifier, 1, "II")
		t.eq(two[2].effect, E.Hunger, "with Minecraft's Hunger")
		t.eq(two[2].amplifier, 0)
		local three = Radiation.symptoms(3)
		t.eq(#three, 3)
		t.eq(three[1].amplifier, 2, "III")
		t.eq(three[2].amplifier, 1, "Hunger II")
		t.eq(three[3].effect, E.Nausea, "and Nausea")
	end)

	t.test("radiation: Radiation Sickness is a harmful effect that hurts by magic on an interval, and kills", function()
		local def = Effects.get(E.RadiationSickness) :: Effects.Effect
		-- (By name, not by id: effects are numbered in list order, which content may change.)
		t.ok(def ~= nil and def.name == "RadiationSickness", "an effect")
		t.eq(def.displayName, "Radiation Sickness")
		t.eq(def.category, "harmful")
		t.eq(def.icon, "radiation")
		t.ok(def.lethal and def.damage == 1 and not def.external, "a running effect that kills")
		t.eq(Effects.find("radiation_sickness"), E.RadiationSickness, "/effect give @s radiation_sickness")
		-- Its cadence: a half heart every 300 >> amp ticks, down to the last.
		for amplifier, every in { [0] = 300, [1] = 150, [2] = 75 } do
			local state = EffectRules.new()
			EffectRules.give(state, E.RadiationSickness, 3000, amplifier)
			local hurt = 0
			for _ = 1, 3000 do
				hurt += EffectRules.tick(state, SURVIVAL, 1, 20)
			end
			t.eq(hurt, 3000 // every, `level {amplifier + 1}: every {every} ticks, the last half heart too`)
		end
		local creative = EffectRules.new()
		EffectRules.give(creative, E.RadiationSickness, 600, 2)
		local spared = 0
		for _ = 1, 600 do
			spared += EffectRules.tick(creative, CREATIVE, 20, 20)
		end
		t.eq(spared, 0, "creative is never hurt")
	end)

	t.test("radiation: the symptoms are renewed so they keep their cadence, and lapse once the dose falls", function()
		local full = settings.Sickness.Ticks
		local S = E.RadiationSickness
		t.eq(Radiation.renewal(S, 0, nil, 0), full, "none: afresh")
		t.eq(Radiation.renewal(S, 1, 0, 400), full, "stronger: afresh")
		t.eq(Radiation.renewal(S, 0, 1, 100), nil, "weaker: the stronger runs out first")
		t.eq(Radiation.renewal(S, 0, 0, full - 10), nil, "not run down a step yet")
		local step = Radiation.step(S, 0)
		t.eq(step, 300)
		t.eq(Radiation.renewal(S, 0, 0, full - step), full, "a step down: back up")
		t.eq(Radiation.renewal(S, 0, 0, full - step - 7), full - 7, "in whole steps: the cadence kept")
		t.eq(Radiation.renewal(S, 0, 0, Effects.INFINITE), nil, "for good: left")
		t.eq(Radiation.step(E.Nausea, 0), Radiation.RENEW_TICKS, "an effect with no interval")
		-- Played out: level II held for 3000 ticks with a look every 20 hurts exactly every 150
		-- ticks, never lapsing; once the dose is gone it lapses within Sickness.Ticks.
		for _, level in { 1, 2, 3 } do
			local state = EffectRules.new()
			local hooks: RadiationRules.Hooks = {
				current = function(effect: number): (number?, number)
					local instance = EffectRules.get(state, effect)
					return EffectRules.amplifier(state, effect), if instance then instance.ticks else 0
				end,
				give = function(effect: number, ticks: number, amplifier: number)
					EffectRules.give(state, effect, ticks, amplifier)
				end,
			}
			local function look()
				for _, symptom in Radiation.symptoms(level) do
					local current, ticks = hooks.current(symptom.effect)
					local give = Radiation.renewal(symptom.effect, symptom.amplifier, current, ticks)
					if give then
						hooks.give(symptom.effect, give, symptom.amplifier)
					end
				end
			end
			local hurt, lapsed = 0, false
			for tick = 0, 2999 do
				if tick % 20 == 0 then
					look()
				end
				hurt += EffectRules.tick(state, SURVIVAL, 10, 20)
				if not EffectRules.has(state, S) then
					lapsed = true
				end
			end
			local every = Radiation.step(S, level - 1)
			t.near(hurt, 3000 / every, 1, `level {level}: a half heart every {every} ticks`)
			t.ok(not lapsed, "never lapses while it holds")
			t.eq(EffectRules.amplifier(state, S), level - 1)
			t.eq(EffectRules.has(state, E.Hunger), level >= 2, "Hunger from II")
			t.eq(EffectRules.has(state, E.Nausea), level >= 3, "Nausea from III")
			for _ = 1, full + 1 do
				EffectRules.tick(state, SURVIVAL, 10, 20)
			end
			t.ok(not EffectRules.has(state, S) and not EffectRules.has(state, E.Hunger), "gone after Sickness.Ticks")
		end
	end)

	--[[ The server's look: how play feels ]]

	-- Plays `seconds` of looks a second at `body` among `w`'s blocks (`each(second)` first), the
	-- symptoms on an EffectRules state ticked alongside. Returns the State, the effects and the
	-- level each minute.
	local function play(w: any, body: any, seconds: number, each: ((second: number) -> ())?)
		local state = RadiationRules.new()
		local effects = EffectRules.new()
		local hooks: RadiationRules.Hooks = {
			current = function(effect: number): (number?, number)
				local instance = EffectRules.get(effects, effect)
				return EffectRules.amplifier(effects, effect), if instance then instance.ticks else 0
			end,
			give = function(effect: number, ticks: number, amplifier: number)
				EffectRules.give(effects, effect, ticks, amplifier)
			end,
		}
		local minutes: { number } = {}
		for second = 1, seconds do
			if each then
				each(second)
			end
			RadiationRules.look(state, w.get, body, 1, hooks)
			for _ = 1, 20 do
				EffectRules.tick(effects, body.mode, 20, 20)
			end
			if second % 60 == 0 then
				table.insert(minutes, Radiation.level(state.dose))
			end
		end
		return state, effects, minutes
	end
	-- A tunnel along x at y 64..65 through rock, with a vein of six ores in its wall.
	local VEIN = { { 0, 64, 1 }, { 1, 64, 1 }, { 0, 65, 1 }, { 1, 65, 2 }, { 0, 64, 2 }, { 1, 64, 2 } }
	local function tunnel()
		local w = world(rock)
		for x = -30, 30 do
			w.set(x, 64, 0, B.Air)
			w.set(x, 65, 0, B.Air)
		end
		for _, cell in VEIN do
			w.set(cell[1], cell[2], cell[3], B.UraniumOre)
		end
		return w
	end
	-- The minute the level first reaches `level` (nil: never).
	local function reached(minutes: { number }, level: number): number?
		for minute, at in minutes do
			if at >= level then
				return minute
			end
		end
		return nil
	end

	t.test("radiation: mining a uranium vein bare skinned for a few minutes makes you mildly sick", function()
		local w = tunnel()
		local inventory = carrying()
		local mined = 0
		local state, effects, minutes = play(
			w,
			{ x = 0.5, y = 64, z = 0.5, mode = SURVIVAL, inventory = inventory },
			600,
			function(second: number)
				-- (An ore every 30 s, its Raw Uranium kept.)
				if second % 30 == 0 and mined < #VEIN then
					mined += 1
					local cell = VEIN[mined]
					w.set(cell[1], cell[2], cell[3], B.Air)
					inventory.slots[1] = stack(I.RawUranium, mined)
				end
			end
		)
		local first = reached(minutes, 1)
		t.ok(first ~= nil and first >= 2 and first <= 5, `mildly sick after a few minutes ({first})`)
		t.eq(reached(minutes, 2), nil, "only mildly")
		t.eq(EffectRules.amplifier(effects, E.RadiationSickness), 0, "Radiation Sickness I")
		t.ok(not EffectRules.has(effects, E.Hunger), "no Hunger yet")
		t.ok(state.rate > 0 and state.carried > 0, "the lumps carried")
	end)

	t.test("radiation: a stack of Raw Uranium carried for several minutes makes you sick, never worse", function()
		local body = { x = 0, y = 64, z = 0, mode = SURVIVAL, inventory = carrying({ stack(I.RawUranium, 64) }) }
		local state, effects, minutes = play(world(air), body, 900)
		local sick = reached(minutes, 2)
		t.ok(sick ~= nil and sick >= 3 and sick <= 8, `sick after several minutes ({sick})`)
		t.eq(reached(minutes, 1), 1, "mildly within the first minute")
		t.ok(Radiation.settled(state.rate) < settings.Sickness.Bands[3], "it settles below III")
		t.eq(EffectRules.amplifier(effects, E.RadiationSickness), 1, "Radiation Sickness II")
		t.ok(EffectRules.has(effects, E.Hunger), "with Hunger")
		-- One lump in a pocket is safe; one ingot (the refined metal) is not.
		t.ok(Radiation.settled(settings.Sources.RawUranium) < settings.Sickness.Bands[1], "a lump settles below I")
		t.ok(Radiation.settled(settings.Sources.UraniumIngot) > settings.Sickness.Bands[2], "an ingot above II")
	end)

	t.test("radiation: standing next to a Block of Uranium is dangerous", function()
		local w = world(function(_x: number, y: number): number?
			return if y < 64 then B.Stone else B.Air
		end)
		w.set(1, 64, 0, B.UraniumBlock)
		local _, effects, minutes = play(w, { x = 0.2, y = 64, z = 0.5, mode = SURVIVAL, inventory = carrying() }, 1800)
		local sick = reached(minutes, 2)
		t.ok(sick ~= nil and sick <= 2, `sick within a minute or two ({sick})`)
		local severe = reached(minutes, 3)
		t.ok(severe ~= nil and severe <= 25, `severe if you stay ({severe})`)
		t.eq(EffectRules.amplifier(effects, E.RadiationSickness), 2, "Radiation Sickness III")
		t.ok(EffectRules.has(effects, E.Nausea), "with Nausea")
	end)

	t.test("radiation: ordinary caves with a vein a few blocks off are safe", function()
		local w = tunnel()
		for _, off in { 4, 6, 10 } do
			local state, effects, minutes = play(w, { x = 0.5 + off, y = 64, z = 0.5, mode = SURVIVAL }, 120)
			t.eq(reached(minutes, 1), nil, `{off} blocks down the tunnel`)
			t.ok(Radiation.settled(state.rate) < settings.Sickness.Bands[1] / 2, `safe for good at {off}`)
			t.ok(not EffectRules.has(effects, E.RadiationSickness))
		end
		-- (Close by, the Geiger counter still clicks now and then: it finds the vein.)
		local close = RadiationRules.new()
		RadiationRules.look(close, w.get, { x = 3.5, y = 64, z = 0.5, mode = SURVIVAL }, 1)
		t.ok(close.rate > 0 and Radiation.clickRate(close.rate) > 0.1, "clicks three blocks off")
	end)

	t.test("radiation: the suit, creative and spectator players, adventure, and radiation off", function()
		local w = world(air)
		w.set(1, 64, 0, B.UraniumBlock)
		local function body(mode: string, armor: { Items.Stack? }?): any
			return { x = 0.2, y = 64, z = 0.5, mode = mode, inventory = carrying({ stack(I.UraniumIngot, 9) }, armor) }
		end
		local suited, effects = play(w, body(SURVIVAL, SUIT), 120)
		t.eq(suited.rate, 0, "the whole suit keeps out all of it")
		t.eq(suited.dose, 0)
		t.ok(not EffectRules.has(effects, E.RadiationSickness))
		local partial = RadiationRules.new()
		RadiationRules.look(partial, w.get, body(SURVIVAL, { SUIT[1] }), 1)
		local bare = RadiationRules.new()
		RadiationRules.look(bare, w.get, body(SURVIVAL), 1)
		t.near(partial.rate, bare.rate * 0.75, 1e-9, "the mask alone: a quarter")
		local adventure = RadiationRules.new()
		RadiationRules.look(adventure, w.get, body(ADVENTURE), 1)
		t.near(adventure.rate, bare.rate, 1e-9, "adventure as survival")
		for _, mode in { CREATIVE, SPECTATOR } do
			local state = RadiationRules.new(2)
			local given = 0
			RadiationRules.look(state, w.get, body(mode), settings.HalfLife, {
				current = function(): (number?, number)
					return nil, 0
				end,
				give = function()
					given += 1
				end,
			})
			t.eq(state.rate, 0, `{mode}: never exposed`)
			t.near(state.dose, 1, 1e-9, `{mode}: the dose only decays`)
			t.eq(given, 0, `{mode}: no sickness`)
		end
		-- Off: no exposure, and the dose kept as it is.
		settings.Enabled = false
		local off = RadiationRules.new(2)
		local rate = RadiationRules.look(off, w.get, body(SURVIVAL), 60)
		settings.Enabled = true
		t.eq(rate, 0, "off: none")
		t.eq(off.dose, 2, "off: kept")
		-- A new character starts clean; a saved dose is checked.
		t.eq(RadiationRules.new().dose, 0)
		t.eq(RadiationRules.new(0 / 0).dose, 0, "NaN")
		t.eq(RadiationRules.new(-3).dose, 0)
		t.eq(RadiationRules.new(math.huge).dose, 0)
		t.eq(RadiationRules.new(1.5).dose, 1.5)
		t.near(RadiationRules.CENTRE, 0.9, 1e-9, "measured at the body's centre")
	end)

	--[[ The Geiger counter ]]

	t.test("radiation: the Geiger counter clicks as a Poisson process, faster with the rate, capped", function()
		local clicks = settings.Clicks
		t.eq(Radiation.clickRate(0), 0)
		t.eq(Radiation.clickRate(settings.MinRate / 2), 0, "below MinRate: silent")
		t.near(Radiation.clickRate(1), clicks.PerSvh, 1e-9, "PerSvh at 1 Sv/h")
		t.near(Radiation.clickRate(4), clicks.PerSvh * 2, 1e-9, "the square root")
		t.eq(Radiation.clickRate(1e6), clicks.Max, "capped")
		t.ok(Radiation.clickRate(0.002) < 0.5, "a vein in the rock nearby: a click every few seconds")
		t.ok(Radiation.clickRate(19.2) > 8, "a stack of Raw Uranium: about a dozen")
		-- Played at 60 frames a second: the clicks come at the rate asked; never two a frame. (A
		-- seeded generator: Lune has no Random.)
		local seed = 7
		local random = {
			NextNumber = function(_self: any): number
				seed = (seed * 1103515245 + 12345) % 2147483648
				return seed / 2147483648
			end,
		}
		for _, rate in { 0.05, 1, 20, 500 } do
			local count, frames, seconds = 0, 0, 200
			for _ = 1, seconds * 60 do
				frames += 1
				if Radiation.clicks(rate, 1 / 60, random:NextNumber()) then
					count += 1
				end
			end
			local expected = Radiation.clickRate(rate) * seconds
			t.near(count, expected, 4 * math.sqrt(expected) + 2, `{rate} Sv/h: {count} clicks in {seconds} s`)
			t.ok(count <= frames and count / seconds <= clicks.Max * 1.1, "at most one a frame, Max a second")
		end
		t.ok(not Radiation.clicks(0, 1, 0), "none at 0")
		t.ok(Radiation.clicks(1e6, 1, 0.999), "a long frame at the cap: certain")
	end)

	--[[ Shown ]]

	t.test("radiation: the published values have two significant figures; F3's units", function()
		t.near(Radiation.round(1.2345), 1.2, 1e-9)
		t.near(Radiation.round(0.012345), 0.012, 1e-12)
		t.near(Radiation.round(56.7), 57, 1e-9)
		t.eq(Radiation.round(0), 0)
		t.eq(Radiation.round(-1), 0)
		t.eq(Radiation.round(0 / 0), 0)
		t.eq(Radiation.format(56.69, "Sv/h"), "57 Sv/h")
		t.eq(Radiation.format(1.234, "Sv/h"), "1.2 Sv/h")
		t.eq(Radiation.format(0.35, "Sv"), "350 mSv")
		t.eq(Radiation.format(0.0021, "Sv/h"), "2.1 mSv/h")
		t.eq(Radiation.format(0.0000123, "Sv"), "12 µSv")
		t.eq(Radiation.format(0, "Sv"), "0 Sv")
		t.ok(Radiation.RATE_ATTRIBUTE ~= Radiation.DOSE_ATTRIBUTE, "two attributes")
	end)

	--[[ Saved ]]

	t.test("radiation: the dose is saved in the player record (version 5) and the character (version 4)", function()
		-- Save/PlayerCodec: an optional f32 after the food bar, flag bit 7.
		local record = PlayerCodec.new()
		t.eq(record.radiation, 0, "none")
		local plain = PlayerCodec.encode(record)
		t.ok(not bit32.btest(buffer.readu8(plain, 1), 128), "no dose, no flag")
		record.radiation = 2.5
		local bytes = PlayerCodec.encode(record)
		t.eq(buffer.readu8(bytes, 0), 5, "version 5")
		t.ok(bit32.btest(buffer.readu8(bytes, 1), 128), "the dose's flag")
		t.eq(buffer.len(bytes), buffer.len(plain) + 4, "an f32 at the end")
		t.eq((PlayerCodec.decode(bytes) :: any).radiation, 2.5, "round trips")
		local four = buffer.create(buffer.len(plain))
		buffer.copy(four, 0, plain, 0)
		buffer.writeu8(four, 0, 4)
		t.eq((PlayerCodec.decode(four) :: any).radiation, 0, "version 4: none")
		local wrong = buffer.create(buffer.len(bytes))
		buffer.copy(wrong, 0, bytes, 0)
		buffer.writeu8(wrong, 0, 4)
		t.eq((PlayerCodec.decode(wrong)), nil, "version 4 never had the flag")
		local cut = buffer.create(buffer.len(bytes) - 1)
		buffer.copy(cut, 0, bytes, 0, buffer.len(cut))
		t.eq((PlayerCodec.decode(cut)), nil, "a truncated dose")
		record.radiation = 0 / 0
		t.ok(not bit32.btest(buffer.readu8(PlayerCodec.encode(record), 1), 128), "NaN: none written")
		record.radiation = -1
		t.eq((PlayerCodec.decode(PlayerCodec.encode(record)) :: any).radiation, 0, "negative: none")
		-- Nothing live yet (the title screen): the saved dose is kept; once a character stands,
		-- the live one's.
		local saved = PlayerCodec.new()
		saved.radiation = 3
		local waiting = PlayerCodec.withWaiting(
			PlayerCodec.new(),
			saved,
			{ standing = false, climate = false, effects = false, mana = false, survivor = false, radiation = false }
		)
		t.eq(waiting.radiation, 3)
		local live = PlayerCodec.new()
		live.radiation = 0.5
		t.eq(
			PlayerCodec.withWaiting(
				live,
				saved,
				{ standing = true, climate = true, effects = true, mana = true, survivor = true, radiation = true }
			).radiation,
			0.5,
			"live: the live one's"
		)
		-- Save/CharacterCodec: the same, flag bit 5; kept with the things of an unfair visit.
		local character = CharacterCodec.new(1, "Curie", Characters.Difficulty.Classic, Appearance.default(), 0)
		t.eq(character.radiation, 0)
		local none = CharacterCodec.encode(character)
		character.radiation = 4.25
		local withDose = CharacterCodec.encode(character)
		t.eq(buffer.readu8(withDose, 0), 4, "version 4")
		t.ok(bit32.btest(buffer.readu8(withDose, 1), 32), "the dose's flag")
		t.eq(buffer.len(withDose), buffer.len(none) + 4)
		t.eq((CharacterCodec.decode(withDose) :: any).radiation, 4.25, "round trips")
		local three = buffer.create(buffer.len(none))
		buffer.copy(three, 0, none, 0)
		buffer.writeu8(three, 0, 3)
		t.eq((CharacterCodec.decode(three) :: any).radiation, 0, "version 3: none")
		local bad = buffer.create(buffer.len(withDose))
		buffer.copy(bad, 0, withDose, 0)
		buffer.writeu8(bad, 0, 3)
		t.eq((CharacterCodec.decode(bad)), nil, "version 3 never had the flag")
		local kept = CharacterCodec.new(1, "Curie", Characters.Difficulty.Classic, Appearance.default(), 0)
		CharacterCodec.keepThings(kept, character)
		t.eq(kept.radiation, 4.25, "an unfair visit cures nothing")
	end)

	t.test("radiation: the server looks, saves and publishes; the client clicks and F3 shows it", function()
		local function code(path: string): string
			return fs.readFile(path)
		end
		local main = code("src/server/IceVoxel_Server.server.luau")
		t.ok(string.find(main, "Radiation.start(world)", 1, true), "the server starts it")
		for _, path in { "src/server/World/WorldSave.luau", "src/server/Players/CharacterStore.luau" } do
			local source = code(path)
			t.ok(string.find(source, "Radiation.export(player)", 1, true), `{path} saves the dose`)
			t.ok(string.find(source, "Radiation.restore(player, record.radiation)", 1, true), `{path} restores it`)
		end
		local glue = code("src/server/Players/Radiation.luau")
		t.ok(string.find(glue, "world:peekBlock", 1, true), "the server's loaded blocks, never generating")
		t.ok(string.find(glue, "Radiation.RATE_ATTRIBUTE", 1, true), "the rate published")
		local geiger = code("src/client/Audio/Geiger.luau")
		t.ok(
			string.find(geiger, "Radiation.clicks(", 1, true) and string.find(geiger, "playFlat(", 1, true),
			"flat clicks"
		)
		t.ok(string.find(code("src/client/IceVoxel_Client.client.luau"), "Geiger.start()", 1, true), "started")
		t.ok(string.find(code("src/client/Debug/DebugOverlay.luau"), "radiationLine()", 1, true), "F3's line")
	end)
end
