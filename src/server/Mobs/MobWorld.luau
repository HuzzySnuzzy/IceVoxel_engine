--!strict
--[[
	Mobs on the server: Minecraft 1.20.1's LivingEntity / Mob rules for the kinds of
	Shared/Entities/MobList, without any Roblox APIs so the tests run them (Mobs/Mobs is the Roblox
	side: players, replication, the network, spawning).

	Each tick (`tick`, 20 a second), in id order, for every mob whose chunk ticks (`context.active`:
	loaded and within Config.Server.SimulationRadius chunks of a player, World/Simulation; the rest
	are frozen where they are, as Minecraft's entities in chunks that don't tick):
	  AI         Mobs/MobAI: wander, panic, hunt, hit, shoot, swell; it steers and jumps.
	  Physics    Shared/Entities/MobPhysics: gravity, friction, fluids, collision, stepping and
	             jumping, climbing, slow falling.
	  Falls      landing after more than 3 blocks hurts ceil(distance - 3), through armor
	             (LivingEntity.causeFallDamage; not chickens).
	  Fire       Players/Burning.tickPlayer with the kind's armor, as for players: lava hurts 4 every
	             10 ticks and sets it burning 15 s, fire and campfires hurt, burning costs 1 every
	             20 ticks, water puts it out. (A mob catches fire after 20 ticks in a fire block,
	             as a player does; Minecraft's mobs at once.) Zombies and skeletons burn in
	             daylight (`burnsInDaylight`, Mob.isSunBurnTick): by day (Level.isDay with the
	             weather where they stand, `context.isDay`: not in a thunderstorm), out of water
	             and out of the rain (`context.rainingAt` at the feet or the top of the box),
	             with the open sky over their eyes (`skyClear`: Level.canSeeSky's full sky light,
	             so the leaves of a tree shelter them, glass doesn't), one tick in 25 sets them
	             burning for 8 s.
	  Walls      eyes in an opaque block: 1 every 10 ticks (in_wall).
	  Hurts      `hurt` goes through LivingEntity.hurt's cooldown (Burning.hurtPlayer: 10 ticks in
	             which only a bigger hurt lands, by the difference), softened by the kind's armor
	             unless it bypasses it (falls, burning, walls); a fresh hurt flashes the mob red
	             for 10 ticks (hurtTime), plays its hurt sound, knocks it back 0.4 away from where
	             it came from (Combat.knockback) and makes it panic (creatures) or hunt the player
	             (monsters, MobAI.hurt). A player's hit counts for the kill for 100 ticks
	             (lastHurtByPlayerTime).
	  Death      at 0 health it dies: the death sound, a `deaths` record (the killer: the player
	             whose hit counts, or nil), and 20 ticks later (the body lies tipped and red; the
	             count goes on in a frozen chunk too) it is gone, dropping its loot (MobList
	             drops: min..max each, `chance`, `byPlayer` only when a player killed it; raw meat
	             cooked when it died burning).
	  Blasts     `explode`: Minecraft's explosion damage and push (Shared/World/Explosion) on every
	             live mob in reach, as for items and players. A creeper that blows up is gone
	             without drops or a death.
	  Despawn    every 20 ticks, every mob (frozen ones too): a monster more than 128 blocks from
	             every player goes at once; beyond 32 blocks, after 600 ticks without anything
	             happening near it (noActionTime: hurt, or a player within 32, start it over;
	             a frozen one's time counts on, as Minecraft's would tick there), one check in
	             40 (Minecraft: a tick in 800). Creatures stay, but one with no
	             player within 128 blocks for Config.Mobs.ForgetTicks goes too, to keep memory
	             bounded. Below the world (y < -64) anything goes.
	At most `maxMobs` exist: spawning more fails (`spawn` returns 0).

	What the rest of the server must act on piles up until `takeChanges`: spawned and removed
	ids, deaths (kind, position, killer), drops, hits on players (damage, knockback), arrows,
	explosions and sounds.

	Positions are in blocks: a mob's position is the bottom centre of its box.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Combat = require(Shared.Entities.Combat)
local DayCycle = require(Shared.DayCycle)
local Effects = require(Shared.Effects)
local Explosion = require(Shared.World.Explosion)
local Foods = require(Shared.Items.Foods)
local GameMode = require(Shared.GameMode)
local MobList = require(Shared.Entities.MobList)
local MobPhysics = require(Shared.Entities.MobPhysics)

local Burning = require(script.Parent.Parent.Players.Burning)
local Lightning = require(script.Parent.Parent.World.Lightning)
local MobAI = require(script.Parent.MobAI)

export type PlayerView = MobAI.PlayerView

export type Mob = {
	id: number,
	kind: MobList.Kind,
	variant: number,
	body: MobPhysics.Body,
	health: number,
	-- LivingEntity's burning and hurt cooldown (Players/Burning's player state).
	burn: Burning.PlayerState,
	-- Ticks of the red hurt flash left; ticks since it died (0: alive).
	hurtTime: number,
	deathTime: number,
	dead: boolean,
	-- Ticks lived and ticks without anything happening (Minecraft's noActionTime).
	age: number,
	idle: number,
	-- Ticks with no player within the despawn distance (creatures' forgetting).
	far: number,
	-- Its chunk didn't tick on the last tick (not active, or not loaded): it stands frozen.
	frozen: boolean,
	-- The player whose hit counts for the kill, and for how many ticks more.
	attacker: any?,
	attackerTicks: number,
	killer: any?,
	burnedDeath: boolean,
	removed: boolean,
	ai: MobAI.State,
}

export type Death = { id: number, kind: string, x: number, y: number, z: number, killer: any? }
export type Drop = { item: number, count: number, x: number, y: number, z: number }
export type Hit = {
	id: number,
	kind: string,
	key: any,
	damage: number,
	kx: number,
	ky: number,
	kz: number,
}
export type Arrow = { id: number, x: number, y: number, z: number, tx: number, ty: number, tz: number, hit: boolean }
export type Blast = { id: number, x: number, y: number, z: number, power: number }
export type Sound = { name: string, x: number, y: number, z: number }

export type Changes = {
	spawned: { number },
	removed: { number },
	deaths: { Death },
	drops: { Drop },
	hits: { Hit },
	arrows: { Arrow },
	explosions: { Blast },
	sounds: { Sound },
}

-- Where a hurt comes from (all optional): a player (kill credit, a monster's revenge), a
-- position (the knockback's and the panic's direction), its knockback strength, whether armor
-- softens it.
export type Source = {
	player: any?,
	x: number?,
	z: number?,
	knockback: number?,
	bypassArmor: boolean?,
}

-- A player's swing at a mob (`attack`): who, where their feet and eyes are, their game mode, the
-- item in hand, ticks since their last swing or change of item (Combat.strength) and their status
-- effects (Strength and Weakness: Shared/Effects.meleeDamage; nil: none).
export type Attacker = {
	key: any,
	x: number,
	y: number,
	z: number,
	eye: number,
	mode: string,
	alive: boolean,
	item: number?,
	ticks: number,
	levels: Effects.Levels?,
}

export type Context = {
	players: { PlayerView },
	-- The day time (ticks; Shared/DayCycle).
	dayTime: number,
	-- Is the cell under the open sky (server World/Skylight.open; nil: not loaded)?
	skyOpen: (x: number, y: number, z: number) -> boolean?,
	-- Does it see the sky at full light, nothing that dims it (leaves, fluids) above either
	-- (World/Skylight.clear: Minecraft's canSeeSky, for burning in daylight)?
	skyClear: (x: number, y: number, z: number) -> boolean?,
	-- Is it raining on the cell (World/WeatherServer.rainingAt: Minecraft's Level.isRainingAt)?
	-- nil: it never rains.
	rainingAt: ((x: number, y: number, z: number) -> boolean)?,
	-- Is it day at column (x, z), the weather's darkening counted (World/WeatherServer.isDayAt:
	-- Minecraft's Level.isDay, false in a thunderstorm)? nil: DayCycle.isDay of `dayTime`.
	isDay: ((x: number, z: number) -> boolean)?,
	-- Does chunk (cx, cz) tick (loaded and near a player)?
	active: (cx: number, cz: number) -> boolean,
}

export type Options = {
	maxMobs: number,
	-- Ticks a creature with no player within the despawn distance is kept.
	forgetTicks: number,
	-- 0..1 (math.random when absent).
	random: (() -> number)?,
}

export type MobWorld = {
	getBlock: MobPhysics.GetBlock,
	options: Options,
	random: () -> number,
	nextId: number,
	byId: { [number]: Mob },
	order: { Mob },
	live: number,
	tickCount: number,
	changes: Changes,

	spawn: (self: MobWorld, kind: number, x: number, y: number, z: number, variant: number?, yaw: number?) -> number,
	get: (self: MobWorld, id: number) -> Mob?,
	count: (self: MobWorld) -> number,
	each: (self: MobWorld) -> { Mob },
	remove: (self: MobWorld, id: number) -> (),
	tick: (self: MobWorld, context: Context) -> (),
	hurt: (self: MobWorld, id: number, amount: number, source: Source?) -> number,
	kill: (self: MobWorld, id: number) -> boolean,
	attack: (self: MobWorld, id: number, attacker: Attacker) -> (number?, boolean | string),
	explode: (self: MobWorld, x: number, y: number, z: number, power: number) -> number,
	lightning: (self: MobWorld, x: number, y: number, z: number, damage: number, burnTicks: number) -> number,
	near: (self: MobWorld, x: number, y: number, z: number, radius: number) -> { Mob },
	overlaps: (
		self: MobWorld,
		minX: number,
		minY: number,
		minZ: number,
		maxX: number,
		maxY: number,
		maxZ: number
	) -> boolean,
	takeChanges: (self: MobWorld) -> Changes,
	-- (MobAI's World.)
	hitPlayer: (self: MobWorld, mob: Mob, player: PlayerView, damage: number, kx: number, ky: number, kz: number) -> (),
	arrow: (
		self: MobWorld,
		mob: Mob,
		x: number,
		y: number,
		z: number,
		tx: number,
		ty: number,
		tz: number,
		hit: boolean
	) -> (),
	explodeMob: (self: MobWorld, mob: Mob, power: number) -> (),
	sound: (self: MobWorld, name: string, x: number, y: number, z: number) -> (),
}

local MobWorld = {}
MobWorld.__index = MobWorld

-- Minecraft's numbers.
MobWorld.HURT_TIME = 10
MobWorld.DEATH_TIME = 20
MobWorld.ATTACKER_TICKS = 100
MobWorld.DESPAWN_DISTANCE = 128
MobWorld.NO_DESPAWN_DISTANCE = 32
MobWorld.IDLE_DESPAWN = 600
-- (Minecraft rolls 1 in 800 a tick; this checks every DESPAWN_INTERVAL ticks.)
MobWorld.DESPAWN_INTERVAL = 20
MobWorld.DESPAWN_ODDS = 40
MobWorld.SUN_BURN_SECONDS = 8
-- isSunBurnTick at full daylight: random.nextFloat() * 30 < (1.0 - 0.4) * 2.
MobWorld.SUN_BURN_CHANCE = 1.2 / 30
MobWorld.IN_WALL_DAMAGE = 1
MobWorld.VOID_Y = -64

local SURVIVAL = GameMode.SURVIVAL
local TICKS_PER_SECOND = 20
local CHUNK = ChunkLayout.SIZE
local floor = math.floor

local function newChanges(): Changes
	return { spawned = {}, removed = {}, deaths = {}, drops = {}, hits = {}, arrows = {}, explosions = {}, sounds = {} }
end

function MobWorld.new(getBlock: MobPhysics.GetBlock, options: Options): MobWorld
	local self = {
		getBlock = getBlock,
		options = options,
		random = options.random or math.random,
		nextId = 1,
		byId = {},
		order = {},
		live = 0,
		tickCount = 0,
		changes = newChanges(),
	}
	return (setmetatable(self, MobWorld) :: any) :: MobWorld
end

--[[
	Adds a mob of kind `kind` (MobList id) standing at (x, y, z) (blocks: the bottom centre of its
	box), facing `yaw` (radians; random when nil), with colour `variant` (random by the kind's
	odds when nil). Returns its id, or 0 when the kind is unknown, the position not finite or
	`maxMobs` are alive.
]]
function MobWorld.spawn(
	self: MobWorld,
	kind: number,
	x: number,
	y: number,
	z: number,
	variant: number?,
	yaw: number?
): number
	local spec = MobList.get(kind)
	if spec == nil or self.live >= self.options.maxMobs then
		return 0
	end
	if
		not (x == x and y == y and z == z)
		or math.abs(x) == math.huge
		or math.abs(y) == math.huge
		or math.abs(z) == math.huge
	then
		return 0
	end
	local id = self.nextId
	self.nextId += 1
	local mob: Mob = {
		id = id,
		kind = spec,
		variant = variant or MobList.randomVariant(spec, self.random),
		body = MobPhysics.new(x, y, z, yaw or self.random() * math.pi * 2),
		health = spec.health,
		burn = Burning.newPlayer(),
		hurtTime = 0,
		deathTime = 0,
		dead = false,
		age = 0,
		idle = 0,
		far = 0,
		frozen = false,
		attacker = nil,
		attackerTicks = 0,
		killer = nil,
		burnedDeath = false,
		removed = false,
		ai = MobAI.new(),
	}
	self.byId[id] = mob
	table.insert(self.order, mob)
	self.live += 1
	table.insert(self.changes.spawned, id)
	return id
end

function MobWorld.get(self: MobWorld, id: number): Mob?
	return self.byId[id]
end

-- Mobs alive or dying (not yet gone).
function MobWorld.count(self: MobWorld): number
	return self.live
end

-- The mobs in id order (a new list), dying ones too.
function MobWorld.each(self: MobWorld): { Mob }
	local list = table.create(self.live)
	for _, mob in self.order do
		if not mob.removed then
			table.insert(list, mob)
		end
	end
	return list
end

local function removeMob(self: MobWorld, mob: Mob)
	if mob.removed then
		return
	end
	mob.removed = true
	self.byId[mob.id] = nil
	self.live -= 1
	table.insert(self.changes.removed, mob.id)
end

-- Removes a mob at once, without drops or a death (/kill's discard, despawning).
function MobWorld.remove(self: MobWorld, id: number)
	local mob = self.byId[id]
	if mob then
		removeMob(self, mob)
	end
end

-- The live mobs (not dying) whose feet are within `radius` blocks of (x, y, z).
function MobWorld.near(self: MobWorld, x: number, y: number, z: number, radius: number): { Mob }
	local found = {}
	local limit = radius * radius
	for _, mob in self.order do
		if not mob.removed and not mob.dead then
			local body = mob.body
			local dx, dy, dz = body.x - x, body.y - y, body.z - z
			if dx * dx + dy * dy + dz * dz <= limit then
				table.insert(found, mob)
			end
		end
	end
	return found
end

--[[
	Does any mob (dying ones too: their bodies are there until gone) have its box overlapping the
	box (minX, minY, minZ) to (maxX, maxY, maxZ)? Boxes that only touch don't overlap. Placing a
	block refuses such a box (Level.isUnobstructed: no block is placed inside a living entity).
]]
function MobWorld.overlaps(
	self: MobWorld,
	minX: number,
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number
): boolean
	for _, mob in self.order do
		if not mob.removed then
			local body, kind = mob.body, mob.kind
			local half = kind.width / 2
			if
				body.x + half > minX
				and body.x - half < maxX
				and body.y + kind.height > minY
				and body.y < maxY
				and body.z + half > minZ
				and body.z - half < maxZ
			then
				return true
			end
		end
	end
	return false
end

local function sound(self: MobWorld, name: string, mob: Mob)
	local body = mob.body
	table.insert(self.changes.sounds, { name = name, x = body.x, y = body.y + mob.kind.height / 2, z = body.z })
end

-- The mob dies (LivingEntity.die): its death sound and record; it lies DEATH_TIME ticks.
local function die(self: MobWorld, mob: Mob)
	mob.dead = true
	mob.health = 0
	mob.deathTime = 0
	mob.killer = if mob.attackerTicks > 0 then mob.attacker else nil
	mob.burnedDeath = mob.burn.fire > 0
	local body = mob.body
	sound(self, mob.kind.sounds.death, mob)
	table.insert(self.changes.deaths, {
		id = mob.id,
		kind = mob.kind.name,
		x = body.x,
		y = body.y,
		z = body.z,
		killer = mob.killer,
	})
end

-- Its loot (see the header), at its body's centre.
local function dropLoot(self: MobWorld, mob: Mob)
	local body = mob.body
	for _, drop in mob.kind.kindDrops do
		if drop.byPlayer and mob.killer == nil then
			continue
		end
		if drop.chance < 1 and self.random() >= drop.chance then
			continue
		end
		local count = drop.min + floor(self.random() * (drop.max - drop.min + 1))
		count = math.min(count, drop.max)
		if count > 0 then
			local item = if mob.burnedDeath then Foods.COOKED[drop.item] or drop.item else drop.item
			table.insert(self.changes.drops, {
				item = item,
				count = count,
				x = body.x,
				y = body.y + math.min(mob.kind.height / 2, 0.5),
				z = body.z,
			})
		end
	end
end

-- Damage that already went through the cooldown (and armor): health, flash, sound, death.
local function apply(self: MobWorld, mob: Mob, landed: number, fresh: boolean)
	if landed <= 0 or mob.dead then
		return
	end
	mob.health -= landed
	mob.idle = 0
	if fresh then
		mob.hurtTime = MobWorld.HURT_TIME
	end
	if mob.health <= 0 then
		die(self, mob)
	elseif fresh then
		sound(self, mob.kind.sounds.hurt, mob)
	end
end

--[[
	Hurts mob `id` by `amount` half hearts from `source` (see Source): LivingEntity.hurt's
	cooldown and armor, the knockback, the panic or the revenge. Returns the half hearts that
	landed (0: none: dead, gone, or under the cooldown).
]]
function MobWorld.hurt(self: MobWorld, id: number, amount: number, source: Source?): number
	local mob = self.byId[id]
	if mob == nil or mob.dead or not (amount > 0) then
		return 0
	end
	local fresh = mob.burn.cooldown <= 0
	local armor = if source and source.bypassArmor then 0 else mob.kind.armor or 0
	local landed = Burning.hurtPlayer(mob.burn, SURVIVAL, amount, armor, 0)
	if landed <= 0 and not fresh then
		return 0
	end
	local player = source and source.player
	if player ~= nil then
		mob.attacker = player
		mob.attackerTicks = MobWorld.ATTACKER_TICKS
	end
	apply(self, mob, landed, fresh)
	if fresh and source and source.x and source.z then
		local body = mob.body
		local strength = source.knockback or 0
		if strength > 0 then
			body.vx, body.vy, body.vz =
				Combat.knockback(strength, source.x, source.z, body.x, body.z, body.vx, body.vy, body.vz, body.onGround)
			body.onGround = false
		end
	end
	if not mob.dead and fresh then
		MobAI.hurt(self :: any, mob :: any, player, source and source.x, source and source.z)
	end
	return landed
end

-- Kills mob `id` at once, as Minecraft's /kill: it dies (drops, a death without a killer).
function MobWorld.kill(self: MobWorld, id: number): boolean
	local mob = self.byId[id]
	if mob == nil or mob.dead then
		return false
	end
	mob.attacker, mob.attackerTicks = nil, 0
	die(self, mob)
	return true
end

--[[
	A player hitting mob `id` (Protocol Attack; Shared/Entities/Combat): refused unless the player
	is alive and not a spectator, the mob alive, its box within the mode's reach of the eyes
	(+ Combat.SERVER_LEEWAY) and in sight (its centre, eyes or feet); then the held item's damage
	at its attack strength with a 0.4 knockback away from the player; the attacker's Strength and
	Weakness change the item's damage first (Minecraft's attack_damage modifiers, which the attack
	strength then scales). Returns the half hearts that landed (0: refused, or under the mob's hurt
	cooldown) and whether it was a strong hit (strength 0.9 or more; else a weak one), or nil and
	why it was refused.
]]
function MobWorld.attack(self: MobWorld, id: number, attacker: Attacker): (number?, boolean | string)
	local mob = self.byId[id]
	if not attacker.alive then
		return nil, "dead"
	end
	local reach = Combat.reach(attacker.mode)
	if reach <= 0 then
		return nil, "mode"
	end
	if mob == nil or mob.dead then
		return nil, "gone"
	end
	local body, kind = mob.body, mob.kind
	local half = kind.width / 2
	local ex, ey, ez = attacker.x, attacker.y + attacker.eye, attacker.z
	local distance = Combat.boxDistance(
		ex,
		ey,
		ez,
		body.x - half,
		body.y,
		body.z - half,
		body.x + half,
		body.y + kind.height,
		body.z + half
	)
	if distance > reach + Combat.SERVER_LEEWAY then
		return nil, "reach"
	end
	local getBlock = self.getBlock
	if
		not MobAI.canSee(getBlock, ex, ey, ez, body.x, body.y + kind.height / 2, body.z)
		and not MobAI.canSee(getBlock, ex, ey, ez, body.x, body.y + kind.eye, body.z)
		and not MobAI.canSee(getBlock, ex, ey, ez, body.x, body.y + 0.1, body.z)
	then
		return nil, "sight"
	end
	local base, speed = Combat.attackOf(attacker.item)
	local levels = attacker.levels
	if levels then
		base = Effects.meleeDamage(base, levels)
	end
	local strength = Combat.strength(attacker.ticks, speed)
	local landed = MobWorld.hurt(
		self,
		id,
		Combat.damage(base, strength),
		{ player = attacker.key, x = attacker.x, z = attacker.z, knockback = Combat.KNOCKBACK }
	)
	return landed, strength >= Combat.STRONG
end

--[[
	A lightning bolt at (x, y, z) (blocks: the bottom centre of the struck cell; World/Lightning):
	every live mob it reaches (Lightning.hits) catches fire for `burnTicks` (one tick more when it
	already burns: Entity.thunderHit) and takes `damage` half hearts through its cooldown and
	armor. Returns how many it reached.
]]
function MobWorld.lightning(self: MobWorld, x: number, y: number, z: number, damage: number, burnTicks: number): number
	local reached = 0
	for _, mob in MobWorld.near(self, x, y, z, Lightning.REACH + Lightning.REACH_UP + 4) do
		local body, kind = mob.body, mob.kind
		if Lightning.hits(x, y, z, body.x, body.y, body.z, kind.width, kind.height) then
			local burn = mob.burn
			burn.fire = if burn.fire > 0 then burn.fire + 1 else burnTicks
			MobWorld.hurt(self, mob.id, damage, nil)
			reached += 1
		end
	end
	return reached
end

--[[
	An explosion of `power` at (x, y, z) (blocks; World/Explosions' handler): every live mob in
	reach takes Minecraft's damage for how close and how much in the open it is, through its
	cooldown and armor, and is pushed away by it. Returns how many it killed.
]]
function MobWorld.explode(self: MobWorld, x: number, y: number, z: number, power: number): number
	local reach = Explosion.REACH * power
	local killed = 0
	for _, mob in MobWorld.near(self, x, y, z, reach) do
		local body, kind = mob.body, mob.kind
		local half = kind.width / 2
		local seen = Explosion.seenPercent(
			self.getBlock,
			x,
			y,
			z,
			body.x - half,
			body.y,
			body.z - half,
			body.x + half,
			body.y + kind.height,
			body.z + half
		)
		local damage, px, py, pz = Explosion.hit(x, y, z, power, body.x, body.y, body.z, body.y + kind.eye, seen)
		if damage then
			MobWorld.hurt(self, mob.id, damage, { x = x, z = z })
			body.vx += px
			body.vy += py
			body.vz += pz
			body.onGround = false
			if mob.dead then
				killed += 1
			end
		end
	end
	return killed
end

--[[ MobAI's world: what the AI does to the rest of the game ]]

function MobWorld.hitPlayer(
	self: MobWorld,
	mob: Mob,
	player: PlayerView,
	damage: number,
	kx: number,
	ky: number,
	kz: number
)
	table.insert(self.changes.hits, {
		id = mob.id,
		kind = mob.kind.name,
		key = player.key,
		damage = damage,
		kx = kx,
		ky = ky,
		kz = kz,
	})
end

function MobWorld.arrow(
	self: MobWorld,
	mob: Mob,
	x: number,
	y: number,
	z: number,
	tx: number,
	ty: number,
	tz: number,
	hit: boolean
)
	table.insert(self.changes.arrows, { id = mob.id, x = x, y = y, z = z, tx = tx, ty = ty, tz = tz, hit = hit })
end

-- A creeper going off: the blast (for the next explosions step) and the creeper gone.
function MobWorld.explodeMob(self: MobWorld, mob: Mob, power: number)
	local body = mob.body
	table.insert(self.changes.explosions, { id = mob.id, x = body.x, y = body.y, z = body.z, power = power })
	removeMob(self, mob)
end

function MobWorld.sound(self: MobWorld, name: string, x: number, y: number, z: number)
	table.insert(self.changes.sounds, { name = name, x = x, y = y, z = z })
end

--[[ Ticking ]]

local function playersNearest(players: { PlayerView }, x: number, y: number, z: number): number
	local best = math.huge
	for _, player in players do
		local dx, dy, dz = player.x - x, player.y - y, player.z - z
		local d = dx * dx + dy * dy + dz * dz
		if d < best then
			best = d
		end
	end
	return math.sqrt(best)
end

-- Despawning (see the header), every DESPAWN_INTERVAL ticks for every mob. With nobody in the
-- world nothing changes (Mob.checkDespawn finds no nearest player).
local function despawn(self: MobWorld, context: Context)
	if #context.players == 0 then
		return
	end
	local interval = MobWorld.DESPAWN_INTERVAL
	for _, mob in self.order do
		if mob.removed then
			continue
		end
		local body = mob.body
		if body.y < MobWorld.VOID_Y then
			removeMob(self, mob)
			continue
		end
		local distance = playersNearest(context.players, body.x, body.y, body.z)
		if mob.kind.hostile then
			if distance > MobWorld.DESPAWN_DISTANCE then
				removeMob(self, mob)
			elseif distance < MobWorld.NO_DESPAWN_DISTANCE then
				mob.idle = 0
			else
				-- (A frozen monster's idle time counts here, as its chunk doesn't tick: Minecraft's
				-- simulation distance reaches past these 128 blocks, so its monsters this far out
				-- tick and idle away. Otherwise those left 56-128 blocks behind would stay for good.)
				if mob.frozen then
					mob.idle += interval
				end
				if mob.idle > MobWorld.IDLE_DESPAWN and floor(self.random() * MobWorld.DESPAWN_ODDS) == 0 then
					removeMob(self, mob)
				end
			end
		elseif distance > MobWorld.DESPAWN_DISTANCE then
			mob.far += interval
			if mob.far >= self.options.forgetTicks then
				removeMob(self, mob)
			end
		else
			mob.far = 0
		end
	end
end

-- One tick of a live mob (see the header).
local function tickMob(self: MobWorld, context: Context, mob: Mob)
	local kind, body = mob.kind, mob.body
	local ai = self :: any
	local forward, jump = MobAI.step(ai, context, mob :: any)
	if mob.removed then
		return
	end
	local landed = MobPhysics.tick(body, kind, forward, jump, self.getBlock)
	if landed > MobPhysics.SAFE_FALL and kind.fallDamage ~= false then
		MobWorld.hurt(self, mob.id, math.ceil(landed - MobPhysics.SAFE_FALL), { bypassArmor = true })
	end
	if mob.dead then
		return
	end

	-- Daylight (Mob.isSunBurnTick: not in rain either, isInWaterRainOrBubble's rain at the feet
	-- or the top of the box), then lava, fire and burning (Players/Burning).
	local x, z = floor(body.x), floor(body.z)
	local isDay, rainingAt = context.isDay, context.rainingAt
	if
		kind.burnsInDaylight
		and body.waterDepth <= 0
		and mob.burn.fire <= 0
		and DayCycle.isDay(context.dayTime)
		and (isDay == nil or isDay(x, z))
		and context.skyClear(x, floor(body.y + kind.eye), z) == true
		and self.random() < MobWorld.SUN_BURN_CHANCE
		and not (rainingAt ~= nil and (rainingAt(x, floor(body.y), z) or rainingAt(x, floor(body.y + kind.height), z)))
	then
		mob.burn.fire = MobWorld.SUN_BURN_SECONDS * TICKS_PER_SECOND
	end
	local touching = Burning.touchingAt(self.getBlock, body.x, body.y, body.z, kind.width, kind.height)
	local fresh = mob.burn.cooldown <= 1
	local damage = Burning.tickPlayer(mob.burn, SURVIVAL, touching, kind.armor or 0, 0)
	if damage > 0 then
		apply(self, mob, damage, fresh)
		if not mob.dead and fresh then
			MobAI.hurt(ai, mob :: any, nil, nil, nil)
		end
	end
	if mob.dead then
		return
	end

	-- Eyes in a wall.
	local eye = self.getBlock(x, floor(body.y + kind.eye), z)
	if eye and Blocks.isOpaque(eye) and Blocks.isSolid(eye) then
		MobWorld.hurt(self, mob.id, MobWorld.IN_WALL_DAMAGE, { bypassArmor = true })
	end
end

--[[
	One server tick (see the header) with the players and the world's state in `context`.
]]
function MobWorld.tick(self: MobWorld, context: Context)
	self.tickCount += 1
	local getBlock = self.getBlock
	-- (Nothing spawns during the tick; mobs that go are only flagged until the end of it.)
	for _, mob in self.order do
		if mob.removed then
			continue
		end
		local body = mob.body
		local cx, cz = floor(body.x) // CHUNK, floor(body.z) // CHUNK
		local frozen = not context.active(cx, cz) or getBlock(floor(body.x), floor(body.y), floor(body.z)) == nil
		mob.frozen = frozen
		if frozen and not mob.dead then
			continue
		end
		if not frozen then
			mob.age += 1
			mob.idle += 1
			if mob.attackerTicks > 0 then
				mob.attackerTicks -= 1
			end
		end
		if mob.hurtTime > 0 then
			mob.hurtTime -= 1
		end
		if mob.dead then
			-- The body falls where it is, then goes with its loot. (Dying goes on in a chunk that
			-- doesn't tick too, the body still: a frozen mob killed by /kill is gone 20 ticks
			-- later, not left dying for good.)
			if not frozen then
				MobPhysics.tick(body, mob.kind, 0, false, getBlock)
			end
			mob.deathTime += 1
			if mob.deathTime >= MobWorld.DEATH_TIME then
				dropLoot(self, mob)
				removeMob(self, mob)
			end
			continue
		end
		tickMob(self, context, mob)
	end
	if self.tickCount % MobWorld.DESPAWN_INTERVAL == 0 then
		despawn(self, context)
	end
	-- Drop gone mobs from the id order.
	local kept = table.create(self.live)
	for _, mob in self.order do
		if not mob.removed then
			table.insert(kept, mob)
		end
	end
	self.order = kept
end

-- The changes since the last call (see Changes).
function MobWorld.takeChanges(self: MobWorld): Changes
	local changes = self.changes
	self.changes = newChanges()
	return changes
end

return MobWorld
