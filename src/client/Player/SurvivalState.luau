--!strict
--[[
	This player's thirst and body temperature (Tough As Nails) as the server last sent them
	(Protocol Survival, server Players/ToughAsNails): what the HUD (Ui/SurvivalHud), drinking
	(Interaction/Drinking) and F3 (Debug/DebugOverlay) read. nil until the first message, and for
	good when Config.ToughAsNails turns thirst and temperature off (the server sends nothing).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local ToughAsNails = require(Shared.ToughAsNails)
local Drinks = require(Shared.ToughAsNails.Drinks)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)

local SurvivalState = {}

local current: Protocol.SurvivalStatus? = nil
local changedEvent = Instance.new("BindableEvent")
-- Fires when a new state arrives.
SurvivalState.changed = changedEvent.Event

-- The last state the server sent (nil: none yet, or thirst and temperature are off).
function SurvivalState.get(): Protocol.SurvivalStatus?
	return current
end

--[[
	May this player drink `drink` now, in game `mode` (Drinks.drinkable: thirsty or invulnerable
	with thirst on, Thirst.canDrink's rule; a tea whenever temperature is on)?
]]
function SurvivalState.canDrink(mode: string, drink: Drinks.Drink?): boolean
	local status = current
	if status == nil or GameMode.isSpectator(mode) then
		return false
	end
	local thirsty = GameMode.invulnerable(mode) or status.thirst < ToughAsNails.Thirst.MAX
	return Drinks.drinkable(drink, thirsty, status.thirstOn, status.temperatureOn)
end

-- Is hand drinking on (Config.ToughAsNails.HandDrinking)?
function SurvivalState.handDrinking(): boolean
	return Config.ToughAsNails.HandDrinking == true
end

function SurvivalState.start()
	ClientNet.on(Protocol.ServerMessage.Survival, function(payload: buffer)
		local status = Protocol.decodeSurvival(payload)
		if status then
			current = status
			changedEvent:Fire()
		end
	end)
end

return SurvivalState
