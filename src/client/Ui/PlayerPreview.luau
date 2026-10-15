--!strict
--[[
	The player in the survival inventory's centre column (Ui/InventoryScreen): the character cloned
	into a WorldModel in a ViewportFrame, drawn unboxed (no face, no frame: the dimmed world shows
	around it), filling whatever rect the screen gives it (`setRect`, the character section's body).

	  opened     clones Players.LocalPlayer.Character (scripts, sounds, constraints, movers and
	             particles removed, parts anchored), upright at the origin facing the camera, and
	             fits the camera to it for the rect's shape (again on every setRect)
	  update     the selected hotbar item in its hand (ItemModels at ItemModels.handPivot, as
	             Player/HeldItems holds it; rebuilt only when the item or the item looks change),
	             and what the character shows (Player/EquipmentLooks.dress, again only when an
	             armor or equipment stack, the hidden bits or the open slots changed)
	  follow     turns it towards the pointer like Minecraft's renderEntityInInventoryFollowsMouse:
	             atan(offset / 40 GUI pixels) x 20 degrees
	  closed     destroys the clone

	Nothing is done per frame but the cheap compares in `update` and the turn in `follow`.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Accessories = require(Shared.Items.Accessories)
local Types = require(Shared.Inventory.Types)

local ItemModels = require(script.Parent.Parent.Rendering.ItemModels)
local EquipmentLooks = require(script.Parent.Parent.Player.EquipmentLooks)

type Window = Types.Window

local FOV = 30
-- Share of the frame's height the character fills.
local FILL = 0.9
-- GUI pixels of pointer offset for Minecraft's turn (atan(dx / FOLLOW) x FOLLOW_ANGLE).
local FOLLOW = 40
local FOLLOW_ANGLE = math.rad(20)

export type PlayerPreview = {
	frame: ViewportFrame,
	setRect: (self: PlayerPreview, x: number, y: number, w: number, h: number) -> (),
	opened: (self: PlayerPreview) -> (),
	closed: (self: PlayerPreview) -> (),
	update: (self: PlayerPreview, window: Window) -> (),
	follow: (self: PlayerPreview, point: Vector2?) -> (),
}

type Self = PlayerPreview & {
	camera: Camera,
	world: WorldModel,
	w: number,
	h: number,
	clone: Model?,
	-- The clone's bounds (centre and size), for fitting the camera to a new rect.
	centre: Vector3,
	size: Vector3,
	yaw: number,
	-- The item drawn in its hand (false: not drawn yet), its model and the item looks generation.
	heldItem: number | false | nil,
	heldModel: Model?,
	heldLook: number,
	-- What it was dressed from (stacks are values: a change is a new table), the looks text and the
	-- pieces' folder.
	looksRefs: { any },
	looksText: string?,
	looksFolder: Folder?,
}

local PlayerPreview = {}
PlayerPreview.__index = PlayerPreview

function PlayerPreview.new(parent: Instance, z: number?): PlayerPreview
	local frame = Instance.new("ViewportFrame")
	frame.Name = "Character"
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ZIndex = z or 2
	frame.Ambient = Color3.fromRGB(170, 170, 170)
	frame.LightColor = Color3.fromRGB(140, 140, 140)
	frame.LightDirection = Vector3.new(-0.4, -1, 0.6)
	frame.Parent = parent
	local camera = Instance.new("Camera")
	camera.FieldOfView = FOV
	camera.Parent = frame
	frame.CurrentCamera = camera
	local world = Instance.new("WorldModel")
	world.Parent = frame
	local self = {
		frame = frame,
		camera = camera,
		world = world,
		w = 1,
		h = 1,
		clone = nil,
		centre = Vector3.zero,
		size = Vector3.one,
		yaw = math.huge,
		heldItem = false,
		heldModel = nil,
		heldLook = 0,
		looksRefs = {},
		looksText = nil,
		looksFolder = nil,
	}
	return (setmetatable(self, PlayerPreview) :: any) :: PlayerPreview
end

-- Fits the camera to the clone for the frame's shape.
local function fit(self: Self)
	if self.clone == nil then
		return
	end
	local size = self.size
	local aspect = if self.h > 0 then self.w / self.h else 1
	local half = math.max(math.max(size.Y, 1) / 2, size.X / 2 / math.max(aspect, 0.1)) / FILL
	local distance = half / math.tan(math.rad(FOV / 2)) + size.Z / 2
	self.camera.CFrame = CFrame.lookAt(self.centre - Vector3.new(0, 0, distance), self.centre)
end

-- Puts the frame at (x, y), `w` x `h` (GUI pixels in its parent).
function PlayerPreview.setRect(self: Self, x: number, y: number, w: number, h: number)
	self.frame.Position = UDim2.fromOffset(x, y)
	self.frame.Size = UDim2.fromOffset(w, h)
	if w ~= self.w or h ~= self.h then
		self.w, self.h = w, h
		fit(self)
	end
end

local function cloneCharacter(): Model?
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil
	end
	local archivable = character.Archivable
	character.Archivable = true
	local ok, result = pcall(function()
		return character:Clone()
	end)
	character.Archivable = archivable
	if not ok or result == nil then
		return nil
	end
	local clone = result :: Model
	for _, descendant in clone:GetDescendants() do
		if
			descendant:IsA("BaseScript")
			or descendant:IsA("Sound")
			or descendant:IsA("Constraint")
			or descendant:IsA("BodyMover")
			or descendant:IsA("VectorForce")
			or descendant:IsA("ParticleEmitter")
		then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		elseif descendant:IsA("Humanoid") then
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	local root = clone:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		clone.PrimaryPart = root
		root.Transparency = 1
	end
	return clone
end

-- Builds the character (when the screen opens).
function PlayerPreview.opened(self: Self)
	self:closed()
	local clone = cloneCharacter()
	if clone == nil then
		return
	end
	-- Upright at the origin facing -Z, the camera in front of it (on the -Z side).
	clone:PivotTo(CFrame.identity)
	clone.Parent = self.world
	local box, size = clone:GetBoundingBox()
	self.centre, self.size = box.Position, size
	self.clone = clone
	self.yaw = 0
	self.heldItem = false
	-- (Dressed by the next update.)
	table.clear(self.looksRefs)
	self.looksText = nil
	self.looksFolder = nil
	fit(self)
end

function PlayerPreview.closed(self: Self)
	local clone = self.clone
	if clone then
		clone:Destroy()
		self.clone = nil
	end
	self.heldModel = nil
	self.heldItem = false
	self.looksFolder = nil
	self.looksText = nil
end

-- Puts the selected item in the hand (rebuilt only when it or item looks change).
local function updateHeld(self: Self, window: Window)
	local inventory = window.inventory
	local stack = inventory.slots[inventory.selected]
	local item = if stack and stack.count > 0 then stack.item else nil
	local look = ItemModels.generation()
	if item == self.heldItem and look == self.heldLook then
		return
	end
	self.heldItem = item
	self.heldLook = look
	local old = self.heldModel
	if old then
		old:Destroy()
		self.heldModel = nil
	end
	local clone = self.clone
	-- Held as Player/HeldItems holds it on characters (tools upright from the fist).
	local at = if clone and item then ItemModels.handPivot(item, clone) else nil
	if clone and at and item then
		local model = ItemModels.build(item, ItemModels.handSize(item))
		model:PivotTo(at)
		-- Inside the clone, so it turns with it.
		model.Parent = clone
		self.heldModel = model
	end
end

-- Keeps `value` at `refs[i]`; true when it was something else.
local function differs(refs: { any }, i: number, value: any): boolean
	if refs[i] ~= value then
		refs[i] = value
		return true
	end
	return false
end

-- Dresses the clone in what the character shows (see the header).
local function updateLooks(self: Self, window: Window)
	local clone = self.clone
	if clone == nil then
		return
	end
	local inventory = window.inventory
	local refs = self.looksRefs
	local changed = false
	local i = 0
	for slot = 1, Types.ARMOR_SIZE do
		changed = differs(refs, i + 1, inventory.armor[slot]) or changed
		changed = differs(refs, i + 2, inventory.vanityArmor[slot]) or changed
		i += 2
	end
	for slot = 1, Types.ACCESSORY_SIZE do
		changed = differs(refs, i + 1, inventory.accessories[slot]) or changed
		changed = differs(refs, i + 2, inventory.vanityAccessories[slot]) or changed
		i += 2
	end
	changed = differs(refs, i + 1, inventory.hidden) or changed
	changed = differs(refs, i + 2, inventory.accessorySlots) or changed
	if not changed and self.looksText ~= nil then
		return
	end
	local looks = Accessories.looks(inventory)
	if looks == self.looksText then
		return
	end
	self.looksText = looks
	local old = self.looksFolder
	if old then
		old:Destroy()
	end
	self.looksFolder = EquipmentLooks.dress(clone, looks)
end

function PlayerPreview.update(self: Self, window: Window)
	updateHeld(self, window)
	updateLooks(self, window)
end

-- Turns the character towards `point` (screen pixels), or back to the front without one.
function PlayerPreview.follow(self: Self, point: Vector2?)
	local clone = self.clone
	if clone == nil then
		return
	end
	local yaw = 0
	if point and self.frame.Visible then
		local position, size = self.frame.AbsolutePosition, self.frame.AbsoluteSize
		local pixels = if self.w > 0 then size.X / self.w else 0
		if pixels > 0 then
			local dx = (point.X - (position.X + size.X / 2)) / pixels
			yaw = math.atan(dx / FOLLOW) * FOLLOW_ANGLE
		end
	end
	if math.abs(yaw - self.yaw) > 1e-3 then
		self.yaw = yaw
		clone:PivotTo(CFrame.Angles(0, yaw, 0))
	end
end

return PlayerPreview
