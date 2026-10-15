--!strict
--[[
	What darkens the world behind an open screen (Ui/Screens owns one, in the screens' GUI under
	everything else).

	Rules:

	  * `setOpen(true, kind)` when a screen opens or the shown kind changes (the inventory, the
	    creative screen, another module's panel), `setOpen(false, kind)` when it closes; nothing
	    else drives it. What each kind gets (a darker layer, a vignette, a blur of the world) is
	    this module's; it adds no ScreenGui and nothing per frame.
	  * It sits at ZIndex 0 and is never Active: clicks go through it to the screens' Modal button.

	This version is Minecraft's: one dark layer, a little lighter at the bottom, for every kind.
]]

export type Kind = "inventory" | "creative" | "panel"

export type Backdrop = {
	root: Frame,
	open: boolean,
	kind: Kind?,
	setOpen: (self: Backdrop, open: boolean, kind: Kind) -> (),
}

local Backdrop = {}
Backdrop.__index = Backdrop

-- The backdrop in `gui` (the screens' GUI, which is itself enabled only while a screen is open).
function Backdrop.new(gui: Instance): Backdrop
	local root = Instance.new("Frame")
	root.Name = "Backdrop"
	root.BackgroundColor3 = Color3.fromRGB(16, 16, 16)
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = 0
	root.Parent = gui
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new(0.25, 0.19)
	fade.Parent = root
	local self = { root = root, open = false, kind = nil }
	return (setmetatable(self, Backdrop) :: any) :: Backdrop
end

function Backdrop.setOpen(self: Backdrop, open: boolean, kind: Kind)
	self.open = open
	self.kind = if open then kind else nil
	if self.root.Visible ~= open then
		self.root.Visible = open
	end
end

return Backdrop
