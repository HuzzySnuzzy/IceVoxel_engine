--!strict
--[[
	The "Now Playing" toast, as Minecraft's toasts: a 160 x 32 GUI pixel panel that slides in from
	the right edge of the screen when a track starts (Audio/Music), shows a music disc, "Now
	Playing" in yellow and the track's title, stays Config.Music.ToastSeconds (5) and slides back
	out ("swooshes away"). A new track's toast replaces the one showing.

	It sits in the top right corner in Ui/HudLayout's first toast slot (UiScale.hud().music: under
	the minimap and its coordinates line, under the Map button on touch screens, else in the
	corner itself, at the GUI scale), and tells Ui/UiScale while it shows, so the "World saved"
	toast goes under it and the status effect icons under both. It hides with the HUD (the world
	map hides it). `setEnabled` (the player's Music Toasts setting) stops new toasts; one showing
	slides out.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local Style = require(script.Parent.Style)
local UiScale = require(script.Parent.UiScale)

-- Minecraft's toast (GUI pixels).
local WIDTH, HEIGHT = 160, 32
-- Seconds sliding in and out (Minecraft's toasts take 600 ms each way, eased).
local SLIDE = 0.45
-- The text: left edge, lines and the room for the title.
local TEXT_X = 30
local TITLE_Y, NAME_Y = 7, 18
local TEXT_W = WIDTH - TEXT_X - 6

-- A music disc (16 x 16): # rim, K disc, S shine, L label; "." shows the panel through it.
local DISC = {
	".....######.....",
	"...##KKKKKK##...",
	"..#KKKKSSKKKK#..",
	".#KKKSSKKKKKKK#.",
	".#KKSKKLLLLKKK#.",
	"#KKSKKLLLLLLKKK#",
	"#KKKKLLL..LLLKK#",
	"#KKKKLL....LLKK#",
	"#KKKKLL....LLKK#",
	"#KKKKLLL..LLLKK#",
	"#KKKKKLLLLLLKKK#",
	".#KKKKKLLLLKKK#.",
	".#KKKKKKKKKKKK#.",
	"..#KKKKKKKKKK#..",
	"...##KKKKKK##...",
	".....######.....",
}
local DISC_PALETTE = {
	["#"] = Color3.fromRGB(16, 16, 16),
	K = Color3.fromRGB(44, 44, 48),
	S = Color3.fromRGB(96, 96, 104),
	L = Color3.fromRGB(87, 189, 87),
}
-- Minecraft's toast: a dark face with a lighter edge.
local FACE = Color3.fromRGB(33, 33, 38)
local EDGE = Color3.fromRGB(86, 86, 96)

local MusicToast = {}

local started = false
local enabled = true
local root: Frame? = nil
local panel: Frame? = nil
local nameLabel: TextLabel? = nil
local nameShadow: TextLabel? = nil
local uiScale: UIScale? = nil
-- Bumped by every show, so an older toast's timer never slides a newer one out.
local generation = 0
local tween: Tween? = nil
-- Hides the toasts with the HUD while one shows (one connection a frame then, none otherwise).
local following: RBXScriptConnection? = nil

-- `text` cut to fit `width` GUI pixels, with "..." when it was cut.
local function fitted(text: string, width: number): string
	if Style.textWidth(text) <= width then
		return text
	end
	local length = utf8.len(text) or #text
	while length > 0 do
		length -= 1
		local cut = string.sub(text, 1, (utf8.offset(text, length + 1) or (#text + 1)) - 1) .. "..."
		if Style.textWidth(cut) <= width then
			return cut
		end
	end
	return "..."
end

-- Panel x (GUI pixels) when hidden: out past the screen's right edge (its margin and notch too).
local function hiddenX(): number
	local insets = UiScale.insets()
	local layout = UiScale.hud()
	local right = UiScale.viewport().X - (layout.area.x + layout.area.w)
	return WIDTH + 8 + math.ceil((right + insets.right) / layout.scale)
end

local function slide(x: number, direction: Enum.EasingDirection)
	local frame = panel
	if frame == nil then
		return
	end
	if tween then
		tween:Cancel()
	end
	local next = TweenService:Create(
		frame,
		TweenInfo.new(SLIDE, Enum.EasingStyle.Quad, direction),
		{ Position = UDim2.fromOffset(x, 0) }
	)
	tween = next
	next:Play()
end

-- Is the Now Playing toast on screen (other toasts go under it)?
function MusicToast.showing(): boolean
	local frame = panel
	return frame ~= nil and frame.Visible
end

-- Puts the toast where Ui/HudLayout says (hidden while it waits for room), at its scale.
local function layout()
	local holder = root
	local scale = uiScale
	if holder == nil or scale == nil then
		return
	end
	local corner = UiScale.hud()
	local place = corner.music
	if scale.Scale ~= corner.scale then
		scale.Scale = corner.scale
	end
	holder.Visible = place ~= nil
	if place then
		holder.Position = UDim2.fromOffset(place.x, place.y)
	end
end

-- The toast has gone: the corner forgets it, the HUD is no longer followed.
local function gone()
	UiScale.setToast("music", nil)
	local connection = following
	if connection then
		following = nil
		connection:Disconnect()
	end
end

function MusicToast.start()
	if started then
		return
	end
	started = true
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	-- (The whole screen: Ui/HudLayout's screen pixels. Over the minimap, under WAILA, the HUD and
	-- the screens.)
	local gui = UiScale.screenGui("IceVoxelToasts", "Toasts", { inset = true, full = true, kind = "scaled" })

	local holder = Instance.new("Frame")
	holder.Name = "Toasts"
	holder.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = holder

	local face = Style.frame(holder, hiddenX(), 0, WIDTH, HEIGHT, Color3.new(0, 0, 0), 1)
	face.Name = "NowPlaying"
	face.Visible = false
	Style.frame(face, 1, 1, WIDTH - 2, HEIGHT - 2, EDGE, 2)
	Style.frame(face, 2, 2, WIDTH - 4, HEIGHT - 4, FACE, 3)
	Style.pixelArt(face, 8, 8, DISC, DISC_PALETTE, 4)
	Style.shadowText(face, "Now Playing", TEXT_X, TITLE_Y, TEXT_W, 10, Style.Colour.Yellow, 5)
	local label, shadow = Style.shadowText(face, "", TEXT_X, NAME_Y, TEXT_W, 10, Style.Colour.Text, 5)

	root, panel, nameLabel, nameShadow, uiScale = holder, face, label, shadow, scale
	layout()
	UiScale.hudChanged:Connect(layout)
	gui.Parent = playerGui
end

-- Follows the HUD's visibility while the toast shows.
local function follow()
	if following then
		return
	end
	local holder = root
	local gui = holder and holder.Parent
	if gui == nil or not gui:IsA("ScreenGui") then
		return
	end
	following = RunService.RenderStepped:Connect(function()
		local shown = UiScale.hudShown()
		if gui.Enabled ~= shown then
			gui.Enabled = shown
		end
	end)
end

-- Slides the toast in with `title`, and out again after Config.Music.ToastSeconds.
function MusicToast.show(title: string)
	local frame = panel
	if not started or not enabled or frame == nil then
		return
	end
	generation += 1
	local mine = generation
	local text = fitted(title, TEXT_W)
	if nameLabel and nameShadow then
		nameLabel.Text = text
		nameShadow.Text = text
	end
	UiScale.setToast("music", WIDTH)
	follow()
	layout()
	if not frame.Visible then
		frame.Position = UDim2.fromOffset(hiddenX(), 0)
		frame.Visible = true
	end
	slide(0, Enum.EasingDirection.Out)
	task.delay(SLIDE + Config.Music.ToastSeconds, function()
		if generation == mine then
			slide(hiddenX(), Enum.EasingDirection.In)
			task.delay(SLIDE, function()
				if generation == mine and panel then
					panel.Visible = false
					gone()
				end
			end)
		end
	end)
end

-- The player's Music Toasts setting: off, no new toasts (one showing slides out).
function MusicToast.setEnabled(value: boolean)
	enabled = value
	if not value and panel and panel.Visible then
		generation += 1
		local mine = generation
		slide(hiddenX(), Enum.EasingDirection.In)
		task.delay(SLIDE, function()
			if generation == mine and panel then
				panel.Visible = false
				gone()
			end
		end)
	end
end

return MusicToast
