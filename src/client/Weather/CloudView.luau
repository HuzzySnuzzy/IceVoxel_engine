--!strict
--[[
	The clouds out to the view distance (Roblox glue over Weather/CloudLod's rings; the numbers in
	Config.Weather.Clouds, the Clouds setting picks Off / Fast / Fancy).

	  Rings     one Model a ring of detail in "IceVoxelClouds" (workspace), its parts the ring's
	            boxes: anchored, no collision, queries, touches or audio, Config's material,
	            colour by shade (Color to Dark), see-through by Transparency; rain shafts in
	            ShaftColor, more see-through, from the ground under them (the generator's height
	            there, Weather/WeatherState, looked up again at every plan: CloudLod.groundShafts)
	            up to the lowest rain cloud's base. No clouds at all where the world has no
	            weather (WeatherState.enabled false: the debug worlds, Config.Weather.Enabled).
	  Planning  a ring is planned again (CloudLod.plan: the weather sampled with Shared/Weather's
	            grid at this frame's moment, one call a ring) when the camera has moved two of its
	            cells in the air's frame (its window changed) or the finer ring's window moved (its
	            hole: CloudLod.sameWindow), every RefreshSeconds x 2^ring (the storms change
	            slowly), or when the mode or view distance changed; one ring a frame at most, the
	            finest first, and only once the last plan's parts are all placed. CloudLod.diff
	            keeps the parts of boxes the new plan shares.
	  Budget    at most Clouds.PartsPerFrame parts are placed or removed in a frame: new boxes
	            nearest first, then the ones the plan dropped (after their replacements, so the
	            sky never shows a hole); released parts are pooled (unparented) and reused.
	  Wind      boxes are planned in the air's frame and placed at the air's displacement when
	            they were made; each ring's Model is moved (Model:PivotTo, one call) to the
	            displacement now every 0.1 x 2^ring seconds: the clouds drift with the weather's
	            wind (a step of a few hundredths of a block near the camera), far rings less often.

	Measured on seed 12345 (tests/spec/WeatherVisuals, two in-game days at the spawn and 3 km out):
	Fancy at the default view (2048 blocks, 5 rings) 202 parts on average, 387 at most (122 of
	them rain shafts); Fancy at Ultra's 4096 (6 rings): 325, 496; Fancy at 1024: 140, 238; Fast at
	2048: 88, 122; Fast at the phones' 512 (Low): 38, 48. Planning a ring takes 0.2-0.7 ms (Lune,
	native code), one ring a frame at most; with PartsPerFrame that bounds a frame's work.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)

local CloudLod = require(script.Parent.CloudLod)
local WeatherState = require(script.Parent.WeatherState)

local BLOCK = Config.BlockSize

type Ring = {
	model: Model,
	-- The window the ring was planned for (its hole too), and when (os.clock).
	window: CloudLod.Window?,
	planned: number,
	-- Box key -> its part (false: a shaft with no room under its cloud).
	live: { [string]: BasePart | false },
	adds: { CloudLod.Box },
	addIndex: number,
	removals: { string },
	-- The displacement the model's parts are placed at, and when it last moved.
	appliedX: number,
	appliedZ: number,
	movedAt: number,
}

local CloudView = {}

local mode = CloudLod.FANCY
local viewDistance: () -> number = function()
	return Config.Lod.ViewDistance
end
local settings: CloudLod.Settings? = nil
-- The mode and view distance `settings` were made for.
local settingsMode, settingsView = -1, -1
local pattern: CloudLod.Pattern? = nil
local folder: Folder? = nil
local rings: { Ring } = {}
local pool: { Part } = {}
local palette: { Color3 } = {}
local partCount = 0
local gridBuffer: buffer? = nil

local function colourOf(rgb: { number }): Color3
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function buildPalette()
	local clouds = Config.Weather.Clouds
	local light, dark = colourOf(clouds.Color), colourOf(clouds.Dark)
	for shade = 1, CloudLod.SHADES do
		palette[shade] = light:Lerp(dark, (shade - 1) / (CloudLod.SHADES - 1))
	end
end

local function newRing(level: number): Ring
	local model = Instance.new("Model")
	model.Name = `Ring{level}`
	local dx, dz = WeatherState.displacement()
	model.WorldPivot = CFrame.new(dx * BLOCK, 0, dz * BLOCK)
	model.Parent = folder
	return {
		model = model,
		window = nil,
		planned = -math.huge,
		live = {},
		adds = {},
		addIndex = 1,
		removals = {},
		appliedX = dx,
		appliedZ = dz,
		movedAt = os.clock(),
	}
end

local function acquire(): Part
	local part = table.remove(pool)
	if part then
		return part
	end
	local clouds = Config.Weather.Clouds
	local fresh = Instance.new("Part")
	fresh.Name = "Cloud"
	fresh.Anchored = true
	fresh.CanCollide = false
	fresh.CanQuery = false
	fresh.CanTouch = false
	fresh.CastShadow = clouds.CastShadow
	fresh.TopSurface = Enum.SurfaceType.Smooth
	fresh.BottomSurface = Enum.SurfaceType.Smooth
	local material = (Enum.Material :: any)[clouds.Material]
	fresh.Material = if material then material else Enum.Material.SmoothPlastic
	pcall(function()
		(fresh :: any).AudioCanCollide = false
	end)
	return fresh
end

local function release(part: Part)
	part.Parent = nil
	table.insert(pool, part)
	partCount -= 1
end

-- The generator's ground at (x, z) (a shaft's base: CloudLod.groundShafts).
local function groundAt(x: number, z: number): number
	local _, ground = WeatherState.temperatureAt(x, z)
	return ground
end

-- Places box `box` of `ring` (returns its part, or false for a shaft with no room).
local function place(ring: Ring, box: CloudLod.Box): Part | false
	local clouds = Config.Weather.Clouds
	local base, top = box.base, box.top
	if box.shaft and base >= top - 8 then
		return false
	end
	local part = acquire()
	part.Size = Vector3.new((box.x1 - box.x0) * BLOCK, (top - base) * BLOCK, (box.z1 - box.z0) * BLOCK)
	part.CFrame = CFrame.new(
		((box.x0 + box.x1) / 2 + ring.appliedX) * BLOCK,
		(base + top) / 2 * BLOCK,
		((box.z0 + box.z1) / 2 + ring.appliedZ) * BLOCK
	)
	if box.shaft then
		part.Color = colourOf(clouds.ShaftColor)
		part.Transparency = clouds.ShaftTransparency[if box.shade >= 2 then 1 else 2]
	else
		part.Color = palette[box.shade]
		part.Transparency = clouds.Transparency
	end
	part.Parent = ring.model
	partCount += 1
	return part
end

-- Plans ring `level` for the camera at air-frame (cu, cw).
local function plan(level: number, ring: Ring, cu: number, cw: number, dx: number, dz: number)
	local s = settings :: CloudLod.Settings
	local field = WeatherState.field()
	if field == nil then
		return
	end
	local moment = WeatherState.moment
	local sample = function(u0: number, w0: number, step: number, cols: number, rows: number): buffer
		local out = field:grid(moment, u0 + dx, w0 + dz, step, cols, rows, gridBuffer)
		gridBuffer = out
		return out
	end
	local boxes = CloudLod.plan(s, pattern :: CloudLod.Pattern, level, cu, cw, sample)
	-- (Shafts stand on the ground under where the clouds are now: placed again once it changed.)
	CloudLod.groundShafts(boxes, groundAt, dx, dz, Config.SeaLevel)
	ring.window = CloudLod.window(s, level, cu, cw)
	ring.planned = os.clock()
	local added, removed = CloudLod.diff(ring.live, boxes)
	ring.adds, ring.addIndex, ring.removals = added, 1, removed
end

-- Clears ring `ring` (every part removed over the next frames).
local function clear(ring: Ring)
	ring.adds, ring.addIndex = {}, 1
	local removals = {}
	for key in ring.live do
		table.insert(removals, key)
	end
	ring.removals = removals
end

-- Places and removes parts within `budget`. Returns what is left of it.
local function apply(ring: Ring, budget: number): number
	while budget > 0 and ring.addIndex <= #ring.adds do
		local box = ring.adds[ring.addIndex]
		ring.addIndex += 1
		if ring.live[box.key] == nil then
			ring.live[box.key] = place(ring, box)
			budget -= 1
		end
	end
	if ring.addIndex <= #ring.adds then
		return budget
	end
	while budget > 0 and #ring.removals > 0 do
		local key = table.remove(ring.removals) :: string
		local part = ring.live[key]
		ring.live[key] = nil
		if part then
			release(part :: Part)
			budget -= 1
		end
	end
	return budget
end

local function busy(ring: Ring): boolean
	return ring.addIndex <= #ring.adds or #ring.removals > 0
end

local function step()
	local root = folder
	if root == nil then
		return
	end
	local view = viewDistance()
	if mode ~= settingsMode or view ~= settingsView then
		settingsMode, settingsView = mode, view
		settings = if mode == CloudLod.OFF then nil else CloudLod.settings(mode, view)
		for _, ring in rings do
			ring.planned = -math.huge
			ring.window = nil
		end
	end
	-- (A world without weather has no clouds: as the Clouds setting's Off.)
	local s = if WeatherState.enabled() then settings else nil
	local wanted = if s then CloudLod.levels(s) else 0
	while #rings < wanted do
		table.insert(rings, newRing(#rings))
	end

	local camera = workspace.CurrentCamera
	local position = if camera then camera.CFrame.Position / BLOCK else Vector3.zero
	local dx, dz = WeatherState.displacement()
	local cu, cw = position.X - dx, position.Z - dz
	local now = os.clock()

	-- One plan a frame: the finest ring that needs one and has placed its last.
	if s and WeatherState.field() then
		local refresh = Config.Weather.Clouds.RefreshSeconds
		for level = 0, wanted - 1 do
			local ring = rings[level + 1]
			if busy(ring) then
				continue
			end
			local window = CloudLod.window(s, level, cu, cw)
			if not CloudLod.sameWindow(ring.window, window) or now - ring.planned >= refresh * 2 ^ level then
				plan(level, ring, cu, cw, dx, dz)
				break
			end
		end
	end
	-- Rings past what is wanted (Off, a shorter view) go.
	for level = wanted + 1, #rings do
		local ring = rings[level]
		if not busy(ring) and next(ring.live) ~= nil then
			clear(ring)
		end
	end

	local budget = Config.Weather.Clouds.PartsPerFrame
	for _, ring in rings do
		if budget <= 0 then
			break
		end
		budget = apply(ring, budget)
	end

	-- Drift with the wind.
	for level, ring in rings do
		if now - ring.movedAt >= 0.1 * 2 ^ (level - 1) and (ring.appliedX ~= dx or ring.appliedZ ~= dz) then
			ring.movedAt = now
			ring.appliedX, ring.appliedZ = dx, dz
			ring.model:PivotTo(CFrame.new(dx * BLOCK, 0, dz * BLOCK))
		end
	end
end

-- The Clouds setting (CloudLod.OFF / FAST / FANCY).
function CloudView.setMode(value: number)
	mode = math.clamp(math.floor(value), CloudLod.OFF, CloudLod.FANCY)
end

-- Cloud parts on screen, rings and parts still to place or remove (F3).
function CloudView.stats(): (number, number, number)
	local waiting = 0
	for _, ring in rings do
		waiting += math.max(0, #ring.adds - ring.addIndex + 1) + #ring.removals
	end
	local wanted = if settings then CloudLod.levels(settings :: CloudLod.Settings) else 0
	return partCount, wanted, waiting
end

-- Starts drawing clouds for world `seed`, as far as `distance()` (blocks: the view distance).
function CloudView.start(seed: number, distance: () -> number)
	viewDistance = distance
	pattern = CloudLod.pattern(seed)
	buildPalette()
	local root = Instance.new("Folder")
	root.Name = "IceVoxelClouds"
	root.Parent = workspace
	folder = root
	RunService.Heartbeat:Connect(step)
end

return CloudView
