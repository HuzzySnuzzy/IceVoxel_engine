--!strict
--[[
	The open block's section body in the survival inventory (Ui/InventoryScreen's VICINITY column):
	MenuLayout's panel for the block's window drawn in the survival look, its title strip cut off
	(every spot, gauge, bar, tank, status and line moved up InventoryColumns.BODY_CUT):

	  chest     rows of 9 under the section's "CHEST (n/27)" bar
	  crafting  the 3 x 3 grid, a chevron, the result in its large frame
	  furnace   the input over the fuel, the result; the flame and the progress as thin bars
	  machine   a Mekanism machine (Shared/Machines): its kind's slots (an empty upgrade slot shows
	            its card's outline), its gauges, the energy bar, a fluid gauge per tank, the status
	            line and the lines under it (a battery's input and output)

	The gauges in this look, all from the window's container `data` like before (MenuLayout's
	maths: flameRows, arrowColumns, the machines' sources, energyRows, tankRows):

	  progress  (the furnace's and a machine's arrow) a horizontal bar 2 tall across the arrow's
	            place, white on the light track (Theme Quantity on QuantityTrack)
	  fuel      (the flame) the same bar in the Fuel orange
	  energy    a vertical bar 2 wide down the middle of Mekanism's bar place, filling from the
	            bottom in Machines.energyColour (hovering the place says "stored / capacity")
	  tanks     the gauge's frame on the TankTrack shade, the fluid's colour filling its inside from
	            the bottom, no scale marks (hovering says "Lava: 5,000 mB" and its capacity)
	  arrows    a crafting table's static arrow: a chevron (Ui/Silhouettes "chevron") in Chevron
	            white, 8 x 8 in the middle of the arrow's place
	  text      the status line and the extra lines in small soft text, cut short with "..." before
	            the energy bar

	Slots are SlotWidgets in the "container" group (the screen draws and hit-tests them); grid lines
	(InventoryColumns.gridLines) sit under them on the section's slab. Nothing here runs per frame
	unless the container's data changed (snapshots replace the data table, so the same table shows
	the same; the furnace's bars write only on a change).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Fluids = require(Shared.Fluids)
local Types = require(Shared.Inventory.Types)

local InventoryColumns = require(script.Parent.InventoryColumns)
local MenuLayout = require(script.Parent.MenuLayout)
local SlotWidgets = require(script.Parent.SlotWidgets)
local Style = require(script.Parent.Style)
local Theme = require(script.Parent.Theme)

type Window = Types.Window

local Dayz = Style.Dayz

-- (Gauge bars, the chevron and the room kept right of a status line: Theme.Size's GAUGE, CHEVRON
-- and LINE_ROOM.)
local Size = Theme.Size
-- A text line's height.
local LINE_H = 8

-- A machine's tank gauge: its frame, the fluid filling it (rows and fluid shown).
type Tank = { frame: Frame, fill: Frame, spot: MenuLayout.TankSpot, shown: number, fluid: number }

export type ContainerPanel = {
	layout: MenuLayout.Panel,
	render: (self: ContainerPanel, window: Window) -> (),
	tooltipAt: (self: ContainerPanel, point: Vector2, window: Window) -> { string }?,
	destroy: (self: ContainerPanel) -> (),
}

type Self = ContainerPanel & {
	parts: { GuiObject },
	flame: Style.Bar?,
	progress: Style.Bar?,
	energy: Style.Bar?,
	energyHit: Frame?,
	energyColour: string,
	status: TextLabel?,
	lines: { TextLabel },
	tanks: { Tank },
	machineData: { number }?,
	machineShown: boolean,
}

local ContainerPanel = {}
ContainerPanel.__index = ContainerPanel

-- A horizontal bar `Size.GAUGE` tall across the middle of `rect` (body coordinates), on the light track.
local function quantityBar(body: Frame, rect: MenuLayout.Rect, cut: number, colour: Color3): Style.Bar
	local bar =
		Dayz.bar(body, rect.x, rect.y + cut + math.floor((rect.h - Size.GAUGE) / 2), rect.w, Size.GAUGE, false, 4)
	bar.track.BackgroundColor3 = Dayz.Colour.QuantityTrack
	bar.track.BackgroundTransparency = Dayz.Alpha.QuantityTrack
	bar.fill.BackgroundColor3 = colour
	return bar
end

-- A transparent Frame over `rect` (the parts hovered for a tooltip).
local function hitFrame(body: Frame, rect: MenuLayout.Rect, cut: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Hit"
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Position = UDim2.fromOffset(rect.x, rect.y + cut)
	frame.Size = UDim2.fromOffset(rect.w, rect.h)
	frame.ZIndex = 3
	frame.Parent = body
	return frame
end

--[[
	The block's content in `body` (its section's body): MenuLayout's `layout` for `container`, its
	slots made in `widgets` (group "container"), scaled with `scaled`.
]]
function ContainerPanel.new(
	body: Frame,
	layout: MenuLayout.Panel,
	widgets: SlotWidgets.SlotWidgets,
	scaled: Style.Scaled
): ContainerPanel
	local cut = InventoryColumns.containerOffset()
	local self = (
		setmetatable({
			layout = layout,
			parts = {},
			flame = nil,
			progress = nil,
			energy = nil,
			energyHit = nil,
			energyColour = "",
			status = nil,
			lines = {},
			tanks = {},
			machineData = nil,
			machineShown = false,
		}, ContainerPanel) :: any
	) :: Self
	local parts = self.parts

	-- The slab's grid lines, then the slots over them.
	local spots: { InventoryColumns.Spot } = {}
	for _, at in layout.slots do
		table.insert(spots, {
			store = "container",
			slot = at.slot,
			x = at.x,
			y = at.y + cut,
			big = at.big,
			ghost = at.ghost,
		})
	end
	for _, line in Dayz.lines(body, InventoryColumns.gridLines(spots), 1) do
		table.insert(parts, line)
	end
	for _, at in spots do
		local widget = widgets:slot(body, "container", at.x, at.y, "container", at.slot, at.big, scaled)
		-- (A machine's upgrade slots show the card's outline while empty.)
		local ghost = at.ghost
		if ghost then
			widgets:art(widget, ghost)
		end
	end

	-- A crafting table's static arrow: a chevron.
	local arrow = layout.arrow
	if arrow then
		local chevron = Dayz.silhouette(
			body,
			"chevron",
			arrow.x + math.floor((arrow.w - Size.CHEVRON) / 2),
			arrow.y + cut + math.floor((arrow.h - Size.CHEVRON) / 2),
			Size.CHEVRON,
			Size.CHEVRON,
			Dayz.Colour.Chevron,
			Dayz.Alpha.Chevron,
			3
		)
		table.insert(parts, chevron)
	end
	local flame = layout.flame
	if flame then
		local bar = quantityBar(body, flame, cut, Dayz.Colour.Fuel)
		self.flame = bar
		table.insert(parts, bar.track)
	end
	local progress = layout.progress
	if progress then
		local bar = quantityBar(body, progress, cut, Dayz.Colour.Quantity)
		self.progress = bar
		table.insert(parts, bar.track)
	end
	local energy = layout.energy
	if energy then
		-- Mekanism's power bar: a thin bar down its middle, filling from the bottom.
		local bar = Dayz.bar(
			body,
			energy.x + math.floor((energy.w - Size.GAUGE) / 2),
			energy.y + cut,
			Size.GAUGE,
			energy.h,
			true,
			4
		)
		self.energy = bar
		self.energyHit = hitFrame(body, energy, cut)
		table.insert(parts, bar.track)
		table.insert(parts, self.energyHit :: Frame)
	end
	local status = layout.status
	if status then
		local label = Dayz.label(
			body,
			"",
			status.x,
			status.y + cut,
			MenuLayout.WIDTH - status.x - Size.LINE_ROOM,
			LINE_H,
			"small",
			Dayz.Colour.TextSoft,
			5,
			Enum.TextXAlignment.Left,
			scaled
		)
		-- (A long line ends in "..." before the energy bar instead of running under it.)
		label.TextTruncate = Enum.TextTruncate.AtEnd
		self.status = label
		table.insert(parts, label)
	end
	for _, at in layout.lines do
		local label = Dayz.label(
			body,
			"",
			at.x,
			at.y + cut,
			MenuLayout.WIDTH - at.x - Size.LINE_ROOM,
			LINE_H,
			"small",
			Dayz.Colour.TextSoft,
			5,
			Enum.TextXAlignment.Left,
			scaled
		)
		label.TextTruncate = Enum.TextTruncate.AtEnd
		table.insert(self.lines, label)
		table.insert(parts, label)
	end
	for _, spot in layout.tanks do
		-- Mekanism's GuiFluidGauge: its frame shaded, the fluid filling its inside from the bottom.
		local rect = spot.frame
		local frame = Style.frame(body, rect.x, rect.y + cut, rect.w, rect.h, Dayz.Colour.TankTrack, 4)
		frame.BackgroundTransparency = Dayz.Alpha.TankTrack
		Dayz.outline(frame, Dayz.Colour.Hairline, Dayz.Alpha.Hairline, scaled)
		local inner = spot.inner
		local fill =
			Style.frame(frame, inner.x - rect.x, inner.y - rect.y + inner.h, inner.w, 0, Dayz.Colour.TankTrack, 1)
		table.insert(self.tanks, { frame = frame, fill = fill, spot = spot, shown = -1, fluid = -1 })
		table.insert(parts, frame)
	end
	return self
end

-- A machine's tank gauges from its `data` (MenuLayout.tankRows / tankFluid / tankColour).
local function renderTanks(self: Self, data: { number }?)
	for _, tank in self.tanks do
		local spot = tank.spot
		local rows = MenuLayout.tankRows(data, spot)
		local fluid = MenuLayout.tankFluid(data, spot)
		if rows ~= tank.shown then
			tank.shown = rows
			local inner = spot.inner
			tank.fill.Position = UDim2.fromOffset(inner.x - spot.frame.x, inner.y - spot.frame.y + inner.h - rows)
			tank.fill.Size = UDim2.fromOffset(inner.w, rows)
		end
		if fluid ~= tank.fluid then
			tank.fluid = fluid
			local rgb = MenuLayout.tankColour(fluid)
			tank.fill.BackgroundColor3 = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
			-- (Water and fuel show a little of the gauge's back through them; lava and oil none.)
			local record = Fluids.get(fluid)
			tank.fill.BackgroundTransparency = if record and record.light == 0 and fluid ~= Fluids.OIL then 0.1 else 0
		end
	end
end

-- A machine's energy bar from its `data` (MenuLayout.energyRows / energyColour).
local function renderEnergy(self: Self, data: { number }?)
	local bar, energy = self.energy, self.layout.energy
	if bar == nil or energy == nil then
		return
	end
	local rows = MenuLayout.energyRows(data, energy.h)
	local rgb = MenuLayout.energyColour(MenuLayout.energyFraction(data))
	local key = `{rgb[1]},{rgb[2]},{rgb[3]}`
	local colour: Color3? = nil
	if key ~= self.energyColour then
		self.energyColour = key
		colour = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end
	bar:set(rows / energy.h, colour)
end

local function setText(label: TextLabel?, text: string)
	if label and label.Text ~= text then
		label.Text = text
	end
end

--[[
	The gauges, energy bar, tanks, status and lines from `window`'s container: a machine's from the
	fields its panel names (again only when its data table changed), a furnace's flame and arrow.
]]
function ContainerPanel.render(self: Self, window: Window)
	local container = window.container
	local layout = self.layout
	if container and container.kind == "machine" then
		local data = container.data
		if self.machineShown and data == self.machineData then
			return
		end
		self.machineShown = true
		self.machineData = data
		local flame = self.flame
		if flame then
			flame:set(MenuLayout.machineFlameRows(data, layout.flameSource) / MenuLayout.FLAME_SIZE)
		end
		local progress = self.progress
		if progress then
			progress:set(MenuLayout.machineArrowColumns(data, layout.progressSource) / MenuLayout.ARROW_WIDTH)
		end
		renderEnergy(self, data)
		renderTanks(self, data)
		setText(self.status, MenuLayout.statusText(container))
		if #self.lines > 0 then
			local texts = MenuLayout.lineTexts(container)
			for i, label in self.lines do
				setText(label, texts[i] or "")
			end
		end
		return
	end
	local data = if container and container.kind == "furnace" then container.data else nil
	local flame = self.flame
	if flame then
		flame:set(MenuLayout.flameRows(data) / MenuLayout.FLAME_SIZE)
	end
	local progress = self.progress
	if progress then
		progress:set(MenuLayout.arrowColumns(data) / MenuLayout.ARROW_WIDTH)
	end
end

-- A machine's energy bar ("1.2 kJ / 20 kJ") or tank gauge ("Lava: 5,000 mB", its capacity) under
-- `point`, nil elsewhere.
function ContainerPanel.tooltipAt(self: Self, point: Vector2, window: Window): { string }?
	local container = window.container
	if container == nil then
		return nil
	end
	local hit = self.energyHit
	if hit and Style.contains(hit, point) then
		return { MenuLayout.energyTooltip(container.data) }
	end
	for _, tank in self.tanks do
		if Style.contains(tank.frame, point) then
			return MenuLayout.tankTooltip(container.data, tank.spot)
		end
	end
	return nil
end

-- Destroys what it drew (its slots are the widgets' group "container": the screen drops them).
function ContainerPanel.destroy(self: Self)
	for _, part in self.parts do
		part:Destroy()
	end
	table.clear(self.parts)
	table.clear(self.tanks)
	table.clear(self.lines)
end

return ContainerPanel
