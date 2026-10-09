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
	          WorldListRules.MIN_SHOW seconds. On touch screens it sits right above Roblox's jump
	          and action buttons (and the HUD), by their real size. One position a frame while
	          shown, nothing built.
	  Toast   for operators (only they get the sizes): a toast as Ui/MusicToast's, in the top right
	          corner (under the Now Playing toast while that one shows, and dropping under one
	          that comes in over it; the status effect icons then move under it too), sliding in
	          with "World saved" and "1.4 MB of 64 MB (largest region 0.3 / 4 MB)", red when the
	          save failed or the world nears its most; it stays TOAST_SECONDS and slides out, as
	          wide as its line.
	Both are placed by Ui/HudLayout (UiScale.hud: `saving`, `save`; this tells Ui/UiScale when they
	show), at the GUI scale, and hidden with the HUD (the world map hides it: on narrower screens
	the icon would cover its weather bar, the toast its buttons). While the icon or the toast is
	up, one connection a frame does all of that; none otherwise.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local HudLayout = require(script.Parent.HudLayout)
local MusicToast = require(script.Parent.MusicToast)
local Style = require(script.Parent.Style)
local UiScale = require(script.Parent.UiScale)
local WorldListRules = require(script.Parent.WorldListRules)

-- GUI pixels: the icon's art and label (HudLayout.SAVING_WIDTH x SAVING_HEIGHT), the toast.
local ICON = 12
local LABEL = HudLayout.SAVING_WIDTH - ICON - 4
local TOAST_HEIGHT = HudLayout.TOAST_HEIGHT
local TOAST_MIN_WIDTH = HudLayout.TOAST_WIDTH
local TOAST_SECONDS = 5
local SLIDE = 0.45
local TEXT_X = 30

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

	-- (The whole screen: Ui/HudLayout's screen pixels. Over the HUD and the toasts, under the
	-- screens.)
	local gui = UiScale.screenGui("IceVoxelSaving", "Saving", { inset = true, full = true, kind = "scaled" })

	-- The icon, bottom right.
	local corner = Instance.new("Frame")
	corner.Name = "SavingIcon"
	corner.BackgroundTransparency = 1
	corner.Size = UDim2.fromOffset(HudLayout.SAVING_WIDTH, HudLayout.SAVING_HEIGHT)
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
	-- Whether the toast sits under the Now Playing toast (it showed when this one came, or came in
	-- over it); it never moves back up while it shows.
	local underMusic = false
	-- Whether the icon is up (it shows where Ui/HudLayout finds room for it).
	local iconUp = false
	-- Where Ui/HudLayout puts the icon and the toast (hidden while there is no room), at its scale.
	local function layout()
		local hud = UiScale.hud()
		local scale = hud.scale
		if cornerScale.Scale ~= scale then
			cornerScale.Scale = scale
			holderScale.Scale = scale
		end
		local place, toast = hud.saving, hud.save
		corner.Visible = iconUp and place ~= nil
		if place then
			corner.Position = UDim2.fromOffset(place.x, place.y)
		end
		holder.Visible = toast ~= nil
		if toast then
			holder.Position = UDim2.fromOffset(toast.x, toast.y)
		end
		holder.Size = UDim2.fromOffset(width, TOAST_HEIGHT)
	end
	layout()
	UiScale.hudChanged:Connect(layout)
	-- The toast's x (GUI pixels) out past the screen's right edge (its margin and notch too).
	local function hiddenX(): number
		local hud = UiScale.hud()
		local right = UiScale.viewport().X - (hud.area.x + hud.area.w)
		return width + 8 + math.ceil((right + UiScale.insets().right) / hud.scale)
	end

	-- One connection a frame while the icon or the toast is up (see the header): hidden with the
	-- HUD, the icon bobbing, the toast dropping under a Now Playing toast that came in over it.
	local shownAt = 0
	local watching: RBXScriptConnection? = nil
	local function watch()
		if watching then
			return
		end
		watching = RunService.RenderStepped:Connect(function()
			local shown = UiScale.hudShown()
			if gui.Enabled ~= shown then
				gui.Enabled = shown
			end
			if corner.Visible then
				icon.Position = UDim2.fromOffset(LABEL + 4, 2 - WorldListRules.bob(os.clock() - shownAt))
			end
			if panel.Visible and not underMusic and MusicToast.showing() then
				underMusic = true
				UiScale.setToast("save", width, true)
			end
		end)
	end
	local function unwatch()
		local connection = watching
		if connection == nil or iconUp or panel.Visible then
			return
		end
		watching = nil
		connection:Disconnect()
	end

	-- The icon: up while a save is in flight, and at least MIN_SHOW; bobbing meanwhile.
	local inFlight = false
	onSaving = function()
		inFlight = true
		if not iconUp then
			shownAt = os.clock()
			iconUp = true
			UiScale.setSaving(true)
			layout()
		end
		watch()
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
		iconUp = false
		UiScale.setSaving(false)
		layout()
		unwatch()
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
		if not panel.Visible then
			underMusic = MusicToast.showing()
			panel.Position = UDim2.fromOffset(hiddenX(), 0)
			panel.Visible = true
		end
		UiScale.setToast("save", width, underMusic)
		layout()
		watch()
		slide(0, Enum.EasingDirection.Out)
		task.delay(SLIDE + TOAST_SECONDS, function()
			if generation == mine then
				slide(hiddenX(), Enum.EasingDirection.In)
				task.delay(SLIDE, function()
					if generation == mine then
						panel.Visible = false
						UiScale.setToast("save", nil)
						unwatch()
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
