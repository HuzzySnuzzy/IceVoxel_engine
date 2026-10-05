--!strict
--[[
	The spectator menu on screen (Minecraft 1.20.1's SpectatorGui), in the hotbar's place: Ui/Hud
	builds it into its canvas and routes a spectator's keys, wheel and taps here. The menu itself
	is Ui/SpectatorMenu (pure).

	  look      the hotbar's bar with nine slots: "Teleport to Player" (a head), the players' head
	            shots, the page arrows and "Close Menu" (an X), drawn from Frames like the rest of
	            the HUD; disabled items are dimmed, enabled ones show their number key in the
	            corner, the selected slot has the hotbar's selection frame, and the selected item's
	            name (or the page's prompt) shows above the bar. It fades out 3 seconds after the
	            last key (a CanvasGroup) and closes after 5.
	  keys      1-9 open the menu, then select a slot, and use it when pressed again; the middle
	            click (also the touch "..." button and gamepad DPad up) opens it or uses the
	            selected slot; the wheel moves the selection while it is open (gamepad L1 / R1 too)
	            and otherwise changes the flying speed (`onFlyingSpeed`: Player/MovementController,
	            MouseHandler.onScroll). A click or tap on a slot of the open menu is its number key.
	  teleport  using a player sends Protocol SpectatorTeleport; the server moves the spectator
	            to their feet (Players/Teleport, Characters.teleportFeet). The menu stays open.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local SpectatorMenu = require(script.Parent.SpectatorMenu)
local Style = require(script.Parent.Style)

local SLOTS = SpectatorMenu.SLOTS
-- The label over the menu reaches this far (GUI pixels) past either end of the bar: the root
-- prompt is wider than the hotbar.
local LABEL_OVERHANG = 150
-- A disabled item is drawn at a quarter of its brightness (SpectatorGui.renderSlot).
local DIM = 0.25

--[[ Icons: 16 x 16 pixel art (Minecraft's spectator widgets, redrawn) ]]

local OUTLINE = Color3.fromRGB(24, 24, 24)

-- "Teleport to Player": a player's face.
local HEAD_ART = {
	"HHHHHHHH",
	"HHHHHHHH",
	"HSSSSSSH",
	"SSSSSSSS",
	"SWESSEWS",
	"SSSNNSSS",
	"SSMMMMSS",
	"SSMSSMSS",
}
local HEAD_PALETTE = {
	H = Color3.fromRGB(60, 40, 22),
	S = Color3.fromRGB(196, 140, 108),
	W = Color3.fromRGB(240, 240, 240),
	E = Color3.fromRGB(60, 70, 160),
	N = Color3.fromRGB(150, 98, 74),
	M = Color3.fromRGB(110, 60, 46),
}

local CLOSE_ART = {
	"................",
	"................",
	"..KK........KK..",
	"..KXK......KXK..",
	"...KXK....KXK...",
	"....KXK..KXK....",
	".....KXKKXK.....",
	"......KXXK......",
	"......KXXK......",
	".....KXKKXK.....",
	"....KXK..KXK....",
	"...KXK....KXK...",
	"..KXK......KXK..",
	"..KK........KK..",
	"................",
	"................",
}

local NEXT_ART = {
	"................",
	"................",
	"................",
	".......K........",
	".......KK.......",
	".......KAK......",
	"..KKKKKKAAK.....",
	"..KAAAAAAAAK....",
	"..KAAAAAAAAAK...",
	"..KAAAAAAAAK....",
	"..KKKKKKAAK.....",
	".......KAK......",
	".......KK.......",
	".......K........",
	"................",
	"................",
}

local function mirrored(art: { string }): { string }
	local rows = {}
	for i, row in art do
		rows[i] = string.reverse(row)
	end
	return rows
end
local PREVIOUS_ART = mirrored(NEXT_ART)

local ARROW_PALETTE = { K = OUTLINE, A = Color3.fromRGB(230, 230, 230) }
local CLOSE_PALETTE = { K = OUTLINE, X = Color3.fromRGB(230, 230, 230) }

local function dimmed(palette: { [string]: Color3 }, dim: boolean): { [string]: Color3 }
	if not dim then
		return palette
	end
	local out = {}
	for key, colour in palette do
		out[key] = Color3.new(colour.R * DIM, colour.G * DIM, colour.B * DIM)
	end
	return out
end

--[[ State ]]

local SpectatorGui = {}

local gui = SpectatorMenu.newGui()
local flyingSpeedHandler: ((steps: number) -> ())? = nil

-- Built by `build`.
type Cell = { icon: Frame, key: TextLabel, keyShadow: TextLabel, shown: string }
local layer: CanvasGroup? = nil
local cells: { Cell } = {}
local selectionFrame: Frame? = nil
local label: TextLabel? = nil
local labelShadow: TextLabel? = nil
local barX, barY = 0, 0

-- The players "Teleport to Player" lists: everyone else not spectating, by user id.
local function targets(): { SpectatorMenu.Player }
	local list = {}
	for _, player in Players:GetPlayers() do
		table.insert(list, {
			userId = player.UserId,
			name = player.DisplayName,
			spectator = GameMode.isSpectator(GameMode.of(player)),
		})
	end
	return SpectatorMenu.targets(list, Players.LocalPlayer.UserId)
end

local function perform(action: SpectatorMenu.Action?)
	if action and action.kind == "teleport" then
		ClientNet.send(Protocol.ClientMessage.SpectatorTeleport, Protocol.encodeSpectatorTeleport(action.userId))
	end
end

-- Is the menu open?
function SpectatorGui.isOpen(): boolean
	return SpectatorMenu.isOpen(gui)
end

-- Closes the menu (leaving spectator mode, death).
function SpectatorGui.close()
	SpectatorMenu.close(gui)
end

-- Number key 1..9.
function SpectatorGui.hotbarKey(slot: number)
	perform(SpectatorMenu.hotbarKey(gui, slot - 1, targets(), os.clock()))
end

-- The middle click (and the touch button): opens the menu or uses the selected slot.
function SpectatorGui.middleClick()
	perform(SpectatorMenu.middleClick(gui, targets(), os.clock()))
end

-- Gamepad L1 / R1 (`direction` -1 / +1): opens the menu, then moves the selection.
function SpectatorGui.step(direction: number)
	if not SpectatorMenu.isOpen(gui) then
		SpectatorMenu.open(gui, targets(), os.clock())
	else
		SpectatorMenu.scroll(gui, direction, os.clock())
	end
end

--[[
	The mouse wheel (`delta` as Roblox gives it: positive turned up): moves the selection while the
	menu is open (up: left), else changes the flying speed by whole notches (up: faster).
]]
function SpectatorGui.wheel(delta: number)
	if delta == 0 then
		return
	end
	local notches = if delta > 0 then 1 else -1
	if SpectatorMenu.isOpen(gui) then
		SpectatorMenu.scroll(gui, -notches, os.clock())
	elseif flyingSpeedHandler then
		flyingSpeedHandler(notches)
	end
end

-- The wheel turned `steps` notches while the menu is closed goes to `handler` (the flying speed).
function SpectatorGui.onFlyingSpeed(handler: (steps: number) -> ())
	flyingSpeedHandler = handler
end

--[[
	Builds the menu into the HUD's `canvas` (GUI pixels): its bar drawn by `drawBar(parent, x, y)`
	(the hotbar's look) at (x, y), the selection frame by `drawSelection(parent)`, and the label
	at `labelY`. Hidden until a spectator opens it.
]]
function SpectatorGui.build(
	canvas: Frame,
	x: number,
	y: number,
	labelY: number,
	drawBar: (parent: Instance, x: number, y: number) -> (),
	drawSelection: (parent: Instance) -> Frame
)
	barX, barY = x, y
	local group = Instance.new("CanvasGroup")
	group.Name = "SpectatorMenu"
	group.BackgroundTransparency = 1
	group.BorderSizePixel = 0
	group.Size = UDim2.fromScale(1, 1)
	group.ZIndex = 3
	group.Visible = false
	group.Parent = canvas
	layer = group
	drawBar(group, x, y)
	for slot = 1, SLOTS do
		local cellX = x + 1 + (slot - 1) * 20
		local icon = Instance.new("Frame")
		icon.Name = `Item{slot}`
		icon.BackgroundTransparency = 1
		icon.Position = UDim2.fromOffset(cellX + 2, y + 3)
		icon.Size = UDim2.fromOffset(16, 16)
		icon.ZIndex = 5
		icon.Parent = group
		-- The number key, at the item's bottom right.
		local key, keyShadow = Style.shadowText(
			group,
			tostring(slot),
			cellX + 2,
			y + 12,
			17,
			8,
			Style.Colour.Text,
			7,
			Enum.TextXAlignment.Right
		)
		-- (A tap on a slot is its number key.)
		local button = Instance.new("TextButton")
		button.Text = ""
		button.BackgroundTransparency = 1
		button.AutoButtonColor = false
		button.Selectable = false
		button.Position = UDim2.fromOffset(cellX, y + 1)
		button.Size = UDim2.fromOffset(20, 20)
		button.ZIndex = 9
		button.Parent = group
		button.Activated:Connect(function()
			if SpectatorMenu.isOpen(gui) then
				SpectatorGui.hotbarKey(slot)
			end
		end)
		cells[slot] = { icon = icon, key = key, keyShadow = keyShadow, shown = "" }
	end
	local selection = drawSelection(group)
	selection.ZIndex = 8
	selectionFrame = selection
	-- (Outside the group, which would cut a long prompt off at the hotbar's width.)
	local text, shadow = Style.shadowText(
		canvas,
		"",
		-LABEL_OVERHANG,
		labelY,
		canvas.Size.X.Offset + 2 * LABEL_OVERHANG,
		8,
		Style.Colour.Text,
		7,
		Enum.TextXAlignment.Center
	)
	text.Visible = false
	shadow.Visible = false
	label, labelShadow = text, shadow
end

-- Draws `item` into a slot's icon frame (rebuilt only when what it shows changes).
local function drawIcon(cell: Cell, item: SpectatorMenu.Item)
	local key = `{item.kind} {if item.player then item.player.userId else ""} {item.enabled}`
	if key == cell.shown then
		return
	end
	cell.shown = key
	local icon = cell.icon
	icon:ClearAllChildren()
	local dim = not item.enabled
	if item.kind == "teleport" then
		Style.pixelArt(icon, 0, 0, HEAD_ART, dimmed(HEAD_PALETTE, dim), 6, 2)
	elseif item.kind == "close" then
		Style.pixelArt(icon, 0, 0, CLOSE_ART, dimmed(CLOSE_PALETTE, dim), 6)
	elseif item.kind == "next" then
		Style.pixelArt(icon, 0, 0, NEXT_ART, dimmed(ARROW_PALETTE, dim), 6)
	elseif item.kind == "previous" then
		Style.pixelArt(icon, 0, 0, PREVIOUS_ART, dimmed(ARROW_PALETTE, dim), 6)
	elseif item.kind == "player" and item.player then
		-- The player's face, 12 x 12 two pixels in (PlayerFaceRenderer.draw(g, skin, 2, 2, 12)).
		local head = Instance.new("ImageLabel")
		head.BackgroundTransparency = 1
		head.BorderSizePixel = 0
		head.Position = UDim2.fromOffset(2, 2)
		head.Size = UDim2.fromOffset(12, 12)
		head.ScaleType = Enum.ScaleType.Crop
		head.Image = `rbxthumb://type=AvatarHeadShot&id={item.player.userId}&w=48&h=48`
		head.ImageColor3 = if dim then Color3.new(DIM, DIM, DIM) else Color3.new(1, 1, 1)
		head.ZIndex = 6
		head.Parent = icon
	end
end

--[[
	Once a frame: draws the menu while `shown` (the player spectates and no screen is open) and
	closes it once it has faded away.
]]
function SpectatorGui.render(now: number, shown: boolean)
	local group = layer
	if group == nil then
		return
	end
	local text, shadow = label, labelShadow
	local function hide()
		if group.Visible then
			group.Visible = false
		end
		if text and shadow and text.Visible then
			text.Visible = false
			shadow.Visible = false
		end
	end
	if not shown then
		if SpectatorMenu.isOpen(gui) then
			SpectatorMenu.close(gui)
		end
		hide()
		return
	end
	SpectatorMenu.update(gui, now)
	local menu = gui.menu
	local alpha = SpectatorMenu.alpha(gui, now)
	if menu == nil or alpha <= 0 then
		hide()
		return
	end
	group.Visible = true
	group.GroupTransparency = 1 - alpha
	for slot, cell in cells do
		local item = SpectatorMenu.item(menu, slot - 1)
		drawIcon(cell, item)
		local numbered = item.kind ~= "empty" and item.enabled
		cell.key.Visible = numbered
		cell.keyShadow.Visible = numbered
	end
	local selection = selectionFrame
	if selection then
		selection.Visible = menu.selected >= 0
		selection.Position = UDim2.fromOffset(barX - 1 + math.max(menu.selected, 0) * 20, barY - 1)
	end
	-- The selected item's name or the prompt (renderTooltip: not once nearly faded).
	if text and shadow then
		local line = SpectatorMenu.label(menu)
		if text.Text ~= line then
			text.Text = line
			shadow.Text = line
		end
		local visible = alpha * 255 > 3
		text.Visible = visible
		shadow.Visible = visible
		text.TextTransparency = 1 - alpha
		shadow.TextTransparency = 1 - alpha
	end
end

return SpectatorGui
