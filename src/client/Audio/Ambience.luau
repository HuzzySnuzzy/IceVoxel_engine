--!strict
--[[
	Sounds of the surroundings that only this client plays (Minecraft's animateTick and ambient
	sounds):

	  Furnace  while the open window is a furnace that burns (its `data` litTime > 0, which the
	           client only knows while the window shows it), it crackles at random
	           (block.furnace.fire_crackle, SoundRules.CRACKLE_CHANCE per tick) at the furnace:
	           the block aimed at when the window opened, else the player.
	  Machines every burning Heat or Combustion Generator within SoundRules.CRACKLE_RANGE blocks of the
	           listener (its Machines record says it works: Rendering/TransmitterRenderer
	           .activeMachines; the client knows these without opening them) crackles the same
	           way, at the generator.
	  Lava     lava with air above it within 32 blocks of the listener pops and bubbles now and
	           then (SoundRules.lavaTick: Minecraft's LavaFluid.animateTick on its random display
	           ticks, sampled), at the lava.
	  Moods    Minecraft's cave mood (Audio/CaveMood): every tick a random block within 8 blocks of
	           the player's eyes raises the mood when it is dark and lowers it in daylight or near
	           torches; at 100% one of the cave mood sounds (Sounds.MOODS, from
	           Sounds/MusicList.Moods; the stand-in ambient.cave while there are none) plays two
	           blocks beyond that block, and the mood starts over. The light comes from
	           Rendering/LightingController.skyLight and CaveMood.blockLight. Config.Sounds.Ambient
	           (and the player's Cave Moods setting, SoundPlayer.allows) keeps it quiet; the mood
	           still counts (F3 shows it, `mood`).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Mining = require(Shared.Mining)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Sounds = require(Shared.Sounds)

local BlockInteraction = require(script.Parent.Parent.Interaction.BlockInteraction)
local CaveMood = require(script.Parent.CaveMood)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local SoundPlayer = require(script.Parent.SoundPlayer)
local SoundRules = require(script.Parent.SoundRules)
local TransmitterRenderer = require(script.Parent.Parent.Rendering.TransmitterRenderer)

local TICK = 1 / Mining.TICK_RATE
-- Ticks run at most per frame (a hitch does not make a burst of crackles).
local MAX_TICKS_PER_FRAME = 5
-- The player's eyes above their feet (blocks), where Minecraft's mood looks from.
local EYE = PlayerPhysics.dimensions("standing").eye

local Ambience = {}

local mood = CaveMood.new()

-- The cave mood, 0..1 (F3 shows it as a percentage, as Minecraft's debug screen does).
function Ambience.mood(): number
	return mood.mood
end

-- `getBlock`: the client's blocks (nil where none are loaded), for lava's sounds.
function Ambience.start(getBlock: SoundRules.GetBlock?)
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
	local random = Random.new()
	local function nextInt(n: number): number
		return random:NextInteger(0, n - 1)
	end
	-- The light at a cell for the mood: the sky's, else the block light (only searched in the dark).
	local function light(x: number, y: number, z: number): (number?, number)
		local sky = LightingController.skyLight(x, y, z)
		if sky == nil or sky > 0 or getBlock == nil then
			return sky, 0
		end
		return 0, CaveMood.blockLight(getBlock, x, y, z)
	end
	local function moodTick()
		local view = MovementController.current
		if view == nil then
			return
		end
		local feet = view.feet
		local x, y, z = CaveMood.tick(mood, feet.X, feet.Y + EYE, feet.Z, light, nextInt)
		if x and y and z and SoundPlayer.allows("ambient") then
			local moods = Sounds.MOODS
			SoundPlayer.play(if #moods > 0 then moods[random:NextInteger(1, #moods)] else "ambient.cave", x, y, z)
		end
	end

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
				if getBlock then
					local x, y, z = math.floor(listener.X), math.floor(listener.Y), math.floor(listener.Z)
					for _, sound in SoundRules.lavaTick(getBlock, x, y, z, math.random) do
						SoundPlayer.play(sound.sound, sound.x, sound.y, sound.z, sound.volume, sound.pitch)
					end
				end
			end
			moodTick()
		end
	end)
end

return Ambience
