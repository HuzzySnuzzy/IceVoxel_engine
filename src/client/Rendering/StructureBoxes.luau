--!strict
--[[
	Structure blocks' outlines in the world (Minecraft's StructureBlockRenderer).

	  outline  a SAVE block's region always, a LOAD block's when "Show Bounding Box" is on (the
	           template's turned box where LOAD puts it); CORNER and DATA blocks and regions with
	           a side of 0 draw nothing (World/StructureRecords.region). Each is a SelectionBox
	           (Minecraft's light gray lines) on an invisible, non-colliding, non-queried part the
	           size of the region. While a structure block's screen is open its outline follows
	           the fields being typed (Ui/StructureScreen.preview).
	  name     a small label over the block with the structure's name (and mode).
	  air      a SAVE block with "Show Invisible Blocks" marks the air cells of its region with
	           small blue cubes (Minecraft draws their outlines), at most MAX_AIR of them, in
	           regions of at most MAX_SCAN cells; structure voids are drawn by the world itself.

	The nearest LIMIT structure blocks within RANGE blocks of the camera are outlined, refreshed
	every INTERVAL seconds and whenever the records or the open screen change. As Minecraft's
	(drawn only for players who may use operator blocks), none of it shows outside creative.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Settings = require(Shared.Structures.Settings)

local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local StructureRecords = require(script.Parent.Parent.World.StructureRecords)
local StructureScreen = require(script.Parent.Parent.Ui.StructureScreen)
local Style = require(script.Parent.Parent.Ui.Style)

local BLOCK = Config.BlockSize
-- Blocks sideways from the camera, outlines at most, seconds between refreshes.
local RANGE = 128
local LIMIT = 24
local INTERVAL = 0.25
-- The name label is drawn this far (blocks).
local LABEL_DISTANCE = 48
-- "Show Invisible Blocks": regions scanned at most (cells), air markers at most, rescans (s).
local MAX_SCAN = 16384
local MAX_AIR = 2048
local AIR_RESCAN = 2
-- Minecraft's outline colour (0.9 gray) and its air marker colour (0.5, 0.5, 1).
local LINE_COLOUR = Color3.new(0.9, 0.9, 0.9)
local AIR_COLOUR = Color3.new(0.5, 0.5, 1)
-- Studs added to an outline so its lines sit just outside the blocks' faces.
local OUTSET = 0.04

type Entry = { part: Part, box: SelectionBox, anchor: Part, label: TextLabel, gui: BillboardGui }

local StructureBoxes = {}

local started = false

local function newEntry(folder: Folder): Entry
	local part = Instance.new("Part")
	part.Name = "StructureRegion"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Locked = true
	part.Parent = folder
	local box = Instance.new("SelectionBox")
	box.Color3 = LINE_COLOUR
	box.LineThickness = 0.08
	box.SurfaceTransparency = 1
	box.Adornee = part
	box.Parent = part

	local anchor = Instance.new("Part")
	anchor.Name = "StructureLabel"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Locked = true
	anchor.Parent = folder
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(240, 18)
	gui.StudsOffset = Vector3.new(0, BLOCK * 0.5 + 1, 0)
	gui.MaxDistance = LABEL_DISTANCE * BLOCK
	gui.LightInfluence = 0
	gui.Adornee = anchor
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Style.FONT
	label.TextSize = 14
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Text = ""
	label.Parent = gui
	return { part = part, box = box, anchor = anchor, label = label, gui = gui }
end

local function hide(entry: Entry)
	entry.box.Visible = false
	entry.gui.Enabled = false
end

-- The label over a structure block: its name and mode ("hut (Save)").
local function labelText(s: Settings.StructureSettings, mode: string): string
	local name = if s.name ~= "" then s.name else "(no name)"
	local modeName = string.upper(string.sub(mode, 1, 1)) .. string.sub(mode, 2)
	return `{name} ({modeName})`
end

function StructureBoxes.start(world: ClientWorld.ClientWorld, records: () -> StructureRecords.Records)
	if started then
		return
	end
	started = true
	local folder = Instance.new("Folder")
	folder.Name = "IceVoxelStructureBoxes"
	folder.Parent = workspace
	local entries: { Entry } = {}

	local airFolder = Instance.new("Folder")
	airFolder.Name = "Air"
	airFolder.Parent = folder
	local airParts: { Part } = {}
	local airUsed = 0
	-- What the air markers show (region and block), and when they were scanned.
	local airKey = ""
	local airScanned = -math.huge

	local function getBlock(x: number, y: number, z: number): number?
		return world:getBlock(x, y, z)
	end

	local function airPart(index: number): Part
		local part: Part? = airParts[index]
		if part == nil then
			local created = Instance.new("Part")
			created.Name = "Air"
			created.Anchored = true
			created.CanCollide = false
			created.CanQuery = false
			created.CanTouch = false
			created.CastShadow = false
			created.Material = Enum.Material.SmoothPlastic
			created.Color = AIR_COLOUR
			created.Transparency = 0.55
			created.Size = Vector3.new(BLOCK * 0.2, BLOCK * 0.2, BLOCK * 0.2)
			created.Locked = true
			airParts[index] = created
			part = created
		end
		return part :: Part
	end

	-- Marks the air cells of `region` (or nothing: nil).
	local function showAir(region: { number }?, key: string, now: number)
		if region == nil then
			if airUsed > 0 then
				for i = 1, airUsed do
					airParts[i].Parent = nil
				end
				airUsed = 0
			end
			airKey = ""
			return
		end
		if key == airKey and now - airScanned < AIR_RESCAN then
			return
		end
		airKey = key
		airScanned = now
		local count = 0
		local cells = (region[4] - region[1] + 1) * (region[5] - region[2] + 1) * (region[6] - region[3] + 1)
		if cells <= MAX_SCAN then
			for y = region[2], region[5] do
				for z = region[3], region[6] do
					for x = region[1], region[4] do
						local block = getBlock(x, y, z)
						if (block == Blocks.AIR or block == Blocks.CAVE_AIR) and count < MAX_AIR then
							count += 1
							local part = airPart(count)
							part.CFrame = CFrame.new((x + 0.5) * BLOCK, (y + 0.5) * BLOCK, (z + 0.5) * BLOCK)
							part.Parent = airFolder
						end
					end
				end
			end
		end
		for i = count + 1, airUsed do
			airParts[i].Parent = nil
		end
		airUsed = count
	end

	local lastVersion = -1
	local lastPreview = ""
	local nextRefresh = 0
	local wasCreative = false
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		local creative = ClientInventory.isCreative()
		if not creative then
			if wasCreative then
				wasCreative = false
				for _, entry in entries do
					hide(entry)
				end
				showAir(nil, "", now)
			end
			return
		elseif not wasCreative then
			-- (Back in creative: redraw at once.)
			wasCreative = true
			nextRefresh = 0
		end
		local r = records()
		local px, py, pz, preview = StructureScreen.preview()
		local previewKey = ""
		if px and py and pz and preview then
			local s = preview :: Settings.StructureSettings
			previewKey =
				`{px},{py},{pz}|{s.mode}|{s.offset[1]},{s.offset[2]},{s.offset[3]}|{s.size[1]},{s.size[2]},{s.size[3]}|{s.rotation}|{s.mirror}|{s.showBoundingBox}|{s.showInvisible}|{s.name}`
		end
		if now < nextRefresh and r.version == lastVersion and previewKey == lastPreview then
			return
		end
		nextRefresh = now + INTERVAL
		lastVersion = r.version
		lastPreview = previewKey

		local camera = workspace.CurrentCamera.CFrame.Position / BLOCK
		local override: StructureRecords.Outlined? = nil
		if px and py and pz and preview then
			override = { x = px, y = py, z = pz, settings = preview }
		end
		local list = StructureRecords.outlined(r, camera.X, camera.Z, RANGE, LIMIT, getBlock, override)
		local airRegion: { number }? = nil
		local airFor = ""
		for i, item in list do
			local entry = entries[i]
			if entry == nil then
				entry = newEntry(folder)
				entries[i] = entry
			end
			local block = getBlock(item.x, item.y, item.z)
			local mode = (if block then Blocks.structureMode(block) else nil) or item.settings.mode
			-- (The screen's mode is the one being looked at while it is open.)
			if override and override.x == item.x and override.y == item.y and override.z == item.z then
				mode = item.settings.mode
			end
			local region = StructureRecords.region(item.x, item.y, item.z, item.settings, mode)
			if region == nil then
				hide(entry)
				continue
			end
			local size = Vector3.new(region[4] - region[1] + 1, region[5] - region[2] + 1, region[6] - region[3] + 1)
			entry.part.Size = size * BLOCK + Vector3.new(OUTSET, OUTSET, OUTSET) * 2
			entry.part.CFrame = CFrame.new(
				(region[1] + size.X / 2) * BLOCK,
				(region[2] + size.Y / 2) * BLOCK,
				(region[3] + size.Z / 2) * BLOCK
			)
			entry.box.Visible = true
			entry.anchor.CFrame = CFrame.new((item.x + 0.5) * BLOCK, (item.y + 0.5) * BLOCK, (item.z + 0.5) * BLOCK)
			entry.label.Text = labelText(item.settings, mode)
			entry.gui.Enabled = true
			if airRegion == nil and mode == "save" and item.settings.showInvisible then
				airRegion = region
				airFor = `{item.x},{item.y},{item.z}|{table.concat(region, ",")}`
			end
		end
		for i = #list + 1, #entries do
			hide(entries[i])
		end
		showAir(airRegion, airFor, now)
	end)
end

return StructureBoxes
