--!strict
--[[
	What each game mode lets a player do on the server, beyond block edits (those are
	Network/EditRules: `mayEdit`, `minesOverTime`, `blocksPlacing`), without the Roblox parts, so
	the tests can run them. The modes' abilities are Shared/GameMode's (Minecraft 1.20.1's
	GameType.updatePlayerAbilities); this says what the server makes of them:

	  Using items    the Configurator and buckets on blocks (Players/ItemUse): survival and
	                 creative (`mayUseItemOn`: ItemStack.useOn passes without Abilities.mayBuild),
	                 so never in adventure or spectator.
	  Menus          a right click on a block with a menu opens it in every mode (adventure like
	                 survival; spectators read only, ServerPlayerGameMode.useItemOn's MenuProvider).
	                 Spectators don't count as openers (`opensContainers`: ChestBlockEntity.startOpen
	                 skips them), so a chest's lid stays shut and silent for them. What they may do
	                 in a window is Inventory/Menu.allows (InventoryState.applyAs): select a hotbar
	                 slot and close it, nothing else, and they throw nothing (Q).
	  Pickups        everyone alive but spectators picks items up (`picksUp`).
	  Damage         creative and spectator players can't be hurt (`invulnerable`: Players/
	                 Characters gives their characters an invisible ForceField, which
	                 Humanoid:TakeDamage respects); falls hurt only players who can't fly
	                 (`fallDamage`: Player.causeFallDamage returns early with Abilities.mayfly).
	                 Players in a wall (left spectator in rock, buried in sand) suffocate
	                 (`inWall`: LivingEntity.baseTick's in-wall damage), so nobody stays walled in.
	                 Lava hurts and sets burning only players who can be hurt (Players/Burning:
	                 creative and spectator players never burn).
	  Death          a spectator who dies anyway (a game script setting Health) drops nothing and
	                 keeps everything (`keepsInventory`: ServerPlayer.die skips dropAllDeathLoot
	                 for spectators, restoreFrom keeps their inventory).
	  Sounds         spectators make none (`makesSounds`): no hurt or death sound, no chest lid.
	  Teleport       a spectator may teleport to another player in the game (`spectatorTeleport`:
	                 the spectator menu's "Teleport to Player", ServerGamePacketListenerImpl
	                 .handleTeleportToEntityPacket).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Protocol = require(Shared.Net.Protocol)

local GameModeRules = {}

local function finite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

-- Minecraft players have 20 health points (half hearts) and take damage from falls past 3 blocks.
GameModeRules.MINECRAFT_HEALTH = 20
GameModeRules.SAFE_FALL = 3

-- May a player in game mode `mode` use the item in their hand on a block (the Configurator,
-- buckets)? Survival and creative (Abilities.mayBuild).
function GameModeRules.mayUseItemOn(mode: string): boolean
	return GameMode.mayBuild(mode)
end

--[[
	Does a player in `mode` who opens a container count as one of its openers (a chest's lid opens
	and sounds for the first, closes after the last)? Everyone but spectators.
]]
function GameModeRules.opensContainers(mode: string): boolean
	return not GameMode.isSpectator(mode)
end

-- Does a living player in `mode` pick up item entities? Everyone but spectators.
function GameModeRules.picksUp(mode: string): boolean
	return GameMode.canPickUp(mode)
end

-- Is a player in `mode` safe from damage (creative, spectator: Abilities.invulnerable)?
function GameModeRules.invulnerable(mode: string): boolean
	return GameMode.invulnerable(mode)
end

--[[
	The half hearts (of MINECRAFT_HEALTH) a landing after falling `distance` blocks costs a player
	in `mode`: ceil(distance - SAFE_FALL), never below 0 (LivingEntity.calculateFallDamage). 0 for
	players who may fly or can't be hurt (creative, spectator); adventure players are hurt like
	survival players. A distance that is no number costs nothing.
]]
function GameModeRules.fallDamage(mode: string, distance: number): number
	if GameMode.mayFly(mode) or GameMode.invulnerable(mode) or not (distance > GameModeRules.SAFE_FALL) then
		return 0
	end
	return math.ceil(distance - GameModeRules.SAFE_FALL)
end

-- Half hearts a player in a wall loses, and seconds between two such hurts (Minecraft hurts them
-- every tick; the 10 ticks of invulnerability after a hurt let one in every half second).
GameModeRules.IN_WALL_DAMAGE = 1
GameModeRules.IN_WALL_INTERVAL = 0.5

-- Eye heights (blocks above the feet) of the poses: standing, crouching, crawling or swimming.
local EYES = {
	PlayerPhysics.dimensions("standing").eye,
	PlayerPhysics.dimensions("crouching").eye,
	PlayerPhysics.dimensions("crawling").eye,
}

--[[
	Does a player in `mode` whose feet are at (x, y, z) (blocks) in `world` suffocate (Minecraft's
	in-wall damage, LivingEntity.baseTick: Entity.isInWall, then a hurt by inWall)? Only players who
	can be hurt; spectators are never in a wall (noPhysics). The hull and its pose are the client's,
	so the server can't tell standing from crouching or crawling: it counts a player in a wall only
	when the eyes of every pose are (PlayerPhysics.isInWall). One of them is the real eyes, so
	crawling or crouching under blocks never hurts; but eyes in a block above free space (the head
	in a ceiling, which Minecraft hurts too) don't either: the player can move out of that. Feet
	that are no place (not finite, or past Protocol.MAX_COORDINATE: every client owns its
	character) are in no wall.
]]
function GameModeRules.inWall(mode: string, world: PlayerPhysics.World, x: number, y: number, z: number): boolean
	if
		GameMode.invulnerable(mode)
		or GameMode.noClip(mode)
		or not (finite(x) and finite(y) and finite(z))
		or math.abs(x) > Protocol.MAX_COORDINATE
		or math.abs(y) > Protocol.MAX_COORDINATE
		or math.abs(z) > Protocol.MAX_COORDINATE
	then
		return false
	end
	for _, eye in EYES do
		if not PlayerPhysics.isInWall(world, x, y + eye, z) then
			return false
		end
	end
	return true
end

-- Does a player in `mode` make sounds the server plays (hurt, death, chest lids)? Not spectators.
function GameModeRules.makesSounds(mode: string): boolean
	return not GameMode.isSpectator(mode)
end

-- Does a player in `mode` who dies keep their inventory? With `keepInventory`
-- (Config.Gameplay.KeepInventory) everyone does, and spectators always do.
function GameModeRules.keepsInventory(mode: string, keepInventory: boolean): boolean
	return keepInventory or GameMode.isSpectator(mode)
end

--[[
	Where a SpectatorTeleport takes player `from` (user id, in game mode `mode`) going to player
	`to`, whose feet are at (x, y, z) (blocks): those feet, for a spectator going to someone else.
	The height is kept within spectators' limits (PlayerPhysics.NO_CLIP_MIN_Y .. NO_CLIP_MAX_Y).
	Feet that are no place (not finite, or past Protocol.MAX_COORDINATE sideways: every client owns
	its character, so the target's position may be anything) refuse it. Returns nil, 0, 0 when it
	is refused.
]]
function GameModeRules.spectatorTeleport(
	mode: string,
	from: number,
	to: number,
	x: number,
	y: number,
	z: number
): (number?, number, number)
	if
		not GameMode.isSpectator(mode)
		or from == to
		or not (finite(x) and finite(y) and finite(z))
		or math.abs(x) > Protocol.MAX_COORDINATE
		or math.abs(z) > Protocol.MAX_COORDINATE
	then
		return nil, 0, 0
	end
	return x, math.clamp(y, PlayerPhysics.NO_CLIP_MIN_Y, PlayerPhysics.NO_CLIP_MAX_Y), z
end

return GameModeRules
