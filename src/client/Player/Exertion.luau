--!strict
--[[
	Reports the movement that costs thirst (Tough As Nails; Shared/ToughAsNails/Exertion): Player/
	MovementController hands every movement tick to `tick`, which counts it, and about once a
	second (Exertion.INTERVAL), or as soon as sprinting starts or stops, what was counted goes to
	the server (Protocol Exertion) with the sprint flag (the body temperature's sprinting).
	Nothing is sent while thirst and temperature are off (no Survival message ever came), nor while
	there is nothing new.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)
local PlayerPhysics = require(Shared.Movement.PlayerPhysics)
local ExertionRules = require(Shared.ToughAsNails.Exertion)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SurvivalState = require(script.Parent.SurvivalState)

local Exertion = {}

local TICKS = math.round(ExertionRules.INTERVAL * 20)

local report = ExertionRules.new()
local ticks = 0
local sentSprinting = false

--[[
	One movement tick of `state` (after PlayerPhysics.tick), which was at `previous` (feet, blocks)
	before it, with the tick's `events`.
]]
function Exertion.tick(state: PlayerPhysics.State, events: PlayerPhysics.Events, previous: Vector3)
	if SurvivalState.get() == nil then
		return
	end
	ExertionRules.record(report, state, state.x - previous.X, state.y - previous.Y, state.z - previous.Z, events.jumped)
	ticks += 1
	local toggled = report.sprinting ~= sentSprinting
	if toggled or (ticks >= TICKS and not ExertionRules.isEmpty(report)) or (ticks >= TICKS and report.sprinting) then
		ClientNet.send(Protocol.ClientMessage.Exertion, Protocol.encodeExertion(report))
		ExertionRules.reset(report)
		sentSprinting = report.sprinting
		ticks = 0
	elseif ticks >= TICKS then
		ticks = 0
	end
end

return Exertion
