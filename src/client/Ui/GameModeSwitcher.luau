--!strict
--[[
	The game mode switcher (F3 + F4): Minecraft 1.20.1's GameModeSwitcherScreen in the game's UI
	style (Ui/Style). Its logic is Ui/ModeSwitch (pure, tested); this draws it and feeds it.

	  look     centred: a dark translucent box, the highlighted mode's name over it, four slots (the
	           inventory's sunken slot look) with their icons, Creative a grass block and Survival an
	           iron sword (Ui/ItemIcon), Adventure a map and Spectator an ender eye drawn as pixel
	           art (the game has neither item), a white frame on the highlighted slot, and
	           "[ F4 ] Next" under them with "[ F4 ]" in aqua. Scaled like the HUD (Ui/UiScale).
	  input    opened by Debug/DebugOverlay (F3 + F4, with the permission to change one's own
	           mode), which also passes on F4 while it is open (`next`). The mouse highlights the
	           slot it moves onto; clicking does nothing more, as in Minecraft. It is checked
	           every frame whether F3 is still down (checkToClose): once it is not, the
	           highlighted mode is asked for (Protocol SetGameMode, the /gamemode command's rules
	           and answer on the server) unless it is the current one, and the switcher closes.
	           Escape (Roblox's menu) or an inventory screen opening closes it without switching.
	           While it is open it has the keys, as a Minecraft Screen does: the player stands
	           still (Player/MovementController), and the hotbar's or spectator menu's keys and the
	           wheel (Ui/Hud.setInputTaken) and the clicks (Interaction/BlockInteraction) do
	           nothing.
	  mouse    only while it is shown: a Modal button frees the mouse (in first person too) and
	           takes the clicks, so nothing behind it is broken or used.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local Hud = require(script.Parent.Hud)
local ItemIcon = require(script.Parent.ItemIcon)
local ModeSwitch = require(script.Parent.ModeSwitch)
local Screens = require(script.Parent.Screens)
local Style = require(script.Parent.Style)
local UiScale = require(script.Parent.UiScale)

local WIDTH, HEIGHT = ModeSwitch.PANEL_WIDTH, ModeSwitch.PANEL_HEIGHT
local MOUSE_STEP = "IceVoxelSwitcherMouse"
-- Minecraft's aqua (§b).
local AQUA = Color3.fromRGB(85, 255, 255)
local BACKGROUND = Color3.fromRGB(16, 16, 16)
local BACKGROUND_TRANSPARENCY = 0.35
local EDGE = Color3.fromRGB(110, 110, 110)
local SELECTION = Color3.fromRGB(255, 255, 255)

--[[ The icons the game has no item for: 16 x 16 pixel art ]]

local MAP_ART = {
	"................",
	".KKKKKKKKKKKKKK.",
	".KPPPPPPPPPPPPK.",
	".KPGGPPPPPWWPPK.",
	".KPGGGPPPWWWPPK.",
	".KPPGGPPPPWPPPK.",
	".KPPPPPPRPPPPPK.",
	".KPPPPPRRRPPPPK.",
	".KPPPPPPRPPPPPK.",
	".KPWWPPPPPGGPPK.",
	".KPWWWPPPGGGPPK.",
	".KPPWPPPPPGPPPK.",
	".KPPPPPPPPPPPPK.",
	".KKKKKKKKKKKKKK.",
	"................",
	"................",
}
local MAP_PALETTE = {
	K = Color3.fromRGB(107, 74, 43),
	P = Color3.fromRGB(232, 217, 168),
	G = Color3.fromRGB(94, 158, 58),
	W = Color3.fromRGB(74, 123, 208),
	R = Color3.fromRGB(192, 48, 48),
}

local EYE_ART = {
	"................",
	".....KKKKKK.....",
	"...KKDDDDDDKK...",
	"..KDDGGGGGGDDK..",
	"..KDGHLLLLGGDK..",
	".KDGHLLLLLLGGDK.",
	".KDGLLLPPLLLGDK.",
	".KDGLLLPPLLLGDK.",
	".KDGLLLPPLLLGDK.",
	".KDGLLLPPLLLGDK.",
	".KDGGLLLLLLGGDK.",
	"..KDGGLLLLGGDK..",
	"..KDDGGGGGGDDK..",
	"...KKDDDDDDKK...",
	".....KKKKKK.....",
	"................",
}
local EYE_PALETTE = {
	K = Color3.fromRGB(11, 42, 32),
	D = Color3.fromRGB(30, 107, 78),
	G = Color3.fromRGB(47, 163, 122),
	L = Color3.fromRGB(127, 224, 192),
	H = Color3.fromRGB(220, 255, 240),
	P = Color3.fromRGB(10, 26, 20),
}

local GameModeSwitcher = {}

local switcher: ModeSwitch.Switcher? = nil
-- Set by start.
local openImpl: () -> () = function() end

-- Is the switcher shown?
function GameModeSwitcher.isOpen(): boolean
	return switcher ~= nil
end

-- Opens it (F3 + F4; the caller checked the permission).
function GameModeSwitcher.open()
	openImpl()
end

-- F4 while it is open: the next mode.
function GameModeSwitcher.next()
	local current = switcher
	if current then
		ModeSwitch.next(current)
	end
end

type Slot = { mode: string, button: TextButton, selection: Frame }

function GameModeSwitcher.start()
	local player = Players.LocalPlayer

	-- Over the HUD and WAILA, under the carried stack's layer.
	local gui =
		UiScale.screenGui("IceVoxelGameModeSwitcher", "Switcher", { inset = true, kind = "scaled", enabled = false })

	-- Visible and Modal: Roblox frees the mouse while it is shown; it also takes the clicks.
	local modal = Instance.new("TextButton")
	modal.Name = "Modal"
	modal.Text = ""
	modal.BackgroundTransparency = 1
	modal.AutoButtonColor = false
	modal.Selectable = false
	modal.Size = UDim2.fromScale(1, 1)
	modal.Modal = true
	modal.ZIndex = 0
	modal.Parent = gui

	-- The screen's centre is Minecraft's (width / 2, height / 2); the box sits at (-62, -58) of it.
	local root = Instance.new("Frame")
	root.Name = "Switcher"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(-ModeSwitch.PANEL_X / WIDTH, -ModeSwitch.PANEL_Y / HEIGHT)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	root.ZIndex = 1
	root.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = root

	local back = Style.frame(root, 0, 0, WIDTH, HEIGHT, BACKGROUND, 1)
	back.BackgroundTransparency = BACKGROUND_TRANSPARENCY
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, 3)
	round.Parent = back
	local edge = Instance.new("UIStroke")
	edge.Color = EDGE
	edge.Thickness = 1
	edge.Transparency = 0.3
	edge.Parent = back

	-- (Positions inside the box: Minecraft's offsets from the centre, less the box's.)
	local function inside(x: number, y: number): (number, number)
		return x - ModeSwitch.PANEL_X, y - ModeSwitch.PANEL_Y
	end

	local slots: { Slot } = {}
	for index, mode in GameMode.ORDER do
		local x, y = inside(ModeSwitch.slotX(index), ModeSwitch.SLOT_Y)
		local size = ModeSwitch.SLOT
		Style.inset(root, x, y, size, size, 2)
		local iconX, iconY = x + ModeSwitch.ICON_INSET, y + ModeSwitch.ICON_INSET
		if mode == GameMode.CREATIVE or mode == GameMode.SURVIVAL then
			local icon = ItemIcon.new(root, iconX, iconY, 4)
			icon:set(if mode == GameMode.CREATIVE then Items.id.Grass else Items.id.IronSword, 1)
		else
			local art = if mode == GameMode.ADVENTURE then MAP_ART else EYE_ART
			local palette = if mode == GameMode.ADVENTURE then MAP_PALETTE else EYE_PALETTE
			Style.pixelArt(root, iconX, iconY, art, palette, 4)
		end
		local selection = Instance.new("Frame")
		selection.BackgroundTransparency = 1
		selection.Position = UDim2.fromOffset(x, y)
		selection.Size = UDim2.fromOffset(size, size)
		selection.ZIndex = 5
		selection.Visible = false
		selection.Parent = root
		Style.border(selection, 0, 0, size, size, 2, SELECTION, 1)
		local button = Instance.new("TextButton")
		button.Name = mode
		button.Text = ""
		button.BackgroundTransparency = 1
		button.AutoButtonColor = false
		button.Selectable = false
		button.Position = UDim2.fromOffset(x, y)
		button.Size = UDim2.fromOffset(size, size)
		button.ZIndex = 6
		button.Parent = root
		table.insert(slots, { mode = mode, button = button, selection = selection })
	end

	local titleX, titleY = inside(ModeSwitch.PANEL_X, ModeSwitch.TITLE_Y)
	local title, titleShadow =
		Style.shadowText(root, "", titleX, titleY, WIDTH, 8, Style.Colour.Text, 7, Enum.TextXAlignment.Center)

	-- "[ F4 ] Next", centred as one line.
	local key, rest = ModeSwitch.HELP_KEY, ` {ModeSwitch.HELP_TEXT}`
	local keyWidth, restWidth = Style.textWidth(key), Style.textWidth(rest)
	local _, helpY = inside(0, ModeSwitch.HELP_Y)
	local helpX = math.floor((WIDTH - keyWidth - restWidth) / 2)
	Style.shadowText(root, key, helpX, helpY, keyWidth + 2, 8, AQUA, 7)
	Style.shadowText(root, rest, helpX + keyWidth, helpY, restWidth + 2, 8, Style.Colour.Text, 7)

	gui.Parent = player:WaitForChild("PlayerGui")

	local mouseIconWas = true

	local function close(switch: boolean)
		local current = switcher
		if current == nil then
			return
		end
		switcher = nil
		gui.Enabled = false
		Hud.setInputTaken(false)
		RunService:UnbindFromRenderStep(MOUSE_STEP)
		UserInputService.MouseIconEnabled = mouseIconWas
		if switch then
			-- (switchToHoveredGameMode: against the mode now, and only with the permission.)
			current.current = GameMode.of(player)
			local choice = ModeSwitch.choice(current)
			if choice and GameMode.mayChangeOwn(player) then
				ClientNet.send(Protocol.ClientMessage.SetGameMode, Protocol.encodeSetGameMode(choice))
			end
		end
	end

	-- The mouse in InputObject.Position space (GetMouseLocation includes the top bar inset).
	local function mousePoint(): Vector2
		return UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
	end

	local function render()
		local current = switcher
		if current == nil then
			return
		end
		-- Minecraft's checkToClose: F3 (the Debug Screen key binding) let go switches and closes.
		if not Keybinds.isDown("debug") then
			close(true)
			return
		end
		local value = UiScale.fit(WIDTH, HEIGHT, gui.AbsoluteSize)
		if scale.Scale ~= value then
			scale.Scale = value
		end
		local point = mousePoint()
		local over: string? = nil
		for _, slot in slots do
			if Style.contains(slot.button, point) then
				over = slot.mode
			end
		end
		ModeSwitch.pointer(current, point.X, point.Y, over)
		for _, slot in slots do
			local selected = slot.mode == current.hovered
			if slot.selection.Visible ~= selected then
				slot.selection.Visible = selected
			end
		end
		local text = ModeSwitch.title(current)
		if title.Text ~= text then
			title.Text = text
			titleShadow.Text = text
		end
	end

	openImpl = function()
		if switcher ~= nil or Screens.isOpen() then
			return
		end
		switcher = ModeSwitch.new(GameMode.of(player), GameMode.previousOf(player))
		mouseIconWas = UserInputService.MouseIconEnabled
		gui.Enabled = true
		Hud.setInputTaken(true)
		RunService:BindToRenderStep(MOUSE_STEP, Enum.RenderPriority.Camera.Value + 1, function()
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end)
		render()
	end

	RunService.RenderStepped:Connect(render)
	-- Escape closes without switching (Roblox opens its menu on Escape).
	GuiService.MenuOpened:Connect(function()
		close(false)
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Escape then
			close(false)
		end
	end)
	-- An inventory screen (or a block's window the server opens) takes over.
	Screens.changed:Connect(function(open: boolean)
		if open then
			close(false)
		end
	end)
	player.CharacterAdded:Connect(function()
		close(false)
	end)
end

return GameModeSwitcher
