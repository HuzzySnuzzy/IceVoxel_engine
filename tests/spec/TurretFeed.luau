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
	line branching to several turrets feeds each as it would alone, evenly when it cannot.
	And every other destination is exactly as before: a machine that demands nothing reproduces
	the deliveries measured on the Transport before the demand rule, chests and furnaces still
	back off, and with Config.Turrets.Enabled false no line waits for a turret.
]]

local Loader = require("../lib/Loader")

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
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
		ticks. Returns the world's parts (`set` places more blocks) and a stepper that refills the
		chest every 100 ticks.
	]]
	local function line(tier: number, length: number, block: number, item: number, service: any?): any
		local blocks: { [number]: number } = {}
		local containers = Containers.new()
		local function getBlock(x: number, y: number, z: number): number?
			return blocks[Coords.posKey(x, y, z)] or AIR
		end
		local pipes = TransmitterWorld.new({
			getBlock = getBlock,
			containers = containers,
			inventoryChanged = function() end,
			drop = function() end,
		})
		local machines = MachineWorld.new({
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
		held, a shot whenever the order may fire, the feeder rule's tier on the real pipes. Counts
		the shots it fired (the kind takes exactly those: ready, armed, powered, not blocked), in
		all and by turret (`byKey`, pos keys).
	]]
	local function shooter(): (any, () -> any, (any) -> ())
		local s: any = nil
		local counter = { shots = 0, byKey = {} }
		local function service(order: any, out: any): any
			out.feed = TransmitterWorld.feedTier(s.pipes, order.x, order.y, order.z, order.block)
			out.tracking = true
			out.fired = order.ready and order.armed and order.powered and not order.blocked
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
		transporters of its tier at `arms` ({ x, z }) joined to it.
	]]
	local function branched(spec: Turrets.Spec, arms: { { number } }, turrets: { { number } }): { number }
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

	t.test("turret feed: the feeder rule reads the transporters next to it", function()
		local spec = Turrets.of("smg", 4)
		local s = line(3, 1, spec.block, spec.ammo, nil)
		local x = s.x
		t.eq(TransmitterWorld.feedTier(s.pipes, x, Y, 0, spec.block), 3, "an Elite one beside it")
		-- A side set to NONE or PULL gives nothing; PUSH does.
		local EAST = 5
		TransmitterWorld.setMode(s.pipes, x - 1, Y, 0, EAST, M.NONE)
		t.eq(TransmitterWorld.feedTier(s.pipes, x, Y, 0, spec.block), 0, "cut: by hand")
		TransmitterWorld.setMode(s.pipes, x - 1, Y, 0, EAST, M.PULL)
		t.eq(TransmitterWorld.feedTier(s.pipes, x, Y, 0, spec.block), 0, "pulling: by hand")
		TransmitterWorld.setMode(s.pipes, x - 1, Y, 0, EAST, M.PUSH)
		t.eq(TransmitterWorld.feedTier(s.pipes, x, Y, 0, spec.block), 3, "pushing feeds it")
		-- The best of several; the Restrictive Transporter counts as Basic; none over the gun.
		local blocks: { [number]: number } = {}
		local containers = Containers.new()
		local pipes = TransmitterWorld.new({
			getBlock = function(bx: number, by: number, bz: number): number?
				return blocks[Coords.posKey(bx, by, bz)] or AIR
			end,
			containers = containers,
		})
		local function set(bx: number, by: number, bz: number, block: number)
			local key = Coords.posKey(bx, by, bz)
			local old = blocks[key] or AIR
			blocks[key] = block
			TransmitterWorld.blockChanged(pipes, bx, by, bz, old, block)
		end
		set(0, Y, 0, spec.block)
		set(0, Y + 1, 0, T[4])
		t.eq(TransmitterWorld.feedTier(pipes, 0, Y, 0, spec.block), 0, "an Ultimate one over the gun feeds nothing")
		set(0, Y, 1, B.RestrictiveTransporter)
		t.eq(TransmitterWorld.feedTier(pipes, 0, Y, 0, spec.block), 1, "the Restrictive Transporter: Basic")
		set(1, Y, 0, T[2])
		set(0, Y - 1, 0, T[3])
		t.eq(TransmitterWorld.feedTier(pipes, 0, Y, 0, spec.block), 3, "the best: Elite, from below")
		t.eq(TransmitterWorld.feedTier(pipes, 0, Y, 0, B.Chest), 4, "a chest takes them through its top too")
		t.eq(TransmitterWorld.feedTier(pipes, 5, Y, 5, spec.block), 0, "none near")
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
end
