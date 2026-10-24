--!strict
--[[
	The turrets (twelve kinds "turret_<type>_<tier>": SMG, Rifle and Sniper in Basic, Advanced,
	Elite and Ultimate; BlockList "<Tier><Type>Turret", Shared/Turrets' Specs). A turret is a
	Mekanism machine holding a few rounds of its calibre, which a Logistical Transporter feeds,
	and energy: it keeps the books, the server's turret simulation aims and decides (TickContext
	`turret`, Shared/Turrets/Types' Service: server Turrets/TurretWorld). Every kind is the same
	but for its Spec.

	Slots (each kind its own: its rules and limits are its Spec's):
	  1 ammo    its round only (Spec `ammo`), at most Spec `buffer` of them: by hand, shift-click
	            and transporters through every face but Up (where the gun sits)
	  2 optic   a Laser Sight (any type) or a Rifle Scope (rifle and sniper), one; by hand and
	            shift-click only
	  3 muzzle  a Suppressor or an Improvised Suppressor (every type: the turret's own table, not
	            the guns' `fits`), one; by hand and shift-click only
	Transporters reach only the ammo slot and never take anything out (inputs give nothing,
	Core's default). Attachments never wear on a turret (nothing here or in the simulation changes
	their stacks); a Ruined one does nothing (Weapons/Handling.muzzleWorks), as on a gun.
	`demand`: the demand rule (server Transmitters/Transport) keeps its line ready.

	Data after the header (Shared/Machines), frozen (saved containers and items depend on it; only
	appended to):
	   7 credit       the cadence's credit (0..Shared/Turrets/TurretRules.CREDIT)
	   8 state        Shared/Turrets.packState(status, feed, lure, tracking), the kind's `state`
	                  (Machines records carry it: WAILA's status, the feed and the Lure)
	   9 lure         1 on (a fresh turret's), 0 off (the Lure button); kept in the item
	  10 held         rounds in its ammo slot after the last tick
	  11 feedRate     rounds arriving a second (Shared/Turrets/TurretRules.feedRate: the panel's
	                  "In: 2.4/s")
	  12 activeDelay  Mekanism's deactivation delay (Machines.showActive: ACTIVE while it targets
	                  or fires)
	  13 range        the blocks it engages at with its optic (TurretRules.range: a Rifle Scope on
	                  a rifle or sniper x 1.25, to MaxRange), written every tick (the panel's)
	RATE is minus the J it used this tick (idle or tracking, and a shot's).

	Each tick (first its range with its optic, whatever follows):
	  1. Config.Turrets.Enabled false, or no service yet: "Disabled", no energy taken, nothing
	     else done (the rounds' count still kept, so the feed rate reads true).
	  2. It takes its tracking energy if it tracked last tick, else its idle energy, all or
	     nothing (Machines.use): `powered`.
	  3. `blocked`: the cell above stops the gun (Shared/Turrets.headClear of ctx.getBlock).
	  4. Its rate is the feeder rule's (Shared/Turrets.rpm of last tick's feed); `armed`: a round
	     in the slot and a shot's energy stored; the cadence's credit grows only while powered
	     (TurretRules.cadence), and `ready` once it reached CREDIT.
	  5. The service answers the order (Shared/Turrets/Types); a shot it fires is taken only when
	     the order was ready, armed, powered and not blocked: a round out of the slot (a new stack
	     table, as kinds must), the shot's energy, CREDIT off the credit.
	  6. The feed rate from the rounds that arrived since the last tick, the rounds held, the
	     packed state from the answer (its status, feed and tracking, the Lure), RATE, ACTIVE.
	The service decides the status (precedence: Disabled, No power, Blocked, then with a target
	Firing within Config.Turrets.FiringTicks of a shot, else No ammo when unarmed while `ready`
	and no round is coming (none held and its feed 0: by hand, or its line stopped), else
	Targeting; without one No ammo with no round, else No target); the kind writes what it says.

	Its panel: the title (the block's name), the ammo, optic and muzzle slots in a row with their
	outlines (Shared/Turrets.GHOSTS), the status line, four lines ("Range 24 · 240 rpm": the range
	with its optic from the window's data, its own without; the feed: "Feed: Elite", "Feed: Basic
	→ 90 rpm" or "Feed: by hand"; "In: 2.4/s" with the window's data; "Lure: on"), the Lure button
	and Mekanism's energy bar. Its `info` (JEI, tooltips): range (its own, without an optic), rpm,
	buffer, idle, tracking, shot.
]]

local Core = require(script.Parent.Parent.Core)
local Config = require(script.Parent.Parent.Parent.Config)
local Coords = require(script.Parent.Parent.Parent.World.Coords)
local Items = require(script.Parent.Parent.Parent.Items)
local Tiers = require(script.Parent.Parent.Parent.Transmitters.Tiers)
local Turrets = require(script.Parent.Parent.Parent.Turrets)
local TurretRules = require(script.Parent.Parent.Parent.Turrets.TurretRules)
local TurretTypes = require(script.Parent.Parent.Parent.Turrets.Types)
local WeaponState = require(script.Parent.Parent.Parent.Weapons.WeaponState)
local Types = require(script.Parent.Parent.Parent.Inventory.Types)

type Container = Types.Container
type Spec = Turrets.Spec

local SLOT = Turrets.SLOT
local STATUS = Turrets.STATUS
local CREDIT = TurretRules.CREDIT
-- The Lure button's id, and the feed rate's and the range's data indices (its fifth and seventh
-- fields).
local LURE_BUTTON = 0
local FEED_RATE = Core.HEADER + 5
local RANGE = Core.HEADER + 7

-- One order and one outcome lent to the service, refilled for every turret (ticks never overlap).
local order: TurretTypes.Order = {
	tick = 0,
	key = 0,
	x = 0,
	y = 0,
	z = 0,
	block = 0,
	powered = false,
	blocked = false,
	armed = false,
	ready = false,
	optic = 0,
	muzzle = 0,
	muzzleFraction = 1,
	ammo = 0,
	held = 0,
	lure = false,
}
local outcome: TurretTypes.Outcome = { status = STATUS.NO_TARGET, fired = false, tracking = false, feed = 0 }

-- A number from the data, whole and within low..high (data from elsewhere).
local function whole(value: number, low: number, high: number): number
	if value ~= value then
		return low
	end
	return math.clamp(math.floor(value), low, high)
end

-- The rounds in the ammo slot (its round only: anything else counts as none).
local function roundsIn(spec: Spec, container: Container): number
	local stack = container.slots[SLOT.AMMO]
	if stack == nil or stack.item ~= spec.ammo then
		return 0
	end
	return math.max(math.floor(stack.count), 0)
end

-- The item in an attachment slot (0: none) and its durability left.
local function mounted(container: Container, slot: number): (number, number)
	local stack = container.slots[slot]
	if stack == nil then
		return 0, 1
	end
	return stack.item, WeaponState.fraction(stack.item, stack.damage)
end

-- Is the status one the block shows working (ACTIVE): targeting or firing?
local function working(status: number): boolean
	return status == STATUS.TARGETING or status == STATUS.FIRING
end

local function tick(spec: Spec, container: Container, ctx: Core.TickContext)
	local lastStatus, lastFeed, _, lastTracking = Turrets.unpackState(Core.get(container, "state"))
	local lure = Core.get(container, "lure") ~= 0
	local held = whole(Core.get(container, "held"), 0, Items.MAX_STACK)
	local count = roundsIn(spec, container)
	local feedRate = Core.get(container, "feedRate")
	-- (The range it engages at, for the panel: the simulation's, TurretRules.range.)
	local optic = mounted(container, SLOT.OPTIC)
	Core.set(container, "range", TurretRules.range(spec, optic))
	local service = ctx.turret
	if not Config.Turrets.Enabled or service == nil then
		-- 1. Inert: nothing taken, nothing done.
		Core.set(container, "feedRate", TurretRules.feedRate(feedRate, count - held))
		Core.set(container, "held", count)
		Core.set(container, "state", Turrets.packState(STATUS.DISABLED, 0, lure, false))
		Core.set(container, "rate", 0)
		Core.showActive(container, working(lastStatus), false)
		return
	end
	-- 2. This tick's energy, all or nothing.
	local need = if lastTracking then spec.tracking else spec.idle
	local powered = Core.use(container, need)
	local used = if powered then Core.quantiseUp(need) else 0
	-- 3. The cell over the gun.
	local blocked = not Turrets.headClear(ctx.getBlock(ctx.x, ctx.y + 1, ctx.z))
	-- 4. The rate the feed allows, a round and a shot's energy, the cadence.
	local rpm = if powered then Turrets.rpm(spec, lastFeed) else 0
	local armed = count >= 1 and Core.energy(container) >= spec.shot
	local credit = whole(Core.get(container, "credit"), 0, CREDIT)
	local ready = credit + rpm >= CREDIT
	-- 5. The service's answer.
	local muzzle, muzzleFraction = mounted(container, SLOT.MUZZLE)
	order.tick = ctx.tick
	order.key = Coords.posKey(ctx.x, ctx.y, ctx.z)
	order.x, order.y, order.z = ctx.x, ctx.y, ctx.z
	order.block = ctx.block
	order.powered = powered
	order.blocked = blocked
	order.armed = armed
	order.ready = ready
	order.optic = optic
	order.muzzle = muzzle
	order.muzzleFraction = muzzleFraction
	order.ammo = count
	order.held = held
	order.lure = lure
	outcome.status, outcome.fired, outcome.tracking, outcome.feed = STATUS.NO_TARGET, false, false, 0
	local out = service(order, outcome)
	local fired = out.fired == true and ready and armed and powered and not blocked
	credit = TurretRules.cadence(credit, rpm, fired)
	if fired then
		local stack = container.slots[SLOT.AMMO] :: Items.Stack
		container.slots[SLOT.AMMO] = Items.withCount(stack, stack.count - 1)
		Core.use(container, spec.shot)
		used += Core.quantiseUp(spec.shot)
	end
	-- 6. The books.
	local now = if fired then count - 1 else count
	Core.set(container, "credit", credit)
	Core.set(container, "feedRate", TurretRules.feedRate(feedRate, count - held))
	Core.set(container, "held", now)
	local status = if type(out.status) == "number" then out.status else STATUS.NO_TARGET
	local feed = if type(out.feed) == "number" then out.feed else 0
	Core.set(container, "state", Turrets.packState(status, feed, lure, out.tracking == true))
	Core.set(container, "rate", -used)
	Core.showActive(container, working(lastStatus), working(status))
end

local function onButton(container: Container, button: number)
	if button == LURE_BUTTON then
		Core.set(container, "lure", if Core.get(container, "lure") ~= 0 then 0 else 1)
	end
end

-- The feeder's tier name ("Basic" ...).
local function tierName(feed: number): string
	local tier = Tiers.TIERS[feed]
	return if tier then tier.name else "?"
end

-- The panel's lines (see the header); the range with its optic and the feed rate only with the
-- window's data.
local function lines(spec: Spec, view: Core.View, data: { number }?): { string }
	local _, feed, lure = Turrets.unpackState(view.state)
	local written = if data then data[RANGE] else nil
	local range = TurretRules.range(spec)
	if type(written) == "number" and written > 0 and written <= Config.Turrets.MaxRange then
		range = written
	end
	local shown = { `Range {string.format("%g", range)} · {spec.rpm} rpm` }
	if feed <= 0 then
		table.insert(shown, "Feed: by hand")
	elseif feed >= spec.tier then
		table.insert(shown, `Feed: {tierName(feed)}`)
	else
		table.insert(shown, `Feed: {tierName(feed)} → {Turrets.rpm(spec, feed)} rpm`)
	end
	local rate = if data then data[FEED_RATE] else nil
	if type(rate) == "number" and rate == rate then
		table.insert(shown, string.format("In: %.1f/s", math.max(rate, 0)))
	end
	table.insert(shown, if lure then "Lure: on" else "Lure: off")
	return shown
end

local function define(spec: Spec): Core.Kind
	local function accepts(slot: number): (item: number) -> boolean
		if slot == SLOT.AMMO then
			return function(item: number): boolean
				return item == spec.ammo
			end
		elseif slot == SLOT.OPTIC then
			return function(item: number): boolean
				return spec.optics[item] == true
			end
		end
		return function(item: number): boolean
			return spec.muzzles[item] == true
		end
	end
	return Core.define(spec.kind, {
		slots = {
			{
				x = 8,
				y = 35,
				accepts = accepts(SLOT.AMMO),
				limit = spec.buffer,
				-- (Every face but Up: the gun sits there.)
				insert = { 0, 2, 3, 4, 5 },
				ghost = Turrets.GHOSTS.ammo,
			},
			{ x = 26, y = 35, accepts = accepts(SLOT.OPTIC), limit = 1, insert = {}, ghost = Turrets.GHOSTS.optic },
			{ x = 44, y = 35, accepts = accepts(SLOT.MUZZLE), limit = 1, insert = {}, ghost = Turrets.GHOSTS.muzzle },
		},
		fields = { "credit", "state", "lure", "held", "feedRate", "activeDelay", "range" },
		keep = { "lure" },
		defaults = { lure = 1 },
		state = "state",
		-- (Read once: with the turrets off no line waits for one.)
		demand = Config.Turrets.Enabled,
		panel = {
			status = { x = 8, y = 20 },
			-- (Right of the slots: 94 pixels to the energy bar, room for "Feed: Advanced → 150 rpm".)
			lines = { x = 66, y = 18 },
		},
		buttons = {
			{ id = LURE_BUTTON, x = 8, y = 56, w = 40, h = 14, label = "Lure" },
		},
		onButton = onButton,
		tick = function(container: Container, ctx: Core.TickContext)
			tick(spec, container, ctx)
		end,
		status = function(view: Core.View): string?
			local status = Turrets.unpackState(view.state)
			return Turrets.STATUS_NAMES[status]
		end,
		lines = function(view: Core.View, data: { number }?): { string }
			return lines(spec, view, data)
		end,
		info = {
			range = spec.range,
			rpm = spec.rpm,
			buffer = spec.buffer,
			idle = spec.idle,
			tracking = spec.tracking,
			shot = spec.shot,
		},
	})
end

local kinds: { [string]: Core.Kind } = {}
for _, spec in Turrets.SPECS do
	local kind = define(spec)
	assert(kind.index.feedRate == FEED_RATE, "a turret's feed rate is its fifth field")
	assert(kind.index.range == RANGE, "a turret's range is its seventh field")
	kinds[spec.kind] = kind
end

return table.freeze(kinds)
