--!strict
--[[
	Small reusable GUI pieces for the map: a right-click menu and a text prompt.
]]

local UserInputService = game:GetService("UserInputService")

export type Item = { text: string, action: () -> () }

local ContextMenu = {}

local FONT = Enum.Font.GothamMedium
local ROW = 30
local WIDTH = 190

local function style(button: TextButton, text: string)
	button.Text = text
	button.Font = FONT
	button.TextSize = 15
	button.TextColor3 = Color3.new(1, 1, 1)
	button.BackgroundColor3 = Color3.fromRGB(38, 42, 50)
	button.AutoButtonColor = true
	button.BorderSizePixel = 0
end

local current: Instance? = nil

function ContextMenu.close()
	if current then
		current:Destroy()
		current = nil
	end
end

--[[
	Opens a menu at `position` (GUI coordinates, e.g. InputObject.Position) inside `gui`.
	Clicking an item runs it; clicking anywhere else closes the menu.
]]
function ContextMenu.show(gui: ScreenGui, position: Vector2, items: { Item })
	ContextMenu.close()

	-- Invisible full screen button behind the menu: clicking it closes the menu.
	local holder = Instance.new("TextButton")
	holder.Name = "IceVoxelContextMenu"
	holder.Text = ""
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = 50
	holder.Activated:Connect(ContextMenu.close)
	holder.SecondaryActivated:Connect(ContextMenu.close)

	local menu = Instance.new("Frame")
	menu.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
	menu.BorderSizePixel = 0
	menu.ZIndex = 51
	local height = #items * ROW + 8
	local screen = gui.AbsoluteSize
	menu.Position = UDim2.fromOffset(
		math.clamp(position.X, 0, math.max(0, screen.X - WIDTH)),
		math.clamp(position.Y, 0, math.max(0, screen.Y - height))
	)
	menu.Size = UDim2.fromOffset(WIDTH, height)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = menu
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.PaddingLeft = UDim.new(0, 4)
	padding.PaddingRight = UDim.new(0, 4)
	padding.Parent = menu
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = menu

	for i, item in items do
		local button = Instance.new("TextButton")
		style(button, item.text)
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.BackgroundTransparency = 1
		button.Size = UDim2.new(1, 0, 0, ROW)
		button.LayoutOrder = i
		button.ZIndex = 52
		local inset = Instance.new("UIPadding")
		inset.PaddingLeft = UDim.new(0, 8)
		inset.Parent = button
		button.Activated:Connect(function()
			ContextMenu.close()
			item.action()
		end)
		button.Parent = menu
	end

	menu.Parent = holder
	holder.Parent = gui
	current = holder
end

--[[
	Asks for a line of text. Calls `done(text)` on OK / Enter, or `done(nil)` on cancel.
]]
function ContextMenu.prompt(gui: ScreenGui, title: string, default: string, done: (string?) -> ())
	ContextMenu.close()

	local holder = Instance.new("Frame")
	holder.Name = "IceVoxelPrompt"
	holder.BackgroundColor3 = Color3.new(0, 0, 0)
	holder.BackgroundTransparency = 0.5
	holder.Size = UDim2.fromScale(1, 1)
	holder.Active = true
	holder.ZIndex = 60

	local box = Instance.new("Frame")
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.5)
	box.Size = UDim2.fromOffset(300, 130)
	box.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
	box.ZIndex = 61
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = box
	box.Parent = holder

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(14, 10)
	label.Size = UDim2.new(1, -28, 0, 22)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = title
	label.ZIndex = 62
	label.Parent = box

	local input = Instance.new("TextBox")
	input.Position = UDim2.fromOffset(14, 40)
	input.Size = UDim2.new(1, -28, 0, 32)
	input.BackgroundColor3 = Color3.fromRGB(44, 48, 58)
	input.TextColor3 = Color3.new(1, 1, 1)
	input.Font = FONT
	input.TextSize = 15
	input.Text = default
	input.ClearTextOnFocus = false
	input.ZIndex = 62
	input.Parent = box

	local function finish(text: string?)
		if holder.Parent then
			holder:Destroy()
			done(text)
		end
	end

	local ok = Instance.new("TextButton")
	style(ok, "OK")
	ok.Position = UDim2.new(1, -134, 1, -42)
	ok.Size = UDim2.fromOffset(56, 30)
	ok.ZIndex = 62
	ok.Activated:Connect(function()
		finish(input.Text)
	end)
	ok.Parent = box

	local cancel = Instance.new("TextButton")
	style(cancel, "Cancel")
	cancel.Position = UDim2.new(1, -72, 1, -42)
	cancel.Size = UDim2.fromOffset(60, 30)
	cancel.ZIndex = 62
	cancel.Activated:Connect(function()
		finish(nil)
	end)
	cancel.Parent = box

	input.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			finish(input.Text)
		end
	end)

	holder.Parent = gui
	if UserInputService.KeyboardEnabled then
		input:CaptureFocus()
	end
end

return ContextMenu
