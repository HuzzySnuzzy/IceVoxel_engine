--!strict
--[[
	Where every player is, for the whole server: the one place server code asks for a player's
	position (blocks, Luau doubles), never their Roblox character.

	Two sources, one API:
	  compat     (Config.Players.ServerPositions false, as today): read from the character, which
	             its client moves and the server trusts (Rig.feet, the root part's position and
	             facing); a teleport moves the character and tells its client through the
	             IceVoxelFeet / IceVoxelTeleports attributes (what Characters.teleportFeet did).
	             Positions that are not finite or lie beyond Protocol.MAX_COORDINATE + 64 blocks
	             (|y| beyond 4096) count as none: a client-owned character may say anything.
	  networked  (ServerPositions true; the server side of the floating origin): characters stand
	             parked and anchored at Config.Players.ParkPosition, so nothing replicates where
	             anyone is; positions come from the clients' Move messages (Net/PlayerSync, checked
	             by MoveCheck), teleports are a private Teleport message to the owner with a new
	             epoch, and poses go only to players whose interest includes them
	             (Players/Interest, PlayerRelay). Built on top of this API; until then the switch
	             reads the characters too.

	API (positions are feet, the bottom centre of the body, in world blocks):
	  feet(player) -> (x?, y, z)       nil: not standing in the world (no character, no root)
	  feetVector(player) -> Vector3?   the same, float32 (Rig.feet's drop-in)
	  center(player) -> (x?, y, z)     the middle of the body (today: the root part's centre)
	  eye(player) -> (x?, y, z)        the eyes (standing: 1.62 above the feet)
	  hull(player) -> (min?, max?)     the standing hull, blocks (Rig.hull's drop-in)
	  yaw(player) -> radians           facing (CFrame.Angles(0, yaw, 0))
	  look(player) -> (x, y, z)        unit view direction
	  alive(player) -> boolean         a living character
	  inReach(player, x, y, z, reach?) block (x, y, z)'s centre within `reach` blocks of the
	                                   body's middle (default Config.Interaction.Reach + 2: the
	                                   slack for movement and latency every reach check uses)
	  each() -> iterator               players with a position: for player, x, y, z in each()
	  chunkOf(player) -> (cx?, cz)     the chunk the feet are in
	  teleport(player, x, y, z, yaw?)  puts the feet at (x, y, z) (doubles), facing `yaw` when
	                                   given; fires `teleported` (player, x, y, z)
	  grant(player, blocks)            movement a knockback (explosions, mob hits) may add beyond
	                                   the speed checks (networked only)
	  spectating(player) -> Player?    whom the player spectates (networked only: the client tells)
	  start(net)                       once, with the world (before Players/Characters)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Protocol = require(Shared.Net.Protocol)
local Rig = require(Shared.Movement.Rig)

local BLOCK = Config.BlockSize
local CHUNK = Config.ChunkSize
local STANDING = PlayerPhysics.STANDING
-- Positions a client-owned character may claim that still count (blocks).
local LIMIT = Protocol.MAX_COORDINATE + 64
local MAX_HEIGHT = 4096

-- What PlayerPositions talks through: Network/ServerNet's `on` and `send` (not required here:
-- ServerNet asks PlayerPositions for reach).
export type Net = {
	on: (kind: number, handler: (player: Player, payload: buffer) -> ()) -> (),
	send: (player: Player, kind: number, payload: buffer) -> (),
}

-- Where positions come from (see the header). Positions are blocks; `feet` and `center` give
-- nil, 0, 0 for a player not standing in the world.
export type Backend = {
	feet: (player: Player) -> (number?, number, number),
	center: (player: Player) -> (number?, number, number),
	eye: (player: Player) -> (number?, number, number),
	yaw: (player: Player) -> number,
	look: (player: Player) -> (number, number, number),
	alive: (player: Player) -> boolean,
	-- false: the player could not be moved (no character).
	teleport: (player: Player, x: number, y: number, z: number, yaw: number?) -> boolean,
	grant: (player: Player, blocks: number) -> (),
	spectating: (player: Player) -> Player?,
}

local PlayerPositions = {}

local teleportedEvent = Instance.new("BindableEvent")
-- Fires (player: Player, x: number, y: number, z: number) after a teleport (feet, blocks).
PlayerPositions.teleported = teleportedEvent.Event

local function sane(x: number, y: number, z: number): boolean
	return x == x and y == y and z == z and math.abs(x) <= LIMIT and math.abs(z) <= LIMIT and math.abs(y) <= MAX_HEIGHT
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

--[[ compat: the characters, as before ]]

local function compatFeet(player: Player): (number?, number, number)
	local character = player.Character
	local feet = if character then Rig.feet(character) else nil
	if feet == nil or not sane(feet.X, feet.Y, feet.Z) then
		return nil, 0, 0
	end
	return feet.X, feet.Y, feet.Z
end

local compat: Backend = {
	feet = compatFeet,

	center = function(player: Player): (number?, number, number)
		local root = rootOf(player)
		if root == nil then
			return nil, 0, 0
		end
		local position = root.Position
		local x, y, z = position.X / BLOCK, position.Y / BLOCK, position.Z / BLOCK
		if not sane(x, y, z) then
			return nil, 0, 0
		end
		return x, y, z
	end,

	eye = function(player: Player): (number?, number, number)
		local x, y, z = compatFeet(player)
		if x == nil then
			return nil, 0, 0
		end
		-- (The server can't tell the pose from a character: the standing eyes.)
		return x, y + STANDING.eye, z
	end,

	yaw = function(player: Player): number
		local root = rootOf(player)
		return if root then Rig.yaw(root.CFrame) else 0
	end,

	look = function(player: Player): (number, number, number)
		local root = rootOf(player)
		local look = if root then root.CFrame.LookVector else Vector3.zAxis
		return look.X, look.Y, look.Z
	end,

	alive = function(player: Player): boolean
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		return humanoid ~= nil and humanoid.Health > 0
	end,

	-- Moves the character so its feet are at (x, y, z), facing `yaw` (else as it faces), and
	-- tells its client where the hull now is.
	teleport = function(player: Player, x: number, y: number, z: number, yaw: number?): boolean
		local character = player.Character
		if character == nil then
			return false
		end
		local rotation
		if yaw then
			rotation = CFrame.Angles(0, yaw, 0)
		else
			local root = character:FindFirstChild("HumanoidRootPart")
			rotation = if root and root:IsA("BasePart") then root.CFrame.Rotation else CFrame.identity
		end
		local feet = Vector3.new(x, y, z)
		character:PivotTo(CFrame.new(feet * BLOCK + Vector3.new(0, Rig.rootOffset(character), 0)) * rotation)
		character:SetAttribute(Rig.TELEPORT_FEET, feet)
		character:SetAttribute(Rig.TELEPORT_COUNT, ((character:GetAttribute(Rig.TELEPORT_COUNT) :: number?) or 0) + 1)
		return true
	end,

	-- (Characters' clients move them: nothing checks their speed.)
	grant = function(_player: Player, _blocks: number) end,

	-- (The server never learns it from a character.)
	spectating = function(_player: Player): Player?
		return nil
	end,
}

local backend: Backend = compat
local net: Net? = nil

--[[ The API ]]

function PlayerPositions.feet(player: Player): (number?, number, number)
	return backend.feet(player)
end

function PlayerPositions.feetVector(player: Player): Vector3?
	local x, y, z = backend.feet(player)
	return if x then Vector3.new(x, y, z) else nil
end

function PlayerPositions.center(player: Player): (number?, number, number)
	return backend.center(player)
end

function PlayerPositions.eye(player: Player): (number?, number, number)
	return backend.eye(player)
end

-- The standing hull (blocks): min and max corners, or nil, nil.
function PlayerPositions.hull(player: Player): (Vector3?, Vector3?)
	local x, y, z = backend.feet(player)
	if x == nil then
		return nil, nil
	end
	local half = STANDING.width / 2
	return Vector3.new(x - half, y, z - half), Vector3.new(x + half, y + STANDING.height, z + half)
end

function PlayerPositions.yaw(player: Player): number
	return backend.yaw(player)
end

function PlayerPositions.look(player: Player): (number, number, number)
	return backend.look(player)
end

function PlayerPositions.alive(player: Player): boolean
	return backend.alive(player)
end

-- Is block (x, y, z)'s centre within `reach` blocks (default Config.Interaction.Reach + 2) of the
-- middle of the player's body?
function PlayerPositions.inReach(player: Player, x: number, y: number, z: number, reach: number?): boolean
	local cx, cy, cz = backend.center(player)
	if cx == nil then
		return false
	end
	local dx, dy, dz = x + 0.5 - cx, y + 0.5 - cy, z + 0.5 - cz
	local limit = reach or Config.Interaction.Reach + 2
	return dx * dx + dy * dy + dz * dz <= limit * limit
end

-- Every player with a position: `for player, x, y, z in PlayerPositions.each() do` (feet).
function PlayerPositions.each(): () -> (Player?, number, number, number)
	local list = Players:GetPlayers()
	local i = 0
	return function(): (Player?, number, number, number)
		while true do
			i += 1
			local player = list[i]
			if player == nil then
				return nil, 0, 0, 0
			end
			local x, y, z = backend.feet(player)
			if x then
				return player, x, y, z
			end
		end
	end
end

-- The chunk the player's feet are in, or nil, 0.
function PlayerPositions.chunkOf(player: Player): (number?, number)
	local x, _, z = backend.feet(player)
	if x == nil then
		return nil, 0
	end
	return math.floor(x / CHUNK), math.floor(z / CHUNK)
end

-- Puts the player's feet at (x, y, z) (blocks, doubles), facing `yaw` when given (radians, as
-- CFrame.Angles(0, yaw, 0)), and fires `teleported`.
function PlayerPositions.teleport(player: Player, x: number, y: number, z: number, yaw: number?)
	if backend.teleport(player, x, y, z, yaw) then
		teleportedEvent:Fire(player, x, y, z)
	end
end

function PlayerPositions.grant(player: Player, blocks: number)
	backend.grant(player, blocks)
end

function PlayerPositions.spectating(player: Player): Player?
	return backend.spectating(player)
end

function PlayerPositions.start(serverNet: Net)
	if net then
		return
	end
	net = serverNet
	if Config.Players.ServerPositions then
		warn("[IceVoxel] Config.Players.ServerPositions: server positions aren't built yet; reading characters")
	end
end

return PlayerPositions
