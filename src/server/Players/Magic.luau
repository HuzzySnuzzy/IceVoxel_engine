--!strict
--[[
	Magic weapons and Mana Crystals on the server (Terraria's: ItemList `magic`, Shared/Magic,
	Config.Mana): the authority over every cast and every projectile.

	  HeldUse    Net/MagicSync HeldUse (using the held item without a block): Shared/Magic/Casting
	             checks it (not a spectator, alive, the selected hotbar slot, the item really in
	             hand); a Mana Crystal is used up (Players/Mana.useCrystal: while fewer than nine
	             were used; item.mana_crystal.use for everyone near; creative keeps the item, as
	             Minecraft's instabuild); a weapon casts when its use time has passed since the
	             last cast (Casting.ready / after on the server's clock: 1 tick of slack, late
	             arrivals credited) and Players/Mana can spend its mana (creative: free;
	             not enough: the client is told, nothing flies).
	  Casting    the projectile (Shared/Magic/Projectiles: the weapon's kind) leaves the eyes
	             (Players/PlayerPositions.eye: 1.62 above the feet, 1.27 sneaking) along the unit
	             direction the client aimed (its camera ray towards what it points at), at most
	             MAX_PER_PLAYER of a player's in flight; everyone within
	             Config.Interest.PlayerDistance of it gets a spawn op (Net/MagicSync Projectiles,
	             with the caster's seq so their client adopts the one it already flies) and hears
	             item.magic.cast (the caster's client played its own).
	  Flight     20 ticks a second, every projectile steps with the shared pure rule against the
	             server's blocks (`world:peekBlock`: nothing generated = passing) and the mobs near
	             it (Mobs/Mobs.near, boxes from MobList): hits hurt the mob through its armor and
	             cooldown (Mobs.magicDamage: the weapon's half hearts times Mana Sickness's cut,
	             Players/Mana.damageFactor; the weapon's knockback away from where the projectile
	             came from; credited to the caster), the spark sets it burning BURN_TICKS 3 s at
	             the weapon's `fire` chance (Mobs.ignite); entity.magic.hit plays where it hit.
	             A bounce (the Water Bolt) sends a sync op with its new path (rounded to f32, as
	             the clients will fly it), an end an end op with its reason; both go to the
	             players the spawn went to. The game has no PvP path, so players are never hit,
	             and no fire block is ever placed (doFireTick has nothing to do with magic).
	  Off        with Config.Mana.Enabled false nothing listens: magic weapons do nothing.
	A caster who leaves takes their projectiles with them (end ops), so no hit is credited to a
	player who is gone.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Casting = require(Shared.Magic.Casting)
local Projectiles = require(Shared.Magic.Projectiles)
local MagicSync = require(Shared.Net.MagicSync)
local Protocol = require(Shared.Net.Protocol)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Mobs = require(script.Parent.Parent.Mobs.Mobs)
local Inventories = require(script.Parent.Inventories)
local Mana = require(script.Parent.Mana)
local PlayerPositions = require(script.Parent.PlayerPositions)

-- Only what Magic uses of ServerNet.ServerNet.
type Net = {
	send: (player: Player, kind: number, payload: buffer) -> (),
	on: (kind: number, handler: (player: Player, payload: buffer) -> ()) -> (),
}

type Flight = {
	id: number,
	projectile: Projectiles.Projectile,
	owner: Player,
	-- The weapon's numbers (ItemList `magic`).
	damage: number,
	fire: number,
	knockback: number,
	-- The players who were sent its spawn.
	viewers: { Player },
}

local Magic = {}

local TICK = 1 / 20
local MAX_TICKS_PER_FRAME = 4
-- Projectiles of one player in flight at once, and in all.
local MAX_PER_PLAYER = 16
local MAX_FLYING = 512
-- Ticks a spark sets a mob burning (Terraria's On Fire!, 3 s).
local BURN_TICKS = 60
-- Mobs looked for around a projectile: its tick's travel plus the largest box.
local NEAR_EXTRA = 3
local CAST = "item.magic.cast"
local HIT = "entity.magic.hit"
local CRYSTAL = "item.mana_crystal.use"

local flights: { [number]: Flight } = {}
local flightCount = 0
local perPlayer: { [Player]: number } = {}
-- When each player's last cast counts from (Casting.after; os.clock()).
local lastCast: { [Player]: number } = {}
local nextId = 1
local random = Random.new()
local hits: { Projectiles.Target } = {}

-- The players within Config.Interest.PlayerDistance (horizontal) of (x, z).
local function viewersNear(x: number, z: number): { Player }
	local distance = Config.Interest.PlayerDistance
	local list = {}
	for player, px, _py, pz in PlayerPositions.each() do
		if player then
			local dx, dz = px - x, pz - z
			if dx * dx + dz * dz <= distance * distance then
				table.insert(list, player)
			end
		end
	end
	return list
end

-- Sends ops (MagicSync Projectiles) to each of `players` still here.
local function sendOps(net: Net, players: { Player }, ops: { MagicSync.ProjectileOp })
	local payload = MagicSync.encodeProjectiles(ops)
	for _, player in players do
		if player.Parent ~= nil then
			net.send(player, Protocol.ServerMessage.Projectiles, payload)
		end
	end
end

-- Takes `flight` out of the flying (the caller sends its end op).
local function remove(flight: Flight)
	flights[flight.id] = nil
	flightCount -= 1
	local owner = flight.owner
	local count = (perPlayer[owner] or 1) - 1
	if count > 0 then
		perPlayer[owner] = count
	else
		perPlayer[owner] = nil
	end
end

local function endOp(flight: Flight): MagicSync.ProjectileOp
	local p = flight.projectile
	return { op = "end", id = flight.id, x = p.x, y = p.y, z = p.z, reason = p.reason }
end

-- A Mana Crystal used from the hand (see the header).
local function useCrystal(player: Player, mode: string)
	if not Mana.useCrystal(player) then
		return
	end
	if not Casting.free(mode) then
		local held = Inventories.heldStack(player)
		if held and held.item == Casting.CRYSTAL then
			Inventories.setHeld(player, Items.withCount(held, held.count - 1))
		end
	end
	if Sounds.allow(player) then
		Sounds.playAt(player, CRYSTAL)
	end
end

-- A weapon's cast (see the header): the projectile spawned, or nothing.
local function cast(net: Net, player: Player, mode: string, use: MagicSync.HeldUse)
	local magic = Items.magic(use.item)
	if magic == nil then
		return
	end
	local now = os.clock()
	local last = lastCast[player]
	if
		not Casting.ready(last, now, magic.useTicks)
		or (perPlayer[player] or 0) >= MAX_PER_PLAYER
		or flightCount >= MAX_FLYING
	then
		return
	end
	local ex, ey, ez = PlayerPositions.eye(player)
	local kind = Projectiles.kind(magic.projectile)
	if ex == nil or kind == nil then
		return
	end
	if Casting.free(mode) then
		Mana.casting(player)
	elseif not Mana.spend(player, magic.mana) then
		return
	end
	lastCast[player] = Casting.after(last, now, magic.useTicks)
	local p = Projectiles.launch(kind, ex, ey, ez, use.dx, use.dy, use.dz)
	local id = nextId
	nextId = if nextId >= 2 ^ 32 - 1 then 1 else nextId + 1
	local flight: Flight = {
		id = id,
		projectile = p,
		owner = player,
		damage = magic.damage,
		fire = magic.fire or 0,
		knockback = magic.knockback or 0,
		viewers = viewersNear(p.x, p.z),
	}
	flights[id] = flight
	flightCount += 1
	perPlayer[player] = (perPlayer[player] or 0) + 1
	sendOps(net, flight.viewers, {
		{
			op = "spawn",
			id = id,
			kind = kind,
			owner = player.UserId,
			seq = use.seq,
			x = p.x,
			y = p.y,
			z = p.z,
			vx = p.vx,
			vy = p.vy,
			vz = p.vz,
		},
	})
	Sounds.play(CAST, p.x, p.y, p.z, player)
end

local function onHeldUse(net: Net, player: Player, payload: buffer)
	local use = MagicSync.decodeHeldUse(payload)
	local window = Inventories.get(player)
	if use == nil or window == nil then
		return
	end
	local mode = GameMode.of(player)
	local held = Inventories.heldStack(player)
	local kind = Casting.check(
		mode,
		PlayerPositions.alive(player),
		window.inventory.selected,
		if held then held.item else nil,
		use.slot,
		use.item
	)
	if kind == "crystal" then
		useCrystal(player, mode)
	elseif kind == "cast" then
		cast(net, player, mode, use)
	end
end

-- What a hit does to mob `target` (see the header).
local function hitMob(flight: Flight, target: Projectiles.Target)
	local p = flight.projectile
	local owner = flight.owner
	local damage = flight.damage * Mana.damageFactor(owner)
	-- (Pushed the way the projectile flew: from a block behind the mob along its path.)
	local speed = math.sqrt(p.vx * p.vx + p.vz * p.vz)
	local fromX, fromZ = p.x, p.z
	if speed > 1e-6 then
		fromX, fromZ = target.x - p.vx / speed, target.z - p.vz / speed
	end
	Mobs.magicDamage(target.id, damage, owner, fromX, fromZ, flight.knockback)
	if flight.fire > 0 and random:NextNumber() < flight.fire then
		Mobs.ignite(target.id, BURN_TICKS)
	end
	Sounds.play(HIT, target.x, target.y + target.height / 2, target.z)
end

local function tick(net: Net, world: WorldServer.World)
	if flightCount == 0 then
		return
	end
	local getBlock = function(x: number, y: number, z: number): number?
		return world:peekBlock(x, y, z)
	end
	-- Ops by the players they go to (one message each this tick).
	local outgoing: { [Player]: { MagicSync.ProjectileOp } } = {}
	local function queue(flight: Flight, op: MagicSync.ProjectileOp)
		for _, viewer in flight.viewers do
			local list = outgoing[viewer]
			if list == nil then
				list = {}
				outgoing[viewer] = list
			end
			table.insert(list, op)
		end
	end
	for id, flight in flights do
		local p = flight.projectile
		local kind = Projectiles.get(p.kind) :: Projectiles.Kind
		local targets = Mobs.near(p.x, p.y, p.z, kind.speed + NEAR_EXTRA) :: any
		local event = Projectiles.step(p, getBlock, targets, hits)
		for _, target in hits do
			hitMob(flight, target)
		end
		if event == "bounce" then
			Projectiles.round(p)
			queue(flight, { op = "sync", id = id, x = p.x, y = p.y, z = p.z, vx = p.vx, vy = p.vy, vz = p.vz })
			Sounds.play(HIT, p.x, p.y, p.z, nil, 0.5)
		elseif p.dead then
			if event == "block" then
				Sounds.play(HIT, p.x, p.y, p.z)
			end
			queue(flight, endOp(flight))
			remove(flight)
		end
	end
	for player, ops in outgoing do
		if player.Parent ~= nil then
			net.send(player, Protocol.ServerMessage.Projectiles, MagicSync.encodeProjectiles(ops))
		end
	end
end

--[[ API ]]

-- Starts magic (see the header): HeldUse, and the projectiles' ticks.
function Magic.start(net: Net, world: WorldServer.World)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastCast[player] = nil
		for _, flight in flights do
			if flight.owner == player then
				flight.projectile.dead = true
				sendOps(net, flight.viewers, { endOp(flight) })
				remove(flight)
			end
		end
		perPlayer[player] = nil
	end)
	if not Config.Mana.Enabled then
		return
	end
	net.on(Protocol.ClientMessage.HeldUse, function(player: Player, payload: buffer)
		onHeldUse(net, player, payload)
	end)
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator = math.min(accumulator + dt, TICK * MAX_TICKS_PER_FRAME)
		while accumulator >= TICK do
			accumulator -= TICK
			tick(net, world)
		end
	end)
end

-- Projectiles in flight (for a debug line or a probe).
function Magic.count(): number
	return flightCount
end

return Magic
