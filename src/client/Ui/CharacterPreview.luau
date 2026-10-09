--!strict
--[[
	A character shown on the title screen's character pages (Ui/CharacterSelect's preview of the
	highlighted character, Ui/AvatarEditor's of the look being made): the R15 rig the server
	built (Players/CharacterLooks: Roblox builds avatars on the server only) in the player's
	PlayerGui folder "IceVoxelPreviews" ("c<id>" or "editor"), cloned into a WorldModel in a
	ViewportFrame, as the inventory's preview clones the player (Ui/InventoryScreen: scripts out,
	parts anchored, a 30 degree camera framing it, lit from above in front).

	  Rigs     `show(name)` follows that rig: whenever the server puts a new one there (a rebuilt
	           look) it replaces the clone, and `cloned(model)` is told (the editor puts its
	           unsent edits back onto it). `show(nil)` empties the box.
	  Turning  dragging across the box with the mouse or a finger turns the character (a GUI
	           pixel a degree), as Minecraft's and Terraria's previews do.
	Built in the title screen's scaled canvas (Ui/MainMenu), so it follows the GUI scale.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Style = require(script.Parent.Style)

-- The folder the server builds rigs in (Players/CharacterLooks.FOLDER).
local FOLDER = "IceVoxelPreviews"
local FOV = 30
-- Degrees the character turns per GUI pixel dragged.
local TURN = 1

export type Preview = {
	frame: ViewportFrame,
	-- Follows rig `name` (nil: nothing shown).
	show: (self: Preview, name: string?) -> (),
	-- The clone shown now (nil: none yet).
	model: (self: Preview) -> Model?,
	setVisible: (self: Preview, visible: boolean) -> (),
	-- Lets go of everything (the title screen is gone).
	destroy: (self: Preview) -> (),
	-- Called with each new clone.
	cloned: ((model: Model) -> ())?,
}

local CharacterPreview = {}

-- A copy of `rig` fit for the viewport: no scripts, anchored, inert.
local function copy(rig: Model): Model?
	local archivable = rig.Archivable
	rig.Archivable = true
	local ok, result = pcall(function(): Model?
		return rig:Clone()
	end)
	rig.Archivable = archivable
	if not ok or result == nil then
		return nil
	end
	local clone = result :: Model
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BaseScript") or descendant:IsA("Sound") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
	local root = clone:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		clone.PrimaryPart = root
		root.Transparency = 1
	end
	return clone
end

-- A preview box at (x, y), `w` x `h` GUI pixels, in `parent`.
function CharacterPreview.new(parent: Instance, x: number, y: number, w: number, h: number, z: number?): Preview
	local zIndex = z or 5
	local box = Style.inset(parent, x - 1, y - 1, w + 2, h + 2, zIndex, Color3.new(0, 0, 0))
	local viewport = Instance.new("ViewportFrame")
	viewport.BackgroundTransparency = 1
	viewport.Position = UDim2.fromOffset(x, y)
	viewport.Size = UDim2.fromOffset(w, h)
	viewport.ZIndex = zIndex + 1
	viewport.Ambient = Color3.fromRGB(170, 170, 170)
	viewport.LightColor = Color3.fromRGB(150, 150, 150)
	viewport.LightDirection = Vector3.new(-0.4, -1, 0.6)
	viewport.Parent = parent
	local camera = Instance.new("Camera")
	camera.FieldOfView = FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	local world = Instance.new("WorldModel")
	world.Parent = viewport

	local self = { frame = viewport, cloned = nil }
	local wanted: string? = nil
	local clone: Model? = nil
	local yaw = 0
	local watching: { RBXScriptConnection } = {}

	local function stopWatching()
		for _, connection in watching do
			connection:Disconnect()
		end
		table.clear(watching)
	end

	local function clear()
		local old = clone
		clone = nil
		if old then
			old:Destroy()
		end
	end

	local function turn()
		local model = clone
		if model then
			model:PivotTo(CFrame.Angles(0, math.rad(yaw), 0))
		end
	end

	-- Shows a copy of `rig`, framed (upright at the origin facing -Z, the camera in front).
	local function take(rig: Model)
		local made = copy(rig)
		if made == nil then
			return
		end
		clear()
		made:PivotTo(CFrame.identity)
		made.Parent = world
		local centre, size = made:GetBoundingBox()
		local height = math.max(size.Y, 1)
		local aspect = w / h
		local half = math.max(height / 2, size.X / 2 / aspect) / 0.88
		local distance = half / math.tan(math.rad(FOV / 2)) + size.Z / 2
		camera.CFrame = CFrame.lookAt(centre.Position - Vector3.new(0, 0, distance), centre.Position)
		clone = made
		turn()
		local callback = (self :: any).cloned
		if callback then
			callback(made)
		end
	end

	local function watchFolder(folder: Instance)
		local name = wanted
		if name == nil then
			return
		end
		local rig = folder:FindFirstChild(name)
		if rig and rig:IsA("Model") then
			take(rig)
		end
		table.insert(
			watching,
			folder.ChildAdded:Connect(function(child: Instance)
				if child.Name == wanted and child:IsA("Model") then
					-- (Its parts arrive with it; a frame later to be sure.)
					task.defer(function()
						if child.Parent == folder and child.Name == wanted then
							take(child)
						end
					end)
				end
			end)
		)
	end

	function self.show(_: Preview, name: string?)
		if name == wanted then
			return
		end
		wanted = name
		stopWatching()
		clear()
		yaw = 0
		if name == nil then
			return
		end
		local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if gui == nil then
			return
		end
		local folder = gui:FindFirstChild(FOLDER)
		if folder then
			watchFolder(folder)
		else
			table.insert(
				watching,
				gui.ChildAdded:Connect(function(child: Instance)
					if child.Name == FOLDER and wanted == name then
						watchFolder(child)
					end
				end)
			)
		end
	end

	function self.model(_: Preview): Model?
		return clone
	end

	function self.setVisible(_: Preview, visible: boolean)
		viewport.Visible = visible
		box.Visible = visible
	end

	-- Dragging turns it.
	local inputs: { RBXScriptConnection } = {}
	local dragging: InputObject? = nil
	local lastX = 0
	viewport.InputBegan:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			dragging = input
			lastX = input.Position.X
		end
	end)
	table.insert(
		inputs,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			local drag = dragging
			if drag == nil or not viewport.Visible then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseMovement or input == drag then
				local pixels = if viewport.AbsoluteSize.X > 0 then viewport.AbsoluteSize.X / w else 1
				yaw = (yaw + (input.Position.X - lastX) / pixels * TURN) % 360
				lastX = input.Position.X
				turn()
			end
		end)
	)
	table.insert(
		inputs,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			local drag = dragging
			if drag and (input == drag or input.UserInputType == Enum.UserInputType.MouseButton1) then
				dragging = nil
			end
		end)
	)

	function self.destroy(_: Preview)
		stopWatching()
		clear()
		for _, connection in inputs do
			connection:Disconnect()
		end
		table.clear(inputs)
	end

	return (self :: any) :: Preview
end

return CharacterPreview
