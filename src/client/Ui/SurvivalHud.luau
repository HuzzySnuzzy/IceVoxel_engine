--!strict
--[[
	Hypothermia and hyperthermia on the screen (Tough As Nails, from the state the server sends:
	Player/SurvivalState): frost white-blue or heat orange-red closes in from the screen's edges, as
	strong as they have got (Minecraft's powder snow outline, alpha = the share of
	Temperature.EXTREME_TICKS frozen; TAN's heat overlay the same way), whichever is the stronger.

	  edges   four strips over the whole screen (EDGE of its height or width deep), each a
	          UIGradient from the edge inwards, in their own ScreenGui (IceVoxelTemperatureOverlay,
	          the "Frost" layer: screen-relative, notches included, under everything else),
	          disabled while nothing shows.
	  when    survival and adventure only, with temperature on; Ui/Hud calls `renderEdges` every
	          frame, before its open-screen early return, so the edges keep up while a screen is
	          open. Painted only when the colour or the strength (in fiftieths) changes.

	The rest of Tough As Nails and Minecraft's hunger on the HUD (thirst, food, temperature, Climate
	Clemency, Internal Warmth and Chill, a held Thermometer's reading) is the status icons'
	(Ui/StatusCluster) and the item-in-hands box's (Ui/Hud).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)
local Temperature = require(Shared.ToughAsNails.Temperature)

local UiScale = require(script.Parent.UiScale)

local SurvivalHud = {}

-- The edges reach this far into the screen (share of its height / width) at full strength.
local EDGE = 0.3
local EDGE_STRENGTH = 0.85
local FROST = Color3.fromRGB(205, 235, 255)
local HEAT = Color3.fromRGB(255, 96, 32)

local edgesGui: ScreenGui? = nil
local edges: { Frame } = {}
local lastColour: Color3? = nil
local lastStrength = -1

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

-- Builds the edges in a screen of their own (once).
function SurvivalHud.buildEdges()
	if edgesGui then
		return
	end
	-- (Screen-relative edges over the whole screen, under everything else.)
	local gui = UiScale.screenGui(
		"IceVoxelTemperatureOverlay",
		"Frost",
		{ inset = true, full = true, kind = "screen", enabled = false }
	)
	edges = {
		newEdge(gui, Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, EDGE), 90),
		newEdge(gui, Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, EDGE), -90),
		newEdge(gui, Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(EDGE, 1), 0),
		newEdge(gui, Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(EDGE, 1), 180),
	}
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	edgesGui = gui
end

--[[
	Draws this frame's edges from `status` (the survival state while the player is survival-like,
	else nil: no edges).
]]
function SurvivalHud.renderEdges(status: Protocol.SurvivalStatus?)
	local gui = edgesGui
	if gui == nil then
		return
	end
	local colour, strength = FROST, 0
	if status and status.temperatureOn then
		local frost = status.frozen / Temperature.EXTREME_TICKS
		local heat = status.heat / Temperature.EXTREME_TICKS
		if frost >= heat then
			colour, strength = FROST, frost
		else
			colour, strength = HEAT, heat
		end
	end
	local on = strength > 0
	if gui.Enabled ~= on then
		gui.Enabled = on
	end
	if not on then
		return
	end
	local step = math.floor(strength * 50)
	if colour == lastColour and step == lastStrength then
		return
	end
	lastColour, lastStrength = colour, step
	for _, edge in edges do
		edge.BackgroundColor3 = colour
		edge.BackgroundTransparency = 1 - math.min(strength, 1) * EDGE_STRENGTH
	end
end

return SurvivalHud
