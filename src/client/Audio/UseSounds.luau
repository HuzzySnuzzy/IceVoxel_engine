--!strict
--[[
	The sound of players eating and drinking, on this client (the rules are Audio/UseSoundRules,
	pure; the loops play through Audio/SoundPlayer.setLoop):

	  This player   from their own hold, at once: Interaction/Eating.useLength (a food, not
	                medicine) and Interaction/Drinking.useLength (a drink), alive or not as their
	                character's Humanoid says, at the drawn hull's mouth (MovementController).
	  The others    from the player attribute the server sets while their use lasts
	                (Inventory/Types.USE_ATTRIBUTE, server Players/UseState), at the mouth of the
	                body this client draws for them (Player/RemotePlayers: tracked and shown,
	                alive), so only players near enough to be tracked are heard, and each as far as
	                its event carries.
	Every frame each player with a use gets its loop (or, should the recording fail to load, its
	clicks: UseSoundRules); one whose use ended, or who is no longer tracked, has its loop stopped
	at once, and a player gone has theirs freed. Nothing runs before `start`, nor with sounds off.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Types = require(Shared.Inventory.Types)

local Drinking = require(script.Parent.Parent.Interaction.Drinking)
local Eating = require(script.Parent.Parent.Interaction.Eating)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local RemotePlayers = require(script.Parent.Parent.Player.RemotePlayers)
local SoundPlayer = require(script.Parent.SoundPlayer)
local UseSoundRules = require(script.Parent.UseSoundRules)

-- Blocks above the feet a player eats and drinks at (Interaction/Eating's sounds too).
local MOUTH = 1.5

local UseSounds = {}

local started = false
-- Each player with a use (or one this frame just ended).
local uses: { [Player]: UseSoundRules.Use } = {}
-- Players handled this frame (the rest have their loops ended).
local seen: { [Player]: boolean } = {}

-- One frame of `player`'s use `kind` at feet (x, y, z), blocks.
local function sound(
	player: Player,
	kind: string?,
	alive: boolean,
	dt: number,
	length: number?,
	x: number,
	y: number,
	z: number
)
	local use = uses[player]
	if use == nil then
		if kind == nil then
			return
		end
		use = UseSoundRules.new()
		uses[player] = use
	end
	seen[player] = true
	local loop, click = UseSoundRules.step(use :: UseSoundRules.Use, kind, alive, dt, length, SoundPlayer.loads)
	SoundPlayer.setLoop(player, loop, x, y + MOUTH, z)
	if click then
		SoundPlayer.play(click, x, y + MOUTH, z)
	end
	if loop == nil and kind == nil then
		-- (The use ended: its loop stopped above; the state goes until the next one.)
		uses[player] = nil
		SoundPlayer.endLoop(player)
	end
end

-- This player's use now: its kind and length (nil, nil: none).
local function localUse(): (string?, number?)
	local eating = Eating.useLength()
	if eating then
		return Types.USE_EAT, eating
	end
	local drinking = Drinking.useLength()
	if drinking then
		return Types.USE_DRINK, drinking
	end
	return nil, nil
end

local function step(dt: number)
	if not SoundPlayer.isEnabled() then
		return
	end
	table.clear(seen)
	local me = Players.LocalPlayer
	local view = MovementController.current
	if view then
		local kind, length = localUse()
		local character = me.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local alive = humanoid ~= nil and humanoid.Health > 0
		sound(me, kind, alive, dt, length, view.feetX, view.feetY, view.feetZ)
	end
	for player, remote in RemotePlayers.each() do
		if player ~= me then
			local kind = UseSoundRules.kindOf(player:GetAttribute(Types.USE_ATTRIBUTE))
			local alive = remote.alive and RemotePlayers.shown(player)
			sound(player, kind, alive, dt, nil, remote.x, remote.y, remote.z)
		end
	end
	-- Players with a use this client no longer hears (untracked, gone): their loops end.
	for player in uses do
		if not seen[player] then
			uses[player] = nil
			SoundPlayer.endLoop(player)
		end
	end
end

function UseSounds.start()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(step)
	Players.PlayerRemoving:Connect(function(player: Player)
		uses[player] = nil
		SoundPlayer.endLoop(player)
	end)
end

return UseSounds
