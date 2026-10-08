--!strict
--[[
	The player's waypoints: the list, beacons in the world, and syncing with the server
	(Players/WaypointStore), which keeps them between sessions.

	Every change bumps a revision number and sends the whole list (debounced) with it. The server
	sends the saved list when the player joins (revision 0) and echoes a revision when filtering
	changed names in it; an echo is applied only if no newer change was made since, so a slow
	answer never undoes a change. Nothing is sent before the saved list arrived; waypoints added
	before that are merged into it.

	Waypoints are world blocks; their beacons stand in the client's render frame (Shared/World/
	Origin: world studs - the origin) and move with it (a Rendering/Rebase mover). The distance on
	a label is between two render positions (the beacon and the camera).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Origin = require(Shared.World.Origin)
local Protocol = require(Shared.Net.Protocol)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local Rebase = require(script.Parent.Parent.Rendering.Rebase)

type Waypoint = Protocol.Waypoint

local BLOCK = Config.BlockSize
local SAVE_DELAY = 1
local PALETTE = {
	{ 255, 99, 71 },
	{ 255, 196, 61 },
	{ 120, 220, 90 },
	{ 64, 200, 255 },
	{ 170, 120, 255 },
	{ 255, 120, 200 },
}

export type Waypoints = {
	list: { Waypoint },
	-- Called whenever the list changes.
	onChanged: (() -> ())?,
	-- Rebuilds beacons, notifies listeners and (if `save`) schedules sending the list.
	changed: (save: boolean) -> (),

	add: (self: Waypoints, name: string, x: number, y: number, z: number) -> (),
	remove: (self: Waypoints, index: number) -> (),
	nearest: (self: Waypoints, x: number, z: number, radius: number) -> number?,
}

local Waypoints = {}
Waypoints.__index = Waypoints

function Waypoints.new(): Waypoints
	local self = (
		setmetatable({ list = {}, onChanged = nil, changed = function(_: boolean) end }, Waypoints) :: any
	) :: Waypoints

	local folder = Instance.new("Folder")
	folder.Name = "IceVoxelWaypoints"
	folder.Parent = workspace.CurrentCamera
	local beacons: { { part: Part, label: TextLabel } } = {}
	local saveAt: number? = nil
	local revision = 0
	local synced = false
	-- The beacons stay over their waypoints when the render origin moves.
	Rebase.register("Waypoints", function(dx: number, dz: number, parts, cframes)
		local d = Vector3.new(dx, 0, dz)
		for _, beacon in beacons do
			local part = beacon.part
			if part.Parent ~= nil then
				table.insert(parts, part)
				table.insert(cframes, part.CFrame - d)
			end
		end
	end)

	local function rebuildBeacons()
		for _, beacon in beacons do
			beacon.part:Destroy()
		end
		table.clear(beacons)
		for _, waypoint in self.list do
			local part = Instance.new("Part")
			part.Name = waypoint.name
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Transparency = 1
			part.Size = Vector3.one
			part.Position = Origin.blocksToRender(waypoint.x + 0.5, waypoint.y + 2, waypoint.z + 0.5)

			local billboard = Instance.new("BillboardGui")
			billboard.AlwaysOnTop = true
			billboard.LightInfluence = 0
			billboard.MaxDistance = math.huge
			billboard.Size = UDim2.fromOffset(160, 40)
			billboard.Parent = part

			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(1, 1)
			label.Font = Enum.Font.GothamBold
			label.TextSize = 14
			label.TextStrokeTransparency = 0.3
			label.TextColor3 = Color3.fromRGB(waypoint.color[1], waypoint.color[2], waypoint.color[3])
			label.Text = waypoint.name
			label.Parent = billboard

			part.Parent = folder
			table.insert(beacons, { part = part, label = label })
		end
	end

	local function changed(save: boolean)
		rebuildBeacons()
		if save then
			revision += 1
			if synced then
				saveAt = os.clock() + SAVE_DELAY
			end
		end
		if self.onChanged then
			self.onChanged()
		end
	end
	self.changed = changed

	ClientNet.on(Protocol.ServerMessage.Waypoints, function(payload)
		local list, answered = Protocol.decodeWaypoints(payload)
		if list == nil then
			return
		end
		if not synced then
			synced = true
			local added = self.list
			self.list = list
			if revision > 0 then
				for _, waypoint in added do
					if #list >= Protocol.MAX_WAYPOINTS then
						break
					end
					table.insert(list, waypoint)
				end
				changed(true)
				return
			end
			changed(false)
		elseif answered == revision then
			self.list = list
			changed(false)
		end
	end)

	local sinceLabels = 0
	RunService.Heartbeat:Connect(function(dt)
		if saveAt and os.clock() >= saveAt then
			saveAt = nil
			ClientNet.send(Protocol.ClientMessage.SaveWaypoints, Protocol.encodeWaypoints(self.list, revision))
		end
		sinceLabels += dt
		if sinceLabels < 0.25 then
			return
		end
		sinceLabels = 0
		local camera = workspace.CurrentCamera.CFrame.Position
		for i, beacon in beacons do
			local waypoint = self.list[i]
			if waypoint then
				local distance = (beacon.part.Position - camera).Magnitude / BLOCK
				beacon.label.Text = `{waypoint.name}\n{math.floor(distance)} m`
			end
		end
	end)

	return self
end

function Waypoints.add(self: Waypoints, name: string, x: number, y: number, z: number)
	if #self.list >= Protocol.MAX_WAYPOINTS then
		return
	end
	local trimmed = Protocol.truncateName(name)
	if trimmed == "" then
		trimmed = `Waypoint {#self.list + 1}`
	end
	table.insert(self.list, {
		name = trimmed,
		x = math.floor(x),
		y = math.floor(y),
		z = math.floor(z),
		color = PALETTE[#self.list % #PALETTE + 1],
	})
	self.changed(true)
end

function Waypoints.remove(self: Waypoints, index: number)
	if self.list[index] then
		table.remove(self.list, index)
		self.changed(true)
	end
end

-- Index of the waypoint closest to (x, z) within `radius` blocks, if any.
function Waypoints.nearest(self: Waypoints, x: number, z: number, radius: number): number?
	local best, bestDistance = nil, radius * radius
	for i, waypoint in self.list do
		local dx, dz = waypoint.x - x, waypoint.z - z
		local distance = dx * dx + dz * dz
		if distance <= bestDistance then
			best, bestDistance = i, distance
		end
	end
	return best
end

return Waypoints
