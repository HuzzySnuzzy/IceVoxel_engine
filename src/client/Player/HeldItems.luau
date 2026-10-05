--!strict
--[[
	The item each player holds (their selected hotbar slot), as Minecraft shows it:

	  third person  a small model of the item in every character's right hand. The server sets the
	                player attribute Types.HELD_ATTRIBUTE; every client draws the models itself
	                (anchored, inert, moved with the hand each frame), so nothing extra replicates.
	                The local player's comes from the predicted inventory, so it changes at once.
	  first person  the local player's item in the bottom right corner of the screen, in a
	                ViewportFrame, dipping in a short swing when breaking or placing (`swing`).

	Blocks and most items are held turned like a block. Tools and sticks are held like Minecraft's
	"handheld" items (ItemModels.handPivot / holdPivot): at the handle, upright rather than lying
	diagonally as in their icon. In third person they point forward and up from the fist; in first
	person they rise from the bottom right corner towards the middle, leaning left, their face to
	the camera, and chop forward when swinging.

	Nothing is drawn for an empty hand or while a Tool is equipped, nor for spectators (Shared/
	GameMode): their body is invisible or a floating head (Player/SpectatorRules), and in first
	person they have no hand. A third person model hides with its character's head when the camera
	fades that out: the local player's in first person, and the player a spectator spectates, whose
	eyes the camera is in (Roblox fades the camera subject's character).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Types = require(Shared.Inventory.Types)

local ItemModels = require(script.Parent.Parent.Rendering.ItemModels)
local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Screens = require(script.Parent.Parent.Ui.Screens)

-- Minecraft's arm swing lasts 6 ticks.
local SWING_TIME = 0.3
-- The camera counts as first person this close (studs) to its focus.
local FIRST_PERSON_DISTANCE = 1

local HeldItems = {}

local swingStart = -math.huge

-- Plays the first person swing (breaking, placing).
function HeldItems.swing()
	swingStart = os.clock()
end

-- `parts` and `hidden` let the first person hiding write only when it changes.
type Held = { item: number, model: Model, parts: { BasePart }, hidden: boolean }

-- First person pose of a block (or any item but tools): `dip` is the swing, 0..1..0.
local function blockPose(dip: number): CFrame
	return CFrame.new(0.35 - 0.25 * dip, -0.45 - 0.2 * dip, -2.4)
		* CFrame.Angles(math.rad(-15 - 40 * dip), math.rad(40), math.rad(5))
end

--[[
	First person pose of a tool's upright view space, at its grip: low in the bottom right corner
	(the handle runs off the bottom), leaning left towards the middle, tipped away a little and
	turned so its face shows. Swinging chops it forward and down towards the middle.
]]
local function toolPose(dip: number): CFrame
	return CFrame.new(0.5 - 0.2 * dip, -0.62 - 0.1 * dip, -2.2)
		* CFrame.Angles(math.rad(-25 - 55 * dip), math.rad(-20), 0)
		* CFrame.Angles(0, 0, math.rad(30))
end

function HeldItems.start()
	local localPlayer = Players.LocalPlayer
	local folder = Instance.new("Folder")
	folder.Name = "IceVoxelHeldItems"
	folder.Parent = workspace.CurrentCamera

	local held: { [Player]: Held } = {}

	local function clear(player: Player)
		local current = held[player]
		if current then
			current.model:Destroy()
			held[player] = nil
		end
	end

	local function itemOf(player: Player): number
		if GameMode.isSpectator(GameMode.of(player)) then
			return 0
		end
		if player == localPlayer then
			local stack = ClientInventory.selectedStack()
			return if stack then stack.item else 0
		end
		local item = player:GetAttribute(Types.HELD_ATTRIBUTE)
		return if type(item) == "number" then item else 0
	end

	-- First person view: a viewport in the bottom right corner.
	local gui = Instance.new("ScreenGui")
	gui.Name = "IceVoxelHand"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -1
	local viewport = Instance.new("ViewportFrame")
	viewport.AnchorPoint = Vector2.new(1, 1)
	viewport.Position = UDim2.fromScale(1, 1)
	viewport.Size = UDim2.fromScale(0.45, 0.45)
	viewport.SizeConstraint = Enum.SizeConstraint.RelativeYY
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(150, 150, 150)
	viewport.LightColor = Color3.fromRGB(190, 190, 190)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
	viewport.Visible = false
	viewport.Parent = gui
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.new(0, 0, 0)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	local handItem = 0
	local handModel: Model? = nil

	RunService.RenderStepped:Connect(function()
		-- Third person: every character's hand.
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local item = itemOf(player)
			local where = if character and item ~= 0 then ItemModels.handPivot(item, character) else nil
			if
				character == nil
				or humanoid == nil
				or humanoid.Health <= 0
				or item == 0
				or where == nil
				or character:FindFirstChildOfClass("Tool") ~= nil
			then
				clear(player)
			else
				local current = held[player]
				if current == nil or current.item ~= item then
					clear(player)
					local model = ItemModels.build(item, ItemModels.handSize(item))
					model.Parent = folder
					local parts: { BasePart } = {}
					for _, part in model:GetDescendants() do
						if part:IsA("BasePart") then
							table.insert(parts, part)
						end
					end
					-- New parts are visible (LocalTransparencyModifier 0).
					current = { item = item, model = model, parts = parts, hidden = false }
					held[player] = current
				end
				assert(current, "held model")
				current.model:PivotTo(where)
				-- Hidden with the camera subject's character in first person (Roblox hides the body
				-- there): the local player's, or the one a spectator spectates.
				local head = character:FindFirstChild("Head")
				local hidden = head ~= nil and head:IsA("BasePart") and head.LocalTransparencyModifier > 0.5
				if hidden ~= current.hidden then
					current.hidden = hidden
					for _, part in current.parts do
						part.LocalTransparencyModifier = if hidden then 1 else 0
					end
				end
			end
		end
		for player in held do
			if player.Parent == nil then
				clear(player)
			end
		end

		-- First person: the item in the corner.
		local view = workspace.CurrentCamera
		local firstPerson = (view.CFrame.Position - view.Focus.Position).Magnitude < FIRST_PERSON_DISTANCE
		local character = localPlayer.Character
		local item = itemOf(localPlayer)
		local show = firstPerson
			and item ~= 0
			and not Screens.isOpen()
			and character ~= nil
			and character:FindFirstChildOfClass("Tool") == nil
		viewport.Visible = show
		if not show then
			return
		end
		if handItem ~= item or handModel == nil then
			if handModel then
				handModel:Destroy()
			end
			local model = ItemModels.build(item, 1)
			model.Parent = viewport
			handModel = model
			handItem = item
		end
		-- Minecraft's swing: the item dips towards the centre and back.
		local t = math.clamp((os.clock() - swingStart) / SWING_TIME, 0, 1)
		local dip = math.sin(t * math.pi)
		local model = handModel :: Model
		if ItemModels.isHandheld(item) then
			model:PivotTo(ItemModels.holdPivot(item, 1, toolPose(dip)))
		else
			model:PivotTo(blockPose(dip))
		end
	end)

	Players.PlayerRemoving:Connect(clear)
end

return HeldItems
