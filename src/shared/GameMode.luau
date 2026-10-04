--!strict
--[[
	Game modes, as Minecraft has them:

	  Survival  blocks take time to mine and drop as items, placing uses items up, falls hurt.
	  Creative  every item from the creative inventory, instant breaking, flying (double tap jump),
	            no fall damage.

	A player's mode is the Player attribute ATTRIBUTE (set by the server, see Players/GameModes), so
	every client sees everyone's mode.
]]

local Config = require(script.Parent.Config)

local GameMode = {}

GameMode.SURVIVAL = "Survival"
GameMode.CREATIVE = "Creative"
GameMode.ATTRIBUTE = "IceVoxelGameMode"

-- "survival" / "s" / "0" and "creative" / "c" / "1" (any case) -> the mode, else nil.
function GameMode.parse(text: string): string?
	local word = string.lower(text)
	if word == "survival" or word == "s" or word == "0" then
		return GameMode.SURVIVAL
	elseif word == "creative" or word == "c" or word == "1" then
		return GameMode.CREATIVE
	end
	return nil
end

-- A player's mode (the default until the server has set it).
function GameMode.of(player: Instance): string
	local mode = player:GetAttribute(GameMode.ATTRIBUTE)
	if mode == GameMode.CREATIVE then
		return GameMode.CREATIVE
	elseif mode == GameMode.SURVIVAL then
		return GameMode.SURVIVAL
	end
	return GameMode.parse(Config.Gameplay.DefaultGameMode) or GameMode.SURVIVAL
end

function GameMode.isCreative(player: Instance): boolean
	return GameMode.of(player) == GameMode.CREATIVE
end

return GameMode
