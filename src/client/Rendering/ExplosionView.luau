--!strict
--[[
	Explosions as this player sees and feels them (the server's Explosion messages, Minecraft's
	ClientboundExplodePacket: server World/Explosions through Players/Characters):

	  Look       a Roblox Explosion at the centre, its size from the power (BLAST_SCALE blocks of
	             radius per power, at most MAX_BLAST blocks): BlastPressure 0 and
	             DestroyJointRadiusPercent 0, so it only draws (Minecraft's explosion particles;
	             the blocks come as ordinary edits and the sound, entity.generic.explode, as the
	             server's Sound message).
	  Knockback  added to the hull's velocity (MovementController.knockback; the server worked
	             out how hard this player was hit, nothing for players it didn't reach).
	  Shake      the camera shakes a moment (this game's addition), `shake`: within
	             Config.Explosions.ShakeDistance x power blocks, stronger the closer and the
	             more powerful (full from power 4 up), fading over SHAKE_SECONDS; several add up
	             (at most full). Turned after the camera updates, so it never drifts.

	`shake` is pure (tests/spec/Explosions); everything Roblox is set up in `start`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)

local ExplosionView = {}

local BLOCK = Config.BlockSize
-- Radius of the drawn blast: blocks per power, and at most.
local BLAST_SCALE = 0.75
local MAX_BLAST = 8
-- How long a shake lasts (s) and how far the camera turns at full strength (degrees).
local SHAKE_SECONDS = 0.45
local MAX_SHAKE_DEGREES = 1.6
-- Power from which a blast shakes fully (TNT's).
local FULL_SHAKE_POWER = 4
-- How fast the shake wobbles (noise per second).
local SHAKE_RATE = 28

--[[
	How hard (0..1) a blast of `power` shakes the camera of a player `distance` blocks from it:
	1 - distance / (ShakeDistance x power), times power / FULL_SHAKE_POWER up to 1; 0 beyond.
]]
function ExplosionView.shake(distance: number, power: number): number
	local reach = Config.Explosions.ShakeDistance * power
	if not (reach > 0) or not (distance < reach) then
		return 0
	end
	return (1 - math.max(distance, 0) / reach) * math.min(1, power / FULL_SHAKE_POWER)
end

function ExplosionView.start()
	local RunService = game:GetService("RunService")
	local Debris = game:GetService("Debris")
	local ClientNet = require(script.Parent.Parent.Net.ClientNet)
	local MovementController = require(script.Parent.Parent.Player.MovementController)

	-- Shakes going on: when each started and how hard.
	local shakes: { { start: number, strength: number } } = {}

	ClientNet.on(Protocol.ServerMessage.Explosion, function(payload: buffer)
		local effect = Protocol.decodeExplosion(payload)
		if effect == nil then
			return
		end
		local centre = Vector3.new(effect.x, effect.y, effect.z)
		local blast = Instance.new("Explosion")
		blast.Position = centre * BLOCK
		blast.BlastRadius = math.min(effect.power * BLAST_SCALE, MAX_BLAST) * BLOCK
		blast.BlastPressure = 0
		blast.DestroyJointRadiusPercent = 0
		blast.ExplosionType = Enum.ExplosionType.NoCraters
		blast.Parent = workspace
		Debris:AddItem(blast, 3)

		MovementController.knockback(effect.kx, effect.ky, effect.kz)

		local camera = workspace.CurrentCamera
		if camera then
			local strength = ExplosionView.shake((camera.Focus.Position / BLOCK - centre).Magnitude, effect.power)
			if strength > 0 then
				table.insert(shakes, { start = os.clock(), strength = strength })
			end
		end
	end)

	RunService:BindToRenderStep("IceVoxelExplosionShake", Enum.RenderPriority.Camera.Value + 1, function()
		if #shakes == 0 then
			return
		end
		local now = os.clock()
		local total = 0
		for i = #shakes, 1, -1 do
			local age = now - shakes[i].start
			if age >= SHAKE_SECONDS then
				table.remove(shakes, i)
			else
				total += shakes[i].strength * (1 - age / SHAKE_SECONDS)
			end
		end
		local camera = workspace.CurrentCamera
		if total > 0 and camera then
			local angle = math.rad(MAX_SHAKE_DEGREES) * math.min(total, 1)
			local t = now * SHAKE_RATE
			camera.CFrame *= CFrame.Angles(math.noise(t, 0.5) * angle, math.noise(0.5, t) * angle, 0)
		end
	end)
end

return ExplosionView
