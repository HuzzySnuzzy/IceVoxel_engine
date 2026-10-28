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
	  Loops    the machines with a loop that work (their records say so) within LOOP_RANGE blocks
	           of the listener play it at the machine (Rendering/TransmitterModel.machineLoop: the
	           electric machines' hums, the fan's whirr, the stove's crackle, the oil heater's
	           roar; SoundPlayer.setLoop), the MAX_LOOPS nearest only, looked at LOOP_HZ times a
	           second; a loop stops as soon as its machine stops, goes or is out of range.
	  Lava     lava with air above it within 32 blocks of the listener pops now and then
	           (SoundRules.lavaTick: Minecraft's LavaFluid.animateTick on its random display
	           ticks, sampled), at the lava; the nearest such lava those samples have found bubbles
	           in a loop (block.lava.ambient, the fifth data sheet's "Lava Ambient") while it is
	           within SoundRules.LAVA_LOOP_RANGE blocks (SoundRules.lavaLoopAt, looked at with the
	           machines' loops).
	  Fire     every fire within 32 blocks of the listener (Rendering/FireRenderer.firesNear)
	           crackles with the odds Minecraft's display ticks give it (SoundRules.fireCrackle:
	           BaseFireBlock.animateTick), at the fire, cue volume 1..2 and pitch 0.3..1.
	  Moods    Minecraft's cave mood (Audio/CaveMood): every tick a random block within 8 blocks of
	           the player's eyes raises the mood when it is dark and lowers it in daylight or near
	           torches; at 100% one of the cave mood sounds (Sounds.MOODS, from the packs' music of
	           the set "mood"; the stand-in ambient.cave while there are none) plays two blocks
	           beyond that block, and the mood starts over. The light comes from
	           Rendering/LightingController.skyLight and CaveMood.blockLight. Config.Sounds.Ambient
	           (and the player's Cave Moods setting, SoundPlayer.allows) keeps it quiet; the mood
	           still counts (F3 shows it, `mood`).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Mining = require(Shared.Mining)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local Sounds = require(Shared.Sounds)

local BlockInteraction = require(script.Parent.Parent.Interaction.BlockInteraction)
local CaveMood = require(script.Parent.CaveMood)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local FireRenderer = require(script.Parent.Parent.Rendering.FireRenderer)
local LightingController = require(script.Parent.Parent.Rendering.LightingController)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local SoundPlayer = require(script.Parent.SoundPlayer)
local SoundRules = require(script.Parent.SoundRules)
local TransmitterModel = require(script.Parent.Parent.Rendering.TransmitterModel)
local TransmitterRenderer = require(script.Parent.Parent.Rendering.TransmitterRenderer)

local TICK = 1 / Mining.TICK_RATE
-- Ticks run at most per frame (a hitch does not make a burst of crackles).
local MAX_TICKS_PER_FRAME = 5
-- The player's eyes above their feet (blocks), where Minecraft's mood looks from.
local EYE = PlayerPhysics.dimensions("standing").eye
-- The seasons' machines' loops: how far they are heard from, how many play at once, and how often
-- (a second) the machines around are looked at.
local LOOP_RANGE = 16
local MAX_LOOPS = 6
local LOOP_HZ = 4

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

	-- The loops playing (SoundPlayer.setLoop keys, one per machine position, and the lava's).
	local looping: { [string]: boolean } = {}
	local loopClock = 0
	-- The lava the lava loop plays at (SoundRules.lavaTick keeps the nearest it samples).
	local lava: SoundRules.LavaLoop = {}
	local function hasLoop(block: number): boolean
		return TransmitterModel.machineLoop(block) ~= nil
	end
	local function updateLoops(listener: Vector3?)
		local now: { [string]: boolean } = {}
		if listener and getBlock then
			local lx, ly, lz = listener.X, listener.Y, listener.Z
			local working = TransmitterRenderer.activeMachines(lx, ly, lz, LOOP_RANGE, hasLoop)
			local function distance(record: any): number
				local dx, dy, dz = record.x + 0.5 - lx, record.y + 0.5 - ly, record.z + 0.5 - lz
				return dx * dx + dy * dy + dz * dz
			end
			table.sort(working, function(a: any, b: any): boolean
				return distance(a) < distance(b)
			end)
			for i = 1, math.min(#working, MAX_LOOPS) do
				local record = working[i]
				local block = getBlock(record.x, record.y, record.z)
				local name = if block then TransmitterModel.machineLoop(block) else nil
				if name then
					local key = `machine {record.x},{record.y},{record.z}`
					now[key] = true
					SoundPlayer.setLoop(key, name, record.x + 0.5, record.y + 0.5, record.z + 0.5)
				end
			end
			local x, y, z = SoundRules.lavaLoopAt(lava, getBlock, lx, ly, lz)
			if x and y and z then
				now.lava = true
				SoundPlayer.setLoop("lava", "block.lava.ambient", x, y, z)
			end
		end
		for key in looping do
			if not now[key] then
				SoundPlayer.endLoop(key)
			end
		end
		looping = now
	end

	local clock = 0
	local random = Random.new()
	local function nextInt(n: number): number
		return random:NextInteger(0, n - 1)
	end
	-- The light at a cell for the mood: the sky's, else the block light (only searched in the
	-- dark), and whether the cell is open cave (bigger caves bring the mood sooner).
	local function light(x: number, y: number, z: number): (number?, number, boolean?)
		local sky = LightingController.skyLight(x, y, z)
		if sky == nil or sky > 0 or getBlock == nil then
			return sky, 0, nil
		end
		local block = getBlock(x, y, z)
		local open = block ~= nil and not Blocks.isOpaque(block)
		return 0, CaveMood.blockLight(getBlock, x, y, z), open
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
			if next(looping) then
				updateLoops(nil)
			end
			return
		end
		loopClock += dt
		if loopClock >= 1 / LOOP_HZ then
			loopClock = 0
			updateLoops(SoundPlayer.listener())
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
					for _, sound in SoundRules.lavaTick(getBlock, x, y, z, math.random, lava) do
						SoundPlayer.play(sound.sound, sound.x, sound.y, sound.z, sound.volume, sound.pitch)
					end
				end
				local lx, ly, lz = listener.X, listener.Y, listener.Z
				for _, fire in FireRenderer.firesNear(lx, ly, lz, SoundRules.FIRE_RANGE) do
					local fx, fy, fz = fire.x + 0.5, fire.y + 0.5, fire.z + 0.5
					if math.random() < SoundRules.fireCrackle(fx - lx, fy - ly, fz - lz) then
						SoundPlayer.play("block.fire.ambient", fx, fy, fz, 1 + math.random(), 0.3 + math.random() * 0.7)
					end
				end
			end
			moodTick()
		end
	end)
end

return Ambience
