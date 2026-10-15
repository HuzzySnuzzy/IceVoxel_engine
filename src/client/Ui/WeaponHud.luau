--!strict
--[[
	The HUD of a firearm in hand, in the manner of DayZ, which counts no rounds on the screen (the
	inventory's HANDS and the icons do: Ui/InventoryScreen, Ui/ItemIcon):

	  indicator  a small word over the held item's box (Ui/Hud's weapon anchor, shown with the box,
	             which Ui/Hud holds while a firearm is in hand): "JAMMED" blinking red while the gun
	             is jammed, what a timed action does while it runs ("RELOADING", "LOADING" a round
	             by hand, "CLEARING" a jam), else the fire mode of a gun with more than one ("SEMI",
	             "AUTO"), dim.
	  bar        a one-pixel bar under the box: a timed action's progress (white), else the raise
	             (grey, filling over the raise time, then olive while the gun is up and may fire).
	  centre     raised over the shoulder in third person a dot of 2 x 2 GUI pixels, white with a
	             dark outline (Config.Weapons.ShoulderDot; Minecraft's crosshair and the mouse icon
	             are hidden meanwhile: Interaction/Firearms.hidesCrosshair, Player/AimCamera); in
	             the sights nothing, but a red dot through a red dot sight; a scope's zoom
	             (Player/AimCamera.scoped) draws the scope instead of the gun: black all round a
	             circle 0.92 of the screen's height across, with a fine black cross and heavier
	             posts at its edges (frames only, no pictures).

	Interaction/Firearms calls `render` every frame with what to show; nothing is written unless it
	changed, and nothing is created after `start`.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local Hud = require(script.Parent.Hud)
local Style = require(script.Parent.Style)
local UiScale = require(script.Parent.UiScale)

-- What the HUD shows (Interaction/Firearms fills one table and passes it every frame).
export type State = {
	-- A firearm in hand.
	held: boolean,
	-- "lowered", "raised" or "sights" (Player/AimRules.Posture).
	posture: string,
	-- The raise's progress (0..1: settled at 1).
	raise: number,
	-- A timed action's progress (nil: none) and its word.
	progress: number?,
	action: string?,
	jammed: boolean,
	-- The fire mode's word for guns with more than one (nil: none).
	mode: string?,
	-- A scope's zoom, and a red dot sight in the sights.
	scoped: boolean,
	redDot: boolean,
}

local WeaponHud = {}

local JAM_COLOUR = Color3.fromRGB(235, 60, 50)
local RED_DOT = Color3.fromRGB(255, 40, 30)
local OUTLINE = Color3.fromRGB(24, 24, 24)
local BAR_RAISING = Color3.fromRGB(150, 150, 150)
local BAR_BUSY = Color3.fromRGB(240, 240, 240)
-- The quickbar's olive.
local BAR_READY = Color3.fromRGB(110, 152, 13)
-- The jam word blinks this often (per second).
local BLINK = 2.5
-- The scope's circle (share of the screen's height) and its posts (screen pixels).
local SCOPE_SHARE = 0.92
local POST = 3

local started = false
local dot: Frame? = nil
local redDot: Frame? = nil
local scope: Frame? = nil
local scopeStroke: UIStroke? = nil
local tag: TextLabel? = nil
local track: Frame? = nil
local fill: Frame? = nil

-- What is drawn now (written only when it changes).
local shownDot, shownRed, shownScope = false, false, false
local shownTag, shownTagColour, shownTagT = "", Color3.new(), -1
local shownBar, shownBarColour = -1, Color3.new()

-- A centre mark: `size` GUI pixels of `colour` in a one-pixel dark outline.
local function centreMark(parent: Instance, name: string, size: number, colour: Color3): Frame
	local outer = Instance.new("Frame")
	outer.Name = name
	outer.AnchorPoint = Vector2.new(0.5, 0.5)
	outer.Position = UDim2.fromScale(0.5, 0.5)
	outer.Size = UDim2.fromOffset(size + 2, size + 2)
	outer.BackgroundColor3 = OUTLINE
	outer.BackgroundTransparency = 0.4
	outer.BorderSizePixel = 0
	outer.Visible = false
	local inner = Instance.new("Frame")
	inner.Position = UDim2.fromOffset(1, 1)
	inner.Size = UDim2.fromOffset(size, size)
	inner.BackgroundColor3 = colour
	inner.BorderSizePixel = 0
	inner.Parent = outer
	local scale = Instance.new("UIScale")
	scale.Parent = outer
	UiScale.follow(function()
		scale.Scale = UiScale.base()
	end)
	outer.Parent = parent
	return outer
end

-- A black bar of the scope's reticle (shares of the circle).
local function reticleBar(parent: Instance, x: number, y: number, w: number, h: number, px: number, py: number)
	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.fromScale(x, y)
	bar.Size = UDim2.new(w, px, h, py)
	bar.BackgroundColor3 = Color3.new(0, 0, 0)
	bar.BorderSizePixel = 0
	bar.Parent = parent
end

local function buildScope(parent: Instance): (Frame, UIStroke)
	local circle = Instance.new("Frame")
	circle.Name = "Scope"
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
	circle.Size = UDim2.fromScale(SCOPE_SHARE, SCOPE_SHARE)
	circle.SizeConstraint = Enum.SizeConstraint.RelativeYY
	circle.BackgroundTransparency = 1
	circle.BorderSizePixel = 0
	circle.Visible = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = circle
	-- (Black everywhere outside the circle: a stroke wider than the screen.)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 2000
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = circle
	-- A fine cross, and heavier posts from the edges to a third of the way in.
	reticleBar(circle, 0.5, 0.5, 1, 0, 0, 1)
	reticleBar(circle, 0.5, 0.5, 0, 1, 1, 0)
	reticleBar(circle, 1 / 6, 0.5, 1 / 3, 0, 0, POST)
	reticleBar(circle, 5 / 6, 0.5, 1 / 3, 0, 0, POST)
	reticleBar(circle, 0.5, 5 / 6, 0, 1 / 3, POST, 0)
	circle.Parent = parent
	return circle, stroke
end

function WeaponHud.start()
	if started then
		return
	end
	started = true
	local screen = UiScale.screenGui("IceVoxelWeaponHud", "Crosshair", { inset = true, full = true, kind = "scaled" })
	local root = Instance.new("Frame")
	root.Name = "Centre"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = screen
	dot = centreMark(root, "ShoulderDot", 2, Color3.new(1, 1, 1))
	redDot = centreMark(root, "RedDot", 2, RED_DOT)
	local circle, stroke = buildScope(root)
	scope, scopeStroke = circle, stroke
	UiScale.follow(function()
		local size = UiScale.viewport()
		stroke.Thickness = math.max(size.X, size.Y)
	end)
	screen.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
end

-- The indicator and the bar on the held item's box (Ui/Hud's weapon anchor, once it is made).
local function attach()
	local anchor, scaled = Hud.weaponAnchor()
	if anchor == nil then
		return
	end
	local label = Style.Dayz.label(anchor, "", 0, 0, 0, 0, "tiny", Style.Dayz.Colour.Text, 5, nil, scaled)
	label.Name = "Indicator"
	label.Position = UDim2.new(0, 0, 0, -9)
	label.Size = UDim2.new(1, 0, 0, 8)
	label.TextXAlignment = Enum.TextXAlignment.Center
	Style.Dayz.textStroke(label, "TextStrokeSoft")
	tag = label
	local back = Instance.new("Frame")
	back.Name = "Progress"
	back.Position = UDim2.new(0, 0, 1, 1)
	back.Size = UDim2.new(1, 0, 0, 1)
	back.BackgroundColor3 = OUTLINE
	back.BackgroundTransparency = 0.5
	back.BorderSizePixel = 0
	back.Visible = false
	back.ZIndex = 5
	back.Parent = anchor
	local bar = Instance.new("Frame")
	bar.Name = "Fill"
	bar.Size = UDim2.fromScale(0, 1)
	bar.BorderSizePixel = 0
	bar.ZIndex = 6
	bar.Parent = back
	track, fill = back, bar
end

-- Draws `state` (see the type) at `now` (os.clock()).
function WeaponHud.render(state: State, now: number)
	if tag == nil and started then
		attach()
	end
	local raised = state.held and state.posture ~= "lowered"
	local showDot = raised and state.posture == "raised" and Config.Weapons.ShoulderDot == true
	local showScope = raised and state.scoped
	local showRed = raised and state.posture == "sights" and state.redDot and not showScope
	if showDot ~= shownDot and dot then
		shownDot = showDot
		dot.Visible = showDot
	end
	if showRed ~= shownRed and redDot then
		shownRed = showRed
		redDot.Visible = showRed
	end
	if showScope ~= shownScope and scope then
		shownScope = showScope
		scope.Visible = showScope
		if scopeStroke then
			scopeStroke.Enabled = showScope
		end
	end

	-- The indicator.
	local text, colour, transparency = "", Style.Dayz.Colour.Text, 0
	if state.held then
		if state.jammed then
			text, colour = "JAMMED", JAM_COLOUR
			transparency = if math.floor(now * BLINK * 2) % 2 == 0 then 0 else 0.6
		elseif state.progress and state.action then
			text = state.action
		elseif state.mode then
			text, transparency = state.mode, 0.35
		end
	end
	local label = tag
	if label then
		if text ~= shownTag then
			shownTag = text
			label.Text = text
		end
		if colour ~= shownTagColour then
			shownTagColour = colour
			label.TextColor3 = colour
		end
		if transparency ~= shownTagT then
			shownTagT = transparency
			label.TextTransparency = transparency
		end
	end

	-- The bar.
	local share, barColour = -1, BAR_BUSY
	if state.held and state.progress then
		share = state.progress
	elseif raised then
		share = state.raise
		barColour = if state.raise >= 1 then BAR_READY else BAR_RAISING
	end
	share = if share < 0 then -1 else math.floor(share * 64) / 64
	if (share ~= shownBar or barColour ~= shownBarColour) and track and fill then
		shownBar, shownBarColour = share, barColour
		track.Visible = share >= 0
		if share >= 0 then
			fill.Size = UDim2.fromScale(share, 1)
			fill.BackgroundColor3 = barColour
		end
	end
end

return WeaponHud
