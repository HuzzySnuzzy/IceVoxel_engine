--[[
	A shot's flight (Shared/Weapons/Ballistics): the zero and the drop, segments that never step
	over a wall, the slab test, every kind of head box and which box a ray counts (every kind's
	drawn head a head shot and its chest never, against client Entities/MobRig), the nearest hit
	(block or box), glass shattered through and leaves passed, unloaded cells, falloff, pellets
	within their cones, the lag-compensated box (server Weapons/FireRules.mobTarget) and the
	bounds a flight stays in.
]]

return function(t, shared, require, server, client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Items = require(shared.Items)
	local MobList = require(shared.Entities.MobList)
	local MobShape = require(shared.Entities.MobShape)
	local Weapons = require(shared.Weapons)
	local Ballistics = require(shared.Weapons.Ballistics)
	local FireRules = require(server.Weapons.FireRules)

	local I = Items.id
	local B = Blocks.id
	local AIR = Blocks.AIR
	local STONE = B.Stone
	local GLASS = B.Glass
	local LEAVES = B.OakLeaves
	local TORCH = B.Torch

	local function kind(name: string): any
		return MobList.get(MobList.find(name) :: number)
	end

	-- A flight of `ammo` (an item name) from `gun`, or of the numbers given.
	local function shotOf(gun: string, ammo: string, shooter: any?): any
		local spec = Weapons.firearm(I[gun]) :: Weapons.FirearmSpec
		local round = Weapons.ammo(I[ammo]) :: Weapons.AmmoSpec
		return FireRules.shotSpec(spec, round, Config.Weapons, shooter)
	end

	local function plain(overrides: { [string]: any }): any
		local shot = {
			velocity = 400,
			gravity = 0,
			zero = 25,
			range = 40,
			maxRange = 100,
			falloffMin = 0.5,
			damage = 10,
			segment = 0.05,
			shooter = nil,
		}
		for key, value in overrides do
			shot[key] = value
		end
		return shot
	end

	-- Blocks: `cells` "x,y,z" -> block, else `fill(x, y, z)` (default air).
	local function worldOf(cells: { [string]: number }?, fill: ((number, number, number) -> number?)?)
		local map = cells or {}
		return function(x: number, y: number, z: number): number?
			local block = map[`{x},{y},{z}`]
			if block ~= nil then
				return block
			end
			if fill then
				return fill(x, y, z)
			end
			return AIR
		end
	end

	local function rulesOf(shatter: boolean?, passLeaves: boolean?): any
		return {
			isGlass = function(block: number): boolean
				return block == GLASS
			end,
			shatter = shatter ~= false,
			passes = function(block: number): boolean
				return passLeaves ~= false and block == LEAVES
			end,
			glassShare = Config.Weapons.GlassShare,
		}
	end

	local EAST = { x = 1, y = 0, z = 0 }

	local function last(impacts: { any }): any
		return impacts[#impacts]
	end

	t.test("ballistics: every gun's zero crosses the sight line at its zero distance", function()
		for _, gun in Weapons.FIREARMS do
			local spec = Weapons.firearm(gun) :: Weapons.FirearmSpec
			for _, round in Weapons.ammoFor(spec.calibre) do
				local ammo = Weapons.ammo(round) :: Weapons.AmmoSpec
				local shot = FireRules.shotSpec(spec, ammo, Config.Weapons)
				t.ok(shot.maxRange >= spec.zero, `{spec.name}: {ammo.name} flies past the zero`)
				-- A wall whose face is at the zero distance.
				local wall = spec.zero
				local getBlock = worldOf(nil, function(x: number): number?
					return if x == wall then STONE else AIR
				end)
				local origin = { x = 0, y = 70.25, z = 0.5 }
				local hits = Ballistics.trace(getBlock, origin, EAST, shot, {}, rulesOf())
				local hit = last(hits)
				t.eq(hit.kind, "block", `{spec.name}: {ammo.name} reaches the wall`)
				t.near(hit.x, wall, 1e-9, "at its face")
				t.near(hit.y, origin.y, 0.02, `{spec.name}: {ammo.name} on the sight line at {wall}`)
				-- Halfway it is not below the line (the arc rises then falls; a segment is its chord,
				-- at most g dt^2 / 8 under it).
				local half = math.floor(wall / 2)
				local mid = last(Ballistics.trace(
					worldOf(nil, function(x: number): number?
						return if x == half then STONE else AIR
					end),
					origin,
					EAST,
					shot,
					{},
					rulesOf()
				))
				local sag = shot.gravity * shot.segment * shot.segment / 8
				t.ok(mid.y >= origin.y - sag - 1e-9, `{spec.name}: not under the line before the zero`)
			end
		end
	end)

	t.test("ballistics: a 900 blocks a second round drops less than 0.3 blocks at 200", function()
		local origin = { x = 0, y = 70, z = 0 }
		local wall = worldOf(nil, function(x: number): number?
			return if x == 200 then STONE else AIR
		end)
		local assault = shotOf("AssaultRifle", "Rounds556")
		t.eq(assault.velocity, 900)
		local zeroed = last(Ballistics.trace(wall, origin, EAST, assault, {}, rulesOf()))
		t.eq(zeroed.kind, "block")
		t.ok(math.abs(zeroed.y - origin.y) < 0.3, `zeroed at 100: {zeroed.y - origin.y}`)
		local unzeroed = plain({ velocity = 900, gravity = Config.Weapons.Gravity, zero = 0, maxRange = 256 })
		local fall = last(Ballistics.trace(wall, origin, EAST, unzeroed, {}, rulesOf()))
		t.ok(origin.y - fall.y > 0.2 and origin.y - fall.y < 0.3, `no zero: dropped {origin.y - fall.y}`)
		-- (A slow bolt drops a lot: the arc is real.)
		local bolt = shotOf("Crossbow", "CrossbowBolt")
		local far = last(Ballistics.trace(
			worldOf(nil, function(x: number): number?
				return if x == 100 then STONE else AIR
			end),
			origin,
			EAST,
			bolt,
			{},
			rulesOf()
		))
		t.ok(origin.y - far.y > 5, `a bolt at 100 blocks fell {origin.y - far.y}`)
	end)

	t.test("ballistics: segments never step over a one block wall", function()
		local fast = plain({ velocity = 900, gravity = 0, maxRange = 256 })
		t.ok(fast.velocity * fast.segment > 40, "segments 45 blocks long")
		for x = 1, 250, 3 do
			for _, offset in { 0, 0.37, 0.999 } do
				local getBlock = worldOf({ [`{x},70,0`] = STONE })
				local origin = { x = offset, y = 70.5, z = 0.5 }
				local hit = last(Ballistics.trace(getBlock, origin, EAST, fast, {}, rulesOf()))
				t.eq(hit.kind, "block", `a wall at {x} from {offset}`)
				t.near(hit.x, x, 1e-9)
				t.near(hit.distance, x - offset, 1e-9, "the distance along the path")
			end
		end
		-- Diagonally, through a one block thick wall's corner cells too.
		local diagonal = { x = 1 / math.sqrt(2), y = 0, z = 1 / math.sqrt(2) }
		for d = 2, 120, 7 do
			local getBlock = worldOf(nil, function(x: number, _y: number, z: number): number?
				return if x + z == 2 * d then STONE else AIR
			end)
			local hit = last(Ballistics.trace(getBlock, { x = 0.5, y = 70.5, z = 0.5 }, diagonal, fast, {}, rulesOf()))
			t.eq(hit.kind, "block", `the diagonal wall at {d}`)
		end
		-- A flight ends where its range does.
		local open = Ballistics.trace(worldOf(), { x = 0, y = 70, z = 0 }, EAST, fast, {}, rulesOf())
		t.eq(#open, 1)
		t.eq(open[1].kind, "none")
		t.near(open[1].distance, 256, 1e-6, "the whole flight")
		t.near(open[1].x, 256, 1e-6)
	end)

	t.test("ballistics: torches and water let a bullet by, fences stop it at their post", function()
		local shot = plain({})
		local origin = { x = 0, y = 70.5, z = 0.5 }
		local hits =
			Ballistics.trace(worldOf({ ["5,70,0"] = TORCH, ["9,70,0"] = STONE }), origin, EAST, shot, {}, rulesOf())
		t.eq(#hits, 1)
		t.near(last(hits).x, 9, 1e-9, "past the torch")
		local water = Blocks.fluidId("Water", 0)
		hits = Ballistics.trace(worldOf({ ["5,70,0"] = water, ["9,70,0"] = STONE }), origin, EAST, shot, {}, rulesOf())
		t.near(last(hits).x, 9, 1e-9, "through water")
		local fence = Blocks.fenceVariant(B.OakFence, 0) or B.OakFence
		hits = Ballistics.trace(worldOf({ ["5,70,0"] = fence, ["9,70,0"] = STONE }), origin, EAST, shot, {}, rulesOf())
		t.eq(last(hits).kind, "block")
		t.eq(last(hits).block, fence, "the fence")
		t.ok(last(hits).x > 5.2 and last(hits).x < 5.5, `at its post: {last(hits).x}`)
	end)

	t.test("ballistics: the slab test enters, misses, starts inside and stops at its limit", function()
		local box = { 2, 0, -0.5, 3, 1, 0.5 }
		t.near(Ballistics.enter(box, 0, 0.5, 0, 1, 0, 0, 10) :: number, 2, 1e-12, "ahead")
		t.eq(Ballistics.enter(box, 0, 0.5, 0, 1, 0, 0, 1.5), nil, "beyond the limit")
		t.eq(Ballistics.enter(box, 0, 1.5, 0, 1, 0, 0, 10), nil, "above it")
		t.eq(Ballistics.enter(box, 0, 0.5, 0, -1, 0, 0, 10), nil, "behind")
		t.eq(Ballistics.enter(box, 2.5, 0.5, 0, 1, 0, 0, 10), 0, "inside: at once")
		t.eq(Ballistics.enter(box, 2.5, 3, 0, 1, 0, 0, 10), nil, "parallel, outside its slab")
		local s = 1 / math.sqrt(2)
		t.near(Ballistics.enter(box, 0, -1.5, 0, s, s, 0, 10) :: number, 2 * math.sqrt(2), 1e-9, "diagonal")
	end)

	t.test("ballistics: head boxes where the kinds are drawn, a player's at the eyes", function()
		local m = Ballistics.HEAD_MARGIN
		local zombie = kind("Zombie")
		local sy, sx = MobShape.scale(zombie)
		local neck = MobShape.neck(zombie) :: number
		local drawn = MobShape.head(zombie) :: { number }
		local body, head = Ballistics.mobBoxes(zombie, 10, 64, 20, 0)
		t.near(body[1], 9.7, 1e-9, "the torso as drawn: 0.6 wide")
		t.near(body[5], 64 + neck, 1e-9, "the body to the neck")
		t.near(neck, 1.5, 0.01, "an ordinary zombie's neck at 1.5")
		t.near(head[2], 64 + neck, 1e-9, "the head from the neck")
		t.near(head[5], 64 + drawn[5] + m, 1e-9, "to the drawn head's top and the margin")
		t.ok(head[5] > 64 + 1.95, "over the top of its box (a hat inside)")
		t.near(head[1], 10 - 0.6 * (sx :: number) - m, 1e-9, "as wide as the drawn head and the margin")
		t.ok((sy :: number) > 0, "a rig")
		-- The brute, drawn 2.3 tall and 1.1 wide: its head where it is drawn, its torso as wide.
		local brute = kind("ZombieBrute")
		local bb, bh = Ballistics.mobBoxes(brute, 0, 0, 0, 0)
		t.near(bb[4] - bb[1], 2 * (select(2, MobShape.scale(brute)) :: number), 1e-9, "the torso: 2 studs drawn")
		t.ok(bb[4] - bb[1] > 0.75, "wider than its box")
		t.near(bb[5], 4.0 / 5.2 * 2.3, 0.01, "the body to the drawn neck (1.77)")
		t.near(bh[2], bb[5], 1e-9)
		t.ok(bh[5] > 2.3, "the head up to the drawn top")
		t.ok(bh[2] < 2.035 and bh[5] > 2.035, "the drawn head's centre (2.035) inside")
		-- The crawler's head lies low in front of it, along its yaw (facing (sin yaw, cos yaw)).
		local crawler = kind("ZombieCrawler")
		t.eq(MobShape.neck(crawler), nil, "no neck: it lies down")
		local _, rest = Ballistics.mobBoxes(crawler, 0, 0, 0, 0)
		local forward = (rest[3] + rest[6]) / 2
		t.near(forward, 0.56, 0.01, "0.56 forward")
		t.near((rest[2] + rest[5]) / 2, 0.34, 0.01, "0.34 up")
		for _, yaw in { 0, math.pi / 2, math.pi, -math.pi / 2, 0.6 } do
			local cb, ch = Ballistics.mobBoxes(crawler, 0, 0, 0, yaw)
			t.near((ch[1] + ch[4]) / 2, math.sin(yaw) * forward, 1e-9, "forward along its yaw")
			t.near((ch[3] + ch[6]) / 2, math.cos(yaw) * forward, 1e-9)
			t.near(ch[2], rest[2], 1e-9, "the same height whichever way")
			t.near(cb[5], 0.6, 1e-9, "the body its box")
		end
		-- Turned a quarter, the head's footprint turns with it (a cow's head is wider than deep).
		local cow = kind("Cow")
		local _, c0 = Ballistics.mobBoxes(cow, 0, 0, 0, 0)
		local _, c90 = Ballistics.mobBoxes(cow, 0, 0, 0, math.pi / 2)
		t.near(c0[4] - c0[1], 0.55 + 2 * m, 1e-9, "the drawn head's width")
		t.near(c0[6] - c0[3], 0.4 + 2 * m, 1e-9, "and depth")
		t.near(c90[4] - c90[1], 0.4 + 2 * m, 1e-9, "turned")
		t.near((c90[1] + c90[4]) / 2, 0.55, 1e-9, "in front of it, to the east")
		local pb, ph = Ballistics.playerBoxes(5, 70, 5, 71.62)
		t.near(pb[5], 71.82, 1e-9, "the body to the eyes + 0.2")
		t.near(ph[2], 71.4, 1e-9)
		t.near(ph[4] - ph[1], 0.5, 1e-9)
		local _, crouched = Ballistics.playerBoxes(5, 70, 5, 71.27)
		t.near(crouched[2], 71.05, 1e-9, "the pose-aware eyes")
	end)

	t.test("ballistics: head or body: the first box a ray enters; beside a player's head counts", function()
		local shot = plain({})
		local zombie = FireRules.mobTarget(
			{ id = 1, kind = kind("Zombie"), variant = 1, x = 10.5, y = 70, z = 0.5, yaw = 0 },
			Config.Weapons
		)
		local getBlock = worldOf()
		local function shoot(target: any, origin: any, dir: any): any
			return last(Ballistics.trace(getBlock, origin, dir, shot, { target }, rulesOf()))
		end
		local headShot = shoot(zombie, { x = 0, y = 71.8, z = 0.5 }, EAST)
		t.eq(headShot.kind, "mob")
		t.eq(headShot.head, true, "at the head's height")
		t.eq(headShot.target, zombie)
		local chest = shoot(zombie, { x = 0, y = 71.2, z = 0.5 }, EAST)
		t.eq(chest.kind, "mob")
		t.eq(chest.head, false, "the chest")
		-- Steeply up from below: in through the legs, so not the head above.
		local up = { x = 0.2, y = 0.98, z = 0 }
		local n = math.sqrt(up.x * up.x + up.y * up.y)
		local climb = shoot(zombie, { x = 10.3, y = 69.9, z = 0.5 }, { x = up.x / n, y = up.y / n, z = 0 })
		t.eq(climb.kind, "mob")
		t.eq(climb.head, false, "a ray through the body first hits the body")
		-- From above, straight down onto the crown; from behind at the head's height.
		local crown = shoot(zombie, { x = 10.5, y = 75, z = 0.5 }, { x = 0, y = -1, z = 0 })
		t.eq(crown.head, true, "from above: the head")
		local back = shoot(zombie, { x = 10.5, y = 71.7, z = -9.5 }, { x = 0, y = 0, z = 1 })
		t.eq(back.head, true, "from behind: the back of its head")
		-- Over the shoulder, beside the head: air.
		local beside = shoot(zombie, { x = 0, y = 71.8, z = 0.5 + 0.45 }, EAST)
		t.eq(beside.kind, "none", "beside the head: nothing drawn there")
		-- The brute's head is where it is drawn: a level shot at it (2.035 up) is a head shot.
		local brute = FireRules.mobTarget(
			{ id = 2, kind = kind("ZombieBrute"), variant = 1, x = 10.5, y = 70, z = 0.5, yaw = 0 },
			Config.Weapons
		)
		local bruteHead = shoot(brute, { x = 0, y = 72.035, z = 0.5 }, EAST)
		t.eq(bruteHead.kind, "mob", "the drawn head: not over it")
		t.eq(bruteHead.head, true, "a head shot")
		local bruteNeck = shoot(brute, { x = 0, y = 71.65, z = 0.5 }, EAST)
		t.eq(bruteNeck.head, false, "the upper chest is the chest")
		local shoulder = shoot(brute, { x = 0, y = 71.6, z = 0.5 + 0.45 }, EAST)
		t.eq(shoulder.kind, "mob", "its shoulder, as broad as drawn")
		t.eq(shoulder.head, false)
		-- A crawler's head sticks out in front of it; its back and sides are its body.
		local crawler = FireRules.mobTarget(
			{ id = 3, kind = kind("ZombieCrawler"), variant = 1, x = 10.5, y = 70, z = 0.5, yaw = -math.pi / 2 },
			Config.Weapons
		)
		local low = shoot(crawler, { x = 0, y = 70.34, z = 0.5 }, EAST)
		t.eq(low.head, true, "the head facing the shooter")
		t.ok(low.x < 10.5 - 0.375, "before the body")
		local intoBack = shoot(crawler, { x = 20, y = 70.4, z = 0.5 }, { x = -1, y = 0, z = 0 })
		t.eq(intoBack.kind, "mob")
		t.eq(intoBack.head, false, "into its back and on to the head: the back")
		t.near(intoBack.x, 10.5 + 0.375, 1e-9, "where the back is")
		local side = shoot(crawler, { x = 10.45, y = 70.3, z = -9.5 }, { x = 0, y = 0, z = 1 })
		t.eq(side.kind, "mob")
		t.eq(side.head, false, "from the side through its middle: the body")
		-- So with an animal: its head in front, its rump behind.
		local pig = FireRules.mobTarget(
			{ id = 4, kind = kind("Pig"), variant = 1, x = 10.5, y = 70, z = 0.5, yaw = math.pi / 2 },
			Config.Weapons
		)
		t.eq(shoot(pig, { x = 20, y = 70.6, z = 0.5 }, { x = -1, y = 0, z = 0 }).head, true, "its face")
		local rump = shoot(pig, { x = 0, y = 70.6, z = 0.5 }, EAST)
		t.eq(rump.kind, "mob")
		t.eq(rump.head, false, "from behind: its rump")
		-- A player's body box rises beside the head: entering it there and on into the head counts.
		local player = FireRules.playerTarget("p", 10.5, 70, 0.5, 71.62)
		local cheek = shoot(player, { x = 0, y = 71.7, z = 0.5 + 0.27 }, { x = 1, y = 0, z = -0.02 })
		t.eq(cheek.kind, "player")
		t.eq(cheek.head, true, "in beside the head, on into it")
		local ear = shoot(player, { x = 0, y = 71.7, z = 0.5 + 0.28 }, EAST)
		t.eq(ear.kind, "player")
		t.eq(ear.head, false, "beside it, never in it: the body box")
		-- The shooter is never a target.
		local me = FireRules.playerTarget("me", 0.5, 70, 0.5, 71.62)
		local shotMine = plain({ shooter = "me" })
		local mine =
			last(Ballistics.trace(getBlock, { x = 0.5, y = 71.62, z = 0.5 }, EAST, shotMine, { me }, rulesOf()))
		t.eq(mine.kind, "none", "never the shooter")
	end)

	t.test("ballistics: every kind's head as drawn is a head shot, its chest never", function()
		local MobRig = require(client.Entities.MobRig)
		local MobModel = require(client.Entities.MobModel)
		local BLOCK = Config.BlockSize
		local frames = table.create(12 * MobRig.FULL_SLOTS, 0)
		local rel = table.create(12 * MobRig.FULL_SLOTS, 0)
		-- The world centre (blocks) of `shape`'s slot named `name` (or numbered), posed for `mob`.
		local function centre(
			build: any,
			shape: any,
			mob: any,
			now: number,
			x: number,
			y: number,
			z: number,
			yaw: number,
			slot: number
		): (number, number, number)
			MobRig.pose(rel, build, shape, mob, now)
			local bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22 =
				MobRig.base(x * BLOCK, y * BLOCK, z * BLOCK, yaw, 0, 0)
			MobRig.place(frames, 0, rel, shape, bx, by, bz, b00, b01, b02, b10, b11, b12, b20, b21, b22)
			-- (Only drawn slots are placed, in order.)
			local at = 0
			for k = 1, slot - 1 do
				if not shape.hidden[k] then
					at += 12
				end
			end
			return frames[at + 1] / BLOCK, frames[at + 2] / BLOCK, frames[at + 3] / BLOCK
		end
		local function slotNamed(shape: any, names: { string }, fallback: number): number
			for slot = 1, shape.count do
				if table.find(names, shape.names[slot]) then
					return slot
				end
			end
			return fallback
		end
		local checked = 0
		for _, k in MobList.kinds do
			local build = MobRig.build(k, 1)
			-- (A zombie on its feet: its head on its neck, seen from every side.)
			local standing = k.rig ~= nil and k.rig.gait ~= "crawl"
			local tiers = if k.rig then { MobRig.FULL, MobRig.REDUCED, MobRig.IMPOSTOR } else { MobRig.IMPOSTOR }
			for _, tier in tiers do
				local shape = MobRig.shape(build, tier)
				local headSlot = slotNamed(shape, { "Head" }, 2)
				local chestSlot = slotNamed(shape, { "UpperTorso", "Torso" }, 1)
				-- At rest; walking calm; chasing with an attack swing.
				for pose = 1, 3 do
					for _, yaw in { 0, 0.7, math.pi / 2, math.pi, -2.2 } do
						local mob = MobModel.new(9, k, 1, { x = 0, y = 0, z = 0, yaw = 0, health = 20, flags = 0 }, 0)
						local now = 0
						if pose >= 2 then
							mob.walk, mob.phase, now = 1, 2.1 * pose, 1.3 * pose
						end
						if pose == 3 then
							mob.aggro, mob.swingStart = 1, now - 0.1
						end
						local target = FireRules.mobTarget(
							{ id = 9, kind = k, variant = 1, x = 10.5, y = 70, z = 0.5, yaw = yaw },
							Config.Weapons
						)
						local where = `{k.name} tier {tier} pose {pose} yaw {yaw}`
						local fx, fz = math.sin(yaw), math.cos(yaw)
						local lx, lz = math.cos(yaw), -math.sin(yaw)
						-- Shots at a point from 10 blocks off: from the front, both sides, behind, above.
						local function from(px: number, py: number, pz: number, side: string): (number?, boolean)
							local ux, uy, uz = 0, 0, 0
							if side == "front" then
								ux, uz = -fx, -fz
							elseif side == "behind" then
								ux, uz = fx, fz
							elseif side == "left" then
								ux, uz = -lx, -lz
							elseif side == "right" then
								ux, uz = lx, lz
							else
								uy = -1
							end
							return Ballistics.hit(target, px - ux * 10, py - uy * 10, pz - uz * 10, ux, uy, uz, 20)
						end
						local hx, hy, hz = centre(build, shape, mob, now, 10.5, 70, 0.5, yaw, headSlot)
						local headSides = { "front", "left", "right", "above" }
						if standing then
							table.insert(headSides, "behind")
						end
						for _, side in headSides do
							local d, head = from(hx, hy, hz, side)
							t.ok(d ~= nil and head, `{where}: the drawn head's centre from {side} is a head shot`)
							checked += 1
						end
						local cx, cy, cz = centre(build, shape, mob, now, 10.5, 70, 0.5, yaw, chestSlot)
						local chestSides = { "behind", "left", "right" }
						if standing then
							table.insert(chestSides, "front")
						end
						for _, side in chestSides do
							local d, head = from(cx, cy, cz, side)
							t.ok(d ~= nil and not head, `{where}: the drawn chest's centre from {side} is a body shot`)
							checked += 1
						end
					end
				end
			end
		end
		t.ok(checked > 1000, `every kind, tier, pose and side: {checked} shots`)
	end)

	t.test("ballistics: the nearest hit wins, block or box", function()
		local shot = plain({})
		local origin = { x = 0, y = 71.2, z = 0.5 }
		local near = FireRules.mobTarget(
			{ id = 1, kind = kind("Zombie"), variant = 1, x = 6.5, y = 70, z = 0.5, yaw = 0 },
			Config.Weapons
		)
		local far = FireRules.mobTarget(
			{ id = 2, kind = kind("Zombie"), variant = 1, x = 12.5, y = 70, z = 0.5, yaw = 0 },
			Config.Weapons
		)
		local wallNear = worldOf({ ["4,71,0"] = STONE })
		local wallMid = worldOf({ ["9,71,0"] = STONE })
		local hit = last(Ballistics.trace(worldOf(), origin, EAST, shot, { far, near }, rulesOf()))
		t.eq(hit.target, near, "the nearer of two mobs, whatever the order")
		hit = last(Ballistics.trace(wallNear, origin, EAST, shot, { far, near }, rulesOf()))
		t.eq(hit.kind, "block", "a wall before both")
		t.near(hit.x, 4, 1e-9)
		hit = last(Ballistics.trace(wallMid, origin, EAST, shot, { far }, rulesOf()))
		t.eq(hit.kind, "block", "the wall in front of the far one")
		hit = last(Ballistics.trace(wallMid, origin, EAST, shot, { far, near }, rulesOf()))
		t.eq(hit.target, near, "the mob in front of the wall")
		t.near(hit.x, 6.2, 1e-9)
		t.near(hit.distance, 6.2, 1e-9)
		t.eq(hit.share, 1, "within range: all of it")
	end)

	t.test("ballistics: glass shatters through at 0.7 a pane, leaves are passed", function()
		local shot = plain({})
		local origin = { x = 0, y = 71.2, z = 0.5 }
		local zombie = FireRules.mobTarget(
			{ id = 1, kind = kind("Zombie"), variant = 1, x = 12.5, y = 70, z = 0.5, yaw = 0 },
			Config.Weapons
		)
		local panes = worldOf({ ["4,71,0"] = GLASS, ["7,71,0"] = GLASS })
		local hits = Ballistics.trace(panes, origin, EAST, shot, { zombie }, rulesOf())
		t.eq(#hits, 3, "two panes and the mob")
		t.eq(hits[1].kind, "glass")
		t.eq(hits[1].cell[1], 4)
		t.eq(hits[1].block, GLASS)
		t.near(hits[1].share, 1, 1e-9, "the first pane met at full share")
		t.eq(hits[2].kind, "glass")
		t.near(hits[2].share, 0.7, 1e-9)
		t.eq(hits[3].kind, "mob")
		t.near(hits[3].share, 0.49, 1e-9, "0.7 a pane")
		t.near(Ballistics.damage(shot, hits[3]), 4.9, 1e-9)
		-- A shooter who may not build: glass is a wall.
		hits = Ballistics.trace(panes, origin, EAST, shot, { zombie }, rulesOf(false))
		t.eq(#hits, 1)
		t.eq(hits[1].kind, "block")
		t.eq(hits[1].block, GLASS)
		-- At most MAX_PANES panes; the next stops it.
		local cells = {}
		for x = 2, 2 + Ballistics.MAX_PANES do
			cells[`{x},71,0`] = GLASS
		end
		hits = Ballistics.trace(worldOf(cells), origin, EAST, shot, { zombie }, rulesOf())
		t.eq(#hits, Ballistics.MAX_PANES + 1)
		t.eq(last(hits).kind, "block", "the last pane stops it")
		-- Leaves are flown through (and stop it without PassLeaves).
		local leafy = worldOf({ ["4,71,0"] = LEAVES, ["5,71,0"] = LEAVES })
		hits = Ballistics.trace(leafy, origin, EAST, shot, { zombie }, rulesOf())
		t.eq(#hits, 1)
		t.eq(hits[1].kind, "mob", "through the leaves")
		t.eq(hits[1].share, 1, "at no cost")
		hits = Ballistics.trace(leafy, origin, EAST, shot, { zombie }, rulesOf(true, false))
		t.eq(hits[1].kind, "block", "PassLeaves off")
		-- The server's rules: Glass by name, every block named "...Leaves".
		local rules = FireRules.blockRules(Config.Weapons, true)
		t.ok(rules.isGlass(GLASS) and not rules.isGlass(STONE), "glass")
		t.ok(rules.passes(LEAVES) and rules.passes(B.SpruceLeaves) and not rules.passes(STONE), "leaves")
		t.eq(rules.shatter, Config.Weapons.ShatterGlass)
		t.eq(FireRules.blockRules(Config.Weapons, false).shatter, false, "not for those who may not build")
	end)

	t.test("ballistics: an unloaded cell stops a flight", function()
		local shot = plain({})
		local getBlock = worldOf(nil, function(x: number): number?
			return if x >= 10 then nil else AIR
		end)
		local zombie = FireRules.mobTarget(
			{ id = 1, kind = kind("Zombie"), variant = 1, x = 15.5, y = 70, z = 0.5, yaw = 0 },
			Config.Weapons
		)
		local hits = Ballistics.trace(getBlock, { x = 0.25, y = 71.2, z = 0.5 }, EAST, shot, { zombie }, rulesOf())
		t.eq(#hits, 1)
		t.eq(hits[1].kind, "none", "it ends there")
		t.near(hits[1].x, 10, 1e-9)
		t.near(hits[1].distance, 9.75, 1e-9)
		t.eq(hits[1].target, nil)
	end)

	t.test("ballistics: falloff is full to the range, falloffMin at the end and beyond", function()
		for _, round in Weapons.AMMO do
			local ammo = Weapons.ammo(round) :: Weapons.AmmoSpec
			local far = Ballistics.maxRange(ammo)
			t.eq(far, math.min(ammo.range * 2.5, Config.Weapons.MaxRange), ammo.name)
			t.eq(Ballistics.share(ammo, 0), 1)
			t.eq(Ballistics.share(ammo, ammo.range), 1, `{ammo.name} at its range`)
			t.near(Ballistics.share(ammo, far), ammo.falloffMin, 1e-9, `{ammo.name} at its end`)
			t.near(Ballistics.share(ammo, far + 50), ammo.falloffMin, 1e-9, "beyond")
			local mid = (ammo.range + far) / 2
			t.near(Ballistics.share(ammo, mid), (1 + ammo.falloffMin) / 2, 1e-9, `{ammo.name} halfway`)
		end
		-- The trace's own shares agree: a 9mm round at 60 blocks (range 40, end 100).
		local nine = shotOf("Pistol", "Rounds9mm")
		t.eq(nine.maxRange, 100)
		local zombie = FireRules.mobTarget(
			{ id = 1, kind = kind("Zombie"), variant = 1, x = 60.3, y = 70, z = 0.5, yaw = 0 },
			Config.Weapons
		)
		local hit = last(Ballistics.trace(worldOf(), { x = 0, y = 71.7, z = 0.5 }, EAST, nine, { zombie }, rulesOf()))
		t.eq(hit.kind, "mob")
		local ammo = Weapons.ammo(I.Rounds9mm) :: Weapons.AmmoSpec
		t.near(hit.share, Ballistics.share(ammo, hit.distance), 1e-9)
		t.ok(hit.share < 1 and hit.share > 0.5, `{hit.share}`)
	end)

	t.test("ballistics: buckshot's 8 pellets stay within the shot's and their own cones", function()
		local buck = Weapons.ammo(I.Buckshot) :: Weapons.AmmoSpec
		t.eq(buck.pellets, 8)
		local seed = 12345
		local function random(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		local aim = { x = 0.6, y = 0.1, z = -0.79 }
		local n = math.sqrt(aim.x * aim.x + aim.y * aim.y + aim.z * aim.z)
		aim = { x = aim.x / n, y = aim.y / n, z = aim.z / n }
		local cone = 1.5
		local widest = 0
		for _ = 1, 200 do
			local pellets = Ballistics.pellets(aim.x, aim.y, aim.z, cone, buck.cone, buck.pellets, random)
			t.eq(#pellets, 8)
			local distinct = {}
			for _, p in pellets do
				t.near(p.x * p.x + p.y * p.y + p.z * p.z, 1, 1e-9, "unit")
				local angle = math.deg(math.acos(math.clamp(p.x * aim.x + p.y * aim.y + p.z * aim.z, -1, 1)))
				t.ok(angle <= cone + buck.cone + 1e-6, `a pellet {angle} degrees off`)
				widest = math.max(widest, angle)
				distinct[`{p.x},{p.y},{p.z}`] = true
			end
			local count = 0
			for _ in distinct do
				count += 1
			end
			t.eq(count, 8, "each its own way")
		end
		t.ok(widest > buck.cone, `the cones add up (widest {widest})`)
		-- One pellet: the shot's direction; no cone: the aim itself; at most 12.
		local one = Ballistics.pellets(aim.x, aim.y, aim.z, 0, 0, 1, random)
		t.near(one[1].x, aim.x, 1e-12)
		t.eq(#Ballistics.pellets(1, 0, 0, 1, 1, 40, random), 12)
	end)

	t.test("ballistics: the box where the client saw a mob counts only within LagCompMax", function()
		local zombie = kind("Zombie")
		local s = Config.Weapons
		t.eq(s.LagCompMax, 2)
		local near = FireRules.mobTarget(
			{ id = 1, kind = zombie, variant = 1, x = 20.5, y = 70, z = 0.5, yaw = 0, sx = 20.5, sy = 70, sz = 2.0 },
			s
		)
		t.ok(near.seenBody ~= nil and near.seenHead ~= nil, "1.5 blocks apart: both")
		local far = FireRules.mobTarget(
			{ id = 2, kind = zombie, variant = 1, x = 20.5, y = 70, z = 0.5, yaw = 0, sx = 20.5, sy = 70, sz = 3.0 },
			s
		)
		t.eq(far.seenBody, nil, "2.5 apart: only where it is")
		local unseen =
			FireRules.mobTarget({ id = 3, kind = zombie, variant = 1, x = 20.5, y = 70, z = 0.5, yaw = 0 }, s)
		t.eq(unseen.seenBody, nil, "never sent")
		local still = FireRules.mobTarget(
			{ id = 4, kind = zombie, variant = 1, x = 20.5, y = 70, z = 0.5, yaw = 0, sx = 20.5, sy = 70, sz = 0.5 },
			s
		)
		t.eq(still.seenBody, nil, "the same place: nothing more to test")
		-- A shot at where the client saw it hits within LagCompMax, misses beyond.
		local shot = plain({})
		local origin = { x = 0, y = 71.2, z = 2.0 }
		local hit = last(Ballistics.trace(worldOf(), origin, EAST, shot, { near }, rulesOf()))
		t.eq(hit.kind, "mob", "where it was seen")
		t.eq(hit.target, near)
		local miss = last(Ballistics.trace(worldOf(), { x = 0, y = 71.2, z = 3.0 }, EAST, shot, { far }, rulesOf()))
		t.eq(miss.kind, "none", "too far from where it is")
		-- Both places in the way: the nearer counts.
		local both = FireRules.mobTarget(
			{ id = 5, kind = zombie, variant = 1, x = 20.5, y = 70, z = 0.5, yaw = 0, sx = 19, sy = 70, sz = 0.5 },
			s
		)
		local first = last(Ballistics.trace(worldOf(), { x = 0, y = 71.2, z = 0.5 }, EAST, shot, { both }, rulesOf()))
		t.near(first.x, 18.7, 1e-9, "the seen box, nearer")
	end)

	t.test("ballistics: head factors, damage and the bounds of a flight", function()
		local s = Config.Weapons
		local function target(name: string, variant: number): any
			return FireRules.mobTarget(
				{ id = 1, kind = kind(name), variant = variant, x = 0, y = 0, z = 0, yaw = 0 },
				s
			)
		end
		t.eq(Ballistics.headFactor(target("Zombie", 1)), s.ZombieHead)
		t.eq(Ballistics.headFactor(target("ZombieSoldier", 1)), s.ZombieHead * s.HelmetShare, "a soldier's helmet")
		t.eq(Ballistics.headFactor(target("Cow", 1)), s.MobHead)
		t.eq(Ballistics.headFactor(FireRules.playerTarget("p", 0, 0, 0, 1.62)), s.PlayerHead)
		local shot = plain({ damage = 7 })
		t.near(
			Ballistics.damage(shot, { kind = "mob", head = true, share = 1, target = target("Zombie", 1) } :: any),
			21,
			1e-9
		)
		t.near(
			Ballistics.damage(shot, { kind = "mob", head = false, share = 0.5, target = target("Zombie", 1) } :: any),
			3.5,
			1e-9
		)
		t.eq(Ballistics.damage(shot, { kind = "block", head = false, share = 1 } :: any), 0, "no target")
		-- Bounds hold every point of the flight (a slow bolt's arc falls well below its aim).
		local bolt = shotOf("Crossbow", "CrossbowBolt")
		local origin = { x = 0, y = 100, z = 0 }
		local minX, minY, _, maxX, maxY = Ballistics.bounds(origin, EAST, bolt)
		t.near(minX, 0, 1e-9)
		t.ok(maxX > 140 and maxX <= bolt.maxRange, `as far as it flies: {maxX}`)
		t.ok(maxY >= origin.y and minY < origin.y - 15, `its fall: {minY}`)
		local hit = last(Ballistics.trace(worldOf(), origin, EAST, bolt, {}, rulesOf()))
		t.ok(hit.y >= minY - 1e-9 and hit.x <= maxX + 1e-9, "the end inside")
	end)
end
