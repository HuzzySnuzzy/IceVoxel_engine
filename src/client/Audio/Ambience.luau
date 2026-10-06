--!strict
--[[
	Sounds of the surroundings that only this client plays (Minecraft's animateTick and ambient
	sounds):

	  Furnace  while the open window is a furnace that burns (its `data` litTime > 0, which the
	           client only knows while the window shows it), it crackles at random
	           (block.furnace.fire_crackle, SoundRules.CRACKLE_CHANCE per tick) at the furnace:
	           the block aimed at when the window opened, else the player.
	  Machines every burning Heat Generator within SoundRules.CRACKLE_RANGE blocks of the
	           listener (its Machines record says it works: Rendering/TransmitterRenderer
	           .activeMachines; the client knows these without opening them) crackles the same
	           way, at the generator.
	  Caves    deep underground (the sky light reaching the camera below SoundRules.CAVE_EXPOSURE,
	           Rendering/LightingController.skyExposure), a low rumble (ambient.cave) every few
	           minutes spent there, somewhere near the listener. Config.Sounds.Ambient (and the
	           player's Cave Rumble setting, SoundPlayer.allows) turns it off.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Mining = require(Shared.Mining)

local BlockInteraction = require(script.Parent.Parent.Interaction.BlockInteraction)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local SoundPlayer = require(script.Parent.SoundPlayer)
local SoundRules = require(script.Parent.SoundRules)
local TransmitterRenderer = require(script.Parent.Parent.Rendering.TransmitterRenderer)

local TICK = 1 / Mining.TICK_RATE
-- Ticks run at most per frame (a hitch does not make a burst of crackles).
local MAX_TICKS_PER_FRAME = 5
-- The cave rumble comes from up to this many blocks around the listener (each way).
local CAVE_SPREAD = 8

local Ambience = {}

function Ambience.start()
	-- The open furnace window's block (blocks, its centre) and the window it belongs to.
	local furnaceWindow = -1
	local furnaceAt: Vector3? = nil

	local function furnaceBurning(): boolean
		local window = ClientInventory.window()
		local container = window.container
		if window.id == 0 or container == nil or container.kind ~= "furnace" then
			furnaceWindow = -1
			return false
		end
		if window.id ~= furnaceWindow then
			-- Just opened: the furnace is the block aimed at (the one right clicked), if it is one.
			furnaceWindow = window.id
			local hit = BlockInteraction.target()
			furnaceAt = if hit and hit.block == container.block
				then Vector3.new(hit.x + 0.5, hit.y + 0.5, hit.z + 0.5)
				else nil
		end
		local data = container.data
		return data ~= nil and (data[1] or 0) > 0
	end

	local function crackle()
		local at = furnaceAt
		if at == nil then
			local view = MovementController.current
			at = if view then view.feet + Vector3.new(0, 1, 0) else nil
		end
		if at then
			SoundPlayer.play("block.furnace.fire_crackle", at.X, at.Y, at.Z)
		end
	end

	local clock = 0
	local caveTime = 0
	local caveDelay = SoundRules.caveDelay(math.random())

	RunService.Heartbeat:Connect(function(dt: number)
		if not SoundPlayer.isEnabled() then
			return
		end
		clock = math.min(clock + dt, TICK * MAX_TICKS_PER_FRAME)
		while clock >= TICK do
			clock -= TICK
			if furnaceBurning() and math.random() < SoundRules.CRACKLE_CHANCE then
				crackle()
			end
			local listener = SoundPlayer.listener()
			if listener then
				local burning = TransmitterRenderer.activeMachines(
					listener.X,
					listener.Y,
					listener.Z,
					SoundRules.CRACKLE_RANGE,
					SoundRules.crackles
				)
				for _, record in burning do
					if math.random() < SoundRules.CRACKLE_CHANCE then
						SoundPlayer.play("block.furnace.fire_crackle", record.x + 0.5, record.y + 0.5, record.z + 0.5)
					end
				end
			end
		end

		-- Caves: time spent in the dark brings the rumble closer; time in daylight takes it back.
		if SoundPlayer.allows("ambient") and LightingController.skyExposure() < SoundRules.CAVE_EXPOSURE then
			caveTime += dt
			local listener = SoundPlayer.listener()
			if caveTime >= caveDelay and listener then
				caveTime = 0
				caveDelay = SoundRules.caveDelay(math.random())
				local at = listener
					+ Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1) * CAVE_SPREAD
				SoundPlayer.play("ambient.cave", at.X, at.Y, at.Z)
			end
		else
			caveTime = math.max(0, caveTime - dt)
		end
	end)
end

return Ambience
