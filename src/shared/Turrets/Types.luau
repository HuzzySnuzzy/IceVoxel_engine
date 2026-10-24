--!strict
--[[
	The shapes a turret's machine tick and the server's turret simulation share (Shared/Turrets):
	what the tick asks (an Order), what the simulation answers (an Outcome) and the service that
	answers it. Types only, requiring nothing, so Machines/Core can name the service in its
	TickContext (as it names Seasons/Rooms' Sample) without depending on the turrets.

	Each machine tick of a turret (Machines/Kinds/Turret) fills one Order and calls the service
	(TickContext `turret`: server Turrets/TurretWorld.step, bound by server Turrets/Turrets and
	handed to the machines by Machines.setTurretService; nil before that, or with
	Config.Turrets.Enabled false, and the kind then shows "Disabled"). The service aims, picks a
	target and decides whether the shot this tick goes; the kind keeps the books (energy, the
	round taken, the cadence's credit, the packed state). Both tables are lent for the call: the
	service fills and returns `out` (or a table of its own) and keeps neither.

	These shapes are frozen: the kind, the simulation and the client's view are built on them by
	different hands.
]]

-- One turret's question this tick (see the header).
export type Order = {
	-- The machines' tick count (TickContext `tick`): a new number is a new tick, for work the
	-- simulation does once a tick for every turret (its grid of hostiles, its budgets).
	tick: number,
	-- Shared/World/Coords.posKey(x, y, z): the turret's key, and its cell and block.
	key: number,
	x: number,
	y: number,
	z: number,
	block: number,
	-- It took this tick's idle or tracking energy (all or nothing: Machines.use).
	powered: boolean,
	-- The cell above stops the gun (Shared/Turrets.headClear false).
	blocked: boolean,
	-- A round in its ammo slot and a shot's energy stored.
	armed: boolean,
	-- The cadence allows a shot this tick (its credit reached Shared/Turrets/TurretRules.CREDIT).
	ready: boolean,
	-- The items in its optic and muzzle slots (0: none) and the muzzle device's durability left
	-- (0..1, Weapons/WeaponState.fraction; 1 without one). They never wear on a turret.
	optic: number,
	muzzle: number,
	muzzleFraction: number,
	-- Rounds in its ammo slot now (before this tick's shot) and after its last tick.
	ammo: number,
	held: number,
	-- Its Lure is on (the panel's button).
	lure: boolean,
}

-- The simulation's answer: the status to show (Shared/Turrets.STATUS), whether the shot goes
-- (taken only when the order was ready, armed, powered and not blocked), whether it tracks a
-- target (it then draws its tracking energy next tick) and the feeder rule's tier (0: fed by
-- hand; Shared/Turrets.rpm caps its rate by it from the next tick).
export type Outcome = { status: number, fired: boolean, tracking: boolean, feed: number }

-- What answers a turret's tick (see the header).
export type Service = (order: Order, out: Outcome) -> Outcome

-- (Types only; a module must still return something.)
return table.freeze({})
