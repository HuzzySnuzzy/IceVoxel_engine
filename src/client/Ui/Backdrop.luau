--!strict
--[[
	What darkens the world behind an open screen (Ui/Screens owns one, in the screens' GUI under
	everything else).

	  inventory, creative   the survival look: on a mouse, a light black layer (Theme's Backdrop,
	                        t 0.85) under a vignette, black darkening towards the corners (one
	                        full-screen image of Masks.vignette: clear inside VIGNETTE_INNER of the
	                        way out, Theme's Vignette at the corners), and the world behind blurred
	                        (a BlurEffect of Config.Ui.InventoryBlur on the camera; 0: none); on a
	                        mouse where the vignette's image can't be made (no EditableImage), a
	                        darker uniform layer (BackdropTouch, t 0.70) in its place, the blur
	                        kept; on a touch screen that darker layer and no blur
	  panel                 another module's panel (out of the inventory family): Minecraft's dark
	                        layer, a little lighter at the bottom

	Rules:

	  * `setOpen(true, kind)` when a screen opens or the shown kind changes, `setOpen(false, kind)`
	    when it closes; nothing else drives it, and it writes only what changes. It adds no
	    ScreenGui and does nothing per frame; the vignette is drawn once, the first time it shows.
	  * It sits at ZIndex 0 and is never Active: clicks go through it to the screens' Modal button.
	  * The blur exists only while an inventory kind is open on a screen that is not touch, with or
	    without the vignette (the blur goes with the screen, the darker layer only stands in for
	    the vignette); it is off whenever the backdrop is closed or shows a panel.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local Masks = require(script.Parent.Masks)
local Style = require(script.Parent.Style)
local UiScale = require(script.Parent.UiScale)

export type Kind = "inventory" | "creative" | "panel"

export type Backdrop = {
	root: Frame,
	open: boolean,
	kind: Kind?,
	setOpen: (self: Backdrop, open: boolean, kind: Kind) -> (),
}

-- The vignette's image (stretched over the screen) and where it starts darkening (a share of the
-- way from the centre to a corner).
local VIGNETTE_W, VIGNETTE_H = 256, 144
local VIGNETTE_INNER = 0.45
-- Minecraft's layer behind a panel: its colour and its transparency at the top and the bottom.
local PANEL_COLOUR = Color3.fromRGB(16, 16, 16)
local PANEL_TOP, PANEL_BOTTOM = 0.25, 0.19

type Self = Backdrop & {
	fade: UIGradient,
	-- The vignette's image (made the first time it shows), and whether it can't be made.
	vignette: ImageLabel?,
	noVignette: boolean,
	blur: BlurEffect?,
	-- What the layer shows: "" closed, "panel", "survival" (the light layer and the vignette) or
	-- "dark" (BackdropTouch: touch, or a mouse without the vignette).
	shown: string,
}

local Backdrop = {}
Backdrop.__index = Backdrop

-- The backdrop in `gui` (the screens' GUI, which is itself enabled only while a screen is open).
function Backdrop.new(gui: Instance): Backdrop
	local root = Instance.new("Frame")
	root.Name = "Backdrop"
	root.BackgroundColor3 = PANEL_COLOUR
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = 0
	root.Visible = false
	root.Parent = gui
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new(PANEL_TOP, PANEL_BOTTOM)
	fade.Parent = root
	local self = {
		root = root,
		open = false,
		kind = nil,
		fade = fade,
		vignette = nil,
		noVignette = false,
		blur = nil,
		shown = "",
	}
	return (setmetatable(self, Backdrop) :: any) :: Backdrop
end

-- The vignette's image, made the first time (nil when no image can be made).
local function vignetteOf(self: Self): ImageLabel?
	local made = self.vignette
	if made or self.noVignette then
		return made
	end
	local Dayz = Style.Dayz
	local edge = 1 - Dayz.Alpha.Vignette
	local content = Dayz.maskContent("Vignette", function(): Masks.Mask
		return Masks.vignette(VIGNETTE_W, VIGNETTE_H, VIGNETTE_INNER, edge)
	end)
	if content == nil then
		self.noVignette = true
		return nil
	end
	local image = Instance.new("ImageLabel")
	image.Name = "Vignette"
	image.BackgroundTransparency = 1
	image.BorderSizePixel = 0
	image.Size = UDim2.fromScale(1, 1)
	image.ImageContent = content
	image.ImageColor3 = Dayz.Colour.Vignette
	image.ZIndex = 1
	image.Visible = false
	image.Parent = self.root
	self.vignette = image
	return image
end

-- The world's blur on the camera (made the first time), on or off; writes only what changes (a
-- new camera gets it on the next open).
local function setBlur(self: Self, on: boolean)
	local size = Config.Ui.InventoryBlur
	local blur = self.blur
	if on and size > 0 then
		if blur == nil then
			local made = Instance.new("BlurEffect")
			made.Name = "IceVoxelInventoryBlur"
			made.Size = size
			blur = made
			self.blur = made
		end
		assert(blur, "blur")
		local camera = Workspace.CurrentCamera
		if blur.Parent ~= camera then
			blur.Parent = camera
		end
		if not blur.Enabled then
			blur.Enabled = true
		end
	elseif blur and blur.Enabled then
		blur.Enabled = false
	end
end

function Backdrop.setOpen(self: Self, open: boolean, kind: Kind)
	self.open = open
	self.kind = if open then kind else nil
	-- (An inventory kind on a screen that is not touch: the blur, and the vignette if it can be.)
	local mouse = open and kind ~= "panel" and not UiScale.touch()
	local shown = ""
	if open then
		if kind == "panel" then
			shown = "panel"
		else
			shown = if mouse and vignetteOf(self) then "survival" else "dark"
		end
	end
	setBlur(self, mouse)
	if shown == self.shown then
		return
	end
	self.shown = shown
	local Dayz = Style.Dayz
	local root = self.root
	root.Visible = open
	self.fade.Enabled = shown == "panel"
	if shown == "panel" then
		root.BackgroundColor3 = PANEL_COLOUR
		root.BackgroundTransparency = 0
	elseif shown ~= "" then
		local key = if shown == "survival" then "Backdrop" else "BackdropTouch"
		root.BackgroundColor3 = Dayz.Colour[key]
		root.BackgroundTransparency = Dayz.Alpha[key]
	end
	local vignette = self.vignette
	if vignette then
		vignette.Visible = shown == "survival"
	end
end

return Backdrop
