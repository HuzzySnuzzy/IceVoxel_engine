--!strict
--[[
	Server side of the cosmetic characters.

	Players move as a Minecraft-style hull on their own client (Player/MovementController); the
	Roblox character only shows where the hull is. So on the server:
	  * every character part goes into a collision group that collides with nothing (Rig), so Roblox
	    physics never pushes characters around; a dead character's parts go back to Default so the
	    body falls onto the terrain,
	  * `teleport` / `teleportFeet` move a character and tell its client the exact feet position
	    (attributes), so the hull moves with it,
	  * landings reported by the client turn into fall damage (Config.Movement.FallDamage), like
	    Minecraft: ceil(distance - 3) half hearts of 20, scaled to the Humanoid's MaxHealth
	    (GameModeRules.fallDamage). Survival and adventure players only: creative and spectator
	    players never take fall damage (they may fly).
	  * creative and spectator players can't be hurt (Minecraft's Abilities.invulnerable,
	    GameModeRules.invulnerable): while in those modes their character holds an invisible
	    ForceField (INVULNERABLE), which Humanoid:TakeDamage and explosions respect. (Setting
	    Health directly still hurts, as Minecraft's /kill and the void do.)
	  * players in a wall suffocate (GameModeRules.inWall, at the feet Rig.feet reads from the
	    character, against the server's blocks): IN_WALL_DAMAGE half hearts every
	    IN_WALL_INTERVAL, until they get out or die, so one who leaves spectator inside rock
	    isn't walled in for good (Minecraft's in-wall damage).
	  * sounds (Audio/Sounds), heard by everyone near: losing health (entity.player.hurt, at most
	    every half second like Minecraft's invulnerability time) and dying (entity.player.death),
	    from any cause; and a hurting landing's small or big fall with the fall sound of the block
	    landed on, for everyone but the player, whose client played them already
	    (LivingEntity.causeFallDamage). Spectators make none (GameModeRules.makesSounds).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Rig = require(Shared.Movement.Rig)

local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local SharedSounds = require(Shared.Sounds)
local GameModeRules = require(script.Parent.GameModeRules)

local BLOCK = Config.BlockSize
-- Minecraft players have 20 health points (half hearts).
local MINECRAFT_HEALTH = GameModeRules.MINECRAFT_HEALTH
-- The invisible ForceField of characters whose game mode can't be hurt.
local INVULNERABLE = "IceVoxelInvulnerable"
-- Landings a player may report per second (a real one needs a fall first).
local MAX_LANDINGS_PER_SECOND = 4
-- Seconds between hurt sounds of one character (Minecraft's 10 ticks of invulnerability).
local HURT_SOUND_INTERVAL = 0.5

local Characters = {}

local function setGroup(part: Instance, group: string)
	if part:IsA("BasePart") then
		part.CollisionGroup = group
	end
end

--[[
	Moves a character so its feet are at `feet` (blocks), keeping its rotation, and tells its
	client where the hull now is.
]]
function Characters.teleportFeet(character: Model, feet: Vector3)
	local root = character:FindFirstChild("HumanoidRootPart")
	local rotation = if root and root:IsA("BasePart") then root.CFrame.Rotation else CFrame.identity
	local position = feet * BLOCK + Vector3.new(0, Rig.rootOffset(character), 0)
	character:PivotTo(CFrame.new(position) * rotation)
	character:SetAttribute(Rig.TELEPORT_FEET, feet)
	character:SetAttribute(Rig.TELEPORT_COUNT, ((character:GetAttribute(Rig.TELEPORT_COUNT) :: number?) or 0) + 1)
end

--[[
	Moves a character so its feet stand centred on block (x, y, z) (y = the block the feet are in),
	keeping its rotation, and tells its client where the hull now is.
]]
function Characters.teleport(character: Model, x: number, y: number, z: number)
	Characters.teleportFeet(character, Vector3.new(x + 0.5, y, z + 0.5))
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
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local feet = if character then Rig.feet(character) else nil
		if
			humanoid
			and humanoid.Health > 0
			and feet
			and GameModeRules.inWall(GameMode.of(player), blocks, feet.X, feet.Y, feet.Z)
		then
			humanoid:TakeDamage(GameModeRules.IN_WALL_DAMAGE / MINECRAFT_HEALTH * humanoid.MaxHealth)
		end
	end
end

--[[
	Starts handling characters. `world` (optional) gives the block a hurting landing sounds like
	and the blocks players suffocate in; without it only the player's fall sound plays, and nobody
	suffocates.
]]
function Characters.start(net: ServerNet.ServerNet, world: WorldServer.World?)
	if not workspace:IsCollisionGroupRegistered(Rig.COLLISION_GROUP) then
		workspace:RegisterCollisionGroup(Rig.COLLISION_GROUP)
	end
	-- Every group registered so far (Default, this one, a game's own); groups registered later
	-- collide with characters unless the game turns that off itself.
	for _, group in workspace:GetRegisteredCollisionGroups() do
		workspace:CollisionGroupSetCollidable(Rig.COLLISION_GROUP, group.name, false)
	end

	local function onCharacter(player: Player, character: Model)
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
			local healthChanged = humanoid.HealthChanged:Connect(function(newHealth: number)
				-- (Health cut to a lowered MaxHealth is no hurt.)
				local hurt = newHealth < health and newHealth < humanoid.MaxHealth
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
				healthChanged:Disconnect()
				added:Disconnect()
				removing:Disconnect()
				if GameModeRules.makesSounds(GameMode.of(player)) then
					Sounds.playAt(player, "entity.player.death")
				end
				for _, part in character:GetDescendants() do
					setGroup(part, "Default")
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
		local halfHearts = GameModeRules.fallDamage(GameMode.of(player), distance)
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
		local feet = if character then Rig.feet(character) else nil
		if feet then
			Sounds.play(SharedSounds.fall(halfHearts), feet.X, feet.Y, feet.Z, player)
			local below = if world
				then world:peekBlock(math.floor(feet.X), math.floor(feet.Y - 0.2), math.floor(feet.Z))
				else nil
			if below then
				Sounds.play(SharedSounds.block(below, "fall"), feet.X, feet.Y, feet.Z, player)
			end
		end
		-- TakeDamage respects ForceFields (e.g. spawn protection).
		humanoid:TakeDamage(halfHearts / MINECRAFT_HEALTH * humanoid.MaxHealth)
	end)
	Players.PlayerRemoving:Connect(function(player)
		landings[player] = nil
	end)

	-- Suffocation, checked every IN_WALL_INTERVAL against generated blocks only.
	if world then
		local blocks: PlayerPhysics.World = {
			getBlock = function(x: number, y: number, z: number): number?
				return world:peekBlock(x, y, z)
			end,
		}
		local untilCheck = GameModeRules.IN_WALL_INTERVAL
		RunService.Heartbeat:Connect(function(dt: number)
			untilCheck -= dt
			if untilCheck <= 0 then
				untilCheck = GameModeRules.IN_WALL_INTERVAL
				suffocate(blocks)
			end
		end)
	end
end

return Characters
