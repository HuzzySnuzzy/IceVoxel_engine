--!strict
--[[
	The Tough As Nails mod's survival mechanics (TAN for Minecraft 1.20.x), shared and pure:

	  Thirst        thirst, hydration and exhaustion (TAN's ThirstData, Minecraft's FoodData),
	                dehydration, regeneration that needs thirst, TAN's Thirst effect
	  Temperature   the five levels, the target the surroundings give, the drift towards it,
	                hypothermia and hyperthermia
	  Drinks        what is drunk (water sources, dirty and purified bottles and canteens) and how
	                bottles and canteens fill and empty
	  Exertion      movement measured by the client for thirst (sprinting, swimming, jumps)

	The server runs them (Players/ToughAsNails, its surroundings from Players/Climate) and sends
	each player their own state (Protocol Survival), which the HUD draws (client Ui/SurvivalHud:
	the droplets, the temperature gauge, the frost and heat at the screen's edges) and F3 prints.
	Config.ToughAsNails turns thirst and temperature on and off and tunes them.

	Survival and adventure players are affected (`affects`); creative and spectator players are
	not (GameMode.invulnerable, TAN's check): their stats stand still and never hurt.
]]

local Config = require(script.Parent.Config)
local GameMode = require(script.Parent.GameMode)

local Thirst = require(script.Thirst)
local Temperature = require(script.Temperature)
local Drinks = require(script.Drinks)
local Exertion = require(script.Exertion)

local ToughAsNails = {}

ToughAsNails.Thirst = Thirst
ToughAsNails.Temperature = Temperature
ToughAsNails.Drinks = Drinks
ToughAsNails.Exertion = Exertion

-- Do thirst and temperature run for a player in game `mode`?
function ToughAsNails.affects(mode: string): boolean
	return not GameMode.invulnerable(mode)
end

-- Is thirst on (Config.ToughAsNails.Thirst)?
function ToughAsNails.thirstOn(): boolean
	return Config.ToughAsNails.Thirst == true
end

-- Is body temperature on (Config.ToughAsNails.Temperature)?
function ToughAsNails.temperatureOn(): boolean
	return Config.ToughAsNails.Temperature == true
end

return ToughAsNails
