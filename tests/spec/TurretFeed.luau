--[[
	A turret's feed on the real pipes (Shared/Turrets): the feeder rule (a turret fires at most
	the rate of the best Logistical Transporter tier feeding it: Shared/Turrets.rpm,
	TransmitterWorld.feedTier) and the demand rule (server Transmitters/Transport: a line into a
	full turret waits 3 ticks instead of backing off), on the real TransmitterWorld, MachineWorld
	and Containers stepped as the server does (pipes, then machines), with the turret kind's own
	tick (Machines/Kinds/Turret) and a stand-in for the server's simulation that fires whenever it
	may and reports the feeder rule's tier.

	The contract (the turrets design's tables, measured on the same code): a turret fed through
	one transporter of its tier or better holds its full rate; through a lower tier exactly that
	tier's rate; longer lines deliver its buffer once a trip (within 5 % of the measured table); a
	line branching to several turrets feeds each as it would alone, evenly when it cannot, and
	each through its cheapest route. The feeder rule counts only transporters that bring the
	turret rounds, forgets one that stopped or was replaced, and keeps a full turret's feeder
	across a restart.
	And every other destination is exactly as before: a machine that demands nothing reproduces
	the deliveries measured on the Transport before the demand rule, chests and furnaces still
	back off, and with Config.Turrets.Enabled false no line waits for a turret. A line waiting for
	a full turret costs what a backoff would: it searches its routes on the same ticks as with the
	turrets off, so every other line pulls as it did then, and pulls take turns when the tick's
	searches run out; yet it sees a turret placed on it or another calibre in its chest within 3
	ticks, and one pull's rounds into many turrets work out their turns once.
]]

local Loader = require("../lib/Loader")

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Coords = require(shared.World.Coords)
	local Items = require(shared.Items)
	local Machines = require(shared.Machines)
	local Transmitters = require(shared.Transmitters)
	local Turrets = require(shared.Turrets)
	local Containers = require(server.Players.Containers)
	local MachineWorld = require(server.Machines.MachineWorld)
	local TransmitterWorld = require(server.Transmitters.TransmitterWorld)
	local Transport = require(server.Transmitters.Transport)

	local B, I = Blocks.id, Items.id
	local AIR = Blocks.AIR
	local M = Transmitters.MODES
	local WEST = 4
	local Y = 64
	local T = {
		B.BasicLogisticalTransporter,
		B.AdvancedLogisticalTransporter,
		B.EliteLogisticalTransporter,
		B.UltimateLogisticalTransporter,
	}
	local STATUS = Turrets.STATUS
	local WARM, TICKS = 400, 2400

	--[[
		A world of blocks (air elsewhere): a chest of `item` at x = 0, `length` transporters of tier
		`tier` (the first pulling from the chest), the destination `block` after them and, under it,
		a Creative Energy Cube (touching machines share energy). `service` answers the turrets'
		ticks. Returns the world's parts (`set` places more blocks, `restart` starts the server
		again) and a stepper that refills the chest every 100 ticks.
	]]
	local function line(tier: number, length: number, block: number, item: number, service: any?): any
		local blocks: { [number]: number } = {}
		local containers = Containers.new()
		local function getBlock(x: number, y: number, z: number): number?
			return blocks[Coords.posKey(x, y, z)] or AIR
		end
		local pipes, machines
		local function worlds()
			pipes = TransmitterWorld.new({
				getBlock = getBlock,
				containers = containers,
				inventoryChanged = function() end,
				drop = function() end,
			})
			machines = MachineWorld.new({
				getBlock = getBlock,
				containers = containers,
				transmitters = pipes,
				dayTime = function()
					return 6000
				end,
				turret = function()
					return service
				end,
			})
		end
		worlds()
		local function set(x: number, y: number, z: number, new: number)
			local key = Coords.posKey(x, y, z)
			local old = blocks[key] or AIR
			blocks[key] = new
			TransmitterWorld.blockChanged(pipes, x, y, z, old, new)
			MachineWorld.blockChanged(machines, x, y, z, old, new)
		end
		set(0, Y, 0, B.Chest)
		local chest = containers:get(0, Y, 0, B.Chest)
		local function refill()
			for slot = 1, 27 do
				chest.slots[slot] = Items.newStack(item, Items.maxStack(item))
			end
		end
		refill()
		for x = 1, length do
			set(x, Y, 0, T[tier])
		end
		assert(TransmitterWorld.setMode(pipes, 1, Y, 0, WEST, M.PULL))
		local at = length + 1
		set(at, Y - 1, 0, B.CreativeEnergyCube)
		set(at, Y, 0, block)
		local s = { pipes = pipes, machines = machines, containers = containers, x = at, ticks = 0, set = set }
		-- A server restart: new pipes and machines on the same blocks and containers (saved, the
		-- turret's state with them), the puller's PULL side put back (the pipes' saved modes).
		function s.restart()
			worlds()
			s.pipes, s.machines = pipes, machines
			local keys = {}
			for key in blocks do
				table.insert(keys, key)
			end
			table.sort(keys)
			for _, key in keys do
				local x, y, z = Coords.decodePosKey(key)
				TransmitterWorld.blockChanged(pipes, x, y, z, AIR, blocks[key])
				MachineWorld.blockChanged(machines, x, y, z, AIR, blocks[key])
			end
			TransmitterWorld.setMode(pipes, 1, Y, 0, WEST, M.PULL)
		end
		function s.step(n: number)
			for _ = 1, n do
				s.ticks += 1
				if s.ticks % 100 == 0 then
					refill()
				end
				TransmitterWorld.step(pipes)
				MachineWorld.step(machines)
			end
		end
		function s.container(): any
			return containers:peek(at, Y, 0)
		end
		function s.puller(): any
			return TransmitterWorld.node(pipes, 1, Y, 0)
		end
		return s
	end

	--[[
		A stand-in for the server's simulation (server Turrets/TurretWorld's place): a target always
		held (or while `firing(tick)`, the world's ticks), a shot whenever the order may fire, the
		feeder rule's tier on the real pipes (every tick, or as the simulation looks: at a turret's
		first tick and every `every` ticks). Counts the shots it fired (the kind takes exactly
		those: ready, armed, powered, not blocked), in all and by turret (`byKey`, pos keys);
		`feed` holds each turret's last look.
	]]
	local function shooter(firing: ((number) -> boolean)?, every: number?): (any, () -> any, (any) -> ())
		local s: any = nil
		local counter = { shots = 0, byKey = {}, feed = {} }
		local function service(order: any, out: any): any
			local key = order.key
			if every == nil or counter.feed[key] == nil or s.ticks % every == 0 then
				counter.feed[key] = TransmitterWorld.feedTier(s.pipes, order.x, order.y, order.z, order.block)
			end
			out.feed = counter.feed[key]
			out.tracking = true
			out.fired = (firing == nil or firing(s.ticks))
				and order.ready
				and order.armed
				and order.powered
				and not order.blocked
			out.status = if out.fired then STATUS.FIRING elseif not order.armed then STATUS.NO_AMMO else STATUS.TARGETING
			if out.fired then
				counter.shots += 1
				counter.byKey[order.key] = (counter.byKey[order.key] or 0) + 1
			end
			return out
		end
		return counter, function()
			return service
		end, function(world: any)
			s = world
		end
	end

	-- Rounds a second `spec` fires fed through `length` transporters of tier `feeder`.
	local function fired(spec: Turrets.Spec, feeder: number, length: number): number
		local counter, get, bindWorld = shooter()
		local s = line(feeder, length, spec.block, spec.ammo, get())
		bindWorld(s)
		s.step(WARM)
		counter.shots = 0
		s.step(TICKS)
		return counter.shots / (TICKS / 20)
	end

	--[[
		The turrets design's table (its bench, `feedtable` on this code): the share of each turret's
		own rate held fed by Basic / Advanced / Elite / Ultimate transporters at lengths 1, 2 and 4.
	]]
	local MEASURED: { [string]: { { number } } } = {
		smg1 = { { 1.00, 0.65, 0.32 }, { 1.00, 1.00, 0.65 }, { 1.00, 1.00, 1.00 }, { 1.00, 1.00, 1.00 } },
		smg2 = { { 0.60, 0.57, 0.30 }, { 1.00, 0.80, 0.57 }, { 1.00, 1.00, 0.80 }, { 1.00, 1.00, 1.00 } },
		smg3 = { { 0.38, 0.38, 0.25 }, { 0.62, 0.62, 0.46 }, { 1.00, 1.00, 0.67 }, { 1.00, 1.00, 1.00 } },
		smg4 = { { 0.25, 0.25, 0.24 }, { 0.42, 0.42, 0.40 }, { 0.67, 0.67, 0.67 }, { 1.00, 1.00, 1.00 } },
		rifle1 = { { 1.00, 0.62, 0.33 }, { 1.00, 1.00, 0.62 }, { 1.00, 1.00, 1.00 }, { 1.00, 1.00, 1.00 } },
		rifle2 = { { 0.60, 0.60, 0.39 }, { 1.00, 1.00, 0.78 }, { 1.00, 1.00, 1.00 }, { 1.00, 1.00, 1.00 } },
		rifle3 = { { 0.38, 0.38, 0.37 }, { 0.62, 0.62, 0.62 }, { 1.00, 1.00, 1.00 }, { 1.00, 1.00, 1.00 } },
		rifle4 = { { 0.25, 0.25, 0.25 }, { 0.42, 0.42, 0.42 }, { 0.67, 0.67, 0.67 }, { 1.00, 1.00, 1.00 } },
		sniper1 = { { 1.00, 1.00, 1.00 }, { 1.00, 1.00, 1.00 }, { 1.00, 1.00, 1.00 }, { 1.00, 1.00, 1.00 } },
		sniper2 = { { 0.75, 0.75, 0.75 }, { 1.00, 1.00, 1.00 }, { 1.00, 1.00, 1.00 }, { 1.00, 1.00, 1.00 } },
		sniper3 = { { 0.50, 0.50, 0.50 }, { 0.67, 0.67, 0.67 }, { 1.00, 1.00, 1.00 }, { 1.00, 1.00, 1.00 } },
		sniper4 = { { 0.38, 0.38, 0.38 }, { 0.50, 0.50, 0.50 }, { 0.75, 0.75, 0.75 }, { 1.00, 1.00, 1.00 } },
	}
	local LENGTHS = { 1, 2, 4 }

	t.test("turret feed: one transporter of its tier or better holds the full rate, a lower one its rate", function()
		local worst = math.huge
		for _, spec in Turrets.SPECS do
			local full = spec.rpm / 60
			for feeder = 1, 4 do
				local share = fired(spec, feeder, 1) / full
				if feeder >= spec.tier then
					worst = math.min(worst, share)
					t.ok(share >= 0.99, `{spec.name} fed by {T[feeder]}: {share} of its rate`)
				else
					-- (The feeder rule: exactly the lower tier's rate of its type.)
					local rule = Turrets.rpm(spec, feeder) / spec.rpm
					t.near(share, rule, 0.01 * rule, `{spec.name} fed by tier {feeder}: the rule's {rule}`)
				end
			end
		end
		print(`    the worst matching-or-better share at one transporter: {worst}`)
	end)

	t.test("turret feed: longer lines give a round a trip, as measured (within 5 %)", function()
		local worst = 0
		for _, spec in Turrets.SPECS do
			local full = spec.rpm / 60
			local rows = MEASURED[`{spec.type}{spec.tier}`]
			for feeder = 1, 4 do
				for i, length in LENGTHS do
					local share = fired(spec, feeder, length) / full
					local measured = rows[feeder][i]
					local off = math.abs(share - measured) / measured
					worst = math.max(worst, off)
					t.ok(off <= 0.05, `{spec.name}, tier {feeder} at {length}: {share} (measured {measured})`)
				end
			end
		end
		print(`    the largest difference from the measured table: {math.round(worst * 1000) / 10} %`)
	end)

	t.test("turret feed: a full turret's line waits 3 ticks, never backing off", function()
		local spec = Turrets.of("rifle", 1)
		local counter, get, bindWorld = shooter()
		local s = line(1, 1, spec.block, spec.ammo, get())
		bindWorld(s)
		s.step(WARM)
		t.ok(counter.shots > 0, "it fires")
		-- (Firing 0.75 a second on a buffer of one: full most of the time.)
		local puller = s.puller()
		local longest = 0
		for _ = 1, 400 do
			s.step(1)
			longest = math.max(longest, puller.pullDelay)
			t.eq(puller.pullFailures, 0, "no failure counted")
		end
		t.ok(longest <= Transmitters.PULL_DELAY - 1, `the longest wait: {longest} ticks`)
		-- With the turret not firing (no service: Disabled) and full, the line waits on, a pull
		-- every 3 ticks: IDLE_DELAY.
		local idle = line(1, 1, spec.block, spec.ammo, nil)
		idle.step(200)
		local container = idle.container()
		t.eq(container.slots[1] and container.slots[1].count, spec.buffer, "full")
		local p = idle.puller()
		local delays: { [number]: boolean } = {}
		for _ = 1, 30 do
			idle.step(1)
			delays[p.pullDelay] = true
			t.eq(p.pullFailures, 0, "never a failure")
		end
		for delay in delays do
			t.ok(delay <= Transport.IDLE_DELAY - 1, `waits {delay}`)
		end
		local turret = Machines.kindOf(spec.block)
		t.ok(turret ~= nil and turret.demand, "the turret demands its rounds")
	end)

	--[[
		Rounds a second each turret of `spec` at `turrets` ({ x, z }, a Creative Energy Cube under
		each) fires, fed by one puller of its tier on a chest (a line of one, no destination) and the
		transporters of its tier at `arms` ({ x, z }) joined to it, with the sides `cut` ({ x, z,
		side }) set to NONE.
	]]
	local function branched(
		spec: Turrets.Spec,
		arms: { { number } },
		turrets: { { number } },
		cut: { { number } }?
	): { number }
		local counter, get, bindWorld = shooter()
		local s = line(spec.tier, 1, AIR, spec.ammo, get())
		bindWorld(s)
		s.set(s.x, Y - 1, 0, AIR)
		for _, at in arms do
			s.set(at[1], Y, at[2], T[spec.tier])
		end
		for _, at in turrets do
			s.set(at[1], Y - 1, at[2], B.CreativeEnergyCube)
			s.set(at[1], Y, at[2], spec.block)
		end
		for _, at in cut or {} do
			assert(TransmitterWorld.setMode(s.pipes, at[1], Y, at[2], at[3], M.NONE))
		end
		s.step(WARM)
		table.clear(counter.byKey)
		s.step(TICKS)
		local rates = {}
		for _, at in turrets do
			table.insert(rates, (counter.byKey[Coords.posKey(at[1], Y, at[2])] or 0) / (TICKS / 20))
		end
		return rates
	end

	t.test("turret feed: a line branching to turrets feeds each, an even share when short", function()
		-- One puller, a T, a turret at the end of each arm (three transporters away): each fires
		-- what it fires there alone, and at Elite and Ultimate its rate (the trip caps Basic and the
		-- Advanced SMG there).
		local tee = { { 2, 0 }, { 2, 1 }, { 2, -1 } }
		local worst = math.huge
		for _, spec in Turrets.SPECS do
			local full = spec.rpm / 60
			local alone = branched(spec, tee, { { 2, 2 } })[1]
			local pair = branched(spec, tee, { { 2, 2 }, { 2, -2 } })
			for i, rate in pair do
				worst = math.min(worst, rate / alone)
				t.ok(rate >= 0.95 * alone, `{spec.name}, turret {i} of two: {rate} a second (alone {alone})`)
				if spec.tier >= 3 then
					t.ok(rate >= 0.95 * full, `{spec.name}, turret {i} of two: its rate ({full})`)
				end
			end
		end
		print(`    the worst share of the rate alone, one of two on a branch: {math.round(worst * 100) / 100}`)
		-- Basic SMGs (1.5 a second each) next to the puller itself share a Basic line's one round a
		-- pull (2 a second) evenly.
		local smg = Turrets.of("smg", 1)
		for _, turrets in { { { 1, 1 }, { 1, -1 } }, { { 1, 1 }, { 1, -1 }, { 2, 0 } } } do
			local rates = branched(smg, {}, turrets)
			for i, rate in rates do
				local share = 2 / #rates
				t.near(rate, share, 0.05 * share, `{#rates} Basic SMGs, turret {i}: {rate} a second`)
			end
		end
	end)

	t.test("turret feed: a turret two transporters reach takes its turn through the cheaper", function()
		-- ProbeRegF (the review's): a line bending round turret A (beside two of its transporters)
		-- with turret B beside the line in between: A fires what it fires reached through one of
		-- them, and so does B (before, after B's turn A's rounds took the long way: an Elite SMG
		-- 2.7 a second instead of 4, a Basic rifle half its rate).
		local bend = { { 2, 0 }, { 3, 0 }, { 3, 1 }, { 3, 2 } }
		local turrets = { { 2, 1 }, { 4, 0 } }
		for _, spec in { Turrets.of("smg", 3), Turrets.of("rifle", 1), Turrets.of("rifle", 2) } do
			local one = branched(spec, bend, turrets, { { 3, 1, WEST } })
			local two = branched(spec, bend, turrets)
			for i, name in { "A", "B" } do
				t.ok(two[i] >= 0.95 * one[i], `{spec.name} {name}: {two[i]} a second (one route to A: {one[i]})`)
			end
		end
	end)

	t.test("turret feed: the feeder rule reads the transporters that bring it rounds", function()
		local spec = Turrets.of("smg", 4)
		local UP, NORTH, SOUTH, EAST = 1, 2, 3, 5
		local function tier(s: any): number
			return TransmitterWorld.feedTier(s.pipes, s.x, Y, 0, spec.block)
		end
		-- (Not firing: Disabled, so full once its rounds came.)
		local s = line(3, 1, spec.block, spec.ammo, nil)
		local x = s.x
		t.eq(tier(s), 0, "nothing came yet: by hand")
		s.step(100)
		t.eq(tier(s), 3, "an Elite one beside it brought them")
		-- A side set to NONE or PULL gives nothing; PUSH does.
		TransmitterWorld.setMode(s.pipes, x - 1, Y, 0, EAST, M.NONE)
		t.eq(tier(s), 0, "cut: by hand")
		TransmitterWorld.setMode(s.pipes, x - 1, Y, 0, EAST, M.PULL)
		t.eq(tier(s), 0, "pulling: by hand")
		TransmitterWorld.setMode(s.pipes, x - 1, Y, 0, EAST, M.PUSH)
		t.eq(tier(s), 3, "pushing feeds it")
		-- Full, nothing can come: it keeps its feeder however long it waits, looked at as the
		-- simulation does (every FeedTicks).
		for _ = 1, 100 do
			s.step(20)
			tier(s)
		end
		t.eq(tier(s), 3, "full for 2000 ticks: still Elite")
		-- Its source gone and its rounds taken out by hand: forgotten once nothing came for
		-- FEED_MEMORY ticks.
		s.set(0, Y, 0, AIR)
		s.container().slots[1] = nil
		s.step(TransmitterWorld.FEED_MEMORY - 20)
		t.eq(tier(s), 3, "a while: still Elite")
		s.step(40)
		t.eq(tier(s), 0, "nothing came: by hand")
		-- The best of several that brought it rounds; the Restrictive Transporter counts as Basic.
		local counter, get, bindWorld = shooter()
		local f = line(1, 1, spec.block, spec.ammo, get())
		bindWorld(f)
		local function feeder(z: number, side: number, block: number)
			local cz = if side == NORTH then z - 1 else z + 1
			f.set(f.x, Y, cz, B.Chest)
			local chest = f.containers:get(f.x, Y, cz, B.Chest)
			for slot = 1, 27 do
				chest.slots[slot] = Items.newStack(spec.ammo, Items.maxStack(spec.ammo))
			end
			f.set(f.x, Y, z, block)
			assert(TransmitterWorld.setMode(f.pipes, f.x, Y, z, side, M.PULL))
		end
		f.step(200)
		t.ok(counter.shots > 0, "it fires")
		t.eq(tier(f), 1, "a Basic one")
		feeder(1, SOUTH, B.RestrictiveTransporter)
		TransmitterWorld.setMode(f.pipes, f.x - 1, Y, 0, EAST, M.NONE)
		f.step(200)
		t.eq(tier(f), 1, "the Restrictive Transporter: Basic")
		feeder(-1, NORTH, T[3])
		f.step(200)
		t.eq(tier(f), 3, "the best: Elite")
		t.eq(TransmitterWorld.feedTier(f.pipes, 5, Y, 5, spec.block), 0, "none near")
		-- None over the gun: an Ultimate one there brings nothing through its top.
		local top = line(4, 1, spec.block, spec.ammo, nil)
		top.set(top.x - 1, Y, 0, AIR)
		top.set(top.x, Y + 2, 0, B.Chest)
		top.containers:get(top.x, Y + 2, 0, B.Chest).slots[1] = Items.newStack(spec.ammo, 64)
		top.set(top.x, Y + 1, 0, T[4])
		assert(TransmitterWorld.setMode(top.pipes, top.x, Y + 1, 0, UP, M.PULL))
		top.step(200)
		t.eq(tier(top), 0, "an Ultimate one over the gun feeds nothing")
	end)

	t.test("turret feed: transporters that bring it no rounds never lift its feeder", function()
		-- ProbeFeedA (the review's): an Ultimate SMG on one Basic transporter (90 a minute) with
		-- an Ultimate transporter beside it that brings it nothing, then with one that brings it
		-- its rounds.
		local spec = Turrets.of("smg", 4)
		local NORTH, SOUTH = 2, 3
		local function fedWith(extra: (any) -> ()): (number, number)
			local counter, get, bindWorld = shooter()
			local s = line(1, 1, spec.block, spec.ammo, get())
			bindWorld(s)
			extra(s)
			s.step(WARM)
			counter.shots = 0
			s.step(TICKS)
			return counter.shots / (TICKS / 20), TransmitterWorld.feedTier(s.pipes, s.x, Y, 0, spec.block)
		end
		local basic = Turrets.rpm(spec, 1) / 60
		local cases: { [string]: (any) -> () } = {
			["a dead stub"] = function(s: any)
				s.set(s.x, Y, 1, T[4])
			end,
			["a red stub its rounds cannot enter"] = function(s: any)
				s.set(s.x, Y, 1, T[4])
				assert(TransmitterWorld.setColour(s.pipes, s.x, Y, 1, 15))
			end,
			["a line of cobblestone passing by"] = function(s: any)
				local at = s.x
				s.set(at - 1, Y, 2, B.Chest)
				s.containers:get(at - 1, Y, 2, B.Chest).slots[1] = Items.newStack(B.Cobblestone, 64)
				s.set(at - 1, Y, 1, T[4])
				assert(TransmitterWorld.setMode(s.pipes, at - 1, Y, 1, SOUTH, M.PULL))
				-- (Kept off the Basic line north of it.)
				assert(TransmitterWorld.setMode(s.pipes, at - 1, Y, 1, NORTH, M.NONE))
				s.set(at, Y, 1, T[4])
				s.set(at + 1, Y, 1, T[4])
				s.set(at + 1, Y, 2, B.Chest)
			end,
		}
		for name, extra in cases do
			local rate, tier = fedWith(extra)
			t.eq(tier, 1, `{name}: still fed by Basic`)
			t.near(rate, basic, 0.01 * basic, `{name}: Basic's rate ({rate} a second)`)
		end
		-- The Basic one replaced by an Ultimate one: Ultimate's rate.
		local rate, tier = fedWith(function(s: any)
			s.set(1, Y, 0, T[4])
			assert(TransmitterWorld.setMode(s.pipes, 1, Y, 0, WEST, M.PULL))
		end)
		t.eq(tier, 4, "an Ultimate one that brings them")
		t.ok(rate >= 0.99 * spec.rpm / 60, `its rate ({rate} a second)`)
	end)

	t.test("turret feed: a transporter that stopped bringing rounds or was replaced is forgotten", function()
		--[[
			ProbeRegG (the review's): an Ultimate SMG on one Advanced transporter, looked at as the
			simulation does (every FeedTicks), with targets for its first 200 ticks and none after
			(so full). An Ultimate transporter beside it brought it 6 rounds while it fired and
			none since, or a Basic one bringing it rounds was replaced by an Ultimate one bringing
			none: the Advanced line is its feeder (before, the Ultimate one counted on however long
			the turret sat full: 7 rounds in its first second of targets, Advanced's cap 2.5).
		]]
		local spec = Turrets.of("smg", 4)
		local EAST = 5
		local function feeding(beside: number): (any, any)
			local _, get, bindWorld = shooter(function(tick: number): boolean
				return tick <= 200
			end, Config.Turrets.FeedTicks)
			local s = line(2, 1, spec.block, spec.ammo, get())
			bindWorld(s)
			s.set(s.x + 2, Y, 0, B.Chest)
			s.set(s.x + 1, Y, 0, T[beside])
			assert(TransmitterWorld.setMode(s.pipes, s.x + 1, Y, 0, EAST, M.PULL))
			return s, s.containers:get(s.x + 2, Y, 0, B.Chest)
		end
		local function tier(s: any): number
			return TransmitterWorld.feedTier(s.pipes, s.x, Y, 0, spec.block)
		end
		local s, chest = feeding(4)
		s.step(150)
		chest.slots[1] = Items.newStack(spec.ammo, 6)
		s.step(650)
		t.eq(chest.slots[1] and chest.slots[1].count or 0, 0, "the Ultimate one brought its 6")
		t.eq(tier(s), 2, "full for 600 ticks since: the Advanced line")
		local r, other = feeding(1)
		other.slots[1] = Items.newStack(spec.ammo, 64)
		r.step(400)
		t.ok((other.slots[1] and other.slots[1].count or 0) < 64, "the Basic one brought rounds")
		t.eq(tier(r), 2, "both bring them: Advanced")
		r.set(r.x + 1, Y, 0, AIR)
		r.set(r.x + 1, Y, 0, T[4])
		r.step(600)
		t.eq(tier(r), 2, "the Ultimate one in its place brings none")
	end)

	t.test("turret feed: after a restart a full turret keeps its feeder until rounds come", function()
		--[[
			ProbeRegG3 (the review's): an Ultimate SMG on one Basic transporter, with an Ultimate
			transporter beside it that brings it nothing, full and idle when the server restarts
			(the feeder rule's records are not saved). Idle and full it still reads Basic, and once
			targets come it fires at Basic's rate (before: by hand, its buffer at its own rate, 6
			rounds in its first second). Filled by hand it stays by hand.
		]]
		local spec = Turrets.of("smg", 4)
		local targets = false
		local counter, get, bindWorld = shooter(function(): boolean
			return targets
		end, Config.Turrets.FeedTicks)
		local function tier(s: any): number
			return TransmitterWorld.feedTier(s.pipes, s.x, Y, 0, spec.block)
		end
		local s = line(1, 1, spec.block, spec.ammo, get())
		bindWorld(s)
		s.set(s.x, Y, 1, T[4])
		s.step(600)
		t.eq(tier(s), 1, "before: Basic")
		s.restart()
		table.clear(counter.feed)
		s.step(399)
		t.eq(tier(s), 1, "after the restart, full for 399 ticks: Basic")
		targets = true
		counter.shots = 0
		s.step(20)
		local cap = Turrets.rpm(spec, 1) / 60
		t.ok(counter.shots <= math.ceil(cap), `{counter.shots} rounds in its first second (Basic's {cap} a second)`)
		s.step(400)
		t.eq(tier(s), 1, "rounds came: Basic")
		-- By hand: no line, the Ultimate one beside it.
		targets = false
		local h = line(1, 1, spec.block, spec.ammo, get())
		bindWorld(h)
		table.clear(counter.feed)
		h.set(1, Y, 0, AIR)
		h.set(h.x, Y, 1, T[4])
		h.container().slots[1] = Items.newStack(spec.ammo, spec.buffer)
		h.step(100)
		h.restart()
		table.clear(counter.feed)
		h.step(100)
		t.eq(tier(h), 0, "after the restart: by hand")
	end)

	t.test("turret feed: a full turret's feeder rebuilt keeps its cap", function()
		--[[
			ProbeR3A (the review's): an Ultimate SMG on a Basic line of 3, full and idle, the
			transporter beside it broken and a Basic one placed again 5 ticks later (no look between).
			Its record starts again from its kept feed, as after a restart: still Basic, and once
			targets come it fires at Basic's rate (before: by hand, 6 rounds in its first second).
		]]
		local spec = Turrets.of("smg", 4)
		local targets = false
		local counter, get, bindWorld = shooter(function(): boolean
			return targets
		end, Config.Turrets.FeedTicks)
		local s = line(1, 3, spec.block, spec.ammo, get())
		bindWorld(s)
		s.step(600)
		t.eq(TransmitterWorld.feedTier(s.pipes, s.x, Y, 0, spec.block), 1, "before: Basic")
		s.set(s.x - 1, Y, 0, AIR)
		s.step(5)
		s.set(s.x - 1, Y, 0, T[1])
		s.step(600)
		t.eq(TransmitterWorld.feedTier(s.pipes, s.x, Y, 0, spec.block), 1, "rebuilt, full for 600 ticks: Basic")
		targets = true
		counter.shots = 0
		s.step(20)
		local cap = Turrets.rpm(spec, 1) / 60
		t.ok(counter.shots <= math.ceil(cap), `{counter.shots} rounds in its first second (Basic's {cap} a second)`)
	end)

	t.test("turret feed: a waiting line whose chest only loses or regains an item keeps its wait", function()
		--[[
			ProbeR3B (the review's): a chest of 9mm, a Basic line of 30 into a full SMG that never
			fires; a cobblestone, which can go nowhere on this line, put in the chest and taken out
			again every 6 ticks (a miner filling the chest, another line emptying it). Only an item the
			chest did not give when the wait began ends it, so the line searches about as often as
			when the chest stays the same (before: every look, six times as often).
		]]
		local spec = Turrets.of("smg", 1)
		local function searches(toggle: boolean): number
			local _, get, bindWorld = shooter(function(): boolean
				return false
			end, Config.Turrets.FeedTicks)
			local s = line(1, 30, spec.block, spec.ammo, get())
			bindWorld(s)
			local chest = s.containers:peek(0, Y, 0)
			local n = 0
			for tick = 1, 2000 do
				if toggle and tick % 6 == 0 then
					local stack = chest.slots[27]
					chest.slots[27] = if stack and stack.item == B.Cobblestone
						then nil
						else Items.newStack(B.Cobblestone, 1)
				end
				s.step(1)
				if s.pipes.searchBudget < Transport.SEARCH_BUDGET then
					n += 1
				end
			end
			return n
		end
		local still, changing = searches(false), searches(true)
		t.ok(changing <= 2 * still, `{changing} searches with the cobblestone coming and going, {still} without`)
	end)

	--[[ Every other destination exactly as before ]]

	--[[
		The turrets design's bench kind on the Transport before the demand rule: a machine that
		takes one item into a slot of `limit` and uses one a tick when it can (wanting 20 a second),
		bound to a spare block. Without `demand` its line must deliver exactly what was measured
		then (`feed2`, "real Transport": rounds a second at lengths 1, 2 and 4, limits 1..3).
	]]
	local BENCH = B.Calcite
	local limit = 1
	local used = 0
	Machines.define("turretfeedbench", {
		slots = {
			{
				x = 8,
				y = 8,
				limit = 64,
				accepts = function(item: number): boolean
					return item == I.Rounds9mm
				end,
			},
		},
		fields = { "credit" },
		tick = function(container: any, _ctx: any)
			local credit = Machines.get(container, "credit") + 1200
			local stack = container.slots[1]
			if credit >= 1200 and stack and stack.count >= 1 then
				credit -= 1200
				container.slots[1] = Items.withCount(stack, stack.count - 1)
				used += 1
			elseif credit > 1200 then
				credit = 1200
			end
			Machines.set(container, "credit", credit)
		end,
	})
	local REAL: { { { number } } } = {
		-- Tier by tier: lengths 1, 2, 4; limits 1, 2, 3.
		{ { 0.52, 1.82, 2.00 }, { 0.26, 0.81, 1.01 }, { 0.17, 0.45, 0.60 } },
		{ { 1.67, 3.33, 3.00 }, { 0.52, 1.03, 1.54 }, { 0.26, 0.51, 0.77 } },
		{ { 2.00, 4.00, 6.00 }, { 1.67, 3.33, 3.00 }, { 0.52, 1.03, 1.54 } },
		{ { 2.00, 4.00, 6.00 }, { 2.00, 4.00, 6.00 }, { 2.00, 4.00, 5.00 } },
	}

	t.test("turret feed: a machine that demands nothing gets exactly the deliveries measured before", function()
		local unbind = Machines.bind(BENCH, "turretfeedbench", { capacity = 1000, input = 1000 })
		local slotLimit = Machines.slotLimit
		Machines.slotLimit = function(block: number, slot: number, item: number?): number
			if block == BENCH then
				return limit
			end
			return slotLimit(block, slot, item)
		end
		local ok, err = pcall(function()
			t.ok(not Machines.demands(BENCH), "no demand")
			for tier = 1, 4 do
				for i, length in LENGTHS do
					for n = 1, 3 do
						limit = n
						local s = line(tier, length, BENCH, I.Rounds9mm, nil)
						s.step(400)
						used = 0
						s.step(4000)
						-- (The bench printed two decimals.)
						local rate = string.format("%.2f", used / 200)
						local before = string.format("%.2f", REAL[tier][i][n])
						t.eq(rate, before, `tier {tier} at {length}, limit {n}: as before`)
					end
				end
			end
		end)
		Machines.slotLimit = slotLimit
		unbind()
		assert(ok, err)
	end)

	t.test("turret feed: chests and furnaces still back off when full", function()
		for _, block in { B.Chest, B.Furnace } do
			local item = if block == B.Chest then I.Rounds9mm else B.Cobblestone
			local s = line(1, 1, block, item, nil)
			-- (Full already: every slot that takes the item.)
			local into = s.containers:get(s.x, Y, 0, block)
			for slot = 1, if block == B.Chest then 27 else 1 do
				into.slots[slot] = Items.newStack(item, Items.maxStack(item))
			end
			s.step(400)
			local p = s.puller()
			t.ok(p.pullFailures >= 3, `{Blocks.get(block).name}: failures counted ({p.pullFailures})`)
			local longest = 0
			for _ = 1, 80 do
				s.step(1)
				longest = math.max(longest, p.pullDelay)
			end
			t.eq(longest, 40 - 1, `{Blocks.get(block).name}: the 40 tick backoff`)
		end
	end)

	t.test("turret feed: with the turrets off no line waits for one", function()
		local env = Loader.new()
		local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
		local serverRoot = env.mount("src/server", "ServerScriptService", "IceVoxel")
		local Config = env.require(root.Config)
		Config.Turrets.Enabled = false
		local OffMachines = env.require(root.Machines)
		local OffBlocks = env.require(root.Blocks)
		local OffCoords = env.require(root.World.Coords)
		local OffItems = env.require(root.Items)
		local OffTransmitters = env.require(root.Transmitters)
		local OffContainers = env.require(serverRoot.Players.Containers)
		local OffPipes = env.require(serverRoot.Transmitters.TransmitterWorld)
		local turret = OffBlocks.id.BasicRifleTurret
		t.ok(not OffMachines.demands(turret), "no turret demands")
		-- A full turret's line backs off as into a full chest.
		local blocks: { [number]: number } = {}
		local containers = OffContainers.new()
		local pipes = OffPipes.new({
			getBlock = function(x: number, y: number, z: number): number?
				return blocks[OffCoords.posKey(x, y, z)] or OffBlocks.AIR
			end,
			containers = containers,
			inventoryChanged = function() end,
			drop = function() end,
		})
		local function set(x: number, y: number, z: number, block: number)
			local key = OffCoords.posKey(x, y, z)
			local old = blocks[key] or OffBlocks.AIR
			blocks[key] = block
			OffPipes.blockChanged(pipes, x, y, z, old, block)
		end
		set(0, Y, 0, OffBlocks.id.Chest)
		containers:get(0, Y, 0, OffBlocks.id.Chest).slots[1] = OffItems.newStack(OffItems.id.Rounds556, 40)
		set(1, Y, 0, OffBlocks.id.BasicLogisticalTransporter)
		assert(OffPipes.setMode(pipes, 1, Y, 0, WEST, OffTransmitters.MODES.PULL))
		set(2, Y, 0, turret)
		for _ = 1, 2000 do
			OffPipes.step(pipes)
		end
		local held = containers:peek(2, Y, 0)
		t.eq(held and held.slots[1] and held.slots[1].count, 1, "its one round")
		local p = OffPipes.node(pipes, 1, Y, 0) :: any
		t.ok(p.pullFailures >= 3, `failures counted ({p.pullFailures})`)
	end)

	--[[ The demand rule's cost: what a backoff would cost ]]

	-- The pipes' modules with the turrets on or off (Config.Turrets.Enabled), and a world of
	-- blocks (air elsewhere) on them: `set` places a block, `chest` one holding `stacks`.
	local function pipesWith(enabled: boolean): any
		local env = Loader.new()
		local root = env.mount("src/shared", "ReplicatedStorage", "IceVoxel")
		local serverRoot = env.mount("src/server", "ServerScriptService", "IceVoxel")
		env.require(root.Config).Turrets.Enabled = enabled
		local m = {
			Blocks = env.require(root.Blocks),
			Coords = env.require(root.World.Coords),
			Items = env.require(root.Items),
			Transmitters = env.require(root.Transmitters),
			TransmitterWorld = env.require(serverRoot.Transmitters.TransmitterWorld),
			Transport = env.require(serverRoot.Transmitters.Transport),
		}
		local blocks: { [number]: number } = {}
		local containers = env.require(serverRoot.Players.Containers).new()
		-- (`reads`: the blocks the pipes asked for.)
		local w: any = { m = m, containers = containers, reads = 0 }
		w.pipes = m.TransmitterWorld.new({
			getBlock = function(x: number, y: number, z: number): number?
				w.reads += 1
				return blocks[m.Coords.posKey(x, y, z)] or m.Blocks.AIR
			end,
			containers = containers,
			inventoryChanged = function() end,
			drop = function() end,
		})
		function w.set(x: number, y: number, z: number, block: number)
			local key = m.Coords.posKey(x, y, z)
			local old = blocks[key] or m.Blocks.AIR
			blocks[key] = block
			m.TransmitterWorld.blockChanged(w.pipes, x, y, z, old, block)
		end
		function w.chest(x: number, y: number, z: number, stacks: { any }): any
			w.set(x, y, z, m.Blocks.id.Chest)
			local chest = containers:get(x, y, z, m.Blocks.id.Chest)
			for slot, stack in stacks do
				chest.slots[slot] = stack
			end
			return chest
		end
		-- One tick; the transporters its route searches visited.
		function w.step(): number
			m.TransmitterWorld.step(w.pipes)
			return m.Transport.SEARCH_BUDGET - w.pipes.searchBudget
		end
		return w
	end

	-- `n` stacks of 64 `item`.
	local function stacksOf(m: any, item: number, n: number): { any }
		local list = {}
		for _ = 1, n do
			table.insert(list, m.Items.newStack(item, 64))
		end
		return list
	end

	t.test("turret feed: a line waiting for a full turret searches its routes as a backoff would", function()
		-- A storage line (a chest of 26 kinds and 9mm, 10 Ultimate transporters past 30 full
		-- chests) into a full Basic SMG that never fires: its searches, tick by tick, with the
		-- turrets on and off.
		local function searches(enabled: boolean): ({ number }, any)
			local w = pipesWith(enabled)
			local m = w.m
			local B = m.Blocks.id
			local kinds = { B.Dirt, B.Stone, B.Sand, B.Gravel, B.Planks, B.Glass, B.Cobblestone }
			for id = 1, 400 do
				local def = m.Blocks.get(id)
				if #kinds < 26 and def and m.Items.isValid(id) and not table.find(kinds, id) then
					if m.Items.maxStack(id) == 64 and def.container == 0 then
						table.insert(kinds, id)
					end
				end
			end
			local source = {}
			for slot, kind in kinds do
				source[slot] = m.Items.newStack(kind, 64)
			end
			source[27] = m.Items.newStack(m.Items.id.Rounds9mm, 60)
			w.chest(0, Y, 0, source)
			for x = 1, 10 do
				w.set(x, Y, 0, B.UltimateLogisticalTransporter)
				w.chest(x, Y, 1, stacksOf(m, B.Cobblestone, 27))
				w.chest(x, Y, -1, stacksOf(m, B.Cobblestone, 27))
				w.chest(x, Y + 1, 0, stacksOf(m, B.Cobblestone, 27))
			end
			assert(m.TransmitterWorld.setMode(w.pipes, 1, Y, 0, WEST, m.Transmitters.MODES.PULL))
			w.set(11, Y, 0, B.BasicSmgTurret)
			w.containers:get(11, Y, 0, B.BasicSmgTurret).slots[1] = m.Items.newStack(m.Items.id.Rounds9mm, 2)
			local visited = {}
			for tick = 1, 400 do
				visited[tick] = w.step()
			end
			return visited, m.TransmitterWorld.node(w.pipes, 1, Y, 0)
		end
		local on, puller = searches(true)
		local off = searches(false)
		local count = 0
		for tick, n in on do
			t.eq(n, off[tick], `tick {tick}: the same search as the backoff's`)
			if n > 0 then
				count += 1
			end
		end
		t.ok(count <= 400 / 40 + 4, `{count} searches in 400 ticks`)
		t.eq(puller.pullFailures, 0, "waiting, not failing")
		t.ok(puller.waits ~= nil and #puller.waits == 1, "it waits for the turret")
	end)

	t.test("turret feed: lines waiting for turrets leave every other line its pulls", function()
		--[[
			ProbeFeedB (the review's): 3000 Ultimate transporters into a full Basic SMG, 8 of them
			pulling 9mm from chests, and 6 unrelated Basic lines of cobblestone between chests far
			away: what those deliver with the turrets on is what they deliver with them off (before,
			two of them got nothing).
		]]
		local function delivered(enabled: boolean): { number }
			local w = pipesWith(enabled)
			local m = w.m
			local B = m.Blocks.id
			local ammo = m.Items.id.Rounds9mm
			for x = 1, 3000 do
				w.set(x, Y, 0, B.UltimateLogisticalTransporter)
			end
			w.set(3001, Y, 0, B.BasicSmgTurret)
			w.containers:get(3001, Y, 0, B.BasicSmgTurret).slots[1] = m.Items.newStack(ammo, 2)
			for i = 1, 8 do
				w.chest(i * 3, Y, -1, { m.Items.newStack(ammo, 64) })
				assert(m.TransmitterWorld.setMode(w.pipes, i * 3, Y, 0, 2, m.Transmitters.MODES.PULL))
			end
			local into = {}
			for j = 1, 6 do
				local z = 200 + j * 4
				w.chest(0, Y, z, stacksOf(m, B.Cobblestone, 27))
				w.set(1, Y, z, B.BasicLogisticalTransporter)
				assert(m.TransmitterWorld.setMode(w.pipes, 1, Y, z, WEST, m.Transmitters.MODES.PULL))
				w.set(2, Y, z, B.BasicLogisticalTransporter)
				into[j] = w.chest(3, Y, z, {})
			end
			for _ = 1, 300 do
				w.step()
			end
			local counts = {}
			for j, chest in into do
				local n = 0
				for _, stack in chest.slots do
					n += stack.count
				end
				counts[j] = n
			end
			return counts
		end
		local on, off = delivered(true), delivered(false)
		for j, n in on do
			t.eq(n, off[j], `line {j}: as with the turrets off`)
		end
		print(`    unrelated lines: {table.concat(on, "/")} (turrets off: {table.concat(off, "/")})`)
	end)

	t.test("turret feed: pulls take turns when the tick's searches run out", function()
		-- A 32 x 32 sheet of transporters (a search visits all 1024: 4 a tick) with 48 chests on
		-- its north and west edges pulled into it, each wanting a pull every 10 ticks (4.8 a
		-- tick), and empty chests along its east edge: every one pulls, about as often as the
		-- others (before, those late in the order never did).
		local w = pipesWith(true)
		local m = w.m
		local B = m.Blocks.id
		for x = 0, 31 do
			for z = 0, 31 do
				w.set(x, Y, z, B.BasicLogisticalTransporter)
			end
			w.chest(32, Y, x, {})
		end
		local pullers = {}
		for i = 1, 48 do
			local x, z, px, pz, toward = i - 1, -1, i - 1, 0, 2
			if i > 32 then
				x, z, px, pz, toward = -1, i - 32, 0, i - 32, WEST
			end
			w.chest(x, Y, z, stacksOf(m, B.Cobblestone, 27))
			assert(m.TransmitterWorld.setMode(w.pipes, px, Y, pz, toward, m.Transmitters.MODES.PULL))
			table.insert(pullers, m.TransmitterWorld.node(w.pipes, px, Y, pz))
		end
		local sent = table.create(#pullers, 0)
		for _ = 1, 200 do
			w.step()
			for i, node in pullers do
				if node.pullDelay == m.Transmitters.PULL_DELAY - 1 then
					sent[i] += 1
				end
			end
		end
		local least, most = math.min(table.unpack(sent)), math.max(table.unpack(sent))
		print(`    pulls each in 200 ticks: {least} to {most}`)
		t.ok(least >= 0.6 * most, `every puller takes its turn ({least} to {most})`)
	end)

	t.test("turret feed: a pull's rounds going on to many turrets work out the turns once", function()
		-- ProbeRegL (the review's): one Ultimate pull of 64 rounds into a line between 400 Basic
		-- SMGs with room for one each sends 64 items and reads each turret's block about once, not
		-- once a round (before, each round looked at every route again: four such pulls into 400
		-- turrets took 43 ms).
		local w = pipesWith(true)
		local m = w.m
		local B = m.Blocks.id
		local ammo = m.Items.id.Rounds9mm
		local n = 400
		local length = n // 2 + 1
		for x = 0, length do
			w.set(x, Y, 0, B.UltimateLogisticalTransporter)
		end
		for x = 1, length - 1 do
			for _, z in { 1, -1 } do
				w.set(x, Y, z, B.BasicSmgTurret)
				w.containers:get(x, Y, z, B.BasicSmgTurret).slots[1] = m.Items.newStack(ammo, 1)
			end
		end
		w.chest(-1, Y, 0, { m.Items.newStack(ammo, 64) })
		assert(m.TransmitterWorld.setMode(w.pipes, 0, Y, 0, WEST, m.Transmitters.MODES.PULL))
		w.reads = 0
		w.step()
		print(`    blocks read in the pulling tick: {w.reads} for {n} turrets`)
		t.eq(w.pipes.itemCount, 64, "a round to each of 64 turrets")
		t.ok(w.reads <= 2 * n, `{w.reads} blocks read for {n} turrets`)
	end)

	t.test("turret feed: a waiting line sees a turret placed on it or another calibre within 3 ticks", function()
		--[[
			ProbeRegH (the review's): an Advanced line of 10 from a chest of 9mm into a full SMG,
			waiting. An SMG placed beside its 5th transporter, or 5.56 put in the chest with a rifle
			turret there, has a round on its way within the 3 tick look, as when every look searched
			(before, up to the backoff's 40 ticks).
		]]
		local function waited(rifle: boolean, offset: number): number
			local w = pipesWith(true)
			local m = w.m
			local B, I = m.Blocks.id, m.Items.id
			local source = w.chest(0, Y, 0, { m.Items.newStack(I.Rounds9mm, 64) })
			for x = 1, 10 do
				w.set(x, Y, 0, B.AdvancedLogisticalTransporter)
			end
			assert(m.TransmitterWorld.setMode(w.pipes, 1, Y, 0, WEST, m.Transmitters.MODES.PULL))
			w.set(11, Y, 0, B.BasicSmgTurret)
			w.containers:get(11, Y, 0, B.BasicSmgTurret).slots[1] = m.Items.newStack(I.Rounds9mm, 2)
			if rifle then
				w.set(5, Y, 1, B.BasicRifleTurret)
			end
			for _ = 1, 400 + offset do
				w.step()
			end
			if rifle then
				source.slots[2] = m.Items.newStack(I.Rounds556, 64)
			else
				w.set(5, Y, 1, B.BasicSmgTurret)
			end
			local key = m.Coords.posKey(5, Y, 1)
			for i = 1, 100 do
				w.step()
				if w.pipes.incoming[key] then
					return i
				end
			end
			return math.huge
		end
		for _, rifle in { false, true } do
			for offset = 0, 2 do
				local n = waited(rifle, offset)
				local what = if rifle then "5.56 for the rifle" else "a new SMG"
				t.ok(n <= Transport.IDLE_DELAY, `{what}, {offset} ticks on: a round on its way after {n} ticks`)
			end
		end
	end)
end
