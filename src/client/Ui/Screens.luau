--!strict
--[[
	The inventory screens' controller.

	  open / close  E, gamepad Y and the HUD's touch button toggle the inventory: the creative
	                "Item selection" screen with the instabuild ability (creative), the inventory
	                screen in survival and adventure (creative players reach it through a tab);
	                spectators have none (E does nothing, and switching to spectator closes the
	                player's own inventory). Escape (and the Roblox menu opening), gamepad B, death
	                and the touch "x" buttons close it. Closing sends `close` for the open window
	                (window 0 too, so the carried stack and the 2 x 2 crafting grid go back into the
	                inventory, like Minecraft).
	  blocks        when a snapshot opens a block's window (the server answered a right click on a
	                chest, crafting table or furnace), the inventory screen opens with the block's
	                panel above the player's. Window 0 (the inventory screen's own, whose
	                container is the player panel's 2 x 2 grid) never shows a panel. When the
	                server closes a block's window (too far, the block broke, death), the screen
	                closes, as in Minecraft. A spectator's block window is read only: every click
	                goes nowhere (ClientInventory refuses what Menu.allows refuses), and JEI's
	                recipe transfer is off.
	  while open    the mouse is free (a Modal button, MouseBehavior Default every frame after the
	                camera, the mouse icon on), the default controls are disabled so the character
	                stops, and `isOpen()` is true for the other client modules.

	Input on an open screen (Minecraft's, see Ui/SlotClicks for what each click does):

	  mouse    left / right / middle click and drag on slots, shift click, double click, clicks
	           outside the panels throw the carried stack; number keys over a slot swap it with
	           the hotbar, Q throws one (Ctrl+Q all); the carried stack follows the mouse and the
	           hovered item shows its tooltip (a machine's energy bar its "stored / capacity").
	           The wheel scrolls the creative grid.
	  gamepad  GuiService selection moves between slots; A = left click, X = right click,
	           Y = shift click, B closes, the right stick scrolls the creative grid.
	  touch    a tap is a left click, a long press (0.4 s) a right click, sliding a finger drags;
	           sliding over the creative grid scrolls it. A tap outside with nothing carried
	           closes the screen (Minecraft's touch screen mode).

	Drags show their result as they grow: the screen draws a copy of the window with the drag
	applied.

	Panels: another module's screen (Ui/StructureScreen: the structure block and jigsaw screens)
	is shown with `showPanel`, in the screens' GUI and with everything that comes with an open
	screen (the darkened world, the free mouse, the controls off, `isOpen()`), but none of the
	inventory's input: its own buttons and text fields take the clicks. E, Escape, gamepad B and
	death close it like any screen (its `closed` is called; Minecraft's Escape cancels such a
	screen), and so does a block's window the server opens.

	Settings: the Options menu (Ui/SettingsScreen, a panel, which requires this module and so
	registers itself with `onSettings`) opens with Config.Settings.Key (P) or GamepadButton
	(D-pad right) while no screen is open, the HUD's touch gear and the inventory's gear (which
	closes the inventory first); the key closes it again.

	JEI (Ui/Jei) comes with every open screen: the item list at the right of the screen and,
	opened from it, the recipe view, which takes the inventory panel's place (no slot clicks while
	it is shown). Clicks on the list or the view go to JEI before anything else; R and U over any
	item (the list, the view, a slot, the creative grid or hotbar) show its recipes or uses,
	Backspace goes back through the views, and E, Escape and gamepad B close the view before the
	screen (Escape still opens Roblox's menu, over the inventory then). The mouse wheel turns JEI's
	pages over the list or the view.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local CreativeScreen = require(script.Parent.CreativeScreen)
local Hud = require(script.Parent.Hud)
local InventoryScreen = require(script.Parent.InventoryScreen)
local ItemIcon = require(script.Parent.ItemIcon)
local Jei = require(script.Parent.Jei)
local MenuLayout = require(script.Parent.MenuLayout)
local SlotClicks = require(script.Parent.SlotClicks)
local Style = require(script.Parent.Style)

type Target = SlotClicks.Target
type Kind = "inventory" | "creative" | "panel"
type Line = { text: string, colour: Color3 }

--[[
	A screen of another module shown by Screens (showPanel). Its `root` is parented into the
	screens' GUI and shown centred, scaled like the inventory for content of `size()` GUI pixels.
	`closed` is called when Screens closes it (not when the panel closes itself with closePanel).
]]
export type Panel = {
	root: GuiObject,
	size: () -> Vector2,
	closed: () -> (),
	firstSelectable: () -> GuiObject?,
}

-- Touch: a long press is a right click; a finger moving this far (pixels) drags or scrolls.
local LONG_PRESS = 0.4
local TOUCH_MOVE = 10
-- Gamepad right stick: scroll a row this often while pushed past STICK_DEAD_ZONE.
local STICK_REPEAT = 0.12
local STICK_DEAD_ZONE = 0.5
-- Minecraft's tooltip sits 12 GUI pixels right of and above the pointer.
local TOOLTIP_OFFSET = 12
-- Escape both reaches InputBegan (sometimes) and opens Roblox's menu: one press within this many
-- seconds acts once.
local ESCAPE_REPEAT = 0.3
local MOUSE_STEP = "IceVoxelScreensMouse"
local STICK_ACTION = "IceVoxelScreensStick"

-- An Enum.KeyCode by name (Config), nil when there is none.
local function keyCode(name: string): Enum.KeyCode?
	local ok, code = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	return if ok then code else nil
end

-- The Options menu's key and gamepad button (Ui/SettingsScreen).
local SETTINGS_KEY = keyCode(Config.Settings.Key)
local SETTINGS_BUTTON = keyCode(Config.Settings.GamepadButton)

local NUMBER_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
}

local MOUSE_BUTTONS: { [Enum.UserInputType]: number } = {
	[Enum.UserInputType.MouseButton1] = SlotClicks.Button.Left,
	[Enum.UserInputType.MouseButton2] = SlotClicks.Button.Right,
	[Enum.UserInputType.MouseButton3] = SlotClicks.Button.Middle,
}

type TouchState = {
	input: InputObject,
	origin: Vector2,
	position: Vector2,
	started: number,
	target: Target?,
	-- pending: not yet a click, drag or scroll; pressed: a button is down (SlotClicks); scroll:
	-- scrolling the creative grid; scrollbar: dragging its thumb; ignored: a JEI touch that slid
	-- away or already acted.
	phase: "pending" | "pressed" | "scroll" | "scrollbar" | "ignored",
	button: number,
	lastY: number,
	-- The JEI item (list or recipe view) the touch started on: a tap shows its recipes, a long
	-- press its uses. `jeiList`: it is the list's.
	jeiItem: number?,
	jeiList: boolean,
}

-- Typing into a text box or Roblox's chat bar?
local function typing(): boolean
	if UserInputService:GetFocusedTextBox() ~= nil then
		return true
	end
	local bar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
	return bar ~= nil and bar.IsFocused
end

-- Is a point (input coordinates, below the top bar inset) over Roblox's own UI: the top bar or
-- the chat window and bar?
local function overCoreGui(point: Vector2): boolean
	if point.Y < 0 then
		return true
	end
	for _, config in TextChatService:GetChildren() do
		if config:IsA("ChatWindowConfiguration") or config:IsA("ChatInputBarConfiguration") then
			if config.Enabled then
				local position, size = config.AbsolutePosition, config.AbsoluteSize
				if
					point.X >= position.X
					and point.Y >= position.Y
					and point.X <= position.X + size.X
					and point.Y <= position.Y + size.Y
				then
					return true
				end
			end
		end
	end
	return false
end

-- Is `window` a block's (a chest, crafting table or furnace open), not the inventory screen's?
local function blockOpen(window: Types.Window): boolean
	return window.id ~= 0 and MenuLayout.hasPanel(window.container)
end

local Screens = {}

local changedEvent = Instance.new("BindableEvent")
-- Fires with `true` when a screen opens and `false` when it closes.
Screens.changed = changedEvent.Event

local current: Kind? = nil
local started = false
-- The panel shown while `current` is "panel" (and the one showPanel asked for).
local panel: Panel? = nil
-- Opens or closes the Options menu (Ui/SettingsScreen.toggle).
local settingsHandler: (() -> ())? = nil

function Screens.isOpen(): boolean
	return current ~= nil
end

-- Set by start.
local open: (kind: Kind) -> () = function() end
local close: () -> () = function() end
local escape: () -> () = function() end
local hidePanel: () -> () = function() end

--[[
	Shows `p` (see Panel) instead of whatever screen is open, opening the screens if none is. Call
	after Screens.start.
]]
function Screens.showPanel(p: Panel)
	if current == "panel" and panel ~= p then
		-- Another panel goes the way Escape would take it.
		local previous = panel
		hidePanel()
		if previous then
			previous.closed()
		end
	end
	panel = p
	open("panel")
end

-- Closes `p` if it is shown (its `closed` is not called: the panel closes itself).
function Screens.closePanel(p: Panel)
	if current == "panel" and panel == p then
		-- (Off the screen first: `close` hides only a panel it still knows, and calls its `closed`.)
		hidePanel()
		panel = nil
		close()
	end
end

-- Is `p` the panel shown?
function Screens.panelShown(p: Panel): boolean
	return current == "panel" and panel == p
end

--[[
	The Options menu's toggle (Ui/SettingsScreen, which can't be required here: it requires this
	module): called for Config.Settings.Key / GamepadButton with no screen open, the key while a
	panel is shown, and the HUD's and the inventory's gear buttons.
]]
function Screens.onSettings(handler: () -> ())
	settingsHandler = handler
end

local function openSettings()
	local handler = settingsHandler
	if handler then
		handler()
	end
end

--[[
	Opens the inventory (the creative item selection with instabuild), or closes the open screen.
	Spectators have no inventory to open.
]]
function Screens.toggle()
	if current then
		close()
	elseif GameMode.canInteract(ClientInventory.mode()) then
		open(if ClientInventory.isCreative() then "creative" else "inventory")
	end
end

-- The tooltip of `item`: its name, the lines of a stack's item data (Items.describe: a tank's
-- water, stored energy), then an armor piece's stats.
local function tooltipLines(item: number, details: { string }?): { Line }
	local lines: { Line } = { { text = Items.displayName(item), colour = Style.Colour.Text } }
	if details then
		for _, text in details do
			table.insert(lines, { text = text, colour = Style.Colour.Gray })
		end
	end
	local def = Items.get(item)
	local armor = def and def.armor
	if armor then
		table.insert(lines, { text = "", colour = Style.Colour.Text })
		table.insert(lines, { text = `When on {Items.ARMOR_SLOTS[armor.slot]}:`, colour = Style.Colour.Gray })
		table.insert(lines, { text = `+{armor.defense} Armor`, colour = Style.Colour.Blue })
		if armor.toughness > 0 then
			table.insert(lines, { text = `+{armor.toughness} Armor Toughness`, colour = Style.Colour.Blue })
		end
	end
	return lines
end

-- Minecraft's tooltip: a dark purple box with a lighter purple border, the name, then details.
local function buildTooltip(parent: Frame, lines: { Line }): Vector2
	parent:ClearAllChildren()
	local scale = Instance.new("UIScale")
	scale.Name = "Scale"
	scale.Parent = parent
	local width = 0
	for _, line in lines do
		width = math.max(width, Style.textWidth(line.text))
	end
	-- 10 pixels per line, and 2 more under the name.
	local height = 8 + (#lines - 1) * 10 + (if #lines > 1 then 2 else 0)
	local w, h = width + 8, height + 8
	local back = Style.frame(parent, 0, 0, w, h, Style.Colour.TooltipBack, 1)
	back.BackgroundTransparency = 0.06
	local border = Style.border(back, 1, 1, w - 2, h - 2, 1, Color3.new(1, 1, 1), 2)
	-- (The border colours blended over the background, as Minecraft draws them translucent.)
	local top, bottom = Color3.fromRGB(36, 0, 90), Color3.fromRGB(23, 0, 50)
	for i, frame in border do
		frame.BackgroundColor3 = if i == 2 then bottom else top
		if i >= 3 then
			frame.BackgroundColor3 = Color3.new(1, 1, 1)
			local gradient = Instance.new("UIGradient")
			gradient.Rotation = 90
			gradient.Color = ColorSequence.new(top, bottom)
			gradient.Parent = frame
		end
	end
	local y = 4
	for i, line in lines do
		if line.text ~= "" then
			Style.shadowText(back, line.text, 4, y, width + 2, 8, line.colour, 5)
		end
		y += if i == 1 then 12 else 10
	end
	parent.Size = UDim2.fromOffset(w, h)
	return Vector2.new(w, h)
end

function Screens.start()
	if started then
		return
	end
	started = true
	ClientInventory.start()
	Hud.start()

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	--[[ GUI ]]

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelScreens"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Under the HUD (whose hotbar is the creative screen's hotbar row), over the map.
	gui.DisplayOrder = 9
	gui.Enabled = false

	-- Minecraft darkens the world behind a screen.
	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.BackgroundColor3 = Color3.fromRGB(16, 16, 16)
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.ZIndex = 0
	backdrop.Parent = gui
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new(0.25, 0.19)
	fade.Parent = backdrop

	-- Visible and Modal: Roblox frees the mouse (also in first person) while it is shown.
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

	local inventory = InventoryScreen.new(gui)
	local creative = CreativeScreen.new(gui)
	local inventoryScale = Instance.new("UIScale")
	inventoryScale.Parent = inventory.root
	local creativeScale = Instance.new("UIScale")
	creativeScale.Parent = creative.root
	-- The shown panel's scale (moved into each panel's root as it is shown).
	local panelScale = Instance.new("UIScale")

	-- The carried stack and the tooltip, above everything (also the HUD).
	local top = Instance.new("ScreenGui")
	top.Name = "IceVoxelCursor"
	top.ResetOnSpawn = false
	top.IgnoreGuiInset = true
	top.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	top.DisplayOrder = 20
	top.Enabled = false
	local carried = Instance.new("Frame")
	carried.Name = "Carried"
	carried.BackgroundTransparency = 1
	carried.AnchorPoint = Vector2.new(0.5, 0.5)
	carried.Size = UDim2.fromOffset(Style.ITEM, Style.ITEM)
	carried.Visible = false
	carried.Parent = top
	local carriedScale = Instance.new("UIScale")
	carriedScale.Parent = carried
	local carriedIcon = ItemIcon.new(carried, 0, 0, 1)
	local tooltip = Instance.new("Frame")
	tooltip.Name = "Tooltip"
	tooltip.BackgroundTransparency = 1
	tooltip.Visible = false
	tooltip.ZIndex = 2
	tooltip.Parent = top
	-- What the tooltip shows (the item and its extra lines, joined), to rebuild it only on a change.
	local tooltipKey = ""
	local tooltipSize = Vector2.zero

	-- JEI: the item list beside the screens and the recipe view (Ui/Jei). Recipes are moved into
	-- the crafting grid only from the inventory screen, which shows it.
	local jei = Jei.new(gui, {
		window = ClientInventory.window,
		creative = ClientInventory.isCreative,
		apply = ClientInventory.apply,
		-- (Spectators look at a crafting table's grid but move nothing into it.)
		gridShown = function(): boolean
			return current == "inventory" and GameMode.canInteract(ClientInventory.mode())
		end,
	})

	gui.Parent = playerGui
	top.Parent = playerGui

	--[[ Clicks ]]

	local clicks = SlotClicks.new({
		window = ClientInventory.window,
		creative = ClientInventory.isCreative,
		apply = ClientInventory.apply,
	})

	local function targetAt(point: Vector2): Target?
		-- Over Roblox's own UI (the top bar, the chat) or JEI: neither a slot nor outside. While the
		-- recipe view is shown, nothing else is either.
		if overCoreGui(point) or jei:covers(point) or jei:viewOpen() then
			return nil
		end
		if current == "creative" then
			return creative:targetAt(point)
		end
		return inventory:targetAt(point)
	end

	local function targetOf(object: GuiObject): Target?
		if jei:viewOpen() then
			return nil
		end
		if current == "creative" then
			return creative:targetOf(object)
		end
		return inventory:targetOf(object)
	end

	local function shiftDown(): boolean
		return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	end

	local function controlDown(): boolean
		return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	end

	--[[ Pointer ]]

	local held: { [number]: boolean } = {}
	local scrollbarHeld = false
	local touch: TouchState? = nil
	local lastTouch: Vector2? = nil
	local stickY = 0
	local nextStickScroll = 0

	local function inputKind(): string
		local preferred = UserInputService.PreferredInput
		if preferred == Enum.PreferredInput.Gamepad then
			return "gamepad"
		elseif preferred == Enum.PreferredInput.Touch then
			return "touch"
		end
		return "mouse"
	end

	-- The mouse position in InputObject.Position space (GetMouseLocation includes the top inset).
	local function mousePoint(): Vector2
		local inset = GuiService:GetGuiInset()
		return UserInputService:GetMouseLocation() - inset
	end

	-- Where the carried stack and tooltip go, and what is hovered.
	local function pointer(): (Vector2?, Target?)
		local kind = inputKind()
		if kind == "gamepad" then
			local object = GuiService.SelectedObject
			if object then
				local position = object.AbsolutePosition + object.AbsoluteSize * 0.75
				return position, targetOf(object)
			end
			return nil, nil
		elseif kind == "touch" then
			local t = touch
			if t then
				return t.position, targetAt(t.position)
			end
			return lastTouch, nil
		end
		local point = mousePoint()
		return point, targetAt(point)
	end

	local function hoverTarget(): Target?
		local _, target = pointer()
		return target
	end

	--[[ Controls and mouse ]]

	local function setControls(enabled: boolean)
		local scripts = player:FindFirstChildOfClass("PlayerScripts")
		local module = scripts and scripts:FindFirstChild("PlayerModule")
		if module == nil or not module:IsA("ModuleScript") then
			return
		end
		pcall(function()
			local controls = (require :: any)(module):GetControls()
			if enabled then
				controls:Enable()
			else
				controls:Disable()
			end
		end)
	end

	local mouseIconWas = true

	--[[ Layout ]]

	local function setScale(scale: UIScale, value: number)
		if scale.Scale ~= value then
			scale.Scale = value
		end
	end

	local function layout()
		local viewport = gui.AbsoluteSize
		local touchScreen = UserInputService.TouchEnabled
		local scale
		-- Where JEI's list may reach down to: above the creative screen's hotbar row (also while the
		-- recipe view hides it, so the list keeps its cells instead of rebuilding them).
		local listBottom = viewport.Y
		local shownPanel = panel
		if current == "panel" and shownPanel then
			local size = shownPanel.size()
			scale = Style.guiScale(viewport, size.X, size.Y, touchScreen)
			setScale(panelScale, scale)
		elseif current == "creative" then
			-- Centred in the space above the HUD's hotbar (the screen's hotbar row).
			local cell = Hud.hotbarCell(1)
			local bottom = viewport.Y - 30
			if cell and cell.AbsoluteSize.Y > 0 then
				bottom = cell.AbsolutePosition.Y - gui.AbsolutePosition.Y - cell.AbsoluteSize.Y * 0.2
			end
			listBottom = bottom
			local size = creative:size()
			scale = Style.guiScale(viewport, size.X, size.Y, touchScreen, Vector2.new(viewport.X, math.max(bottom, 60)))
			setScale(creativeScale, scale)
			local y = math.floor(bottom / 2 + size.Y * scale / 2)
			if creative.root.Position.Y.Offset ~= y then
				creative.root.Position = UDim2.new(0.5, 0, 0, y)
			end
		else
			local size = inventory:size()
			scale = Style.guiScale(viewport, size.X, size.Y, touchScreen)
			setScale(inventoryScale, scale)
		end
		-- JEI: the recipe view in the panel's place (at most the panel's scale), the list to the right
		-- of the panels (all three are centred and MenuLayout.WIDTH wide).
		local viewSize = jei.view:size()
		jei:place({
			viewportX = viewport.X,
			top = GuiService:GetGuiInset().Y,
			bottom = listBottom,
			guiRight = viewport.X / 2 + MenuLayout.WIDTH / 2 * scale,
			scale = scale,
			viewScale = math.min(scale, Style.guiScale(viewport, viewSize.X, viewSize.Y, touchScreen)),
		})
		setScale(carriedScale, scale)
		local tooltipScale = tooltip:FindFirstChild("Scale")
		if tooltipScale and tooltipScale:IsA("UIScale") then
			setScale(tooltipScale, scale)
		end
		return scale
	end

	local function selectFirst()
		if inputKind() ~= "gamepad" then
			return
		end
		local first
		local shownPanel = panel
		if current == "panel" and shownPanel then
			first = shownPanel.firstSelectable()
		elseif jei:viewOpen() then
			first = jei:firstSelectable()
		elseif current == "creative" then
			first = creative:firstSelectable()
		else
			first = inventory:firstSelectable()
		end
		if first then
			GuiService.SelectedObject = first
		end
	end

	local function resetPointer()
		clicks:cancel()
		table.clear(held)
		if scrollbarHeld then
			scrollbarHeld = false
			creative:pointerUp()
		end
		touch = nil
	end

	--[[ Open / close ]]

	local lastWindowId = 0

	-- Shows the open screen's panel, or the JEI recipe view in its place; the HUD's hotbar is the
	-- creative screen's hotbar row.
	local function applyVisibility()
		local viewing = jei:viewOpen()
		inventory.root.Visible = current == "inventory" and not viewing
		creative.root.Visible = current == "creative" and not viewing
		local shownPanel = panel
		if shownPanel then
			shownPanel.root.Visible = current == "panel"
		end
		if current then
			Hud.setMode(if current == "creative" and not viewing then "creative" else "hidden")
		end
	end

	-- Takes the shown panel off the screen (its `closed` is the caller's business).
	hidePanel = function()
		local shownPanel = panel
		if shownPanel then
			-- (A hidden box keeping the focus would keep taking the keys.)
			local focused = UserInputService:GetFocusedTextBox()
			if focused and focused:IsDescendantOf(shownPanel.root) then
				focused:ReleaseFocus()
			end
			shownPanel.root.Visible = false
		end
		panelScale.Parent = nil
	end

	local function showPage(kind: Kind)
		local window = ClientInventory.window()
		applyVisibility()
		if kind == "inventory" then
			inventory:setLayout(window.container, ClientInventory.isCreative())
			inventory:opened()
		else
			inventory:closed()
		end
		if kind ~= "creative" then
			creative:releaseFocus()
		end
		Hud.setHover(nil)
		Hud.setPreview(nil)
	end

	open = function(kind: Kind)
		if current == kind then
			if kind == "panel" then
				-- (Another panel: showPanel took the old one away.)
				local shownPanel = panel
				if shownPanel then
					shownPanel.root.Parent = gui
					panelScale.Parent = shownPanel.root
					applyVisibility()
					layout()
					selectFirst()
				end
			end
			return
		end
		local wasOpen = current ~= nil
		if current == "panel" then
			-- A block's window replaces the panel: it goes as with Escape.
			local previous = panel
			hidePanel()
			panel = nil
			if previous then
				previous.closed()
			end
		end
		current = kind
		resetPointer()
		local shownPanel = panel
		if kind == "panel" and shownPanel then
			shownPanel.root.Parent = gui
			panelScale.Parent = shownPanel.root
		end
		showPage(kind)
		layout()
		-- (JEI's list comes with the inventory screens, not with panels.)
		jei:setVisible(kind ~= "panel")
		if not wasOpen then
			gui.Enabled = true
			top.Enabled = true
			setControls(false)
			mouseIconWas = UserInputService.MouseIconEnabled
			RunService:BindToRenderStep(MOUSE_STEP, Enum.RenderPriority.Camera.Value + 1, function()
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
				UserInputService.MouseIconEnabled = true
			end)
			-- The right stick scrolls the creative grid instead of turning the camera.
			ContextActionService:BindActionAtPriority(STICK_ACTION, function(_, state, input)
				if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
					stickY = 0
				else
					stickY = input.Position.Y
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Thumbstick2)
		end
		selectFirst()
		if not wasOpen then
			changedEvent:Fire(true)
		end
	end

	close = function()
		if current == nil then
			return
		end
		local wasPanel = current == "panel"
		current = nil
		resetPointer()
		creative:releaseFocus()
		-- (Also closes the recipe view and drops the search field's focus.)
		jei:setVisible(false)
		inventory:closed()
		if wasPanel then
			local previous = panel
			hidePanel()
			panel = nil
			if previous then
				previous.closed()
			end
		else
			-- The carried stack and a crafting grid go back into the inventory; a block's window
			-- closes.
			ClientInventory.apply({ kind = "close", window = ClientInventory.window().id })
		end
		lastWindowId = ClientInventory.window().id
		gui.Enabled = false
		top.Enabled = false
		tooltip.Visible = false
		carried.Visible = false
		Hud.setMode("play")
		Hud.setHover(nil)
		Hud.setPreview(nil)
		RunService:UnbindFromRenderStep(MOUSE_STEP)
		ContextActionService:UnbindAction(STICK_ACTION)
		stickY = 0
		UserInputService.MouseIconEnabled = mouseIconWas
		setControls(true)
		local selected = GuiService.SelectedObject
		if selected and (selected:IsDescendantOf(gui) or selected:IsDescendantOf(playerGui)) then
			GuiService.SelectedObject = nil
		end
		changedEvent:Fire(false)
	end

	Hud.onInventoryButton(Screens.toggle)
	Hud.onSettingsButton(openSettings)
	-- The inventory's gear: the inventory closes (its window too), then the menu opens.
	inventory.onSettings = function()
		close()
		openSettings()
	end
	Hud.onScreenWheel(function(delta: number)
		if jei:wheel(mousePoint(), delta) then
			return
		end
		if current == "creative" and not jei:viewOpen() then
			creative:scrollBy(-delta)
		end
	end)
	-- The recipe view opened or closed: it and the panel swap places.
	jei.onViewChanged = function(_open: boolean)
		if current == nil then
			return
		end
		resetPointer()
		applyVisibility()
		Hud.setHover(nil)
		Hud.setPreview(nil)
		layout()
		selectFirst()
	end
	inventory.onTab = function()
		open("creative")
	end
	creative.onTab = function()
		open("inventory")
	end
	inventory.onClose = close
	creative.onClose = close

	-- Blocks' windows opened and closed by the server, and game mode changes.
	ClientInventory.changed:Connect(function()
		jei:inventoryChanged()
		local window = ClientInventory.window()
		if window.id ~= lastWindowId then
			local previous = lastWindowId
			lastWindowId = window.id
			if blockOpen(window) then
				if current == "inventory" then
					inventory:setLayout(window.container, ClientInventory.isCreative())
					resetPointer()
					selectFirst()
				else
					open("inventory")
				end
			elseif current ~= nil and previous ~= 0 then
				close()
			end
		end
		-- A game mode change: spectators keep only a block's window open (read only), and the
		-- item selection needs instabuild.
		local spectator = not GameMode.canInteract(ClientInventory.mode())
		if spectator and (current == "creative" or (current == "inventory" and not blockOpen(window))) then
			close()
		elseif current == "creative" and not ClientInventory.isCreative() then
			open("inventory")
		elseif current == "inventory" then
			inventory:setLayout(window.container, ClientInventory.isCreative())
		end
	end)

	--[[
		Escape closes the recipe view, else the screen. Roblox opens its menu on Escape
		(MenuOpened), and the key may reach InputBegan too, before or after: whichever comes first
		acts and the other, right after, is ignored; so is the Escape that closes the menu. The
		menu opened any other way (its button) does the same.
	]]
	local lastEscape = -math.huge
	escape = function()
		local now = os.clock()
		if now - lastEscape < ESCAPE_REPEAT then
			return
		end
		lastEscape = now
		if jei:viewOpen() then
			jei:closeView()
		else
			close()
		end
	end
	GuiService.MenuOpened:Connect(escape)
	GuiService.MenuClosed:Connect(function()
		lastEscape = os.clock()
	end)
	-- Death closes the screen.
	local function watchCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(close)
		end
	end
	player.CharacterAdded:Connect(function(character)
		close()
		watchCharacter(character)
	end)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
	UserInputService.WindowFocusReleased:Connect(resetPointer)

	--[[ Input ]]

	-- The item under the pointer, wherever it is: JEI's list or view, a slot, the creative grid.
	local function hoveredItem(): number?
		local point, hover = pointer()
		if point then
			local item = jei:itemAt(point)
			if item then
				return item
			end
		end
		local object = GuiService.SelectedObject
		if inputKind() == "gamepad" and object then
			local item = jei:itemOf(object)
			if item then
				return item
			end
		end
		if hover and hover.kind == "slot" then
			local stack = Menu.get(ClientInventory.window(), hover.index)
			return if stack then stack.item else nil
		elseif hover and hover.kind == "grid" and Items.isValid(hover.item) then
			return hover.item
		end
		return nil
	end

	local function touchBegan(input: InputObject)
		if touch then
			return
		end
		local point = Vector2.new(input.Position.X, input.Position.Y)
		lastTouch = point
		local now = os.clock()
		if current == "creative" and creative:pointerDown(point) then
			touch = {
				input = input,
				origin = point,
				position = point,
				started = now,
				target = nil,
				phase = "scrollbar",
				button = 0,
				lastY = point.Y,
				jeiItem = nil,
				jeiList = false,
			}
			return
		end
		local jeiItem, jeiList = jei:itemAt(point)
		touch = {
			input = input,
			origin = point,
			position = point,
			started = now,
			target = targetAt(point),
			phase = "pending",
			button = 0,
			lastY = point.Y,
			jeiItem = jeiItem,
			jeiList = jeiList,
		}
	end

	local function touchMoved(input: InputObject)
		local t = touch
		if t == nil or t.input ~= input then
			return
		end
		local point = Vector2.new(input.Position.X, input.Position.Y)
		t.position = point
		lastTouch = point
		if t.phase == "scrollbar" then
			creative:pointerMove(point)
			return
		end
		if t.phase == "pending" and (point - t.origin).Magnitude > TOUCH_MOVE then
			if t.jeiItem or jei:viewOpen() then
				-- JEI items are tapped, not dragged.
				t.phase = "ignored"
			elseif current == "creative" and creative:inGrid(t.origin) then
				t.phase = "scroll"
			else
				t.phase = "pressed"
				t.button = SlotClicks.Button.Left
				clicks:press(t.target, t.button, false, os.clock())
				clicks:move(t.target)
			end
		end
		if t.phase == "pressed" then
			clicks:move(targetAt(point))
		elseif t.phase == "scroll" then
			creative:scrollBy(-(point.Y - t.lastY) / creative:rowPixels())
			t.lastY = point.Y
		end
	end

	local function touchEnded(input: InputObject)
		local t = touch
		if t == nil or t.input ~= input then
			return
		end
		touch = nil
		local now = os.clock()
		if t.phase == "scrollbar" or t.phase == "scroll" then
			creative:pointerUp()
		elseif t.phase == "ignored" then
			return
		elseif t.phase == "pending" then
			local jeiItem = t.jeiItem
			if jeiItem then
				jei:activate(jeiItem, SlotClicks.Button.Left, false, t.jeiList)
				return
			end
			local target = t.target
			if target and target.kind == "outside" and ClientInventory.window().inventory.cursor == nil then
				close()
				return
			end
			clicks:click(target, SlotClicks.Button.Left, false, now)
		else
			clicks:release(targetAt(t.position), t.button, false, now)
		end
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local kind, key = input.UserInputType, input.KeyCode
		if current == "panel" then
			-- A panel's own buttons and fields take the pointer; E, Escape and B close it, unless
			-- the player is typing (a read only box, focused to copy its text, takes no typing).
			local focused = UserInputService:GetFocusedTextBox()
			if focused and not focused.TextEditable then
				focused = nil
			end
			local bar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
			if focused ~= nil or (bar ~= nil and bar.IsFocused) then
				return
			end
			if kind == Enum.UserInputType.Keyboard then
				if key == Enum.KeyCode.E then
					close()
				elseif key == Enum.KeyCode.Escape and not GuiService.MenuIsOpen then
					escape()
				elseif key == SETTINGS_KEY then
					-- (Closes the Options menu; other panels ignore it.)
					openSettings()
				end
			elseif key == Enum.KeyCode.ButtonB then
				close()
			end
			return
		end
		if (kind == Enum.UserInputType.Keyboard or kind == Enum.UserInputType.Gamepad1) and typing() then
			-- Keys go to the chat (or another text box), not to the screens.
			return
		end
		if current == nil then
			if not processed and (key == Enum.KeyCode.E or key == Enum.KeyCode.ButtonY) then
				Screens.toggle()
			elseif not processed and (key == SETTINGS_KEY or key == SETTINGS_BUTTON) then
				openSettings()
			end
			return
		end
		local now = os.clock()
		if kind == Enum.UserInputType.Keyboard then
			-- Typing in the search box: keys are text.
			if UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			local digit = NUMBER_KEYS[key]
			local viewing = jei:viewOpen()
			if key == Enum.KeyCode.E then
				-- The recipe view first, then the screen.
				if viewing then
					jei:closeView()
				else
					close()
				end
			elseif key == Enum.KeyCode.Escape then
				if not GuiService.MenuIsOpen then
					escape()
				end
			elseif key == Enum.KeyCode.Backspace then
				if viewing then
					jei:back()
				end
			elseif key == Enum.KeyCode.R or key == Enum.KeyCode.U then
				jei:show(hoveredItem(), if key == Enum.KeyCode.R then "recipes" else "uses")
			elseif viewing then
				-- (No slot keys: the slots are hidden behind the view.)
				return
			elseif digit then
				clicks:hotbarKey(hoverTarget(), digit)
			elseif key == Enum.KeyCode.Q then
				clicks:throwKey(hoverTarget(), controlDown())
			end
			return
		end
		local button = MOUSE_BUTTONS[kind]
		if button then
			local point = Vector2.new(input.Position.X, input.Position.Y)
			-- JEI's items and panels take their clicks (nothing else is clickable under the view).
			if jei:press(point, button, shiftDown()) or jei:viewOpen() then
				return
			end
			if current == "creative" and button == SlotClicks.Button.Left and creative:pointerDown(point) then
				scrollbarHeld = true
				return
			end
			held[button] = true
			clicks:press(targetAt(point), button, shiftDown(), now)
			return
		end
		if kind == Enum.UserInputType.Touch then
			touchBegan(input)
			return
		end
		if key == Enum.KeyCode.ButtonB then
			if jei:viewOpen() then
				jei:closeView()
			else
				close()
			end
		elseif key == Enum.KeyCode.ButtonA or key == Enum.KeyCode.ButtonX or key == Enum.KeyCode.ButtonY then
			local object = GuiService.SelectedObject
			-- A JEI item: A its recipes, X its uses, Y (creative) a full stack.
			local item, inList = nil, false
			if object then
				item, inList = jei:itemOf(object)
			end
			if item then
				local jeiButton = if key == Enum.KeyCode.ButtonX
					then SlotClicks.Button.Right
					else SlotClicks.Button.Left
				jei:activate(item, jeiButton, key == Enum.KeyCode.ButtonY, inList)
				return
			end
			local target = if object then targetOf(object) else nil
			if target then
				local right = key == Enum.KeyCode.ButtonX
				clicks:click(
					target,
					if right then SlotClicks.Button.Right else SlotClicks.Button.Left,
					key == Enum.KeyCode.ButtonY,
					now
				)
			end
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseMovement then
			if current == nil then
				return
			end
			local point = Vector2.new(input.Position.X, input.Position.Y)
			if scrollbarHeld then
				creative:pointerMove(point)
			end
			if next(held) ~= nil then
				clicks:move(targetAt(point))
			end
		elseif kind == Enum.UserInputType.Touch then
			touchMoved(input)
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			stickY = input.Position.Y
		end
	end)

	-- (Releases count even over other GUI, so nothing stays held.)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local kind = input.UserInputType
		local button = MOUSE_BUTTONS[kind]
		if button then
			if scrollbarHeld and button == SlotClicks.Button.Left then
				scrollbarHeld = false
				creative:pointerUp()
				return
			end
			if held[button] then
				held[button] = nil
				if current then
					local point = Vector2.new(input.Position.X, input.Position.Y)
					clicks:release(targetAt(point), button, shiftDown(), os.clock())
				end
			end
		elseif kind == Enum.UserInputType.Touch then
			touchEnded(input)
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			stickY = 0
		end
	end)

	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if current then
			layout()
		end
	end)

	--[[ Every frame ]]

	local previewing = false

	RunService.RenderStepped:Connect(function()
		if current == nil then
			return
		end
		local now = os.clock()
		local scale = layout()
		if current == "panel" then
			-- (No slots, carried stack or tooltips on a panel.)
			tooltip.Visible = false
			carried.Visible = false
			return
		end

		-- A touch held still is a right click (on a JEI item: its uses).
		local t = touch
		if t and t.phase == "pending" and now - t.started >= LONG_PRESS then
			local jeiItem = t.jeiItem
			if jeiItem then
				t.phase = "ignored"
				jei:activate(jeiItem, SlotClicks.Button.Right, false, t.jeiList)
			else
				t.phase = "pressed"
				t.button = SlotClicks.Button.Right
				clicks:press(t.target, t.button, false, now)
				clicks:move(t.target)
			end
		end
		-- The right stick scrolls the creative grid (not while the recipe view hides it).
		if
			current == "creative"
			and not jei:viewOpen()
			and math.abs(stickY) > STICK_DEAD_ZONE
			and now >= nextStickScroll
		then
			nextStickScroll = now + STICK_REPEAT
			creative:scrollBy(if stickY > 0 then -1 else 1)
		end

		-- A drag in progress shows its result: draw a copy of the window with it applied.
		local window = ClientInventory.window()
		local shown = window
		local dragged: { [number]: boolean } = {}
		local mode, slots = clicks:dragging()
		-- (Not for spectators, whose drags do nothing.)
		local drag: Types.Action? = if mode ~= nil and #slots > 1
			then { kind = "drag", window = window.id, mode = mode, slots = table.clone(slots) }
			else nil
		if drag and ClientInventory.allows(drag) then
			shown = Menu.copyWindow(window)
			Menu.apply(shown, drag, ClientInventory.isCreative())
			for _, index in slots do
				dragged[index] = true
			end
		end

		local point, hover = pointer()
		local viewing = jei:viewOpen()
		if viewing then
			-- (The panel is hidden behind the recipe view.)
			if previewing then
				previewing = false
				Hud.setPreview(nil)
			end
		elseif current == "creative" then
			creative:render(shown, hover, dragged)
			if shown ~= window or previewing then
				previewing = shown ~= window
				Hud.setPreview(if previewing then shown else nil)
			end
		else
			inventory:render(shown, hover, dragged)
			inventory:follow(point)
		end
		jei:render(now, point)

		-- The carried stack follows the pointer.
		local cursor = shown.inventory.cursor
		local origin = top.AbsolutePosition
		if cursor and point then
			carriedIcon:set(cursor.item, cursor.count, cursor.damage, cursor.data)
			carried.Position = UDim2.fromOffset(point.X - origin.X, point.Y - origin.Y)
			carried.Visible = true
		else
			carried.Visible = false
		end

		-- The hovered item's tooltip (only with nothing carried, like Minecraft), or JEI's: its items
		-- (a tag ingredient says which tag) and its buttons. A slot's stack adds the lines of its
		-- item data.
		local item: number? = nil
		local extra: { Line }? = nil
		local details: { string }? = nil
		if cursor == nil and point then
			item, extra = jei:tooltipAt(point)
			if item == nil and extra == nil and hover then
				if hover.kind == "slot" then
					local stack = Menu.get(window, hover.index)
					item = stack and stack.item
					details = if stack and stack.data then Items.describe(stack) else nil
				elseif hover.kind == "grid" and Items.isValid(hover.item) then
					item = hover.item
				end
			end
			if item == nil and extra == nil and current == "inventory" and not viewing then
				-- What is no item on a panel: a machine's energy bar ("1.2 kJ / 20 kJ").
				local lines = inventory:tooltipAt(point, window)
				if lines then
					local built: { Line } = {}
					for _, text in lines do
						table.insert(built, { text = text, colour = Style.Colour.Text })
					end
					extra = built
				end
			end
		end
		local key = if item then tostring(item) else ""
		if details then
			for _, text in details do
				key ..= `#{text}`
			end
		end
		if extra then
			for _, line in extra do
				key ..= `|{line.text}`
			end
		end
		if key ~= "" and point then
			if key ~= tooltipKey then
				local lines: { Line } = if item then tooltipLines(item, details) else {}
				if extra then
					table.move(extra, 1, #extra, #lines + 1, lines)
				end
				tooltipKey = key
				tooltipSize = buildTooltip(tooltip, lines)
				layout()
			end
			local size = tooltipSize * scale
			local screen = top.AbsoluteSize
			local x = point.X - origin.X + TOOLTIP_OFFSET * scale
			local y = point.Y - origin.Y - TOOLTIP_OFFSET * scale
			if x + size.X > screen.X then
				x = point.X - origin.X - (TOOLTIP_OFFSET + 4) * scale - size.X
			end
			y = math.clamp(y, 0, math.max(0, screen.Y - size.Y))
			tooltip.Position = UDim2.fromOffset(math.max(0, x), y)
			tooltip.Visible = true
		else
			tooltip.Visible = false
		end
	end)
end

return Screens
