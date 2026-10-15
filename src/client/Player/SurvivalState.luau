--!strict
--[[
	This player's thirst and body temperature (Tough As Nails) and food bar (Minecraft's hunger,
	Shared/Hunger) as the server last sent them (Protocol Survival, server Players/ToughAsNails):
	what the HUD (Ui/StatusCluster's status icons, Ui/SurvivalHud's frost and heat), drinking
	(Interaction/Drinking), eating (Interaction/Eating: `foodLevel`), sprinting
	(Player/MovementController: `tooHungry`) and F3 (Debug/DebugOverlay) read. nil until the first message, and for good when Config.ToughAsNails turns thirst and
	temperature off and Config.Hunger is off (the server sends nothing).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Hunger = require(Shared.Hunger)
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
	with thirst on, Thirst.canDrink's rule; a tea whenever temperature is on; a potion always,
	Tough As Nails on or off)?
]]
function SurvivalState.canDrink(mode: string, drink: Drinks.Drink?): boolean
	local status = current
	if GameMode.isSpectator(mode) then
		return false
	elseif status == nil then
		-- (Nothing from the server yet, or thirst and temperature off: potions only.)
		return Drinks.isPotion(drink)
	end
	local thirsty = GameMode.invulnerable(mode) or status.thirst < ToughAsNails.Thirst.MAX
	return Drinks.drinkable(drink, thirsty, status.thirstOn, status.temperatureOn)
end

-- The food bar while hunger is on (nil: off, or nothing from the server yet): Foods.canUse's.
function SurvivalState.foodLevel(): number?
	local status = current
	return if status and status.hungerOn then status.food else nil
end

--[[
	Is this player too hungry to sprint in game `mode` (hunger on and Hunger.canSprint says no:
	food 6 or less, a mode that can't fly)? false until the server said.
]]
function SurvivalState.tooHungry(mode: string): boolean
	local food = SurvivalState.foodLevel()
	return food ~= nil and not Hunger.canSprint(food, mode)
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
