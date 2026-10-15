--!strict
--[[
	Firearms on the server, in the manner of DayZ (Shared/Weapons): the authority over every shot,
	over how players hold their weapons and over the time weapon actions take. This is the glue:
	it hands the pure and testable parts the game's real modules.

	  Weapons/FireRules      the rules of a shot (checks and their order, the flight's numbers,
	                         targets, damage sums, noise, the Shots record, who is sent it, bolts)
	  Weapons/Firing         a Fire message played out: acknowledged always (Players/Inventories),
	                         checked, the jam rolled, the round fired (Inventories.fire), every
	                         pellet traced (Shared/Weapons/Ballistics against `world:peekBlock`,
	                         the mobs of Mobs/Mobs.targets with where the shooter's client saw
	                         them, and with Config.Weapons.PvP the other players), mobs hurt
	                         (Mobs.weaponDamage) and players (Players/Characters.weaponHurt), glass
	                         shattered (block.glass.break), the noise heard by the infected
	                         (Apocalypse/NoiseBus), bolts dropped again (Entities/Entities), and
	                         the Shots record sent to everyone within Config.Weapons.ShotBroadcast
	                         once a frame (Protocol.ServerMessage.Shots)
	  Weapons/WeaponActions  Weapon messages (raise, lower, guard, unguard: the player attribute
	                         Inventory/Types.AIM_ATTRIBUTE, dropped when the hand or the slot
	                         changes, and when a character dies, comes or goes), and the
	                         inventory's actions through Inventories.setWeaponHooks: the weapon
	                         actions' locks (reload, a round, a jam, the fire mode) and their
	                         predicted sounds for the others; any other action that changed the
	                         gun in hand lowers it and locks it as the weapon action would
	Every frame (Heartbeat) the aims are looked over and the queued Shots go out; a player who
	leaves is forgotten. The server script starts it after Mobs/Mobs.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)
local Types = require(Shared.Inventory.Types)
local WeaponSync = require(Shared.Net.WeaponSync)

local WorldServer = require(script.Parent.World.WorldServer)
local Inventories = require(script.Parent.Players.Inventories)
local Characters = require(script.Parent.Players.Characters)
local PlayerPositions = require(script.Parent.Players.PlayerPositions)
local Mobs = require(script.Parent.Mobs.Mobs)
local NoiseBus = require(script.Parent.Apocalypse.NoiseBus)
local Sounds = require(script.Parent.Audio.Sounds)
local Entities = require(script.Parent.Entities.Entities)
local EntityWorld = require(script.Parent.Entities.EntityWorld)

local FireRules = require(script.FireRules)
local Firing = require(script.Firing)
local WeaponActions = require(script.WeaponActions)

-- Only what Weapons uses of ServerNet.ServerNet.
type Net = {
	send: (player: Player, kind: number, payload: buffer) -> (),
	on: (kind: number, handler: (player: Player, payload: buffer) -> ()) -> (),
}

local Weapons = {}

local GLASS_BREAK = "block.glass.break"

local started = false
local actions: WeaponActions.WeaponActions? = nil

-- The player's eyes' height (pose-aware), else 1.62 above the feet.
local function eyeHeight(player: Player, feetY: number): number
	local ex, ey = PlayerPositions.eye(player)
	return if ex ~= nil then ey else feetY + 1.62
end

-- Every player with a position (FireRules.PlayerCandidate).
local function candidates(): { FireRules.PlayerCandidate }
	local list: { FireRules.PlayerCandidate } = {}
	for player, x, y, z in PlayerPositions.each() do
		if player then
			table.insert(list, {
				key = player,
				x = x,
				y = y,
				z = z,
				eyeY = eyeHeight(player, y),
				alive = PlayerPositions.alive(player),
				mode = GameMode.of(player),
			})
		end
	end
	return list
end

-- Starts handling Fire and Weapon messages and the weapon hooks (see the header).
function Weapons.start(net: Net, world: WorldServer.World)
	assert(not started, "Weapons.start was already called")
	started = true
	local settings = Config.Weapons
	local random = Random.new()
	local function roll(): number
		return random:NextNumber()
	end
	local function getBlock(x: number, y: number, z: number): number?
		return world:peekBlock(x, y, z)
	end

	local weaponActions = WeaponActions.new({
		settings = settings,
		now = os.clock,
		held = function(player: Player): Items.Stack?
			return Inventories.heldStack(player)
		end,
		selected = function(player: Player): number?
			local window = Inventories.get(player)
			return if window then window.inventory.selected else nil
		end,
		alive = PlayerPositions.alive,
		mode = GameMode.of,
		setAim = function(player: Player, aim: string?)
			if player.Parent ~= nil and player:GetAttribute(Types.AIM_ATTRIBUTE) ~= aim then
				player:SetAttribute(Types.AIM_ATTRIBUTE, aim)
			end
		end,
		play = function(player: Player, sound: string)
			if player.Parent ~= nil and Sounds.allow(player) then
				Sounds.playAt(player, sound, player)
			end
		end,
		later = function(seconds: number, callback: () -> ())
			task.delay(seconds, callback)
		end,
	})
	actions = weaponActions
	Inventories.setWeaponHooks({
		allow = function(player: Player, action: Types.Action): boolean
			return weaponActions:allow(player, action)
		end,
		applied = function(player: Player, action: Types.Action, before: Items.Stack?, after: Items.Stack?)
			weaponActions:applied(player, action, before, after)
		end,
		changed = function(player: Player, before: Items.Stack?, after: Items.Stack?)
			weaponActions:changed(player, before, after)
		end,
	})

	local shots = Firing.new({
		settings = settings,
		now = os.clock,
		random = roll,
		getBlock = getBlock,
		shooter = function(player: Player): FireRules.Shooter
			local window = Inventories.get(player)
			local aim, raisedAt, raisedSlot, raisedItem = weaponActions:raised(player)
			local ex, ey, ez = PlayerPositions.eye(player)
			return {
				now = 0,
				mode = GameMode.of(player),
				alive = PlayerPositions.alive(player),
				selected = if window then window.inventory.selected else 0,
				held = Inventories.heldStack(player),
				aim = aim,
				raisedAt = raisedAt,
				raisedSlot = raisedSlot,
				raisedItem = raisedItem,
				busyUntil = weaponActions:busyUntil(player),
				lastShot = nil,
				eyeX = ex,
				eyeY = ey,
				eyeZ = ez,
			}
		end,
		userId = function(player: Player): number
			return player.UserId
		end,
		acknowledge = Inventories.acknowledge,
		fire = Inventories.fire,
		held = Inventories.heldStack,
		mobs = function(player: Player, x: number, y: number, z: number, radius: number): { FireRules.MobCandidate }
			return Mobs.targets(player, x, y, z, radius)
		end,
		players = candidates,
		hurtMob = function(
			id: number,
			amount: number,
			player: Player,
			ox: number,
			oz: number,
			knockback: number,
			head: boolean
		): number
			return Mobs.weaponDamage(id, amount, player, ox, oz, knockback, head)
		end,
		hurtPlayer = function(player: Player, amount: number, head: boolean, bleed: boolean): number
			return Characters.weaponHurt(player, amount, head, bleed)
		end,
		noise = NoiseBus.emit,
		shatter = function(x: number, y: number, z: number)
			if world:setBlock(x, y, z, Blocks.AIR) then
				Sounds.play(GLASS_BREAK, x + 0.5, y + 0.5, z + 0.5)
			end
		end,
		drop = function(item: number, x: number, y: number, z: number)
			Entities.spawnItem({ item = item, count = 1 }, x, y, z, 0, 0, 0, EntityWorld.DEFAULT_PICKUP_DELAY)
		end,
		send = function(player: Player, payload: buffer)
			if player.Parent ~= nil then
				net.send(player, Protocol.ServerMessage.Shots, payload)
			end
		end,
	})

	net.on(Protocol.ClientMessage.Fire, function(player: Player, payload: buffer)
		local fire = WeaponSync.decodeFire(payload)
		if fire then
			shots:handle(player, fire)
		end
	end)
	net.on(Protocol.ClientMessage.Weapon, function(player: Player, payload: buffer)
		local op = WeaponSync.decodeWeapon(payload)
		if op then
			weaponActions:weapon(player, op)
		end
	end)
	RunService.Heartbeat:Connect(function()
		weaponActions:tick()
		shots:flush()
	end)
	-- (A character that comes or goes, a death or a respawn, drops the aim, whatever the client
	-- sends: the attribute never outlives a life.)
	local function watch(player: Player)
		player.CharacterAdded:Connect(function()
			weaponActions:lower(player)
		end)
		player.CharacterRemoving:Connect(function()
			weaponActions:lower(player)
		end)
		if player:GetAttribute(Types.AIM_ATTRIBUTE) ~= nil then
			player:SetAttribute(Types.AIM_ATTRIBUTE, nil)
		end
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		weaponActions:forget(player)
		shots:forget(player)
	end)
end

-- The player's aim (Types.AIM_RAISED, AIM_GUARD or nil) and when the gun went up, for a probe.
function Weapons.aim(player: Player): (string?, number?)
	local current = actions
	if current == nil then
		return nil, nil
	end
	return current:raised(player)
end

return Weapons
