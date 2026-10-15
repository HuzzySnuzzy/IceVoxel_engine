--!strict
--!native
--[[
	Mobs on the server: Minecraft 1.20.1's LivingEntity / Mob rules for the kinds of
	Shared/Entities/MobList, without any Roblox APIs so the tests run them (Mobs/Mobs is the Roblox
	side: players, replication, the network, spawning).

	Each tick (`tick`, 20 a second), in id order, for every mob whose chunk ticks (`context.active`:
	loaded and within Config.Server.SimulationRadius chunks of a player, World/Simulation; the rest
	are frozen where they are, as Minecraft's entities in chunks that don't tick):
	  AI         Mobs/MobAI: wander, panic, hunt, hit; it steers and jumps. Zombies also hear
	             noises, hunt through blood moons, walk away when sent, and break blocks
	             (`damageBlock`, below).
	  Crowds     zombies keep a little room between them (Mobs/MobCrowd: hashed once a tick from
	             where they stood at its start, each pushed between its AI and its physics).
	  Physics    Shared/Entities/MobPhysics: gravity, friction, fluids, collision, stepping and
	             jumping, climbing, slow falling.
	  Falls      landing after more than 3 blocks hurts ceil(distance - 3), through armor
	             (LivingEntity.causeFallDamage; not chickens).
	  Fire       Players/Burning.tickPlayer with the kind's armor, as for players: lava hurts 4 every
	             10 ticks and sets it burning 15 s, fire and campfires hurt, burning costs 1 every
	             20 ticks, water and rain put it out (`context.rainingAt`, looked up only while it
	             burns). (A mob catches fire after 20 ticks in a fire block,
	             as a player does; Minecraft's mobs at once.) A `fireImmune` kind (the
	             firefighter zombie) never burns: fire, lava and campfires don't hurt it and
	             lightning doesn't light it. A kind with `burnsInDaylight`
	             burns in daylight (Mob.isSunBurnTick; the apocalypse's zombies don't): by day
	             (Level.isDay with the
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
	             it came from (Combat.knockback; less its kind's `knockbackResist`, as blasts'
	             pushes are) and makes it panic (creatures) or hunt the player (monsters,
	             MobAI.hurt). A player's hit counts for the kill for 100 ticks
	             (lastHurtByPlayerTime).
	  Death      at 0 health it dies: the death sound, a `deaths` record (the killer: the player
	             whose hit counts, or nil), and 20 ticks later (the body lies tipped and red; the
	             count goes on in a frozen chunk too) it is gone, dropping its loot (MobList
	             drops: min..max each, `chance`, `byPlayer` only when a player killed it; raw meat
	             cooked when it died burning).
	  Blasts     `explode`: Minecraft's explosion damage and push (Shared/World/Explosion) on every
	             live mob in reach, as for items and players.
	  Despawn    every 20 ticks, every mob (frozen ones too): a monster more than 128 blocks from
	             every player goes at once; beyond 32 blocks, after 600 ticks without anything
	             happening near it (noActionTime: hurt, or a player within 32, start it over;
	             a frozen one's time counts on, as Minecraft's would tick there), one check in
	             40 (Minecraft: a tick in 800), unless it is `persistent` (a zombie hunting
	             through a blood moon). A zombie sent away (MobAI `leave`) goes once it is
	             Apocalypse.Zombies.Leave.Distance (24) blocks from every player and no player
	             within 64 blocks can see it (from their eyes to its eyes), however near the 32.
	             Creatures stay, but one with no player within 128 blocks for
	             Config.Mobs.ForgetTicks goes too, to keep memory bounded. Below the world
	             (y < -64) anything goes.
	  Blocks     a zombie breaking a block puts its `breakPower` a tick on the block's damage
	             (`damageBlock`: one tally a cell, a door's on its lower half, so zombies on one
	             door share it), which a block left alone for Apocalypse.Breaking.Decay ticks
	             loses; at the block's Blocks.zombieBreak it gives way: a `breaks` record (once),
	             which Mobs/Mobs acts on (it removes the block and drops nothing). The tally is
	             the block's own: when the cell's block goes or becomes another block (a player
	             breaks a hammered plank and puts a new one, or a barricade), it starts over; the
	             same block's variants keep it (a door opened or shut, a fence's arms).
	At most `maxMobs` exist: spawning more fails (`spawn` returns 0).

	What the rest of the server must act on piles up until `takeChanges`: spawned and removed
	ids, deaths (kind, position, killer), drops, hits on players (damage, knockback), sounds,
	zombies' hits on blocks (the thud, every Breaking.HitInterval ticks), blocks broken and
	noises made (a screamer's shriek, for Apocalypse/NoiseBus).

	Positions are in blocks: a mob's position is the bottom centre of its box.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Combat = require(Shared.Entities.Combat)
local Config = require(Shared.Config)
local Coords = require(Shared.World.Coords)
local DayCycle = require(Shared.DayCycle)
local Effects = require(Shared.Effects)
local Explosion = require(Shared.World.Explosion)
local Foods = require(Shared.Items.Foods)
local GameMode = require(Shared.GameMode)
local MobList = require(Shared.Entities.MobList)
local MobPhysics = require(Shared.Entities.MobPhysics)
local Melee = require(Shared.Weapons.Melee)

local Burning = require(script.Parent.Parent.Players.Burning)
local Lightning = require(script.Parent.Parent.World.Lightning)
local MobAI = require(script.Parent.MobAI)
local MobCrowd = require(script.Parent.MobCrowd)

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
	-- (Zombies.) Hunting through a blood moon: it never idles away (see the header).
	persistent: boolean,
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
export type Sound = { name: string, x: number, y: number, z: number }
-- A zombie's hit on a block (mob id, the cell, its block) and a block a zombie broke.
export type BlockHit = { id: number, x: number, y: number, z: number, block: number }
export type Break = { x: number, y: number, z: number, block: number }
export type Noise = MobAI.Noise

export type Changes = {
	spawned: { number },
	removed: { number },
	deaths: { Death },
	drops: { Drop },
	hits: { Hit },
	sounds: { Sound },
	blockHits: { BlockHit },
	breaks: { Break },
	noises: { Noise },
}

-- Where a hurt comes from (all optional): a player (kill credit, a monster's revenge), a
-- position (the knockback's and the panic's direction), its knockback strength, whether armor
-- softens it, and whether it keeps its own immunity (`ownImmunity`: a magic projectile, which
-- strikes a mob once, Shared/Magic/Projectiles' `struck`, as Terraria's projectiles keep their
-- own per-NPC immunity: the 10 tick hurt cooldown doesn't refuse it, it starts one as any hurt).
export type Source = {
	player: any?,
	x: number?,
	z: number?,
	knockback: number?,
	bypassArmor: boolean?,
	ownImmunity: boolean?,
}

-- A player's swing at a mob (`attack`): who, where their feet and eyes are, their game mode, the
-- item in hand, ticks since their last swing or change of item (Combat.strength), their status
-- effects (Strength and Weakness: Shared/Effects.meleeDamage; nil: none) and whether it is the
-- melee rework's heavy attack (Shared/Weapons/Melee; nil: a light one).
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
	heavy: boolean?,
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
	-- (Zombies: MobAI's.) This tick's noises, whether it is night, whether zombies break blocks.
	noises: { Noise }?,
	night: boolean?,
	breaking: boolean?,
}

export type Options = {
	maxMobs: number,
	-- Ticks a creature with no player within the despawn distance is kept.
	forgetTicks: number,
	-- 0..1 (math.random when absent).
	random: (() -> number)?,
}

-- A cell's damage (see the header): so far, the tick last hit, the cell (a door's lower half) and
-- the block's family (`damageFamily`).
export type DamageEntry = { progress: number, last: number, x: number, y: number, z: number, family: number }

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
	-- Mobs went since the id order was last rebuilt.
	dirty: boolean,
	-- Zombies' damage on blocks (by Coords.posKey of the cell, a door's lower half), and the cells
	-- reported broken since the last takeChanges.
	damage: { [number]: DamageEntry },
	broken: { [number]: boolean },
	crowd: MobCrowd.Crowd,

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
	sound: (self: MobWorld, name: string, x: number, y: number, z: number) -> (),
	damageBlock: (self: MobWorld, x: number, y: number, z: number, power: number) -> (number, number),
	blockDamage: (self: MobWorld, x: number, y: number, z: number) -> number,
	blockChanged: (self: MobWorld, x: number, y: number, z: number, old: number, new: number) -> (),
	blockHit: (self: MobWorld, mob: Mob, x: number, y: number, z: number, block: number) -> (),
	breakBlock: (self: MobWorld, mob: Mob, x: number, y: number, z: number, block: number) -> (),
	noise: (self: MobWorld, x: number, y: number, z: number, radius: number) -> (),
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
-- A zombie sent away stays while a player within this many blocks can see it.
MobWorld.LEAVE_SIGHT = 64

local SURVIVAL = GameMode.SURVIVAL
local TICKS_PER_SECOND = 20
local CHUNK = ChunkLayout.SIZE
local floor = math.floor
local posKey = Coords.posKey
local Apocalypse = Config.Apocalypse
-- (Fire Resistance's rules, for a `fireImmune` kind: no fire hurt lands, nothing sets it alight.)
local FIRE_IMMUNE: Effects.FireRules = table.freeze({ immune = true, factor = 0, bonus = 0, ignites = false })

local function newChanges(): Changes
	return {
		spawned = {},
		removed = {},
		deaths = {},
		drops = {},
		hits = {},
		sounds = {},
		blockHits = {},
		breaks = {},
		noises = {},
	}
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
		dirty = false,
		damage = {},
		broken = {},
		crowd = MobCrowd.new(),
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
		persistent = false,
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
	self.dirty = true
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
	if source and source.ownImmunity then
		-- (Its own immunity: see Source.)
		mob.burn.cooldown = 0
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
		local strength = (source.knockback or 0) * (1 - (mob.kind.knockbackResist or 0))
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
	The melee rework (Shared/Weapons/Melee): a `heavy` attack's base damage is Melee.heavyDamage
	(still scaled by the attack strength) and its knockback Melee.knockback(true); a zombie that
	is not aware of anyone (no target, no hunt), hit from behind (its facing against the direction
	to the attacker: Melee.finisher's `behindDot`) with a finisher weapon, dies outright (its
	health and one more, through its armor), when its kind's health allows.
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
	local heavy = attacker.heavy == true
	if heavy then
		base = Melee.heavyDamage(attacker.item, base)
	end
	local levels = attacker.levels
	if levels then
		base = Effects.meleeDamage(base, levels)
	end
	local strength = Combat.strength(attacker.ticks, speed)
	local knockback = Melee.knockback(heavy)
	-- (A finisher: an unaware zombie from behind. Facing (sin yaw, cos yaw) against the way to the
	-- attacker.)
	if MobList.isZombie(kind) then
		local ai = mob.ai
		local aware = ai.target ~= nil or ai.hunt ~= nil
		local dx, dz = attacker.x - body.x, attacker.z - body.z
		local length = math.sqrt(dx * dx + dz * dz)
		local behind = if length > 1e-6 then (math.sin(body.yaw) * dx + math.cos(body.yaw) * dz) / length else 1
		if Melee.finisher(attacker.item, aware, behind, kind.health) then
			local landed = MobWorld.hurt(self, id, mob.health + 1, {
				player = attacker.key,
				x = attacker.x,
				z = attacker.z,
				knockback = knockback,
				bypassArmor = true,
			})
			return landed, strength >= Combat.STRONG
		end
	end
	local landed = MobWorld.hurt(
		self,
		id,
		Combat.damage(base, strength),
		{ player = attacker.key, x = attacker.x, z = attacker.z, knockback = knockback }
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
			if not kind.fireImmune then
				burn.fire = if burn.fire > 0 then burn.fire + 1 else burnTicks
			end
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
			local share = 1 - (kind.knockbackResist or 0)
			body.vx += px * share
			body.vy += py * share
			body.vz += pz * share
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

function MobWorld.sound(self: MobWorld, name: string, x: number, y: number, z: number)
	table.insert(self.changes.sounds, { name = name, x = x, y = y, z = z })
end

-- The cell a block's damage is kept on (its key and y): a door's upper half keeps it on its lower
-- half.
local function damageKey(self: MobWorld, x: number, y: number, z: number, block: number?): (number, number)
	if block ~= nil and Blocks.isDoor(block) then
		local lower = Blocks.plantBottom(block)
		if lower ~= nil and self.getBlock(x, y - 1, z) == lower then
			return posKey(x, y - 1, z), y - 1
		end
	end
	return posKey(x, y, z), y
end

-- Which block a damaged cell holds, as far as its damage goes: the variants of one block (a door's
-- halves and states, a fence's arms, a cave twin and its twin) are one.
local families: { [number]: number } = {}
local function damageFamily(block: number): number
	local family = families[block]
	if family == nil then
		family = Blocks.variants(Blocks.surfaceForm(block))[1]
		families[block] = family
	end
	return family
end

--[[
	A zombie's `power` more damage on the block at (x, y, z) (see the header): its damage so far
	and what breaks it (Blocks.zombieBreak; 0: it never breaks).
]]
function MobWorld.damageBlock(self: MobWorld, x: number, y: number, z: number, power: number): (number, number)
	local block = self.getBlock(x, y, z)
	local needed = if block then Blocks.zombieBreak(block) else 0
	if needed <= 0 then
		return 0, 0
	end
	local key, cellY = damageKey(self, x, y, z, block)
	local family = damageFamily(block :: number)
	local entry = self.damage[key]
	if entry == nil or self.tickCount - entry.last > Apocalypse.Breaking.Decay or entry.family ~= family then
		entry = { progress = 0, last = self.tickCount, x = x, y = cellY, z = z, family = family }
		self.damage[key] = entry
	end
	entry.progress += power
	entry.last = self.tickCount
	return entry.progress, needed
end

-- The damage on the block at (x, y, z) so far (0: none, or it decayed).
function MobWorld.blockDamage(self: MobWorld, x: number, y: number, z: number): number
	local block = self.getBlock(x, y, z)
	local entry = self.damage[(damageKey(self, x, y, z, block))]
	if
		entry == nil
		or block == nil
		or self.tickCount - entry.last > Apocalypse.Breaking.Decay
		or entry.family ~= damageFamily(block)
	then
		return 0
	end
	return entry.progress
end

--[[
	Block (x, y, z) changed from `old` to `new` (WorldServer.onChanged, through Mobs/Mobs): its
	damage starts over unless the new block is a variant of the old (see the header). The tick's
	own check (MobWorld.tick) can't tell a block broken and a new one put in between two ticks.
]]
function MobWorld.blockChanged(self: MobWorld, x: number, y: number, z: number, old: number, new: number)
	if next(self.damage) == nil or damageFamily(old) == damageFamily(new) then
		return
	end
	self.damage[posKey(x, y, z)] = nil
	if Blocks.isDoor(old) and Blocks.plantBottom(old) ~= nil then
		-- (A door's upper half: its damage is kept on its lower half.)
		self.damage[posKey(x, y - 1, z)] = nil
	end
end

function MobWorld.blockHit(self: MobWorld, mob: Mob, x: number, y: number, z: number, block: number)
	table.insert(self.changes.blockHits, { id = mob.id, x = x, y = y, z = z, block = block })
end

-- The block at (x, y, z) gave way (reported once, however many zombies were at it).
function MobWorld.breakBlock(self: MobWorld, _mob: Mob, x: number, y: number, z: number, block: number)
	local key = (damageKey(self, x, y, z, block))
	if self.broken[key] then
		return
	end
	self.broken[key] = true
	self.damage[key] = nil
	table.insert(self.changes.breaks, { x = x, y = y, z = z, block = block })
end

function MobWorld.noise(self: MobWorld, x: number, y: number, z: number, radius: number)
	table.insert(self.changes.noises, { x = x, y = y, z = z, radius = radius })
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

-- May a zombie sent away go (see the header): no player within LEAVE_SIGHT can see it?
local function unseen(self: MobWorld, players: { PlayerView }, mob: Mob): boolean
	local body, kind = mob.body, mob.kind
	local ex, ey, ez = body.x, body.y + kind.eye, body.z
	local limit = MobWorld.LEAVE_SIGHT * MobWorld.LEAVE_SIGHT
	for _, player in players do
		local px, py, pz = player.x, player.y + player.eye, player.z
		local dx, dy, dz = px - ex, py - ey, pz - ez
		if dx * dx + dy * dy + dz * dz <= limit and MobAI.canSee(self.getBlock, px, py, pz, ex, ey, ez) then
			return false
		end
	end
	return true
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
			if
				distance > MobWorld.DESPAWN_DISTANCE
				-- (Sent away, far enough and out of sight.)
				or (
					mob.ai.leave > 0
					and not mob.dead
					and distance >= Apocalypse.Zombies.Leave.Distance
					and unseen(self, context.players, mob)
				)
			then
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
				if
					not mob.persistent
					and mob.idle > MobWorld.IDLE_DESPAWN
					and floor(self.random() * MobWorld.DESPAWN_ODDS) == 0
				then
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
	if kind.zombie then
		MobCrowd.push(self.crowd, mob :: any)
	end
	if
		not kind.burnsInDaylight
		and mob.burn.fire <= 0
		and mob.burn.cooldown <= 0
		and MobPhysics.rest(body, kind, forward, jump, self.getBlock)
	then
		-- (Standing still on a full block in empty cells: nothing moves, burns or smothers it;
		-- the tick's end state set without the tick. Burning.tickPlayer would only clear `heat`.)
		mob.burn.heat = 0
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
		and not kind.fireImmune
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
	-- (No fire, lava or water in quiet cells: MobPhysics' `quiet`.)
	local touching = if body.quiet
		then 0
		else Burning.touchingAt(self.getBlock, body.x, body.y, body.z, kind.width, kind.height)
	if mob.burn.fire > 0 and rainingAt ~= nil and Burning.inRain(rainingAt, body.x, body.y, body.z, kind.height) then
		-- (Rain puts it out: a bolt's fire, or the day's, once the storm reaches it.)
		touching = bit32.bor(touching, Burning.RAIN)
	end
	local fresh = mob.burn.cooldown <= 1
	local damage = Burning.tickPlayer(
		mob.burn,
		SURVIVAL,
		touching,
		kind.armor or 0,
		0,
		if kind.fireImmune then FIRE_IMMUNE else nil
	)
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
	-- (A damaged cell whose block went or became another starts over: see the header.)
	for key, entry in self.damage do
		local block = getBlock(entry.x, entry.y, entry.z)
		if block == nil or damageFamily(block) ~= entry.family then
			self.damage[key] = nil
		end
	end
	-- (Where the zombies stand at the start of the tick: Mobs/MobCrowd.)
	MobCrowd.build(self.crowd, self.order :: any, Apocalypse.Zombies.Separation)
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
		-- (Damage on blocks left alone decays.)
		local decay = Apocalypse.Breaking.Decay
		for key, entry in self.damage do
			if self.tickCount - entry.last > decay then
				self.damage[key] = nil
			end
		end
	end
	-- Drop gone mobs from the id order (only when some went).
	if self.dirty then
		self.dirty = false
		local kept = table.create(self.live)
		for _, mob in self.order do
			if not mob.removed then
				table.insert(kept, mob)
			end
		end
		self.order = kept
	end
end

-- The changes since the last call (see Changes).
function MobWorld.takeChanges(self: MobWorld): Changes
	local changes = self.changes
	self.changes = newChanges()
	table.clear(self.broken)
	return changes
end

return MobWorld
