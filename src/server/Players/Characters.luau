--!strict
--[[
	Server side of the cosmetic characters.

	Players move as a Minecraft-style hull on their own client (Player/MovementController); the
	Roblox character only shows where the hull is. Where a player is, the server asks
	Players/PlayerPositions (feet in blocks, doubles), never the character. So on the server:
	  * every character part goes into a collision group that collides with nothing (Rig), so Roblox
	    physics never pushes characters around; a dead character's parts go back to Default so the
	    body falls onto the terrain (reading positions from characters; see `park` otherwise),
	  * `teleport` / `teleportFeet` / `teleportTo` put a player's feet somewhere through
	    PlayerPositions.teleport, which tells their client the exact feet position (so the hull
	    moves with it) and fires PlayerPositions.teleported,
	  * with the server's own positions (Config.Players.ServerPositions) a new character is
	    `park`ed (Players/Spawning, first thing): its life counted (the IceVoxelLife attribute,
	    matched by the Teleport that places it), its root anchored (server-owned: each client
	    places every character locally from the hull or relayed poses, and that never
	    replicates) and the whole character put at Config.Players.ParkPosition for good: the fake
	    coordinates everyone can read. Joints don't break at death and the body doesn't fall (the
	    clients play Minecraft's death tilt); `Died` is made sure of on the server (an anchored
	    root),
	  * landings reported by the client turn into fall damage (Config.Movement.FallDamage), like
	    Minecraft: ceil(distance - 3) half hearts of 20, scaled to the Humanoid's MaxHealth
	    (GameModeRules.fallDamage). Survival and adventure players only: creative and spectator
	    players never take fall damage (they may fly).
	  * creative and spectator players can't be hurt (Minecraft's Abilities.invulnerable,
	    GameModeRules.invulnerable): while in those modes their character holds an invisible
	    ForceField (INVULNERABLE), which Humanoid:TakeDamage and explosions respect. (Setting
	    Health directly still hurts, as Minecraft's /kill and the void do.)
	  * players in a wall suffocate (GameModeRules.inWall, at their feet, against the server's
	    blocks): IN_WALL_DAMAGE half hearts every
	    IN_WALL_INTERVAL, until they get out or die, so one who leaves spectator inside rock
	    isn't walled in for good (Minecraft's in-wall damage).
	  * lava hurts and burns (Players/Burning, 20 ticks a second on the standing box at the feet,
	    against the server's loaded blocks): 4 half hearts every 10 ticks in it, softened by the
	    armor worn (Players/Inventories), then burning for 15 s after (1 every 20 ticks, through
	    armor) unless water puts it out. Each lava hurt that lands sizzles (entity.generic.burn,
	    Entity.lavaHurt) and water putting the fire out hisses (entity.generic.extinguish_fire),
	    at the feet, each at its Shared/Sounds volume and pitch (once Shared/Sounds has them).
	    Creative and spectator players never burn. A burning character carries the attribute
	    ON_FIRE (true) for clients to show it; a new character starts out of the fire.
	  * explosions (`explosion`, World/Explosions' handler; Shared/World/Explosion): a living
	    player within 2 x power of a blast takes Minecraft's damage for how close and how much
	    in the open they are, through the hurt cooldown lava and burning use and softened by
	    armor (Players/Burning.hurtPlayer; never in creative or spectator), and every player
	    within Config.Explosions.EffectDistance (the Nuke's: Config.Nuke.EffectDistance) gets an
	    Explosion message: the client draws the
	    blast and adds the knockback to its movement (none for spectators, as Minecraft leaves
	    them out of the explosion packet's knockback; the client leaves out creative flight),
	    which the server's speed checks are told to allow (PlayerPositions.grant: 12 x the push,
	    which ground and air drag keep under 11 x).
	  * lightning (`lightning`, World/WeatherServer's strike handler; World/Lightning): a living
	    player (not a spectator) whose box meets a bolt's reach catches fire for 8 s and takes
	    5 half hearts like any other hurt (Minecraft's Entity.thunderHit). Rain puts burning
	    out (`setRain`: the weather is asked only while a player burns, Players/Burning), and
	    a bolt strikes only where it rains, so its fire goes out on the next tick, as
	    Minecraft's does: a strike costs its 5 half hearts, not 13.
	  * status effects (Players/Effects, ticked here with lava and burning, 20 a second): the
	    fluids' effects first (oil's Slowness and Oil Coated, fuel's Nausea, Poison and Fuel Soaked,
	    water washing them off; the eyes are looked at only when a fluid gives effects there),
	    their fire rules for burning (Fire Resistance, the burn factor and bonus, catching at
	    once), then their own tick: Poison, Wither and Instant Damage hurt through the same hurt
	    cooldown without armor (magic), Regeneration and Instant Health heal. Every hurt here
	    (lava, fire, burning, the effects, blasts, falls, walls, mobs' hits: `hurt`) is cut by
	    Resistance (Effects.incomingDamage, after armor, as getDamageAfterMagicAbsorb), Jump Boost
	    takes its levels off a fall's distance, and a blast that reaches a player whose effects
	    ignite (Fuel Soaked) sets them burning (IN_FIRE_SECONDS, times their burn factor).
	  * sounds (Audio/Sounds), heard by everyone near: losing health (entity.player.hurt, at most
	    every half second like Minecraft's invulnerability time) and dying (entity.player.death),
	    from any cause; and a hurting landing's small or big fall with the fall sound of the block
	    landed on, for everyone but the player, whose client played them already
	    (LivingEntity.causeFallDamage). Spectators make none (GameModeRules.makesSounds).
	  * a saved player's health comes back without a hurt sound (`restoreHealth`, World/WorldSave).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Rig = require(Shared.Movement.Rig)
local Explosion = require(Shared.World.Explosion)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Lightning = require(script.Parent.Parent.World.Lightning)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local SharedSounds = require(Shared.Sounds)
local PlayerPositions = require(script.Parent.PlayerPositions)
local Burning = require(script.Parent.Burning)
local EffectRules = require(script.Parent.EffectRules)
local Effects = require(script.Parent.Effects)
local GameModeRules = require(script.Parent.GameModeRules)
local Inventories = require(script.Parent.Inventories)

-- Minecraft players have 20 health points (half hearts).
local MINECRAFT_HEALTH = GameModeRules.MINECRAFT_HEALTH
-- The invisible ForceField of characters whose game mode can't be hurt.
local INVULNERABLE = "IceVoxelInvulnerable"
-- Landings a player may report per second (a real one needs a fall first).
local MAX_LANDINGS_PER_SECOND = 4
-- Seconds between hurt sounds of one character (Minecraft's 10 ticks of invulnerability).
local HURT_SOUND_INTERVAL = 0.5
-- Blocks of movement a knockback of 1 block a tick may cause (ground drag 0.546 and air drag 0.91
-- keep the travel under 11 x the push): what the speed checks are told to allow.
local KNOCKBACK_TRAVEL = 12
-- Lava and burning run at Minecraft's 20 ticks a second, catching up at most a few per frame.
local BURN_TICK = 1 / 20
local MAX_BURN_TICKS_PER_FRAME = 4
-- The body lava and water are looked for in: the standing box (the server can't tell the pose).
local BODY = PlayerPhysics.dimensions("standing")
-- Minecraft's Entity.playEntityOnFireExtinguishedSound and Entity.lavaHurt's sizzle (nil until
-- Shared/Sounds has them).
local EXTINGUISH = SharedSounds.find("entity.generic.extinguish_fire")
local BURN = SharedSounds.find("entity.generic.burn")

local Characters = {}

-- The character attribute that says a player is burning (true while burning, else absent).
Characters.ON_FIRE = "IceVoxelOnFire"

-- Each player's burning (Players/Burning), started over with every character.
local burning: { [Player]: Burning.PlayerState } = {}
-- The weather's rain (World/WeatherServer.rainingAt, `setRain`): rain puts burning players out.
local rainingAt: ((x: number, y: number, z: number) -> boolean)? = nil
-- Players whose next health change is a restore, not a hurt (no hurt sound).
local quietHealth: { [Player]: boolean } = {}

local function setGroup(part: Instance, group: string)
	if part:IsA("BasePart") then
		part.CollisionGroup = group
	end
end

--[[
	Puts `player`'s feet at (x, y, z) (blocks, doubles), facing `yaw` when given (radians, as
	CFrame.Angles(0, yaw, 0)), else as they face: PlayerPositions.teleport (their client is told,
	the hull follows, `teleported` fires).
]]
function Characters.teleportTo(player: Player, x: number, y: number, z: number, yaw: number?)
	PlayerPositions.teleport(player, x, y, z, yaw)
end

--[[
	Moves a character so its feet are at `feet` (blocks), keeping its rotation, and tells its
	client where the hull now is. (A character that is no player's is left alone.)
]]
function Characters.teleportFeet(character: Model, feet: Vector3)
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		PlayerPositions.teleport(player, feet.X, feet.Y, feet.Z)
	end
end

--[[
	Moves a character so its feet stand centred on block (x, y, z) (y = the block the feet are in),
	keeping its rotation, and tells its client where the hull now is.
]]
function Characters.teleport(character: Model, x: number, y: number, z: number)
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		PlayerPositions.teleport(player, x + 0.5, y, z + 0.5)
	end
end

--[[
	A new character, with the server's own positions (see the header; Players/Spawning calls it
	before placing it): its life, its root anchored, no joints broken at death, parked at
	Config.Players.ParkPosition. Does nothing while positions are read from characters.
]]
function Characters.park(player: Player, character: Model)
	if not PlayerPositions.networked() then
		return
	end
	character:SetAttribute(Rig.LIFE, PlayerPositions.spawned(player, character))
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.BreakJointsOnDeath = false
	end
	local park = Config.Players.ParkPosition
	character:PivotTo(CFrame.new(park[1], park[2], park[3]))
end

-- Gives the character an invisible ForceField while the player's game mode can't be hurt
-- (creative, spectator), and takes it away in the others.
local function updateInvulnerable(player: Player, character: Model)
	local field = character:FindFirstChild(INVULNERABLE)
	if GameModeRules.invulnerable(GameMode.of(player)) then
		if field == nil then
			local new = Instance.new("ForceField")
			new.Name = INVULNERABLE
			new.Visible = false
			new.Parent = character
		end
	elseif field then
		field:Destroy()
	end
end

-- Hurts every living player who is in a wall (GameModeRules.inWall) by IN_WALL_DAMAGE.
local function suffocate(blocks: PlayerPhysics.World)
	for player, x, y, z in PlayerPositions.each() do
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid and humanoid.Health > 0 and GameModeRules.inWall(GameMode.of(player), blocks, x, y, z) then
			local damage = Effects.incomingDamage(player, GameModeRules.IN_WALL_DAMAGE)
			humanoid:TakeDamage(damage / MINECRAFT_HEALTH * humanoid.MaxHealth)
		end
	end
end

local function setOnFire(character: Model, onFire: boolean)
	if (character:GetAttribute(Characters.ON_FIRE) == true) ~= onFire then
		character:SetAttribute(Characters.ON_FIRE, if onFire then true else nil)
	end
end

--[[
	One tick of lava, burning and status effects for every living player (Players/Burning,
	Players/Effects): the half hearts it costs and gives back, the burn and extinguish sounds, and
	the ON_FIRE attribute.
]]
local function burnTick(getBlock: Burning.GetBlock)
	for player, fx, fy, fz in PlayerPositions.each() do
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if
			character == nil
			or humanoid == nil
			or humanoid.Health <= 0
			or not (math.abs(fx) <= Protocol.MAX_COORDINATE)
			or not (math.abs(fy) <= Protocol.MAX_COORDINATE)
			or not (math.abs(fz) <= Protocol.MAX_COORDINATE)
		then
			continue
		end
		local state = burning[player]
		if state == nil then
			state = Burning.newPlayer()
			burning[player] = state
		end
		local mode = GameMode.of(player)
		local touching = Burning.touchingAt(getBlock, fx, fy, fz, BODY.width, BODY.height)
		-- (The weather only while burning: rain puts it out.)
		local rain = rainingAt
		if state.fire > 0 and rain and Burning.inRain(rain, fx, fy, fz, BODY.height) then
			touching = bit32.bor(touching, Burning.RAIN)
		end
		-- (The fluid over the eyes, only when some fluid gives effects there.)
		local eyes = 0
		if EffectRules.HEAD_EFFECTS then
			local eyeY = fy + BODY.eye
			eyes = Burning.touching(getBlock, fx - 0.01, eyeY, fz - 0.01, fx + 0.01, eyeY + 0.01, fz + 0.01)
		end
		Effects.touchFluids(player, touching, eyes, mode)
		local window = Inventories.get(player)
		local armor, toughness = 0, 0
		if window then
			armor, toughness = Items.armorPoints(window.inventory.armor)
		end
		local damage, extinguished, hurt =
			Burning.tickPlayer(state, mode, touching, armor, toughness, Effects.fireRules(player))
		-- (The effects' own hurt is magic: through armor, under the same cooldown.)
		local maxHealth = humanoid.MaxHealth
		local health = if maxHealth > 0 then humanoid.Health / maxHealth * MINECRAFT_HEALTH else 0
		local magic, heal = Effects.tick(player, mode, health, MINECRAFT_HEALTH)
		if magic > 0 then
			damage += Burning.hurtPlayer(state, mode, magic)
		end
		damage = Effects.incomingDamage(player, damage)
		-- (The events carry Minecraft's volume and pitch already: no cue on top.)
		if GameModeRules.makesSounds(mode) then
			if extinguished and EXTINGUISH then
				Sounds.play(EXTINGUISH, fx, fy, fz)
			end
			if hurt and BURN then
				Sounds.play(BURN, fx, fy, fz)
			end
		end
		setOnFire(character, Burning.onFire(state))
		if damage > 0 then
			-- (TakeDamage respects the ForceField of players who can't be hurt.)
			humanoid:TakeDamage(damage / MINECRAFT_HEALTH * humanoid.MaxHealth)
		end
		if heal > 0 and humanoid.Health > 0 then
			humanoid.Health =
				math.min(humanoid.MaxHealth, humanoid.Health + heal / MINECRAFT_HEALTH * humanoid.MaxHealth)
		end
	end
end

-- The network, once started (explosion messages).
local started: ServerNet.ServerNet? = nil

--[[
	An explosion of `power` at (x, y, z) (blocks), with the loaded blocks `getBlock` (see the
	header): hurts the players it reaches and sends every player within `range` blocks (default
	Config.Explosions.EffectDistance; the Nuke's Config.Nuke.EffectDistance) its effect and their
	knockback.
]]
function Characters.explosion(
	x: number,
	y: number,
	z: number,
	power: number,
	getBlock: Explosion.GetBlock,
	range: number?
)
	local net = started
	if net == nil then
		return
	end
	local reach = range or Config.Explosions.EffectDistance
	for player, fx, fy, fz in PlayerPositions.each() do
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local dx, dy, dz = fx - x, fy - y, fz - z
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		if
			humanoid == nil
			or not (math.abs(fx) <= Protocol.MAX_COORDINATE)
			or not (math.abs(fy) <= Protocol.MAX_COORDINATE)
			or not (math.abs(fz) <= Protocol.MAX_COORDINATE)
			or distance > reach
		then
			continue
		end
		local mode = GameMode.of(player)
		local kx, ky, kz = 0, 0, 0
		-- (Only those in reach are hurt: no rays for the Nuke's far audience.)
		local inReach = distance <= Explosion.REACH * power
		if inReach and humanoid.Health > 0 and not GameMode.isSpectator(mode) then
			local half = BODY.width / 2
			local seen = Explosion.seenPercent(
				getBlock,
				x,
				y,
				z,
				fx - half,
				fy,
				fz - half,
				fx + half,
				fy + BODY.height,
				fz + half
			)
			local damage, px, py, pz = Explosion.hit(x, y, z, power, fx, fy, fz, fy + BODY.eye, seen)
			if damage then
				kx, ky, kz = px, py, pz
				local state = burning[player]
				if state == nil then
					state = Burning.newPlayer()
					burning[player] = state
				end
				local window = Inventories.get(player)
				local armor, toughness = 0, 0
				if window then
					armor, toughness = Items.armorPoints(window.inventory.armor)
				end
				local landed = Effects.incomingDamage(player, Burning.hurtPlayer(state, mode, damage, armor, toughness))
				local fire = Effects.fireRules(player)
				if fire and fire.ignites and damage > 0 then
					-- (Petrol on the skin catches from the blast.)
					Burning.ignite(state, mode, Burning.IN_FIRE_SECONDS, fire)
				end
				if landed > 0 then
					-- (TakeDamage respects the ForceField of players who can't be hurt.)
					humanoid:TakeDamage(landed / MINECRAFT_HEALTH * humanoid.MaxHealth)
				end
			end
		end
		net.send(
			player,
			Protocol.ServerMessage.Explosion,
			Protocol.encodeExplosion({ x = x, y = y, z = z, power = power, kx = kx, ky = ky, kz = kz })
		)
		local push = math.sqrt(kx * kx + ky * ky + kz * kz)
		if push > 0 then
			PlayerPositions.grant(player, KNOCKBACK_TRAVEL * push)
		end
	end
end

-- Lets `player`'s movement take a knockback of (kx, ky, kz) blocks a tick (a mob's hit: Mobs/
-- Mobs' push), as an explosion's does.
function Characters.knockedBack(player: Player, kx: number, ky: number, kz: number)
	local push = math.sqrt(kx * kx + ky * ky + kz * kz)
	if push > 0 and push == push then
		PlayerPositions.grant(player, KNOCKBACK_TRAVEL * push)
	end
end

-- Where it rains (World/WeatherServer.rainingAt; nil: nowhere): burning players in it go out.
function Characters.setRain(check: ((x: number, y: number, z: number) -> boolean)?)
	rainingAt = check
end

--[[
	A lightning bolt at (x, y, z) (blocks: the bottom centre of the struck cell; World/
	WeatherServer's strike handler): every living player it reaches (World/Lightning.hits, their
	standing box; not spectators) catches fire for Config.Weather.Lightning.BurnSeconds (a tick
	more when already burning: Entity.thunderHit; their fire rules: Fire Resistance, Fuel Soaked)
	and takes its Damage half hearts as any other hurt (`hurt`: cooldown, armor, Resistance).
	Returns how many it reached.
]]
function Characters.lightning(x: number, y: number, z: number): number
	local settings = Config.Weather.Lightning
	local reached = 0
	for player, fx, fy, fz in PlayerPositions.each() do
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local mode = GameMode.of(player)
		if
			humanoid == nil
			or humanoid.Health <= 0
			or GameMode.isSpectator(mode)
			or not Lightning.hits(x, y, z, fx, fy, fz, BODY.width, BODY.height)
		then
			continue
		end
		reached += 1
		local state = burning[player]
		if state == nil then
			state = Burning.newPlayer()
			burning[player] = state
		end
		if Burning.onFire(state) then
			state.fire += 1
		else
			Burning.ignite(state, mode, settings.BurnSeconds, Effects.fireRules(player))
		end
		Characters.hurt(player, settings.Damage)
	end
	return reached
end

--[[
	Hurts a living player by `amount` half hearts from a mob (server Mobs/Mobs: a zombie's or a
	spider's hit, a skeleton's arrow), through the hurt cooldown lava, burning and explosions share
	and softened by the armor worn (Players/Burning.hurtPlayer; never in creative or spectator),
	then by Resistance (Players/Effects.incomingDamage, as every other hurt here). Returns the half
	hearts that landed and whether the hurt was a fresh one (not under the cooldown: Minecraft
	knocks back only those, Resistance or not).
]]
--[[
	Sets a living character's health to `halfHearts` of Minecraft's 20 (scaled to its MaxHealth)
	without it counting as a hurt (no hurt sound): a saved player's health coming back
	(World/WorldSave). 0 or less leaves it full.
]]
function Characters.restoreHealth(player: Player, halfHearts: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 or not (halfHearts > 0) then
		return
	end
	local health = math.clamp(halfHearts / MINECRAFT_HEALTH, 0, 1) * humanoid.MaxHealth
	if math.abs(health - humanoid.Health) > 1e-6 then
		quietHealth[player] = true
		humanoid.Health = health
	end
end

function Characters.hurt(player: Player, amount: number): (number, boolean)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil or humanoid.Health <= 0 then
		return 0, false
	end
	local state = burning[player]
	if state == nil then
		state = Burning.newPlayer()
		burning[player] = state
	end
	local fresh = state.cooldown <= 0
	local window = Inventories.get(player)
	local armor, toughness = 0, 0
	if window then
		armor, toughness = Items.armorPoints(window.inventory.armor)
	end
	local hit = Burning.hurtPlayer(state, GameMode.of(player), amount, armor, toughness)
	local landed = Effects.incomingDamage(player, hit)
	if landed > 0 then
		-- (TakeDamage respects the ForceField of players who can't be hurt.)
		humanoid:TakeDamage(landed / MINECRAFT_HEALTH * humanoid.MaxHealth)
	end
	return landed, fresh and hit > 0
end

--[[
	Starts handling characters. `world` (optional) gives the block a hurting landing sounds like
	and the blocks players suffocate in and burn in; without it only the player's fall sound plays,
	nobody suffocates and nothing burns.
]]
function Characters.start(net: ServerNet.ServerNet, world: WorldServer.World?)
	started = net
	if not workspace:IsCollisionGroupRegistered(Rig.COLLISION_GROUP) then
		workspace:RegisterCollisionGroup(Rig.COLLISION_GROUP)
	end
	-- Every group registered so far (Default, this one, a game's own); groups registered later
	-- collide with characters unless the game turns that off itself.
	for _, group in workspace:GetRegisteredCollisionGroups() do
		workspace:CollisionGroupSetCollidable(Rig.COLLISION_GROUP, group.name, false)
	end

	local function onCharacter(player: Player, character: Model)
		-- (A new character is out of the fire, as Minecraft's respawned player.)
		burning[player] = nil
		updateInvulnerable(player, character)
		for _, part in character:GetDescendants() do
			setGroup(part, Rig.COLLISION_GROUP)
		end
		local added = character.DescendantAdded:Connect(function(part)
			setGroup(part, Rig.COLLISION_GROUP)
		end)
		-- Parts leaving the character (a dropped tool) collide normally again.
		local removing = character.DescendantRemoving:Connect(function(part)
			setGroup(part, "Default")
		end)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			local health = humanoid.Health
			local lastHurt = -math.huge
			local died = false
			local healthChanged = humanoid.HealthChanged:Connect(function(newHealth: number)
				if newHealth <= 0 and PlayerPositions.networked() then
					-- (A parked character's root is anchored and server-owned: make sure the server
					-- hears it die, for the respawn and the drops.)
					task.defer(function()
						if not died and humanoid.Parent and humanoid:GetState() ~= Enum.HumanoidStateType.Dead then
							humanoid:ChangeState(Enum.HumanoidStateType.Dead)
						end
					end)
				end
				-- (Health cut to a lowered MaxHealth is no hurt, nor is a saved health restored.)
				local restored = quietHealth[player] == true
				quietHealth[player] = nil
				local hurt = not restored and newHealth < health and newHealth < humanoid.MaxHealth
				health = newHealth
				local now = os.clock()
				if
					hurt
					and newHealth > 0
					and now - lastHurt >= HURT_SOUND_INTERVAL
					and GameModeRules.makesSounds(GameMode.of(player))
				then
					lastHurt = now
					Sounds.playAt(player, "entity.player.hurt")
				end
			end)
			humanoid.Died:Connect(function()
				died = true
				healthChanged:Disconnect()
				added:Disconnect()
				removing:Disconnect()
				if GameModeRules.makesSounds(GameMode.of(player)) then
					Sounds.playAt(player, "entity.player.death")
				end
				-- (A parked body stays where it is: each client plays the death tilt.)
				if not PlayerPositions.networked() then
					for _, part in character:GetDescendants() do
						setGroup(part, "Default")
					end
				end
			end)
		end
	end

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		player:GetAttributeChangedSignal(GameMode.ATTRIBUTE):Connect(function()
			local character = player.Character
			if character then
				updateInvulnerable(player, character)
			end
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end

	-- Fall damage reported by the client when it lands (survival and adventure players).
	local landings: { [Player]: { count: number, since: number } } = {}
	net.on(Protocol.ClientMessage.Fall, function(player: Player, payload: buffer)
		if not Config.Movement.FallDamage then
			return
		end
		local distance = Protocol.decodeFall(payload)
		if distance == nil then
			return
		end
		-- (Jump Boost takes its levels off the fall: LivingEntity.calculateFallDamage.)
		local halfHearts = GameModeRules.fallDamage(GameMode.of(player), distance - Effects.fallReduction(player))
		if halfHearts <= 0 then
			return
		end
		local now = os.clock()
		local rate = landings[player]
		if rate == nil or now - rate.since >= 1 then
			rate = { count = 0, since = now }
			landings[player] = rate
		end
		rate.count += 1
		if rate.count > MAX_LANDINGS_PER_SECOND then
			return
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil or humanoid.Health <= 0 then
			return
		end
		-- Everyone else hears the landing (the player's client played it): the fall, and the
		-- block landed on (Minecraft's playBlockFallSound: the block 0.2 below the feet).
		local fx, fy, fz = PlayerPositions.feet(player)
		if fx then
			Sounds.play(SharedSounds.fall(halfHearts), fx, fy, fz, player)
			local below = if world then world:peekBlock(math.floor(fx), math.floor(fy - 0.2), math.floor(fz)) else nil
			if below then
				Sounds.play(SharedSounds.block(below, "fall"), fx, fy, fz, player)
			end
		end
		-- TakeDamage respects ForceFields (e.g. spawn protection).
		local damage = Effects.incomingDamage(player, halfHearts)
		humanoid:TakeDamage(damage / MINECRAFT_HEALTH * humanoid.MaxHealth)
	end)
	Players.PlayerRemoving:Connect(function(player)
		landings[player] = nil
		burning[player] = nil
		quietHealth[player] = nil
	end)

	-- Suffocation, checked every IN_WALL_INTERVAL against generated blocks only.
	if world then
		local blocks: PlayerPhysics.World = {
			getBlock = function(x: number, y: number, z: number): number?
				return world:peekBlock(x, y, z)
			end,
		}
		local untilCheck = GameModeRules.IN_WALL_INTERVAL
		local burnAccumulator = 0
		RunService.Heartbeat:Connect(function(dt: number)
			untilCheck -= dt
			if untilCheck <= 0 then
				untilCheck = GameModeRules.IN_WALL_INTERVAL
				suffocate(blocks)
			end
			-- Lava and burning, at 20 ticks a second.
			burnAccumulator = math.min(burnAccumulator + dt, BURN_TICK * MAX_BURN_TICKS_PER_FRAME)
			while burnAccumulator >= BURN_TICK do
				burnAccumulator -= BURN_TICK
				burnTick(blocks.getBlock)
			end
		end)
	end
end

return Characters
