--!strict
--[[
	The saving icon, the "World saved" toast and what the title screen hears of saving (the
	server's WorldSave messages, World/WorldSave; the rules in Ui/WorldListRules).

	  Listen  `listen` (the client boot, before the title screen) owns the WorldSave messages
	          (Net/ClientNet routes a type to one handler): whether worlds can be saved here
	          (`state`, `stateChanged`: the title screen's Load World and its red line) and a
	          load's progress (`loading`: "Loading world: 12 / 40"); saving and saved go to the
	          icon and the toast once `start` built them (in the world).
	  Icon    Bedrock's saving indicator: a little grass block in the bottom right corner, bobbing,
	          with "Saving..." beside it, while a save is in flight (everyone sees it: a save may
	          cost the server a frame, and the icon says why) and at least
	          WorldListRules.MIN_SHOW seconds. On touch screens it sits higher, clear of the jump
	          and action buttons. One position a frame while shown, nothing built.
	  Toast   for operators (only they get the sizes): a toast as Ui/MusicToast's, in the top right
	          corner (under the Now Playing toast while that one shows), sliding in with "World
	          saved" and "1.4 MB of 64 MB (largest region 0.3 / 4 MB)", red when the save failed
	          or the world nears its most; it stays TOAST_SECONDS and slides out, as wide as its
	          line.
	Scaled like the HUD (Style.guiScale, the GUI Scale setting).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local MusicToast = require(script.Parent.MusicToast)
local Style = require(script.Parent.Style)
local WorldListRules = require(script.Parent.WorldListRules)

-- GUI pixels: the icon's art, its corner margin (and above the touch buttons), the toast.
local ICON = 12
local LABEL = 64
local MARGIN = 6
local TOUCH_RAISE = 150
local TOAST_HEIGHT = 32
local TOAST_MIN_WIDTH = 160
local TOAST_SECONDS = 5
local SLIDE = 0.45
local TEXT_X = 30
-- Screen pixels from the right edge.
local RIGHT = 16

-- A grass block from the front: L the grass's light top, G grass, D dirt, S dirt's shade.
local BLOCK_ART = {
	"LLLLLLLLLLLL",
	"GGLGGGGLGGGG",
	"GGGGGGGGGGLG",
	"DGDGGDGGDGGD",
	"DDDDDGDDDDDD",
	"DDSDDDDDSDDD",
	"DDDDDDSDDDDD",
	"SDDDDDDDDDSD",
	"DDDDSDDDDDDD",
	"DDDDDDDDSDDD",
	"DSDDDDDDDDDD",
	"SSSSSSSSSSSS",
}
local BLOCK_PALETTE = {
	G = Color3.fromRGB(92, 158, 62),
	L = Color3.fromRGB(128, 196, 86),
	D = Color3.fromRGB(121, 85, 58),
	S = Color3.fromRGB(92, 64, 44),
}
local FACE = Color3.fromRGB(33, 33, 38)
local EDGE = Color3.fromRGB(86, 86, 96)

local SaveIndicator = {}

local listening = false
local started = false
local saveState: number? = nil
local saveReason = ""
local stateEvent = Instance.new("BindableEvent")
local loadingEvent = Instance.new("BindableEvent")
-- Fires () when whether worlds can be saved here changed (`state`).
SaveIndicator.stateChanged = stateEvent.Event
-- Fires (done: number, total: number) as a world loads.
SaveIndicator.loading = loadingEvent.Event

-- The icon's and the toast's handlers (once `start` built them).
local onSaving: (() -> ())? = nil
local onSaved: ((status: Protocol.SaveStatus) -> ())? = nil

-- Whether worlds can be saved here (Protocol.SaveState; nil: not heard yet) and why not.
function SaveIndicator.state(): (number?, string)
	return saveState, saveReason
end

-- Starts hearing WorldSave messages (before the title screen).
function SaveIndicator.listen()
	if listening then
		return
	end
	listening = true
	ClientNet.on(Protocol.ServerMessage.WorldSave, function(payload: buffer)
		local status = Protocol.decodeWorldSave(payload)
		if status == nil then
			return
		end
		local op = status.op
		if op == Protocol.SaveOp.State then
			saveState, saveReason = status.state, status.text or ""
			stateEvent:Fire()
		elseif op == Protocol.SaveOp.Loading then
			loadingEvent:Fire(status.done or 0, status.total or 0)
		elseif op == Protocol.SaveOp.Saving then
			local handler = onSaving
			if handler then
				handler()
			end
		elseif op == Protocol.SaveOp.Saved then
			local handler = onSaved
			if handler then
				handler(status)
			end
		end
	end)
end

-- Builds the icon and the toast (in the world).
function SaveIndicator.start()
	if started then
		return
	end
	started = true
	SaveIndicator.listen()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelSaving"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	-- (Over the HUD and the toasts, under the screens.)
	gui.DisplayOrder = 8

	-- The icon, bottom right.
	local corner = Instance.new("Frame")
	corner.Name = "SavingIcon"
	corner.AnchorPoint = Vector2.new(1, 1)
	corner.BackgroundTransparency = 1
	corner.Size = UDim2.fromOffset(LABEL + ICON + 4, ICON + 4)
	corner.Visible = false
	corner.Parent = gui
	local cornerScale = Instance.new("UIScale")
	cornerScale.Parent = corner
	local icon = Instance.new("Frame")
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromOffset(ICON, ICON)
	icon.Position = UDim2.fromOffset(LABEL + 4, 2)
	icon.Parent = corner
	Style.pixelArt(icon, 0, 0, BLOCK_ART, BLOCK_PALETTE, 2)
	Style.shadowText(corner, "Saving...", 0, 4, LABEL, 10, Style.Colour.Gray, 2, Enum.TextXAlignment.Right)

	-- The toast, top right.
	local holder = Instance.new("Frame")
	holder.Name = "SaveToast"
	holder.AnchorPoint = Vector2.new(1, 0)
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(TOAST_MIN_WIDTH, TOAST_HEIGHT)
	holder.Parent = gui
	local holderScale = Instance.new("UIScale")
	holderScale.Parent = holder
	local panel = Style.frame(holder, 0, 0, TOAST_MIN_WIDTH, TOAST_HEIGHT, Color3.new(0, 0, 0), 1)
	panel.Visible = false
	local edge = Style.frame(panel, 1, 1, TOAST_MIN_WIDTH - 2, TOAST_HEIGHT - 2, EDGE, 2)
	local face = Style.frame(panel, 2, 2, TOAST_MIN_WIDTH - 4, TOAST_HEIGHT - 4, FACE, 3)
	Style.pixelArt(panel, 10, 10, BLOCK_ART, BLOCK_PALETTE, 4)
	local title, titleShadow = Style.shadowText(panel, "", TEXT_X, 7, 400, 10, Style.Colour.Yellow, 5)
	local line, lineShadow = Style.shadowText(panel, "", TEXT_X, 18, 400, 10, Style.Colour.Text, 5)

	local width = TOAST_MIN_WIDTH
	local function layout()
		local camera = workspace.CurrentCamera
		local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
		local touch = UserInputService.TouchEnabled
		local scale = Style.guiScale(viewport, TOAST_MIN_WIDTH, TOAST_HEIGHT, touch)
		cornerScale.Scale = scale
		holderScale.Scale = scale
		corner.Position = UDim2.new(1, -MARGIN * scale, 1, -(MARGIN + (if touch then TOUCH_RAISE else 0)) * scale)
		local top, toastScale = MusicToast.top()
		if MusicToast.showing() then
			top += (TOAST_HEIGHT + 4) * toastScale
		end
		holder.Position = UDim2.new(1, -RIGHT, 0, top)
		holder.Size = UDim2.fromOffset(width, TOAST_HEIGHT)
	end
	layout()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
	end
	Style.scaleChanged:Connect(layout)

	-- The icon: up while a save is in flight, and at least MIN_SHOW; bobbing meanwhile.
	local inFlight = false
	local shownAt = 0
	local bobbing: RBXScriptConnection? = nil
	onSaving = function()
		inFlight = true
		if not corner.Visible then
			shownAt = os.clock()
			corner.Visible = true
		end
		if bobbing == nil then
			bobbing = RunService.RenderStepped:Connect(function()
				icon.Position = UDim2.fromOffset(LABEL + 4, 2 - WorldListRules.bob(os.clock() - shownAt))
			end)
		end
	end
	local function hideIcon()
		if inFlight then
			return
		end
		local since = os.clock() - shownAt
		if WorldListRules.iconShown(false, since) then
			task.delay(WorldListRules.MIN_SHOW - since, hideIcon)
			return
		end
		corner.Visible = false
		local connection = bobbing
		bobbing = nil
		if connection then
			connection:Disconnect()
		end
	end

	-- The toast.
	local generation = 0
	local tween: Tween? = nil
	local function slide(x: number, direction: Enum.EasingDirection)
		if tween then
			tween:Cancel()
		end
		local nextTween = TweenService:Create(
			panel,
			TweenInfo.new(SLIDE, Enum.EasingStyle.Quad, direction),
			{ Position = UDim2.fromOffset(x, 0) }
		)
		tween = nextTween
		nextTween:Play()
	end
	local function showToast(heading: string, text: string, warn: boolean)
		generation += 1
		local mine = generation
		width = math.max(TOAST_MIN_WIDTH, TEXT_X + math.max(Style.textWidth(heading), Style.textWidth(text)) + 8)
		panel.Size = UDim2.fromOffset(width, TOAST_HEIGHT)
		edge.Size = UDim2.fromOffset(width - 2, TOAST_HEIGHT - 2)
		face.Size = UDim2.fromOffset(width - 4, TOAST_HEIGHT - 4)
		title.Text, titleShadow.Text = heading, heading
		line.Text, lineShadow.Text = text, text
		local colour = if warn then Style.Colour.Red else Style.Colour.Yellow
		title.TextColor3 = colour
		titleShadow.TextColor3 = Style.shadowOf(colour)
		layout()
		if not panel.Visible then
			panel.Position = UDim2.fromOffset(width + RIGHT + 8, 0)
			panel.Visible = true
		end
		slide(0, Enum.EasingDirection.Out)
		task.delay(SLIDE + TOAST_SECONDS, function()
			if generation == mine then
				slide(width + RIGHT + 8, Enum.EasingDirection.In)
				task.delay(SLIDE, function()
					if generation == mine then
						panel.Visible = false
					end
				end)
			end
		end)
	end
	onSaved = function(status: Protocol.SaveStatus)
		inFlight = false
		hideIcon()
		local heading, text, warn = WorldListRules.toast(status)
		if heading then
			showToast(heading, text, warn)
		end
	end
	gui.Parent = playerGui
end

return SaveIndicator
