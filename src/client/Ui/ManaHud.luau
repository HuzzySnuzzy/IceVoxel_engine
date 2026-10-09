--!strict
--[[
	Terraria's mana on the HUD (Ui/Hud builds it into its canvas, so the GUI scale is the hotbar's),
	from what the server says (Player/ManaState); where and when is Ui/ManaStars (pure, tested):

	  stars      a row of 10 stars over the hearts on the left (9 x 9 pixel art like the hearts, 8
	             GUI px apart), each 20 mana: full, half (some of its 20) or empty, in Terraria's
	             mana blue. In the armor's row when no armor icons show, else the row above them;
	             a max past 200 (accessories) starts a second row above. Ui/Hud moves the held
	             item's name and Tough As Nails' status row up by what `render` returns, so the
	             stars never sit under a long name.
	  shown      survival and adventure only (as the hearts), while a magic weapon is selected,
	             while mana isn't full, or Config.Mana.HudLinger 3 s after it changed.
	  refused    a cast the server refused for want of mana blinks the stars' outlines white for
	             BLINK_TIME (as damage blinks the hearts), showing them if they were hidden.
	Painted only when what they show changes (no allocation a frame).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Mana = require(Shared.Mana)

local ManaState = require(script.Parent.Parent.Player.ManaState)
local ManaStars = require(script.Parent.ManaStars)
local Style = require(script.Parent.Style)

-- Where Ui/Hud puts things (GUI px in its canvas): the armor's row and the held item name's row.
export type Layout = { armorY: number, nameY: number }

type Star = { frame: Frame, parts: { [string]: { Frame } }, state: number }

local ManaHud = {}

-- Stars at most (Config.Mana.Max 400 / 20).
local MAX_STARS = Mana.stars(Config.Mana.Max)
local BLINK_TIME = 1

--[[
	9 x 9 pixel art (a five-pointed star). K outline, L / R the left / right half of the fill, H
	a highlight (left half); a half star shows its left half filled, as the hearts do.
]]
local STAR = {
	"....K....",
	"...KHK...",
	"KKKHLRKKK",
	"KHLLLRRRK",
	".KLLLRRK.",
	"..KLLRK..",
	".KLLKRRK.",
	".KLK.KRK.",
	".KK...KK.",
}
local FILL = Color3.fromRGB(64, 112, 255)
local SHINE = Color3.fromRGB(170, 205, 255)
local EMPTY = Color3.fromRGB(26, 32, 64)
local EMPTY_SHINE = Color3.fromRGB(44, 54, 96)
local OUTLINE = Color3.fromRGB(16, 16, 16)
local BLINK_OUTLINE = Color3.fromRGB(255, 255, 255)

local layout: Layout = { armorY = 0, nameY = 0 }
local holder: Frame? = nil
local stars: { Star } = {}
-- What is drawn (to repaint only changes).
local drawnMana, drawnMax, drawnBottom = -1, -1, math.huge
local blinking = false

local function paint(star: Star, state: number)
	if star.state == state then
		return
	end
	star.state = state
	Style.paint(star.parts.L, if state >= 1 then FILL else EMPTY)
	Style.paint(star.parts.H, if state >= 1 then SHINE else EMPTY_SHINE)
	Style.paint(star.parts.R, if state >= 2 then FILL else EMPTY)
end

-- Builds the stars into Ui/Hud's `canvas` (hidden until `render` shows them).
function ManaHud.build(canvas: Frame, where: Layout)
	layout = where
	local frame = Instance.new("Frame")
	frame.Name = "Mana"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromOffset(ManaStars.PER_ROW * ManaStars.STEP + 1, ManaStars.SIZE)
	frame.ZIndex = 2
	frame.Visible = false
	frame.Parent = canvas
	holder = frame
	for i = 1, MAX_STARS do
		local x, y = ManaStars.position(i)
		local starFrame = Instance.new("Frame")
		starFrame.Name = `Star{i}`
		starFrame.BackgroundTransparency = 1
		starFrame.Size = UDim2.fromOffset(ManaStars.SIZE, ManaStars.SIZE)
		starFrame.Position = UDim2.fromOffset(x, y)
		starFrame.Visible = false
		starFrame.Parent = frame
		local parts = Style.pixelArt(starFrame, 0, 0, STAR, { K = OUTLINE, L = EMPTY, R = EMPTY, H = EMPTY_SHINE }, 2)
		stars[i] = { frame = starFrame, parts = parts, state = -1 }
	end
end

--[[
	Draws this frame (Ui/Hud's RenderStepped): `survival` when the hearts show, `magic` when a
	magic weapon is selected, `armored` when the armor icons show. Returns how far the held item's
	name and the rows above it move up (0 while the stars are hidden).
]]
function ManaHud.render(now: number, survival: boolean, magic: boolean, armored: boolean): number
	local frame = holder
	if frame == nil then
		return 0
	end
	local mana, max = ManaState.get()
	local blink = now - ManaState.refusedAt() < BLINK_TIME
	local shown = ManaStars.shown(survival, magic or blink, mana, max, now - ManaState.changedAt())
	if frame.Visible ~= shown then
		frame.Visible = shown
	end
	if not shown then
		return 0
	end
	local bottom, raise = ManaStars.layout(layout.armorY, max, armored, layout.nameY)
	if bottom ~= drawnBottom then
		drawnBottom = bottom
		frame.Position = UDim2.fromOffset(0, bottom)
	end
	if max ~= drawnMax then
		local count = Mana.stars(max)
		for i, star in stars do
			star.frame.Visible = i <= count
		end
	end
	if mana ~= drawnMana or max ~= drawnMax then
		drawnMana, drawnMax = mana, max
		for i, star in stars do
			paint(star, ManaStars.state(mana, i))
		end
	end
	-- (Blinking every 0.15 s while it lasts.)
	local outline = blink and math.floor((now - ManaState.refusedAt()) / 0.15) % 2 == 0
	if outline ~= blinking then
		blinking = outline
		for _, star in stars do
			Style.paint(star.parts.K, if outline then BLINK_OUTLINE else OUTLINE)
		end
	end
	return raise
end

return ManaHud
