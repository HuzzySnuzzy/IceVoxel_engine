--!strict
--[[
	Minecraft's GUI Scale, pure (numbers in, numbers out: no Roblox APIs, so the tests run it).
	Minecraft 1.20.1's Window.calculateScale(guiScale):

	    i = 1; while (i != guiScale && i < w && i < h && w / (i + 1) >= 320 && h / (i + 1) >= 240) i++

	so the automatic scale ("Auto", setting 0) is the largest whole scale that still leaves 320 x 240
	GUI pixels on the screen, and every choice offered is 1 .. that largest (the option's range is
	recomputed for the window): Auto is always the largest, and each choice draws differently.
	1920 x 1080 is 4, 2560 x 1440 6, a 3840 x 2160 window 9 (Config.UiScale.MaxScale, 12, is only a
	sanity cap; the game capped it at 3 before, so its 1080p Auto was a quarter smaller than
	Minecraft's). Touch screens (phones are small, and their points are big) take eighths of
	min(w / 320, h / 240) instead, so the HUD is as big as fits: 667 x 375 is 1.5, 844 x 390 1.625.

	  auto       the automatic scale of a w x h screen (desktop: whole, at least 1; touch: eighths,
	             at least 0.5).
	  maxChoice  the largest whole choice offered (at least 1).
	  choices    { 0 (Auto), 1 .. maxChoice }: what the GUI Scale button cycles through here.
	  base       the scale a setting gives on this screen: Auto for 0; a choice above this screen's
	             largest acts as the largest (Minecraft keeps the stored choice and limits it, so
	             moving to a bigger screen brings it back).
	  fit        `base` shrunk so content of cw x ch GUI pixels fits an area of aw x ah screen pixels
	             with MARGIN around it (the inventory on a small window): whole scales at and above 1
	             on a desktop, eighths below 1 and on touch, never below MIN.
	  reference  for widgets drawn in fixed pixels at 1080p's Auto (the F3 text, the world map's
	             bar, billboards): base / Config.UiScale.ReferenceScale, at least
	             Config.UiScale.MinReference.

	Client Ui/UiScale feeds it the camera's viewport and the GUI Scale setting (Shared/
	PlayerSettings guiScale) and tells every interface root.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local GuiScale = {}

-- GUI pixels Minecraft keeps on screen at the automatic scale.
GuiScale.BASE_WIDTH = 320
GuiScale.BASE_HEIGHT = 240
-- Screen pixels kept free around fitted content.
GuiScale.MARGIN = 8
-- The largest and smallest scales.
GuiScale.MAX = math.max(1, math.floor(Config.UiScale.MaxScale))
GuiScale.MIN = 0.5

-- `value` floored to eighths.
local function eighths(value: number): number
	return math.floor(value * 8) / 8
end

-- The automatic scale of a w x h screen (see the header).
function GuiScale.auto(w: number, h: number, touch: boolean): number
	if touch then
		return math.clamp(
			eighths(math.min(w / GuiScale.BASE_WIDTH, h / GuiScale.BASE_HEIGHT)),
			GuiScale.MIN,
			GuiScale.MAX
		)
	end
	local i = 1
	while
		i < GuiScale.MAX
		and i < w
		and i < h
		and w / (i + 1) >= GuiScale.BASE_WIDTH
		and h / (i + 1) >= GuiScale.BASE_HEIGHT
	do
		i += 1
	end
	return i
end

-- The largest whole choice offered on a w x h screen.
function GuiScale.maxChoice(w: number, h: number, touch: boolean): number
	return math.max(1, math.floor(GuiScale.auto(w, h, touch)))
end

-- The choices offered on a w x h screen: 0 (Auto), then 1 .. maxChoice.
function GuiScale.choices(w: number, h: number, touch: boolean): { number }
	local list = { 0 }
	for choice = 1, GuiScale.maxChoice(w, h, touch) do
		table.insert(list, choice)
	end
	return list
end

-- The scale the GUI Scale setting `setting` (0 or nil: Auto) gives on a w x h screen.
function GuiScale.base(w: number, h: number, touch: boolean, setting: number?): number
	local auto = GuiScale.auto(w, h, touch)
	if setting == nil or setting ~= setting or setting < 1 then
		return auto
	end
	return math.min(math.floor(setting), auto)
end

-- `base` shrunk so cw x ch GUI pixels fit an aw x ah area (see the header).
function GuiScale.fit(base: number, cw: number, ch: number, aw: number, ah: number, touch: boolean): number
	local room = math.min((aw - 2 * GuiScale.MARGIN) / cw, (ah - 2 * GuiScale.MARGIN) / ch)
	local scale = math.min(base, room)
	if not touch and scale >= 1 then
		scale = math.floor(scale)
	else
		scale = eighths(scale)
	end
	return math.max(scale, GuiScale.MIN)
end

-- The UIScale of a widget drawn in fixed pixels at 1080p's Auto (see the header).
function GuiScale.reference(base: number): number
	return math.max(base / Config.UiScale.ReferenceScale, Config.UiScale.MinReference)
end

return GuiScale
