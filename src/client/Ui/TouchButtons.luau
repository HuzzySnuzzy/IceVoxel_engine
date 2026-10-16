--!strict
--[[
	The game's touch buttons in their places (Ui/TouchLayout's slots round the jump button), and the
	camera's own two.

	  place     `place(action, slot)` puts ContextActionService's touch button for `action` in its
	            slot (SetPosition, from the safe area's bottom right corner: UDim2 (1, x, 1, y) of
	            the button frame, whose bottom right is that corner), now and again whenever the
	            screen changes (Ui/UiScale.follow) and a moment after joining (Roblox's touch script
	            may make the button after the call: SetPosition before it is lost). The binder
	            places after binding: Player/MovementController (Sprint, Sneak), Ui/WeaponButtons
	            (FIRE, AIM, RELOAD while a firearm is held).
	  VIEW      a tap: Toggle Perspective (Player/CameraRig.touchView).
	  LOOK      held: freelook (Player/CameraRig.touchLook).
	            The game's own buttons (`start`), drawn as ContextActionService draws its own (its
	            round images, the title in bold white), in a ScreenGui of their own below the top
	            bar that Ui/UiScale measures with Roblox's buttons for the HUD's corner to keep
	            clear of; they take none of ContextActionService's seven touch slots. A press
	            never reaches the world or turns the camera (a button takes the touch). Shown only
	            where they do something (TouchLayout.cameraShown: a touch screen, the Touch Buttons
	            setting, the DayZ camera playing, not a spectator); hidden, LOOK lets go.

	Nothing is made per frame: the step compares what shows with what should.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local GameMode = require(Shared.GameMode)

local CameraRig = require(script.Parent.Parent.Player.CameraRig)
local TouchLayout = require(script.Parent.TouchLayout)
local UiScale = require(script.Parent.UiScale)

local TouchButtons = {}

-- ContextActionService's look for a touch button (Roblox's ContextActionTouch).
local BUTTON_UP = "https://www.roblox.com/asset/?id=97166444"
local BUTTON_DOWN = "https://www.roblox.com/asset/?id=97166756"
-- Seconds after a place that it is put again (see the header).
local PLACE_AGAIN = 2

-- ContextActionService's buttons placed here: action -> slot.
local placed: { [string]: TouchLayout.Slot } = {}
local following = false

local function position(slot: TouchLayout.Slot): UDim2
	local viewport, insets = UiScale.viewport(), UiScale.insets()
	local x, y = TouchLayout.offset(slot, viewport.X, viewport.Y, insets)
	return UDim2.new(1, x, 1, y)
end

local function setPosition(action: string, slot: TouchLayout.Slot)
	-- (An action unbound meanwhile has no button: nothing to move.)
	pcall(function()
		ContextActionService:SetPosition(action, position(slot))
	end)
end

local function placeAll()
	for action, slot in placed do
		-- (Iterating widens the slot's type to a string.)
		setPosition(action, slot :: any)
	end
end

--[[
	Puts ContextActionService's touch button for `action` (bound now, with a touch button) in
	`slot`, now and whenever the screen changes.
]]
function TouchButtons.place(action: string, slot: TouchLayout.Slot)
	placed[action] = slot
	setPosition(action, slot)
	task.delay(PLACE_AGAIN, function()
		if placed[action] == slot then
			setPosition(action, slot)
		end
	end)
	if not following then
		following = true
		UiScale.follow(placeAll)
	end
end

--[[ The camera's VIEW and LOOK ]]

type Button = { frame: ImageButton, slot: TouchLayout.Slot }

local started = false

-- One button in ContextActionService's look, titled `title`, in `slot` of `gui`.
local function button(gui: ScreenGui, name: string, title: string, slot: TouchLayout.Slot): Button
	local frame = Instance.new("ImageButton")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.Image = BUTTON_UP
	frame.Size = UDim2.fromOffset(TouchLayout.BUTTON, TouchLayout.BUTTON)
	frame.Position = position(slot)
	frame.Active = true
	frame.AutoButtonColor = false
	local label = Instance.new("TextLabel")
	label.Name = "ActionTitle"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.SourceSansBold
	label.TextSize = 18
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.TextWrapped = true
	label.Text = title
	label.Parent = frame
	frame.Parent = gui
	return { frame = frame, slot = slot }
end

--[[
	Makes the camera's VIEW and LOOK (with Config.Camera.Enabled; once): the boot, after
	Player/CameraRig.start.
]]
function TouchButtons.start()
	if started or not CameraRig.enabled() then
		return
	end
	started = true
	local gui = UiScale.screenGui("IceVoxelTouchButtons", "Hud", { inset = false, kind = "screen", enabled = false })
	local view = button(gui, "View", "VIEW", "view")
	local look = button(gui, "Look", "LOOK", "look")
	-- The finger holding LOOK (its release ends freelook wherever it lifts).
	local lookTouch: InputObject? = nil
	local function letGo()
		if lookTouch ~= nil then
			lookTouch = nil
			look.frame.Image = BUTTON_UP
			CameraRig.touchLook(false)
		end
	end
	view.frame.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch and input.UserInputState == Enum.UserInputState.Begin then
			CameraRig.touchView()
		end
	end)
	look.frame.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.Touch
			and input.UserInputState == Enum.UserInputState.Begin
			and lookTouch == nil
		then
			lookTouch = input
			look.frame.Image = BUTTON_DOWN
			CameraRig.touchLook(true)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input == lookTouch then
			letGo()
		end
	end)
	UiScale.follow(function()
		view.frame.Position = position(view.slot)
		look.frame.Position = position(look.slot)
	end)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	-- Shown where they do something (see the header).
	RunService.RenderStepped:Connect(function()
		local shown = TouchLayout.cameraShown(
			UiScale.touch(),
			Config.Movement.TouchButtons,
			CameraRig.enabled(),
			CameraRig.playing(),
			GameMode.isSpectatorOf(Players.LocalPlayer)
		)
		if gui.Enabled ~= shown then
			gui.Enabled = shown
			if not shown then
				letGo()
			end
		end
	end)
end

return TouchButtons
