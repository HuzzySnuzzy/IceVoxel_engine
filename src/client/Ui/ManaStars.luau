--!strict
--[[
	The HUD's mana stars (Ui/ManaHud draws them), pure: which stars are full, half or empty, where
	each goes, where the row sits and when it shows, so the tests check the layout without Roblox.

	Terraria draws a star per 20 mana (Shared/Mana.STAR); here, in Minecraft's HUD language, a row
	of 10 like the hearts (9 x 9 pixel art, 8 GUI px apart), left aligned:
	  state     a star is full with its 20, half with any part of them, else empty (the server
	            sends whole mana, so "full" is honest: 19 shows half).
	  rows      ten a row; a max past 200 (accessories) starts a second row 10 px above.
	  layout    the bottom row sits in the armor's row (Ui/Hud's ARMOR_Y 21) when no armor icons
	            show, else a row above them (11). The held item's name (11 in survival) and Tough
	            As Nails' status row above it (Ui/SurvivalHud) then move up by `raise`: just enough
	            for the name to clear the top row (0 when the stars take the armor's row alone, 10
	            over armor or with two rows, 20 with both).
	  shown     survival and adventure only (as the hearts), while a magic weapon is selected, while
	            mana is not full, or for Config.Mana.HudLinger 3 s after it changed; never without
	            mana (max 0: Config.Mana off, or nothing from the server yet).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Mana = require(Shared.Mana)

local ManaStars = {}

-- Stars a row, the step between them and between rows (GUI px), and a star's size.
ManaStars.PER_ROW = 10
ManaStars.STEP = 8
ManaStars.ROW = 10
ManaStars.SIZE = 9

-- Star `i`'s look with `mana` (whole): 0 empty, 1 half, 2 full.
function ManaStars.state(mana: number, i: number): number
	local inStar = mana - Mana.STAR * (i - 1)
	if inStar >= Mana.STAR then
		return 2
	elseif inStar > 0 then
		return 1
	end
	return 0
end

-- Rows of stars a max of `max` needs.
function ManaStars.rows(max: number): number
	return math.ceil(Mana.stars(max) / ManaStars.PER_ROW)
end

-- Star `i`'s place from the bottom row's left (GUI px; rows go up: y is 0 or negative).
function ManaStars.position(i: number): (number, number)
	local column = (i - 1) % ManaStars.PER_ROW
	local row = (i - 1) // ManaStars.PER_ROW
	return column * ManaStars.STEP, -row * ManaStars.ROW
end

--[[
	Where the bottom row goes (its top, GUI px in the HUD's canvas) with the armor's row at
	`armorY` and armor icons shown or not, and how far the held item's name (at `nameY`, default a
	row above the armor's) and the rows above it move up to clear the stars.
]]
function ManaStars.layout(armorY: number, max: number, armored: boolean, nameY: number?): (number, number)
	local bottom = if armored then armorY - ManaStars.ROW else armorY
	local top = bottom - ManaStars.ROW * math.max(ManaStars.rows(max) - 1, 0)
	local name = nameY or armorY - ManaStars.ROW
	return bottom, math.max(0, name + ManaStars.ROW - top)
end

--[[
	Do the stars show? `survival`: the hearts show (survival, adventure); `magic`: a magic weapon
	is selected; `sinceChange`: seconds since mana or its max changed.
]]
function ManaStars.shown(survival: boolean, magic: boolean, mana: number, max: number, sinceChange: number): boolean
	if not survival or max <= 0 then
		return false
	end
	return magic or mana < max or sinceChange < Config.Mana.HudLinger
end

return ManaStars
