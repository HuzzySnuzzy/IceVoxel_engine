--!strict
--[[
	The banner of a new Age (Shared/Progression/Ages): when this player reaches one
	(Player/ProgressionState.ageReached, with the challenge fanfare), the Age's name fades in big in
	the upper middle of the screen, in the Age's colour, under a small "A new Age begins" and over
	what it opens ("37 new recipes"), as Minecraft's title command shows a title and subtitle: fade
	in FADE_IN, stay HOLD, fade out FADE_OUT (Minecraft's /title times 10, 70, 20 ticks). Ages
	reached together (a command, a big reward) show one after another. A 220 x 44 GUI pixel panel
	scaled like the HUD (Style.guiScale, the GUI Scale setting).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Progression = require(Shared.Progression)

local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local Style = require(script.Parent.Style)

local WIDTH, HEIGHT = 220, 44
local FADE_IN, HOLD, FADE_OUT = 0.5, 3.5, 1
-- The banner's top, as a share of the screen's height.
local TOP = 0.22
-- The name's text size (GUI pixels: twice the HUD's).
local NAME_SIZE = 16

local AgeToast = {}

local started = false
local queue: { Progression.Age } = {}
local showing = false

type Line = { label: TextLabel, shadow: TextLabel }

function AgeToast.start()
	if started then
		return
	end
	started = true
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelAgeToast"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- (Over the world and the HUD, under the screens.)
	gui.DisplayOrder = 11

	local holder = Instance.new("Frame")
	holder.Name = "AgeToast"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.fromScale(0.5, TOP)
	holder.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = holder

	local function line(text: string, y: number, h: number, colour: Color3, size: number): Line
		local label, shadow =
			Style.shadowText(holder, text, 0, y, WIDTH, h, colour, 5, Enum.TextXAlignment.Center, size)
		return { label = label, shadow = shadow }
	end
	local top = line("A new Age begins", 0, 10, Style.Colour.Gray, Style.TEXT_SIZE)
	local name = line("", 12, NAME_SIZE + 2, Style.Colour.Text, NAME_SIZE)
	local bottom = line("", 34, 10, Style.Colour.Text, Style.TEXT_SIZE)
	local lines = { top, name, bottom }

	local function layout()
		local camera = workspace.CurrentCamera
		local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
		scale.Scale = Style.guiScale(viewport, WIDTH, HEIGHT, UserInputService.TouchEnabled)
	end
	layout()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
	end
	Style.scaleChanged:Connect(layout)

	local function fade(transparency: number, seconds: number): Tween?
		local last: Tween? = nil
		for _, entry in lines do
			for _, label in { entry.label, entry.shadow } do
				local tween = TweenService:Create(label, TweenInfo.new(seconds), { TextTransparency = transparency })
				tween:Play()
				last = tween
			end
		end
		return last
	end

	local function showNext()
		local age = table.remove(queue, 1)
		if age == nil then
			showing = false
			holder.Visible = false
			return
		end
		showing = true
		local colour = Color3.fromRGB(age.color[1], age.color[2], age.color[3])
		name.label.Text = age.name
		name.shadow.Text = age.name
		name.label.TextColor3 = colour
		name.shadow.TextColor3 = Style.shadowOf(colour)
		local count = #age.recipes
		local text = if count > 0 then `{count} new recipe{if count == 1 then "" else "s"}` else ""
		bottom.label.Text = text
		bottom.shadow.Text = text
		for _, entry in lines do
			entry.label.TextTransparency = 1
			entry.shadow.TextTransparency = 1
		end
		holder.Visible = true
		fade(0, FADE_IN)
		task.delay(FADE_IN + HOLD, function()
			local tween = fade(1, FADE_OUT)
			if tween then
				tween.Completed:Wait()
			end
			showNext()
		end)
	end

	ProgressionState.ageReached:Connect(function(age: Progression.Age)
		table.insert(queue, age)
		if not showing then
			showNext()
		end
	end)
	gui.Parent = playerGui
end

return AgeToast
