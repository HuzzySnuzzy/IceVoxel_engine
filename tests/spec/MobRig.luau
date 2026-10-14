--[[
	The zombies' R15 rigs (client Entities/MobRig) and their colours (Entities/ZombieLooks): the
	part tables are symmetric and sit inside the R15 silhouette, poses are continuous (no part
	jumps between frames, flags changing included), a crawler lies within 0.7 blocks of the
	floor, hidden parts are neither drawn nor posed, the colours follow sleeves, legs, gloves,
	shirtless and barefoot looks (tears and blood from the id, at their odds), every look of
	every kind fits 17 full-rig and 8 reduced-rig parts, only the head and torso cast shadows,
	and what posing 16 full and 24 reduced rigs a frame costs.
]]

local process = require("@lune/process")

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local MobList = require(shared.Entities.MobList)
	local Hash = require(shared.Util.Hash)
	local MobModel = require(client.Entities.MobModel)
	local MobRig = require(client.Entities.MobRig)
	local ZombieLooks = require(client.Entities.ZombieLooks)

	local BLOCK = Config.BlockSize
	local NATIVE = process.env.NOCODEGEN == nil
	local U32 = 4294967296

	local function kindNamed(name: string): MobList.Kind
		return MobList.get(MobList.find(name) :: number) :: MobList.Kind
	end

	-- Every zombie kind, and every variant of it with skin 1 (one per look).
	local function zombies(): { MobList.Kind }
		local list = {}
		for _, kind in MobList.kinds do
			if kind.zombie then
				table.insert(list, kind)
			end
		end
		return list
	end
	local function lookVariants(kind: MobList.Kind): { number }
		local list = {}
		for look = 1, #(MobList.looksOf(kind) :: { MobList.Look }) do
			table.insert(list, MobList.lookVariant(look, 1))
		end
		return list
	end

	local function newMob(kind: MobList.Kind, variant: number, id: number?): MobModel.Mob
		return MobModel.new(id or 1, kind, variant, { x = 0, y = 0, z = 0, yaw = 0, health = 20, flags = 0 }, 0)
	end

	-- The corners (studs, relative to the base) of a slot's box in `rel`.
	local function corners(rel: { number }, shape: MobRig.Shape, slot: number): { { number } }
		local r = (slot - 1) * 12
		local k = slot * 3
		local hx, hy, hz = shape.size[k - 2] / 2, shape.size[k - 1] / 2, shape.size[k] / 2
		local list = {}
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local x, y, z = sx * hx, sy * hy, sz * hz
					table.insert(list, {
						rel[r + 1] + rel[r + 4] * x + rel[r + 5] * y + rel[r + 6] * z,
						rel[r + 2] + rel[r + 7] * x + rel[r + 8] * y + rel[r + 9] * z,
						rel[r + 3] + rel[r + 10] * x + rel[r + 11] * y + rel[r + 12] * z,
					})
				end
			end
		end
		return list
	end

	t.test("mob rig: the part tables are symmetric and sit inside the silhouette", function()
		for _, kind in zombies() do
			for _, variant in lookVariants(kind) do
				local build = MobRig.build(kind, variant)
				local rig = kind.rig :: MobList.Rig
				local height = (rig.height or kind.height) * BLOCK
				t.near(build.sy * MobRig.R15_HEIGHT, height, 1e-9, `{kind.name}: drawn {height} studs tall`)
				t.near(build.sx, build.sy * (rig.width or MobRig.DEFAULT_WIDTH), 1e-9, `{kind.name}: its width`)
				for _, shape in { build.full :: MobRig.Shape, build.reduced :: MobRig.Shape } do
					local where = `{kind.name} variant {variant} tier {shape.tier}`
					-- Left and right mirror each other.
					local byName = {}
					for slot = 1, shape.count do
						byName[shape.names[slot]] = slot
					end
					local pairs = 0
					for slot = 1, shape.body do
						local name = shape.names[slot]
						if string.sub(name, 1, 4) == "Left" then
							local other = byName["Right" .. string.sub(name, 5)]
							t.ok(other ~= nil, `{where}: {name} has a right twin`)
							pairs += 1
							for axis = 1, 3 do
								local a, b = slot * 3 - 3 + axis, other * 3 - 3 + axis
								local sign = if axis == 1 then -1 else 1
								t.near(shape.size[a], shape.size[b], 1e-9, `{where}: {name}'s size`)
								t.near(shape.centre[a], sign * shape.centre[b], 1e-9, `{where}: {name}'s centre`)
								t.near(shape.offset[a], sign * shape.offset[b], 1e-9, `{where}: {name}'s pivot`)
								t.near(shape.arm[a], sign * shape.arm[b], 1e-9, `{where}: {name}'s arm`)
							end
							t.ok(shape.centre[slot * 3 - 2] > 0, `{where}: {name} on the left (+X, facing +Z)`)
							t.eq(shape.joint[slot] == 0, shape.joint[other] == 0, `{where}: {name}'s joint`)
						end
					end
					t.eq(pairs, if shape.tier == MobRig.FULL then 6 else 2, `{where}: left-right pairs`)
					-- At rest every body box sits inside the R15 silhouette (4 x 5.2 x 1.2, scaled), the
					-- feet on the floor and the head at the drawn height; the extras ride on it.
					local rel = table.create(12 * MobRig.FULL_SLOTS, 0)
					MobRig.rest(rel, shape)
					local top, bottom = -math.huge, math.huge
					local hides = false
					for slot = 1, shape.count do
						if shape.hidden[slot] then
							hides = true
							continue
						end
						local k = slot * 3
						t.near(rel[(slot - 1) * 12 + 2], shape.centre[k - 1], 1e-9, `{where}: rest = the table`)
						for _, c in corners(rel, shape, slot) do
							local extra = slot > shape.body
							local slack = if extra then 0.25 * build.sx else 1e-9
							t.ok(math.abs(c[1]) <= 2 * build.sx + slack, `{where}: {shape.names[slot]} inside (x)`)
							t.ok(math.abs(c[3]) <= 0.6 * build.sx + slack, `{where}: {shape.names[slot]} inside (z)`)
							if extra then
								t.ok(c[2] <= height + 0.25 * build.sy, `{where}: {shape.names[slot]} rides the rig`)
							else
								t.ok(c[2] >= -1e-9 and c[2] <= height + 1e-9, `{where}: {shape.names[slot]} (y)`)
								top, bottom = math.max(top, c[2]), math.min(bottom, c[2])
							end
						end
					end
					t.near(top, height, 1e-9, `{where}: the head's top`)
					if not hides then
						t.near(bottom, 0, 1e-9, `{where}: the feet`)
					end
				end
			end
		end
	end)

	--[[
		A zombie (id `id`) walking along +Z at `paceAt(time)` blocks a tick (an update every 0.1 s,
		as the server syncs), drawn every `dt` seconds for `seconds`, its flags following
		`flagsAt(time)`: the largest step any corner of a drawn box makes between two frames
		(studs, relative to the base: the whole frame, not only the box's centre), and which box.
	]]
	local function largestStep(
		kind: MobList.Kind,
		variant: number,
		tier: number,
		paceAt: (number) -> number,
		dt: number,
		seconds: number,
		flagsAt: (number) -> number,
		id: number?
	): (number, string)
		local build = MobRig.build(kind, variant)
		local shape = MobRig.shape(build, tier)
		local mob = newMob(kind, variant, id or 7)
		local rel = table.create(12 * MobRig.FULL_SLOTS, 0)
		local last: { { { number } } } = {}
		local nextUpdate, z = 0, 0
		local worst, worstName = 0, ""
		local frames = math.floor(seconds / dt)
		for frame = 0, frames do
			local now = frame * dt
			while nextUpdate <= now do
				z += paceAt(nextUpdate) * 2
				MobModel.apply(
					mob,
					{ x = 0, y = 0, z = z, yaw = 0, health = 20, flags = flagsAt(nextUpdate) },
					nextUpdate
				)
				nextUpdate += 0.1
			end
			MobModel.stride(mob, now)
			MobRig.pose(rel, build, shape, mob, now)
			for slot = 1, shape.count do
				if not shape.hidden[slot] then
					local now_ = corners(rel, shape, slot)
					local before = last[slot]
					if before then
						for c = 1, 8 do
							local a, b = now_[c], before[c]
							local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
							local d = math.sqrt(dx * dx + dy * dy + dz * dz)
							if d > worst then
								worst, worstName = d, shape.names[slot]
							end
						end
					end
					last[slot] = now_
				end
			end
		end
		return worst, worstName
	end

	local F = MobModel
	-- Aggressive from 1 s, swings at 1.5, 2.5 and 3.5 s, breaking 4-5 s, screaming 5.5-6.5 s.
	local function busy(time: number): number
		local flags = 0
		if time >= 1 and time < 7 then
			flags += F.AGGRESSIVE
		end
		local swing = time % 1
		if time >= 1.5 and time < 4 and swing >= 0.5 and swing < 0.9 then
			flags += F.ATTACK
		end
		if time >= 4 and time < 5 then
			flags += F.BREAKING
		end
		if time >= 5.5 and time < 6.5 then
			flags += F.SCREAMING
		end
		return flags
	end

	-- A kind's chasing pace, blocks a tick: Shared/Entities/MobPhysics' terminal ground speed for
	-- the AI's input (MobAI: speed x chase x 0.98, times the speed as acceleration, against the
	-- ground's drag 0.6 x 0.91).
	local function chasePace(kind: MobList.Kind): number
		return kind.speed * kind.speed * (kind.chase or 1) * 0.98 / (1 - 0.6 * 0.91)
	end
	local function steady(pace: number): (number) -> number
		return function(_time: number): number
			return pace
		end
	end

	t.test("mob rig: poses are continuous at every zombie's own pace and faster, flags changing", function()
		local lines = {}
		for _, kind in zombies() do
			local looks = #(MobList.looksOf(kind) :: { MobList.Look })
			-- (The twitch's timing and the head's tilt come from the id: a lurching zombie is
			-- checked over many, so a twitch lands on every swing, hammering and scream.)
			local ids = if (kind.rig :: MobList.Rig).gait == "lurch" then 24 else 3
			for _, tier in { MobRig.FULL, MobRig.REDUCED } do
				-- Its own chase, and walk 1 (flung by a hit; a runner's chase is already there).
				local paces = { chasePace(kind) }
				if paces[1] < 0.25 then
					table.insert(paces, 0.25)
				end
				for _, pace in paces do
					local worst, where = 0, ""
					for id = 1, ids do
						local variant = MobList.lookVariant((id - 1) % looks + 1, id % #MobList.SKIN_TONES + 1)
						local step, name = largestStep(kind, variant, tier, steady(pace), 1 / 60, 8, busy, id)
						if step > worst then
							worst, where = step, `{name}, id {id}`
						end
					end
					local walk = math.min(1, pace * 4)
					table.insert(
						lines,
						string.format("%s tier %d walk %.2f: %.3f (%s)", kind.name, tier, walk, worst, where)
					)
					t.ok(worst <= 0.3, `{kind.name} tier {tier} walk {walk}: at most 0.3 studs a frame ({worst})`)
				end
			end
		end
		print("         the largest step of any box corner, 60 frames a second, studs:")
		for _, line in lines do
			print("           " .. line)
		end
		-- Smooth, not merely slow: halving the frame time halves the largest step (a jump would
		-- not shrink).
		for _, name in { "Zombie", "ZombieRunner", "ZombieBrute", "ZombieCrawler", "ZombieScreamer" } do
			local kind = kindNamed(name)
			local variant = MobList.lookVariant(1, 2)
			for _, tier in { MobRig.FULL, MobRig.REDUCED } do
				local at60 = largestStep(kind, variant, tier, steady(0.25), 1 / 60, 8, busy)
				local at120 = largestStep(kind, variant, tier, steady(0.25), 1 / 120, 8, busy)
				t.ok(at120 <= 0.6 * at60, `{name} tier {tier}: no jumps ({at60} -> {at120})`)
			end
		end
	end)

	--[[
		Whatever the flags and the pace do, every sync: a seeded run flips each flag at random
		(Aggressive, Attack, Breaking and Screaming) and jumps the pace between standing, the
		kind's chase and walk 1 (half the runs stay at walk 1, where a brute hammering while flung
		once moved a hand 0.31 studs a frame: a bent elbow reaches further than a straight arm,
		and the torso's sway carries the arms). No corner moves more than LIMB_SPEED allows a
		frame (0.29 studs), inside the 0.3 budget.
	]]
	t.test("mob rig: poses stay continuous whatever the flags and the pace do", function()
		local bound = MobRig.LIMB_SPEED / 60
		t.ok(bound <= 0.3, `the limbs' bound is inside the budget ({bound})`)
		local lines = {}
		for _, kind in zombies() do
			local looks = #(MobList.looksOf(kind) :: { MobList.Look })
			local chase = chasePace(kind)
			for _, tier in { MobRig.FULL, MobRig.REDUCED } do
				local worst, where = 0, ""
				for run = 1, 6 do
					local seed = (kind.id * 7919 + run * 104729 + tier * 31) % 2147483647
					local function rand(): number
						seed = (seed * 48271) % 2147483647
						return seed / 2147483647
					end
					-- A 12 s schedule, one entry a sync.
					local flagsList, paceList = {}, {}
					local flags, pace = 0, if run % 2 == 0 then 0.25 else chase
					for i = 0, 130 do
						if rand() < 0.15 then
							flags = bit32.bxor(flags, F.AGGRESSIVE)
						end
						if rand() < 0.2 then
							flags = bit32.bxor(flags, F.ATTACK)
						end
						if rand() < 0.1 then
							flags = bit32.bxor(flags, F.BREAKING)
						end
						if rand() < 0.08 then
							flags = bit32.bxor(flags, F.SCREAMING)
						end
						if run % 2 == 1 then
							local u = rand()
							if u < 0.05 then
								pace = 0
							elseif u < 0.1 then
								pace = chase
							elseif u < 0.15 then
								pace = 0.25
							end
						end
						flagsList[i], paceList[i] = flags, pace
					end
					local function at(list: { [number]: number }): (number) -> number
						return function(time: number): number
							return list[math.floor(time * 10 + 0.5)] or 0
						end
					end
					local id = math.floor(rand() * 100000) + 1
					local variant = MobList.lookVariant(math.floor(rand() * looks) + 1, math.floor(rand() * 6) + 1)
					local step, name = largestStep(kind, variant, tier, at(paceList), 1 / 60, 12, at(flagsList), id)
					if step > worst then
						worst, where = step, `{name}, run {run}`
					end
				end
				table.insert(lines, string.format("%s tier %d: %.3f (%s)", kind.name, tier, worst, where))
				t.ok(worst <= bound + 1e-9, `{kind.name} tier {tier}: at most {bound} studs a frame ({worst}, {where})`)
			end
		end
		print("         the largest step of any box corner, random flags and pace, studs:")
		for _, line in lines do
			print("           " .. line)
		end
	end)

	t.test("mob rig: a crawler lies within 0.7 blocks of the floor", function()
		local crawler = kindNamed("ZombieCrawler")
		t.eq(crawler.rig and crawler.rig.gait, "crawl")
		local modes = {
			function(_time: number): number
				return 0
			end,
			busy,
		}
		local top, bottom = -math.huge, math.huge
		for _, variant in lookVariants(crawler) do
			local build = MobRig.build(crawler, variant)
			for _, shape in { build.full :: MobRig.Shape, build.reduced :: MobRig.Shape } do
				for _, flagsAt in modes do
					local mob = newMob(crawler, variant, 3)
					local rel = table.create(12 * MobRig.FULL_SLOTS, 0)
					local z, nextUpdate = 0, 0
					for frame = 0, 480 do
						local now = frame / 60
						while nextUpdate <= now do
							z += 0.15 * 2
							local state = { x = 0, y = 0, z = z, yaw = 0, health = 20, flags = flagsAt(nextUpdate) }
							MobModel.apply(mob, state, nextUpdate)
							nextUpdate += 0.1
						end
						MobModel.stride(mob, now)
						MobRig.pose(rel, build, shape, mob, now)
						for slot = 1, shape.count do
							if not shape.hidden[slot] then
								for _, c in corners(rel, shape, slot) do
									top, bottom = math.max(top, c[2] / BLOCK), math.min(bottom, c[2] / BLOCK)
								end
							end
						end
					end
				end
			end
		end
		print(string.format("         a crawler's boxes: %.2f to %.2f blocks above the floor", bottom, top))
		t.ok(top <= 0.7, `every box within 0.7 blocks of the floor ({top})`)
		-- (The hands and the reduced rig's arms press into the floor a little as they claw.)
		t.ok(bottom >= -0.3, `nothing sinks far into the floor ({bottom})`)
	end)

	t.test("mob rig: hidden parts are neither drawn nor posed", function()
		local crawler = kindNamed("ZombieCrawler")
		local build = MobRig.build(crawler, MobList.lookVariant(11, 1))
		local full = build.full :: MobRig.Shape
		local hidden = {}
		for slot = 1, full.count do
			if full.hidden[slot] then
				hidden[full.names[slot]] = true
			end
		end
		for _, name in (crawler.rig :: MobList.Rig).hide :: { string } do
			t.ok(hidden[name], `{name} is hidden`)
		end
		local count = 0
		for _ in hidden do
			count += 1
		end
		t.eq(count, 4, "the lower legs and feet only")
		t.eq(MobRig.drawn(full), full.count - 4, "drawn: the rest")
		t.eq(MobRig.drawn(build.reduced :: MobRig.Shape), (build.reduced :: MobRig.Shape).count, "reduced: all")
		-- Posing leaves the hidden slots alone; placing writes only the drawn ones.
		local rel = table.create(12 * MobRig.FULL_SLOTS, -1234)
		local mob = newMob(crawler, 1)
		mob.walk, mob.phase = 1, 3
		MobRig.pose(rel, build, full, mob, 2)
		for slot = 1, full.count do
			local untouched = true
			for i = 1, 12 do
				untouched = untouched and rel[(slot - 1) * 12 + i] == -1234
			end
			t.eq(untouched, full.hidden[slot], `{full.names[slot]}: posed only if drawn`)
		end
		local out = {}
		local stop = MobRig.place(out, 0, rel, full, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1)
		t.eq(stop, 12 * MobRig.drawn(full), "12 numbers a drawn box")
		t.eq(#out, stop)
		for i = 1, stop do
			t.ok(out[i] ~= -1234, "no hidden frame placed")
		end
	end)

	-- A made-up kind wearing `look` (no tears, no blood unless the look says so).
	local function dressed(look: { [string]: any }): MobList.Kind
		local base = kindNamed("Zombie")
		local fake = table.clone(base) :: any
		look.name = look.name or "Test"
		look.weight = 1
		look.torn = look.torn or 0
		look.blood = look.blood or 0
		fake.looks = { look }
		return fake :: MobList.Kind
	end

	t.test("zombie looks: colours follow sleeves, legs, gloves, shirtless and barefoot", function()
		local pack = ZombieLooks.pack
		local skinTone = MobList.SKIN_TONES[2]
		local skin = pack(skinTone[1], skinTone[2], skinTone[3])
		local SHIRT, PANTS, SHOES, GLOVES = { 200, 10, 10 }, { 10, 10, 200 }, { 30, 30, 30 }, { 9, 9, 9 }
		local shirt, pants, shoes, gloves = pack(200, 10, 10), pack(10, 10, 200), pack(30, 30, 30), pack(9, 9, 9)
		local variant = MobList.lookVariant(1, 2)
		local function colours(look: { [string]: any }): { number }
			return ZombieLooks.full(dressed(look), variant, 99)
		end
		-- Short sleeves (the default), long trousers (the default), shoes, gloves.
		local c = colours({ shirt = SHIRT, pants = PANTS, shoes = SHOES, gloves = GLOVES })
		t.eq(c[MobRig.HEAD], skin, "head: skin")
		t.eq(c[MobRig.UPPER_TORSO], shirt, "upper torso: the shirt")
		t.eq(c[MobRig.LOWER_TORSO], pants, "lower torso: the pants")
		t.eq(c[MobRig.LEFT_UPPER_ARM], shirt, "short sleeves cover the upper arms")
		t.eq(c[MobRig.RIGHT_LOWER_ARM], skin, "... not the forearms")
		t.eq(c[MobRig.LEFT_HAND], gloves, "gloves")
		t.eq(c[MobRig.RIGHT_LOWER_LEG], pants, "long trousers")
		t.eq(c[MobRig.LEFT_FOOT], shoes, "shoes")
		-- Long sleeves; no gloves.
		c = colours({ shirt = SHIRT, pants = PANTS, shoes = SHOES, sleeves = "long" })
		t.eq(c[MobRig.LEFT_LOWER_ARM], shirt, "long sleeves cover the forearms")
		t.eq(c[MobRig.RIGHT_HAND], skin, "bare hands")
		-- No sleeves, shorts, barefoot.
		c = colours({ shirt = SHIRT, pants = PANTS, sleeves = "none", legs = "shorts" })
		t.eq(c[MobRig.RIGHT_UPPER_ARM], skin, "sleeveless: bare upper arms")
		t.eq(c[MobRig.LEFT_LOWER_ARM], skin)
		t.eq(c[MobRig.LEFT_UPPER_LEG], pants, "shorts cover the thighs")
		t.eq(c[MobRig.RIGHT_LOWER_LEG], skin, "... not the shins")
		t.eq(c[MobRig.RIGHT_FOOT], skin, "barefoot")
		-- Shirtless: torso and arms skin, whatever the sleeves say.
		c = colours({ pants = PANTS, shoes = SHOES, sleeves = "long" })
		t.eq(c[MobRig.UPPER_TORSO], skin, "shirtless")
		t.eq(c[MobRig.LEFT_UPPER_ARM], skin)
		t.eq(c[MobRig.LEFT_LOWER_ARM], skin)
		-- The extras in slot order, in their own colours; the reduced rig and the impostor.
		local look =
			{ shirt = SHIRT, pants = PANTS, vest = { 1, 2, 3 }, hat = { kind = "helmet", color = { 4, 5, 6 } } }
		local kind = dressed(look)
		c = ZombieLooks.full(kind, variant, 99)
		t.eq(c[MobRig.BODY + 1], pack(1, 2, 3), "the vest")
		t.eq(c[MobRig.BODY + 2], pack(4, 5, 6), "the hat")
		local paint = ZombieLooks.paint(kind, variant, 99)
		t.eq(paint.reduced[MobRig.TORSO], shirt, "reduced torso: the shirt")
		t.eq(paint.reduced[MobRig.LEFT_ARM], shirt, "reduced arm: the upper arm's")
		t.eq(paint.reduced[MobRig.RIGHT_LEG], pants, "reduced leg: the pants")
		t.eq(paint.reduced[MobRig.REDUCED_HEAD], skin, "reduced head: skin")
		t.eq(paint.reduced[MobRig.REDUCED_BODY + 1], pack(1, 2, 3), "reduced vest")
		t.eq(paint.reduced[MobRig.REDUCED_BODY + 2], pack(4, 5, 6), "reduced hat")
		t.eq(paint.impostor[1], shirt, "the impostor's body: the shirt (WAILA's colour)")
		t.eq(paint.impostor[2], skin, "its head: the skin")
		-- A sheep is no zombie: its boxes in its fleece.
		local sheep = kindNamed("Sheep")
		local fleece = ZombieLooks.paint(sheep, 2, 1)
		t.eq(fleece.impostor[1], pack(30, 27, 27), "a black sheep")
		t.eq(#fleece.full, 0, "no rig")
	end)

	t.test("zombie looks: tears and blood come from the id, at their odds", function()
		local zombie = kindNamed("Zombie")
		local variant = MobList.lookVariant(1, 1) -- Red tee: torn 0.2, blood 0.3 (the defaults)
		local look = (MobList.look(zombie, variant)) :: MobList.Look
		local shirt = ZombieLooks.pack(look.shirt[1], look.shirt[2], look.shirt[3])
		local pants = ZombieLooks.pack(look.pants[1], look.pants[2], look.pants[3])
		local skinTone = MobList.SKIN_TONES[1]
		local skin = ZombieLooks.pack(skinTone[1], skinTone[2], skinTone[3])
		local n = 4000
		local tornTorso, bloodyTorso, seatTorn = 0, 0, 0
		for id = 1, n do
			local c = ZombieLooks.full(zombie, variant, id)
			local again = ZombieLooks.full(zombie, variant, id)
			for slot = 1, MobRig.BODY do
				assert(c[slot] == again[slot], "the same zombie is dressed the same")
			end
			local torn = Hash.hash2(id, MobRig.UPPER_TORSO, 0) / U32 < 0.2
			local bloody = Hash.hash2(id, MobRig.UPPER_TORSO + 32, 0) / U32 < 0.3
			if torn then
				tornTorso += 1
			end
			if bloody then
				bloodyTorso += 1
			end
			local expected = if torn then skin else shirt
			if bloody then
				local r, g, b = ZombieLooks.unpack(expected)
				expected = ZombieLooks.pack(r + (110 - r) * 0.35, g + (20 - g) * 0.35, b + (20 - b) * 0.35)
			end
			assert(c[MobRig.UPPER_TORSO] == expected, `zombie {id}: its torso`)
			local seat = c[MobRig.LOWER_TORSO]
			if seat ~= pants then
				local r, g, b = ZombieLooks.unpack(pants)
				local stained = ZombieLooks.pack(r + (110 - r) * 0.35, g + (20 - g) * 0.35, b + (20 - b) * 0.35)
				if seat ~= stained then
					seatTorn += 1
				end
			end
			assert(c[MobRig.HEAD] == skin, "the head is never stained")
		end
		t.near(tornTorso / n, 0.2, 0.03, "a fifth of the shirts torn")
		t.near(bloodyTorso / n, 0.3, 0.03, "three in ten bloodied")
		t.eq(seatTorn, 0, "the seat of the pants never tears")
	end)

	t.test("mob rig: every look of every kind fits 17 full and 8 reduced parts", function()
		local looks = 0
		for _, kind in zombies() do
			for _, variant in lookVariants(kind) do
				local build = MobRig.build(kind, variant)
				local look = (MobList.look(kind, variant)) :: MobList.Look
				local full, reduced = build.full :: MobRig.Shape, build.reduced :: MobRig.Shape
				local extras = #MobRig.extras(look)
				t.eq(full.body, 15, `{kind.name}'s {look.name}: an R15 body`)
				t.eq(full.count, 15 + extras, `{kind.name}'s {look.name}: its extras`)
				t.ok(full.count <= 17, `{kind.name}'s {look.name}: {full.count} full parts`)
				t.ok(reduced.count <= 8, `{kind.name}'s {look.name}: {reduced.count} reduced parts`)
				t.eq(reduced.count, 6 + extras - (if look.stripes then 1 else 0), "the reduced rig drops the band")
				t.eq(#ZombieLooks.full(kind, variant, 1) >= full.count, true, "a colour a part")
				looks += 1
			end
		end
		t.ok(looks >= 30, `every look checked ({looks})`)
		-- The impostor of every kind is its two boxes.
		for _, kind in MobList.kinds do
			local build = MobRig.build(kind, 1)
			t.eq(build.impostor.count, #kind.parts, `{kind.name}: its boxes`)
			t.ok(build.impostor.count <= MobRig.IMPOSTOR_SLOTS, "at most two")
		end
	end)

	t.test("mob rig: only the head and torso cast shadows", function()
		local build = MobRig.build(kindNamed("ZombieSoldier"), 1)
		local full, reduced = build.full :: MobRig.Shape, build.reduced :: MobRig.Shape
		local casting = {}
		for slot = 1, full.count do
			if full.shadow[slot] then
				table.insert(casting, full.names[slot])
			end
		end
		table.sort(casting)
		t.eq(table.concat(casting, " "), "Head LowerTorso UpperTorso", "full rig")
		table.clear(casting)
		for slot = 1, reduced.count do
			if reduced.shadow[slot] then
				table.insert(casting, reduced.names[slot])
			end
		end
		table.sort(casting)
		t.eq(table.concat(casting, " "), "Head Torso", "reduced rig")
		t.eq(Config.Mobs.Rig.ShadowParts, 3)
	end)

	t.test("cost: posing 16 full and 24 reduced rigs a frame", function()
		local kinds = zombies()
		local mobs, builds = {}, {}
		for i = 1, 40 do
			local kind = kinds[(i - 1) % #kinds + 1]
			local variant = MobList.randomVariant(kind, function()
				return ((i * 37) % 100) / 100
			end)
			local mob = newMob(kind, variant, i)
			mob.walk, mob.aggro = 0.5, (i % 2)
			mobs[i], builds[i] = mob, MobRig.build(kind, variant)
		end
		local rel = table.create(12 * MobRig.FULL_SLOTS, 0)
		local times = {}
		for frame = 1, 400 do
			local now = frame / 60
			local start = os.clock()
			for i = 1, 40 do
				local mob = mobs[i]
				mob.phase += mob.walk / 3
				local build = builds[i]
				MobRig.pose(rel, build, (if i <= 16 then build.full else build.reduced) :: MobRig.Shape, mob, now)
			end
			times[frame] = (os.clock() - start) * 1000
		end
		table.sort(times)
		local median, p90 = times[200], times[360]
		print(
			string.format(
				"         MobRig.pose, 16 full + 24 reduced (%s): median %.3f ms, p90 %.3f ms a frame",
				if NATIVE then "native" else "interpreted",
				median,
				p90
			)
		)
		-- (Native: the design's 0.6 ms; interpreted, a Roblox client without native code: 1.5.)
		local budget = if NATIVE then 0.6 else 1.5
		t.ok(median <= budget, `posing 40 rigs within {budget} ms ({median})`)
	end)
end
