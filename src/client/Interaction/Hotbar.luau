--!strict
--[[
	Block picker: nine slots at the bottom of the screen.

	  1-9 / click or tap a slot   select it
	  Q / E, gamepad L1 / R1      previous / next block (pages through every placeable block)
	  ‹ / › buttons               previous / next page
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)

local SLOTS = 9
local SLOT_SIZE = 44

local NUMBER_KEYS = {
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

export type Hotbar = {
	selected: () -> number,
}

local Hotbar = {}

function Hotbar.new(): Hotbar
	local blocks = Blocks.placeable
	local index = 1

	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelHotbar"
	gui.ResetOnSpawn = false

	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -12)
	bar.Size = UDim2.fromOffset(SLOTS * (SLOT_SIZE + 6) + 2 * (28 + 6), SLOT_SIZE)
	bar.BackgroundTransparency = 1
	bar.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 6)
	layout.Parent = bar

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 1, -SLOT_SIZE - 20)
	label.Size = UDim2.fromOffset(300, 22)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Parent = gui

	local render: () -> ()

	-- Buttons sink their clicks and taps, so tapping the hotbar never breaks the block behind it.
	local function pageButton(text: string, order: number, delta: number)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(28, SLOT_SIZE)
		b.BackgroundColor3 = Color3.fromRGB(30, 32, 38)
		b.BackgroundTransparency = 0.3
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamBold
		b.TextSize = 22
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Text = text
		b.LayoutOrder = order
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = b
		b.Activated:Connect(function()
			local pages = (#blocks - 1) // SLOTS + 1
			local page = ((index - 1) // SLOTS + delta) % pages
			index = page * SLOTS + 1
			render()
		end)
		b.Parent = bar
	end
	if #blocks > SLOTS then
		pageButton("‹", 0, -1)
		pageButton("›", SLOTS + 1, 1)
	end

	local slots: { TextButton } = {}
	local strokes: { UIStroke } = {}
	for i = 1, SLOTS do
		local slot = Instance.new("TextButton")
		slot.Text = ""
		slot.AutoButtonColor = false
		slot.Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE)
		slot.BorderSizePixel = 0
		slot.LayoutOrder = i
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = slot
		local stroke = Instance.new("UIStroke")
		stroke.Parent = slot
		local number = Instance.new("TextLabel")
		number.Size = UDim2.fromOffset(14, 14)
		number.Position = UDim2.fromOffset(3, 2)
		number.BackgroundTransparency = 1
		number.Font = Enum.Font.GothamBold
		number.TextSize = 12
		number.TextColor3 = Color3.new(1, 1, 1)
		number.TextStrokeTransparency = 0.3
		number.Text = tostring(i)
		number.Parent = slot
		slot.Activated:Connect(function()
			local candidate = ((index - 1) // SLOTS) * SLOTS + i
			if blocks[candidate] then
				index = candidate
				render()
			end
		end)
		slot.Parent = bar
		slots[i] = slot
		strokes[i] = stroke
	end

	function render()
		local page = (index - 1) // SLOTS
		for i = 1, SLOTS do
			local id = blocks[page * SLOTS + i]
			local slot = slots[i]
			slot.Visible = id ~= nil
			if id then
				local c = Blocks.get(id).color
				slot.BackgroundColor3 = Color3.fromRGB(c[1], c[2], c[3])
				slot.BackgroundTransparency = Blocks.get(id).transparency * 0.6
			end
			local selected = page * SLOTS + i == index
			strokes[i].Thickness = if selected then 3 else 1
			strokes[i].Color = if selected then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
		end
		label.Text = Blocks.get(blocks[index]).name
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local slot = NUMBER_KEYS[input.KeyCode]
		if slot then
			local candidate = ((index - 1) // SLOTS) * SLOTS + slot
			if blocks[candidate] then
				index = candidate
				render()
			end
		elseif input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.ButtonR1 then
			index = index % #blocks + 1
			render()
		elseif input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.ButtonL1 then
			index = (index - 2) % #blocks + 1
			render()
		end
	end)

	render()
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	return {
		selected = function(): number
			return blocks[index]
		end,
	}
end

return Hotbar
