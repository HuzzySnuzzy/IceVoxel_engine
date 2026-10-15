--!strict
--[[
	The survival inventory's GROUND strip (Ui/InventoryScreen's VICINITY column, right under its
	top header): the dropped items near the player, and the one place inside the screen where a
	carried stack is thrown (SlotClicks' `outside`).

	  items     the dropped items within Config.Ui.GroundRadius blocks of the character
	            (EntityRenderer.itemsNear around Origin.renderToBlocks of the HumanoidRootPart),
	            nearest first, in a fixed pool of InventoryColumns.GROUND_SLOTS dayz icons at the
	            strip's places; looked up every Config.Ui.GroundRefresh seconds while the screen
	            is drawn (GroundRadius 0: never; the strip stays as the place to throw things).
	            They are not slots: walking over an item picks it up (the tooltip says so); a
	            click there with nothing carried does nothing.
	  throwing  while a stack is carried the strip is outlined in the drop colour (white at
	            Theme.FEEDBACK_T), plain white while the pointer is over it; an empty strip says
	            "Drop here" while carrying. A transparent button over it is what a gamepad selects
	            to throw (the screen's `targetOf` says `outside` for it).

	Entities/EntityRenderer is required on first use, not at load: it requires the movement
	controller, which requires Ui/Screens, which requires this module through the inventory
	screen (a require cycle at load would stop the client).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Origin = require(Shared.World.Origin)

local InventoryColumns = require(script.Parent.InventoryColumns)
local ItemIcon = require(script.Parent.ItemIcon)
local Style = require(script.Parent.Style)

local Dayz = Style.Dayz

-- What the tooltip of a ground item says under its name.
local HINT = "Walk over it to pick it up"
local DROP_HERE = "Drop here"

type Place = { icon: ItemIcon.ItemIcon, hit: Frame, item: number?, count: number }

-- A dropped item as EntityRenderer.itemsNear lists it (its ItemView).
type ItemView = { id: number, item: number, count: number, x: number, y: number, z: number }
type ItemsNear = (x: number, y: number, z: number, radius: number) -> { ItemView }

-- EntityRenderer.itemsNear, required on first use (see the header).
local itemsNear: ItemsNear? = nil
local function near(x: number, y: number, z: number, radius: number): { ItemView }
	local found = itemsNear
	if found == nil then
		local renderer = (require :: any)(script.Parent.Parent.Entities.EntityRenderer)
		found = renderer.itemsNear :: ItemsNear
		itemsNear = found
	end
	return (found :: ItemsNear)(x, y, z, radius)
end

export type GroundStrip = {
	-- The transparent button over the strip (Selectable: a gamepad throws by selecting it).
	button: TextButton,
	render: (self: GroundStrip, now: number, carrying: boolean, over: boolean) -> (),
	tooltipAt: (self: GroundStrip, point: Vector2) -> { string }?,
	covers: (self: GroundStrip, point: Vector2) -> boolean,
	-- Forgets the items shown (the screen closed).
	reset: (self: GroundStrip) -> (),
}

type Self = GroundStrip & {
	places: { Place },
	outline: Frame,
	hint: TextLabel,
	nextLook: number,
	shown: number,
}

local GroundStrip = {}
GroundStrip.__index = GroundStrip

-- The strip in `body` (its headerless section's body, InventoryColumns.GROUND_H tall).
function GroundStrip.new(body: Frame, scaled: Style.Scaled): GroundStrip
	local button = Instance.new("TextButton")
	button.Name = "Ground"
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundTransparency = 1
	button.BorderSizePixel = 0
	button.Size = UDim2.fromScale(1, 1)
	button.ZIndex = 2
	button.SelectionImageObject = Style.selectionImage
	button.Parent = body

	local outline = Instance.new("Frame")
	outline.Name = "Drop"
	outline.BackgroundTransparency = 1
	outline.BorderSizePixel = 0
	outline.Size = UDim2.fromScale(1, 1)
	outline.ZIndex = 8
	outline.Visible = false
	Dayz.outline(outline, nil, nil, scaled)
	outline.Parent = body

	local hint =
		Dayz.label(body, DROP_HERE, 0, 0, 0, 0, "small", Dayz.Colour.TextMuted, 6, Enum.TextXAlignment.Center, scaled)
	hint.Size = UDim2.fromScale(1, 1)
	hint.Visible = false

	local places: { Place } = {}
	for _, spot in InventoryColumns.spots("ground", { equipment = false } :: any) do
		local icon = ItemIcon.new(body, spot.x, spot.y, 5, "dayz", scaled)
		local hit = Instance.new("Frame")
		hit.Name = "Item"
		hit.BackgroundTransparency = 1
		hit.BorderSizePixel = 0
		hit.Position = UDim2.fromOffset(spot.x - 1, spot.y - 1)
		hit.Size = UDim2.fromOffset(Style.SLOT, Style.SLOT)
		hit.ZIndex = 3
		hit.Visible = false
		hit.Parent = body
		table.insert(places, { icon = icon, hit = hit, item = nil, count = 0 })
	end

	local self = {
		button = button,
		places = places,
		outline = outline,
		hint = hint,
		nextLook = 0,
		shown = 0,
	}
	return (setmetatable(self, GroundStrip) :: any) :: GroundStrip
end

-- Where the character is in world blocks (its HumanoidRootPart), nil without a character.
local function whereAmI(): (number?, number, number)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local x, y, z = Origin.renderToBlocks(root.Position)
		return x, y, z
	end
	return nil, 0, 0
end

-- Looks up the dropped items near the character into the pool (nearest first).
local function look(self: Self)
	local radius = Config.Ui.GroundRadius
	local x, y, z = whereAmI()
	local found: { ItemView } = {}
	if radius > 0 and x then
		found = near(x, y, z, radius)
		table.sort(found, function(a: ItemView, b: ItemView): boolean
			local da = (a.x - x) ^ 2 + (a.y - y) ^ 2 + (a.z - z) ^ 2
			local db = (b.x - x) ^ 2 + (b.y - y) ^ 2 + (b.z - z) ^ 2
			if da ~= db then
				return da < db
			end
			return a.id < b.id
		end)
	end
	local shown = 0
	for i, place in self.places do
		local view = found[i]
		local item = if view then view.item else nil
		local count = if view then view.count else 0
		if item ~= place.item or count ~= place.count then
			place.item, place.count = item, count
			place.icon:set(item, count)
			place.hit.Visible = item ~= nil
		end
		if item then
			shown += 1
		end
	end
	self.shown = shown
end

--[[
	Every frame the screen is drawn: the items again every GroundRefresh seconds, the drop outline
	while `carrying` (plain white when the pointer is `over` the strip), "Drop here" on an empty
	strip while carrying.
]]
function GroundStrip.render(self: Self, now: number, carrying: boolean, over: boolean)
	if now >= self.nextLook then
		self.nextLook = now + math.max(Config.Ui.GroundRefresh, 0.05)
		look(self)
	end
	Dayz.setLit(self.outline, carrying, if over then nil else "drop")
	local hint = carrying and self.shown == 0
	if self.hint.Visible ~= hint then
		self.hint.Visible = hint
	end
end

-- A ground item's tooltip under `point`: its name, its count, how to pick it up.
function GroundStrip.tooltipAt(self: Self, point: Vector2): { string }?
	for _, place in self.places do
		local item = place.item
		if item and Style.contains(place.hit, point) then
			local name = Items.displayName(item)
			if place.count > 1 then
				return { name, `x {place.count}`, HINT }
			end
			return { name, HINT }
		end
	end
	return nil
end

-- Is `point` over the strip (the throw place)?
function GroundStrip.covers(self: Self, point: Vector2): boolean
	return Style.shown(self.button) and Style.contains(self.button, point)
end

function GroundStrip.reset(self: Self)
	self.nextLook = 0
	for _, place in self.places do
		if place.item then
			place.item, place.count = nil, 0
			place.icon:set(nil)
			place.hit.Visible = false
		end
	end
	self.shown = 0
end

return GroundStrip
