--!strict
--[[
	The "Now Playing" toast, as Minecraft's toasts: a 160 x 32 GUI pixel panel that slides in from
	the right edge of the screen when a track starts (Audio/Music), shows a music disc, "Now
	Playing" in yellow and the track's title, stays Config.Music.ToastSeconds (5) and slides back
	out ("swooshes away"). A new track's toast replaces the one showing.

	It sits in the top right corner, under the minimap and its coordinates line while the minimap
	shows (`setMinimapShown`, the Minimap setting), else in the corner itself (below the Map
	button on touch screens). Scaled like the rest of the HUD (Style.guiScale, the GUI Scale
	setting). `setEnabled` (the player's Music Toasts setting) stops new toasts; one showing slides
	out.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local Style = require(script.Parent.Style)

-- Minecraft's toast (GUI pixels).
local WIDTH, HEIGHT = 160, 32
-- Seconds sliding in and out (Minecraft's toasts take 600 ms each way, eased).
local SLIDE = 0.45
-- Screen pixels from the right edge and the top, and below the minimap's coordinates line
-- (Map/Minimap: the map 16 from the top, its line 4 below it, 18 high).
local MARGIN = 16
local MINIMAP_GAP = 6
local MINIMAP_EXTRA = 16 + 4 + 18
-- Where the toast starts on touch screens without the minimap (below the Map button).
local TOUCH_TOP = 64
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
local minimapShown = true
local root: Frame? = nil
local panel: Frame? = nil
local nameLabel: TextLabel? = nil
local nameShadow: TextLabel? = nil
local uiScale: UIScale? = nil
-- Bumped by every show, so an older toast's timer never slides a newer one out.
local generation = 0
local tween: Tween? = nil

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

-- Panel x when shown (0) and hidden (out past the screen's right edge).
local function hiddenX(): number
	return WIDTH + MARGIN + 8
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

-- The toast's top in the corner (screen pixels below the top bar) and its scale.
local function place(): (number, number)
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local touch = UserInputService.TouchEnabled
	local top = if minimapShown
		then MINIMAP_EXTRA + Config.Map.MinimapSize + MINIMAP_GAP
		elseif touch then TOUCH_TOP
		else MARGIN
	return top, Style.guiScale(viewport, WIDTH, HEIGHT, touch)
end

--[[
	Screen pixels (below the top bar) just under the toast's place in the corner, shown or not, and
	the right margin: the status effect icons go there (Ui/EffectHud).
]]
function MusicToast.bottom(): (number, number)
	local top, scale = place()
	return top + HEIGHT * scale, MARGIN
end

local function layout()
	local holder = root
	local scale = uiScale
	if holder == nil or scale == nil then
		return
	end
	local top, toastScale = place()
	scale.Scale = toastScale
	holder.Position = UDim2.new(1, -MARGIN, 0, top)
end

function MusicToast.start()
	if started then
		return
	end
	started = true
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelToasts"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	-- (Over the minimap, under WAILA, the HUD and the screens.)
	gui.DisplayOrder = 7

	local holder = Instance.new("Frame")
	holder.Name = "Toasts"
	holder.AnchorPoint = Vector2.new(1, 0)
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
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
	end
	Style.scaleChanged:Connect(layout)
	gui.Parent = playerGui
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
				end
			end)
		end
	end)
end

-- Whether the minimap shows in the top right corner (the toast goes under it).
function MusicToast.setMinimapShown(value: boolean)
	minimapShown = value
	layout()
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
			end
		end)
	end
end

return MusicToast
