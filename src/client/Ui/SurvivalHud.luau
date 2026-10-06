--!strict
--[[
	Tough As Nails on the HUD (Ui/Hud builds it into its canvas, so the GUI scale is the hotbar's),
	from the state the server sends (Player/SurvivalState), survival and adventure only, as the
	hearts:

	  droplets     with thirst on: 10 droplets on the right above the hotbar, where Minecraft's
	               hunger sits (its 81 x 9 row level with the hearts), filled from the right as
	               hunger is (thirst 2 points a droplet, a half droplet its right half). Pixel art
	               like the hearts. Under TAN's Thirst effect (dirty water) they turn a sickly
	               green, as hunger's shanks do under Hunger; with no hydration left they jitter
	               like hunger without saturation (Gui.renderPlayerHealth: each droplet moves
	               -1..1 pixel on ticks where tick % (thirst x 3 + 1) == 0).
	  gauge        with temperature on: TAN's temperature orb, 13 pixels round, centred over the
	               hotbar between the hearts and the droplets, 30 pixels above the hotbar's top
	               (TAN's height - 52): pale blue icy, blue cold, green neutral, orange warm, red
	               hot. A small arrow beside it says where the level is going (up, orange: warming;
	               down, pale blue: cooling; none: on target).
	  edges        hypothermia and hyperthermia close in from the screen's edges, frost white-blue
	               or heat orange-red, as strong as they have got (Minecraft's powder snow outline,
	               alpha = the share of the 140 ticks frozen; TAN's heat overlay the same way).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Temperature = require(Shared.ToughAsNails.Temperature)

local SurvivalState = require(script.Parent.Parent.Player.SurvivalState)
local Style = require(script.Parent.Style)

-- Where Ui/Hud puts things (GUI pixels in its canvas).
export type Layout = {
	-- The canvas' width (the hotbar's), the droplets' row and the gauge's top left corner.
	width: number,
	rowY: number,
	gaugeX: number,
	gaugeY: number,
}

local SurvivalHud = {}

local TICK = 0.05
-- The edges reach this far into the screen (share of its height / width) at full strength.
local EDGE = 0.3
local EDGE_STRENGTH = 0.85

-- 9 x 9: K outline, L / R the left / right half, H a highlight (with the left half).
local DROPLET = {
	"....K....",
	"...KLK...",
	"..KHLRK..",
	".KHLLRRK.",
	".KHLLRRK.",
	"KHLLLRRRK",
	"KLLLLRRRK",
	".KLLLRRK.",
	"..KKKKK..",
}
-- 13 x 13: K outline, F fill, H highlight, D shade.
local ORB = {
	"....KKKKK....",
	"..KKFFFFFKK..",
	".KFHHFFFFFFK.",
	".KFHFFFFFFFK.",
	"KFHFFFFFFFFFK",
	"KFFFFFFFFFFFK",
	"KFFFFFFFFFFFK",
	"KFFFFFFFFFFDK",
	"KFFFFFFFFFFDK",
	".KFFFFFFFFDK.",
	".KFFFFFFFDDK.",
	"..KKDDDDDKK..",
	"....KKKKK....",
}
local UP = { "..A..", ".AAA.", "AAAAA", ".AAA.", ".AAA." }
local DOWN = { ".AAA.", ".AAA.", "AAAAA", ".AAA.", "..A.." }

local OUTLINE = Color3.fromRGB(16, 16, 16)
local WATER = Color3.fromRGB(48, 118, 230)
local WATER_SHINE = Color3.fromRGB(160, 210, 255)
local SICK = Color3.fromRGB(112, 160, 64)
local SICK_SHINE = Color3.fromRGB(176, 214, 120)
local EMPTY = Color3.fromRGB(28, 32, 44)
local EMPTY_SHINE = Color3.fromRGB(44, 50, 66)
local WARMING = Color3.fromRGB(255, 150, 40)
local COOLING = Color3.fromRGB(150, 210, 255)
local FROST = Color3.fromRGB(205, 235, 255)
local HEAT = Color3.fromRGB(255, 96, 32)

-- Orb colours by level: fill, highlight, shade.
local LEVEL_COLOURS: { [number]: { Color3 } } = {
	[-2] = { Color3.fromRGB(180, 230, 255), Color3.fromRGB(240, 250, 255), Color3.fromRGB(120, 180, 220) },
	[-1] = { Color3.fromRGB(70, 140, 230), Color3.fromRGB(150, 200, 255), Color3.fromRGB(40, 90, 170) },
	[0] = { Color3.fromRGB(120, 200, 90), Color3.fromRGB(190, 240, 160), Color3.fromRGB(70, 140, 50) },
	[1] = { Color3.fromRGB(245, 160, 40), Color3.fromRGB(255, 215, 130), Color3.fromRGB(190, 110, 20) },
	[2] = { Color3.fromRGB(225, 45, 30), Color3.fromRGB(255, 140, 110), Color3.fromRGB(150, 20, 15) },
}

type Droplet = { frame: Frame, parts: { [string]: { Frame } }, key: string, x: number }

local row: Frame? = nil
local droplets: { Droplet } = {}
local gauge: Frame? = nil
local orb: { [string]: { Frame } } = {}
local arrows: { up: Frame?, down: Frame? } = {}
local edgesGui: ScreenGui? = nil
local edges: { Frame } = {}
local lastLevel = math.huge
local lastEdge = ""
local tickCount = 0
local nextTick = 0

-- The state of droplet `i` (1 = rightmost) at `thirst` points: 0 empty, 1 half, 2 full.
function SurvivalHud.dropletState(thirst: number, i: number): number
	return math.clamp(thirst - (i - 1) * 2, 0, 2)
end

-- Does droplet `i` jitter this tick (Minecraft's rule for hunger, see the header)?
function SurvivalHud.jitters(hydration: number, thirst: number, tick: number): boolean
	return hydration <= 0 and tick % (thirst * 3 + 1) == 0
end

local function paintDroplet(droplet: Droplet, state: number, sick: boolean)
	local key = `{state}{sick}`
	if droplet.key == key then
		return
	end
	droplet.key = key
	local fill, shine = if sick then SICK else WATER, if sick then SICK_SHINE else WATER_SHINE
	Style.paint(droplet.parts.R, if state >= 1 then fill else EMPTY)
	Style.paint(droplet.parts.L, if state >= 2 then fill else EMPTY)
	Style.paint(droplet.parts.H, if state >= 2 then shine else EMPTY_SHINE)
end

local function newEdge(parent: Instance, anchor: Vector2, position: UDim2, size: UDim2, rotation: number): Frame
	local frame = Instance.new("Frame")
	frame.BorderSizePixel = 0
	frame.AnchorPoint = anchor
	frame.Position = position
	frame.Size = size
	frame.BackgroundTransparency = 1
	frame.Parent = parent
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new(0, 1)
	gradient.Parent = frame
	return frame
end

-- Builds the droplets and the gauge into Ui/Hud's `canvas`, and the edges in a screen of their own.
function SurvivalHud.build(canvas: Frame, layout: Layout)
	local thirstRow = Instance.new("Frame")
	thirstRow.Name = "Thirst"
	thirstRow.BackgroundTransparency = 1
	thirstRow.Position = UDim2.fromOffset(layout.width - 81, layout.rowY)
	thirstRow.Size = UDim2.fromOffset(81, 9)
	thirstRow.ZIndex = 2
	thirstRow.Visible = false
	thirstRow.Parent = canvas
	row = thirstRow
	for i = 1, 10 do
		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.fromOffset(9, 9)
		local x = 72 - (i - 1) * 8
		frame.Position = UDim2.fromOffset(x, 0)
		frame.Parent = thirstRow
		local parts = Style.pixelArt(frame, 0, 0, DROPLET, { K = OUTLINE, L = EMPTY, R = EMPTY, H = EMPTY_SHINE }, 1)
		droplets[i] = { frame = frame, parts = parts, key = "", x = x }
	end

	local orbFrame = Instance.new("Frame")
	orbFrame.Name = "Temperature"
	orbFrame.BackgroundTransparency = 1
	orbFrame.Position = UDim2.fromOffset(layout.gaugeX, layout.gaugeY)
	orbFrame.Size = UDim2.fromOffset(16, 16)
	orbFrame.ZIndex = 2
	orbFrame.Visible = false
	orbFrame.Parent = canvas
	gauge = orbFrame
	orb = Style.pixelArt(orbFrame, 1, 1, ORB, { K = OUTLINE }, 2)
	local up = Instance.new("Frame")
	up.BackgroundTransparency = 1
	up.Position = UDim2.fromOffset(16, 1)
	up.Size = UDim2.fromOffset(5, 5)
	up.Visible = false
	up.Parent = orbFrame
	Style.pixelArt(up, 0, 0, UP, { A = WARMING }, 2)
	local down = up:Clone()
	down:ClearAllChildren()
	down.Parent = orbFrame
	Style.pixelArt(down, 0, 0, DOWN, { A = COOLING }, 2)
	arrows.up, arrows.down = up, down

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelTemperatureOverlay"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -1
	gui.Enabled = false
	edges = {
		newEdge(gui, Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, EDGE), 90),
		newEdge(gui, Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, EDGE), -90),
		newEdge(gui, Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(EDGE, 1), 0),
		newEdge(gui, Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(EDGE, 1), 180),
	}
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	edgesGui = gui
end

local function setVisible(object: GuiObject?, visible: boolean)
	if object and object.Visible ~= visible then
		object.Visible = visible
	end
end

-- The frost or heat at the edges (strength 0..1).
local function renderEdges(colour: Color3, strength: number)
	local gui = edgesGui
	if gui == nil then
		return
	end
	local on = strength > 0
	if gui.Enabled ~= on then
		gui.Enabled = on
	end
	if not on then
		return
	end
	local key = `{colour}{math.floor(strength * 50)}`
	if key == lastEdge then
		return
	end
	lastEdge = key
	for _, edge in edges do
		edge.BackgroundColor3 = colour
		edge.BackgroundTransparency = 1 - strength * EDGE_STRENGTH
	end
end

--[[
	Draws this frame (Ui/Hud's RenderStepped): `survival` when the hearts show (survival,
	adventure, the HUD in play).
]]
function SurvivalHud.render(now: number, survival: boolean)
	local status = SurvivalState.get()
	local thirstShown = survival and status ~= nil and status.thirstOn
	local temperatureShown = survival and status ~= nil and status.temperatureOn
	setVisible(row, thirstShown)
	setVisible(gauge, temperatureShown)
	if status == nil or not temperatureShown then
		renderEdges(FROST, 0)
	end
	if status == nil then
		return
	end
	local ticked = now >= nextTick
	if ticked then
		nextTick = now + TICK
		tickCount += 1
	end

	if thirstShown then
		local sick = status.effect > 0
		for i, droplet in droplets do
			paintDroplet(droplet, SurvivalHud.dropletState(status.thirst, i), sick)
			if ticked then
				local y = if SurvivalHud.jitters(status.hydration, status.thirst, tickCount)
					then math.random(-1, 1)
					else 0
				if droplet.frame.Position.Y.Offset ~= y then
					droplet.frame.Position = UDim2.fromOffset(droplet.x, y)
				end
			end
		end
	end

	if temperatureShown then
		local level = math.clamp(status.level, Temperature.ICY, Temperature.HOT)
		if level ~= lastLevel then
			lastLevel = level
			local colours = LEVEL_COLOURS[level]
			Style.paint(orb.F, colours[1])
			Style.paint(orb.H, colours[2])
			Style.paint(orb.D, colours[3])
		end
		setVisible(arrows.up, status.target > status.level)
		setVisible(arrows.down, status.target < status.level)
		local frost, heat = status.frozen / Temperature.FREEZE_TICKS, status.heat / Temperature.FREEZE_TICKS
		if frost >= heat then
			renderEdges(FROST, frost)
		else
			renderEdges(HEAT, heat)
		end
	end
end

return SurvivalHud
