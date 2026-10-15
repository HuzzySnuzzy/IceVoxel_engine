--!strict
--[[
	A shot on the server, from its Fire message to its Shots record (the design's firing
	pipeline): Weapons/FireRules' rules played out against the world it is given (Env), so the
	same code runs in the game (Weapons/init hands it the real modules) and in
	tests/spec/WeaponFiring (fakes).

	  1. Rate     every Fire is acknowledged (Players/Inventories.acknowledge, or Inventories.fire
	              for a shot that goes), so the client's predicted round never sticks. More than
	              Config.Weapons.ShotsPerSecond a second (bursts of twice that) are dropped silently.
	  2. Checks   FireRules.check; a refusal queues the shooter a refused record (stopping their
	              automatic fire; "jammed" with its jam flag) and nothing else happens.
	  3. The jam  rolled on the server's random: Handling.jamChance of the gun's condition and its
	              magazine's (never in creative), then Inventories.fire applies the shot (the round,
	              the wear, the feed, the jam) and hands back the gun as it was; the shot counts
	              for the cadence from Handling.after.
	  4. Flight   the round fired (FireRules.round) flies from the claimed eyes (within OriginSlack
	              of the server's, nothing between) along each pellet's direction
	              (FireRules.directions); the mobs near the whole flight (Ballistics.bounds: one
	              Mobs.targets call a shot, with where the shooter's client last saw each) and, with
	              Config.Weapons.PvP, every other living player who is no spectator are its targets;
	              each pellet is traced (Ballistics.trace) against the server's blocks.
	  5. Effects  FireRules.tally: each mob hit once with its head share (through no armour) and
	              once with its body share, the knockback on the first (env.hurtMob:
	              Mobs.weaponDamage, credited to the shooter); each player likewise
	              (env.hurtPlayer: Players/Characters.weaponHurt, the Bleeding roll on the last);
	              the panes passed shatter (env.shatter); the shot's noise at the muzzle
	              (Handling.noise: suppressors, a Ruined one muffles nothing) and ImpactNoise where
	              it landed (FireRules.impactNoise) go to the infected (env.noise:
	              Apocalypse/NoiseBus); a crossbow bolt may drop again (FireRules.recovery).
	  6. Shots    the record (each pellet's last impact; suppressed; the gun jammed after it) is
	              queued for the shooter and every player within ShotBroadcast blocks; `flush`
	              sends each player one Shots message a frame (MAX_SHOTS records each, more
	              messages when there are more).
	Shot sounds are the clients' (Rendering/ShotView), never the server's Audio/Sounds, so nothing
	is heard twice and NoiseRules has nothing to say about them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local WeaponSync = require(Shared.Net.WeaponSync)
local Weapons = require(Shared.Weapons)
local WeaponState = require(Shared.Weapons.WeaponState)
local Handling = require(Shared.Weapons.Handling)
local Ballistics = require(Shared.Weapons.Ballistics)

local FireRules = require(script.Parent.FireRules)

type Stack = Items.Stack

-- What Firing needs of the world (the game's real modules, or a spec's fakes). Players are keys.
export type Env = {
	settings: FireRules.Settings,
	-- Seconds (the server's clock), and a number in [0, 1).
	now: () -> number,
	random: () -> number,
	-- The server's blocks (nil: not loaded).
	getBlock: (x: number, y: number, z: number) -> number?,
	-- The shooter as the checks see them (FireRules.Shooter; `now` and `lastShot` are filled in
	-- here).
	shooter: (player: any) -> FireRules.Shooter,
	-- The player's UserId (the Shots record's shooter).
	userId: (player: any) -> number,
	-- Inventories.acknowledge and Inventories.fire (the gun before the shot, nil: none fired).
	acknowledge: (player: any, seq: number) -> (),
	fire: (player: any, seq: number, item: number, jam: boolean) -> Stack?,
	-- The stack in the player's hand now.
	held: (player: any) -> Stack?,
	-- Mobs.targets.
	mobs: (player: any, x: number, y: number, z: number, radius: number) -> { FireRules.MobCandidate },
	-- Every player with a position (targets and listeners).
	players: () -> { FireRules.PlayerCandidate },
	-- Mobs.weaponDamage and Characters.weaponHurt (what landed).
	hurtMob: (
		id: number,
		amount: number,
		player: any,
		ox: number,
		oz: number,
		knockback: number,
		head: boolean
	) -> number,
	hurtPlayer: (player: any, amount: number, head: boolean, bleed: boolean) -> number,
	-- NoiseBus.emit.
	noise: (x: number, y: number, z: number, radius: number) -> (),
	-- A pane of glass shot through (the block cleared, its sound).
	shatter: (x: number, y: number, z: number) -> (),
	-- A round dropped again as an item (a crossbow bolt).
	drop: (item: number, x: number, y: number, z: number) -> (),
	-- A Shots message to one player.
	send: (player: any, payload: buffer) -> (),
}

type PlayerState = {
	bucket: FireRules.Bucket,
	lastShot: number?,
}

export type Firing = {
	env: Env,
	states: { [any]: PlayerState },
	-- Records waiting for `flush`, by player.
	outbox: { [any]: { WeaponSync.Shot } },
	handle: (self: Firing, player: any, fire: WeaponSync.Fire) -> string?,
	flush: (self: Firing) -> (),
	forget: (self: Firing, player: any) -> (),
}

local Firing = {}
Firing.__index = Firing

function Firing.new(env: Env): Firing
	local self = { env = env, states = {}, outbox = {} }
	return (setmetatable(self, Firing) :: any) :: Firing
end

local function stateOf(self: Firing, player: any): PlayerState
	local state = self.states[player]
	if state == nil then
		state = { bucket = FireRules.newBucket(2 * self.env.settings.ShotsPerSecond), lastShot = nil }
		self.states[player] = state
	end
	return state
end

-- Queues `record` for each of `players`.
local function queue(self: Firing, players: { any }, record: WeaponSync.Shot)
	for _, player in players do
		local list = self.outbox[player]
		if list == nil then
			list = {}
			self.outbox[player] = list
		end
		table.insert(list, record)
	end
end

local function refuse(self: Firing, player: any, fire: WeaponSync.Fire, reason: string): string
	local env = self.env
	env.acknowledge(player, fire.seq)
	queue(self, { player }, FireRules.refused(env.userId(player), fire, reason))
	return reason
end

--[[
	One Fire message from `player` (see the header). Returns why it was refused ("rate" for one
	dropped silently), nil for a shot that went.
]]
function Firing.handle(self: Firing, player: any, fire: WeaponSync.Fire): string?
	local env = self.env
	local s = env.settings
	local now = env.now()
	local state = stateOf(self, player)
	if not FireRules.take(state.bucket, now, s.ShotsPerSecond, 2 * s.ShotsPerSecond) then
		env.acknowledge(player, fire.seq)
		return "rate"
	end
	local shooter = env.shooter(player)
	shooter.now = now
	shooter.lastShot = state.lastShot
	local reason = FireRules.check(shooter, fire, env.getBlock, s)
	if reason then
		return refuse(self, player, fire, reason)
	end
	local held = WeaponState.sane(shooter.held :: Stack)
	local spec = Weapons.firearm(held.item) :: Weapons.FirearmSpec
	local creative = GameMode.instabuild(shooter.mode)
	-- The jam (never in creative: the stack doesn't change there).
	local jam = false
	if not creative then
		local mag, magWear = WeaponState.magazine(held)
		local chance = Handling.jamChance(
			spec,
			WeaponState.fraction(held.item, held.damage),
			if mag then WeaponState.fraction(mag, magWear) else nil
		)
		jam = chance > 0 and env.random() < chance
	end
	local before = env.fire(player, fire.seq, fire.item, jam)
	if before == nil then
		-- (The checks passed, so this is a race with the inventory: nothing went.)
		queue(self, { player }, FireRules.refused(env.userId(player), fire, WeaponState.EMPTY))
		return WeaponState.EMPTY
	end
	state.lastShot = Handling.after(state.lastShot, now, Handling.shotTicks(spec, WeaponState.modeIndex(before)))
	local ammo = Weapons.ammo(FireRules.round(before, spec, creative))
	local after = env.held(player)
	local jammed = after ~= nil and after.item == fire.item and WeaponState.jammed(after)
	local muzzle, muzzleWear = WeaponState.attachment(before, "muzzle")
	local fraction = if muzzle then WeaponState.fraction(muzzle, muzzleWear) else 1
	local suppressed = Handling.suppressed(muzzle, fraction)
	local ox, oy, oz = fire.ox, fire.oy, fire.oz
	-- The muzzle's noise goes out whatever the round (a shot is a shot).
	env.noise(ox, oy, oz, Handling.noise(spec, muzzle, fraction))
	local players = env.players()
	local finals: { Ballistics.Impact } = {}
	if ammo ~= nil then
		finals = Firing.fly(self, player, fire, shooter, players, spec, ammo, muzzle, fraction)
	end
	queue(
		self,
		FireRules.audience(players, ox, oz, player, s),
		FireRules.record(env.userId(player), fire, suppressed, jammed, finals)
	)
	return nil
end

--[[
	The flight and its effects (see the header's 4 and 5) of a shot of `ammo` that went, with
	`players` every player with a position: each pellet's last impact.
]]
function Firing.fly(
	self: Firing,
	player: any,
	fire: WeaponSync.Fire,
	shooter: FireRules.Shooter,
	players: { FireRules.PlayerCandidate },
	spec: Weapons.FirearmSpec,
	ammo: Weapons.AmmoSpec,
	muzzle: number?,
	fraction: number
): { Ballistics.Impact }
	local env = self.env
	local s = env.settings
	local origin: Ballistics.Vec = { x = fire.ox, y = fire.oy, z = fire.oz }
	local shot = FireRules.shotSpec(spec, ammo, s, player)
	local directions = FireRules.directions(spec, ammo, fire, muzzle, fraction, env.random)
	-- Every candidate near the whole flight, asked for once.
	local minX, minY, minZ, maxX, maxY, maxZ = origin.x, origin.y, origin.z, origin.x, origin.y, origin.z
	for _, dir in directions do
		local x0, y0, z0, x1, y1, z1 = Ballistics.bounds(origin, dir, shot)
		minX, minY, minZ = math.min(minX, x0), math.min(minY, y0), math.min(minZ, z0)
		maxX, maxY, maxZ = math.max(maxX, x1), math.max(maxY, y1), math.max(maxZ, z1)
	end
	local cx, cy, cz = (minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2
	local hx, hy, hz = (maxX - minX) / 2, (maxY - minY) / 2, (maxZ - minZ) / 2
	local radius = math.sqrt(hx * hx + hy * hy + hz * hz) + 3
	local targets: { Ballistics.Target } = {}
	for _, mob in env.mobs(player, cx, cy, cz, radius) do
		table.insert(targets, FireRules.mobTarget(mob, s))
	end
	if s.PvP then
		for _, other in players do
			if other.key ~= player and other.alive and not GameMode.isSpectator(other.mode) then
				local dx, dy, dz = other.x - cx, other.y - cy, other.z - cz
				if dx * dx + dy * dy + dz * dz <= radius * radius then
					table.insert(targets, FireRules.playerTarget(other.key, other.x, other.y, other.z, other.eyeY))
				end
			end
		end
	end
	local rules = FireRules.blockRules(s, GameMode.mayBuild(shooter.mode))
	local traces: { { Ballistics.Impact } } = table.create(#directions)
	for i, dir in directions do
		traces[i] = Ballistics.trace(env.getBlock, origin, dir, shot, targets, rules)
	end
	local tally = FireRules.tally(traces, shot, s)
	local pellets = #directions
	for _, hit in tally.mobs do
		local knockback = FireRules.knockback(hit.pellets, pellets, s)
		if hit.head > 0 then
			env.hurtMob(hit.target.key, hit.head, player, origin.x, origin.z, knockback, true)
			knockback = 0
		end
		if hit.body > 0 then
			env.hurtMob(hit.target.key, hit.body, player, origin.x, origin.z, knockback, false)
		end
	end
	for _, hit in tally.players do
		if hit.head > 0 then
			env.hurtPlayer(hit.target.key, hit.head, true, not (hit.body > 0))
		end
		if hit.body > 0 then
			env.hurtPlayer(hit.target.key, hit.body, false, true)
		end
	end
	for _, cell in tally.glass do
		env.shatter(cell[1], cell[2], cell[3])
	end
	local ix, iy, iz = FireRules.impactNoise(tally.finals, origin.x, origin.y, origin.z, s)
	if ix ~= nil then
		env.noise(ix, iy, iz, s.ImpactNoise)
	end
	if ammo.recover then
		for _, impact in tally.finals do
			local x, y, z = FireRules.recovery(ammo, impact, env.random(), s)
			if x ~= nil then
				env.drop(ammo.item, x, y, z)
			end
		end
	end
	return tally.finals
end

-- Sends every queued record (see the header): one Shots message a player, more past MAX_SHOTS.
function Firing.flush(self: Firing)
	if next(self.outbox) == nil then
		return
	end
	local env = self.env
	local outbox = self.outbox
	self.outbox = {}
	local most = WeaponSync.MAX_SHOTS
	for player, records in outbox do
		if #records <= most then
			env.send(player, WeaponSync.encodeShots(records))
		else
			for first = 1, #records, most do
				env.send(player, WeaponSync.encodeShots(table.move(records, first, first + most - 1, 1, {})))
			end
		end
	end
end

-- Forgets a player who left (their bucket, cadence and queued records).
function Firing.forget(self: Firing, player: any)
	self.states[player] = nil
	self.outbox[player] = nil
end

return Firing
