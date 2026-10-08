--!strict
--[[
	The cracks drawn on a block while a survival player mines it: Minecraft's ten destroy stages
	(0 = a few hairline cracks .. 9 = almost broken), on all six faces, without image assets.

	Each face is a SurfaceGui on a transparent part a hair larger than the block. The cracks are
	thin rotated Frames from a fixed pattern: branches growing outwards from a few points near the
	middle, generated once by a seeded random walk (so every block cracks the same way, and each
	face differently). The segments are kept in the order they grew, so stage `s` shows the first
	(s + 1) / 10 of them: the cracks spread as the stage rises. A faint dark layer deepens with
	the stage too.

	A block smaller than its cell (a lantern) passes its outline box (Blocks.outline, as the
	selection highlight): the part takes that box, and each face shows the middle of the pattern
	at the same size, like Minecraft's cracks on the block's own model.

	`show` only toggles visibility and resizes; everything is built once in `new`. The part sits in
	the client's render frame (Shared/World/Origin: world studs - the origin); while it shows, a
	move of the origin carries it along (a Rendering/Rebase mover), and every `show` puts it again.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Origin = require(Shared.World.Origin)

local Rebase = require(script.Parent.Parent.Rendering.Rebase)

local BLOCK = Config.BlockSize
local STAGES = 10
-- Canvas pixels per face, crack segments per face, line thickness (pixels).
local CANVAS = 64
local SEGMENTS = 70
local THICKNESS = 1.6
-- How far each face sits outside the block's face (studs), so it draws on top of it.
local LIFT = 0.02
local CRACK_COLOUR = Color3.fromRGB(24, 22, 20)
local CRACK_TRANSPARENCY = 0.15
-- Opacity of the dark layer per stage.
local SHADE_PER_STAGE = 0.025

local FACES = {
	Enum.NormalId.Top,
	Enum.NormalId.Bottom,
	Enum.NormalId.Front,
	Enum.NormalId.Back,
	Enum.NormalId.Left,
	Enum.NormalId.Right,
}
-- The box axes (1 = X, 2 = Y, 3 = Z) across and down each face of FACES.
local FACE_AXES = { { 1, 3 }, { 1, 3 }, { 1, 2 }, { 1, 2 }, { 3, 2 }, { 3, 2 } }
-- A whole cell, as Blocks.outline gives boxes.
local FULL_BOX = { 0, 0, 0, 1, 1, 1 }

export type CrackOverlay = {
	show: (self: CrackOverlay, x: number, y: number, z: number, stage: number, box: { number }?) -> (),
	hide: (self: CrackOverlay) -> (),
	destroy: (self: CrackOverlay) -> (),
}

type Segment = { x1: number, y1: number, x2: number, y2: number }

-- A small deterministic generator (an LCG), so the pattern never depends on other random users.
local function generator(seed: number): () -> number
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return function(): number
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

--[[
	Crack segments (canvas pixels) for one face, in the order they grow: a few roots near the
	middle send out branches that wander a little, fork now and then and stop at the edges.
]]
local function crackPattern(seed: number): { Segment }
	local random = generator(seed)
	type Tip = { x: number, y: number, angle: number }
	local tips: { Tip } = {}
	local roots = 3 + math.floor(random() * 2)
	for _ = 1, roots do
		local x = CANVAS * (0.35 + random() * 0.3)
		local y = CANVAS * (0.35 + random() * 0.3)
		local angle = random() * 2 * math.pi
		-- Each root cracks two ways.
		table.insert(tips, { x = x, y = y, angle = angle })
		table.insert(tips, { x = x, y = y, angle = angle + math.pi + (random() - 0.5) })
	end
	local segments: { Segment } = {}
	local guard = 0
	while #segments < SEGMENTS and #tips > 0 and guard < SEGMENTS * 8 do
		guard += 1
		local grown: { Tip } = {}
		for _, tip in tips do
			if #segments >= SEGMENTS then
				break
			end
			local angle = tip.angle + (random() - 0.5) * 0.9
			local length = 3 + random() * 4
			local x2 = math.clamp(tip.x + math.cos(angle) * length, 0, CANVAS)
			local y2 = math.clamp(tip.y + math.sin(angle) * length, 0, CANVAS)
			table.insert(segments, { x1 = tip.x, y1 = tip.y, x2 = x2, y2 = y2 })
			local inside = x2 > 0 and x2 < CANVAS and y2 > 0 and y2 < CANVAS
			if inside then
				table.insert(grown, { x = x2, y = y2, angle = angle })
				if random() < 0.22 then
					local side = if random() < 0.5 then -1 else 1
					table.insert(grown, { x = x2, y = y2, angle = angle + side * (0.6 + random() * 0.6) })
				end
			end
		end
		tips = grown
	end
	return segments
end

local function line(segment: Segment): Frame
	local dx, dy = segment.x2 - segment.x1, segment.y2 - segment.y1
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromOffset((segment.x1 + segment.x2) / 2, (segment.y1 + segment.y2) / 2)
	-- A little longer than the segment so the joints close.
	frame.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) + THICKNESS * 0.6, THICKNESS)
	frame.Rotation = math.deg(math.atan2(dy, dx))
	frame.BackgroundColor3 = CRACK_COLOUR
	frame.BackgroundTransparency = CRACK_TRANSPARENCY
	frame.BorderSizePixel = 0
	frame.Visible = false
	return frame
end

local CrackOverlay = {}
CrackOverlay.__index = CrackOverlay

type Face = { gui: SurfaceGui, shade: Frame, lines: { Frame } }

type Self = CrackOverlay & {
	part: Part,
	faces: { Face },
	stage: number,
	visible: boolean,
	-- The outline box the part was last sized for.
	box: { number },
	-- Removes the Rendering/Rebase mover.
	unregister: () -> (),
}

function CrackOverlay.new(): CrackOverlay
	local part = Instance.new("Part")
	part.Name = "IceVoxelCracks"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.one * (BLOCK + 2 * LIFT)

	local faces: { Face } = {}
	for index, normal in FACES do
		local gui = Instance.new("SurfaceGui")
		gui.Name = normal.Name
		gui.Face = normal
		gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
		gui.CanvasSize = Vector2.new(CANVAS, CANVAS)
		-- Lit like the block underneath (Minecraft multiplies the cracks with the block's light).
		gui.LightInfluence = 1
		gui.ClipsDescendants = true
		gui.ResetOnSpawn = false
		gui.Enabled = false
		gui.Adornee = part

		local shade = Instance.new("Frame")
		shade.Name = "Shade"
		shade.Size = UDim2.fromScale(1, 1)
		shade.BackgroundColor3 = Color3.new(0, 0, 0)
		shade.BackgroundTransparency = 1
		shade.BorderSizePixel = 0
		shade.Parent = gui

		-- The whole pattern, centred on the face: a smaller face (a smaller box) crops its middle.
		local pattern = Instance.new("Frame")
		pattern.Name = "Pattern"
		pattern.AnchorPoint = Vector2.new(0.5, 0.5)
		pattern.Position = UDim2.fromScale(0.5, 0.5)
		pattern.Size = UDim2.fromOffset(CANVAS, CANVAS)
		pattern.BackgroundTransparency = 1
		pattern.ZIndex = 2
		pattern.Parent = gui

		local lines: { Frame } = {}
		for i, segment in crackPattern(7919 * index + 104729) do
			local frame = line(segment)
			frame.Name = `Crack{i}`
			frame.ZIndex = 2
			frame.Parent = pattern
			lines[i] = frame
		end
		gui.Parent = part
		faces[index] = { gui = gui, shade = shade, lines = lines }
	end
	part.Parent = workspace.CurrentCamera

	local self: Self = setmetatable({
		part = part,
		faces = faces,
		stage = -1,
		visible = false,
		box = FULL_BOX,
		unregister = function() end,
	}, CrackOverlay) :: any
	-- (Shown, it stays with its block when the origin moves; hidden, the next `show` places it.)
	self.unregister = Rebase.register("CrackOverlay", function(dx: number, dz: number, parts, cframes)
		if self.visible and part.Parent ~= nil then
			table.insert(parts, part)
			table.insert(cframes, part.CFrame - Vector3.new(dx, 0, dz))
		end
	end)
	return self
end

--[[
	Shows destroy stage `stage` (0..9, clamped) on block (x, y, z): on its whole cell, or on `box`
	(Blocks.outline: min x, y, z, max x, y, z in blocks within the cell) for a block smaller than it.
]]
function CrackOverlay.show(self: Self, x: number, y: number, z: number, stage: number, box: { number }?)
	stage = math.clamp(math.floor(stage), 0, STAGES - 1)
	local part = self.part
	if part.Parent ~= workspace.CurrentCamera then
		-- The camera was replaced.
		part.Parent = workspace.CurrentCamera
	end
	local outline = box or FULL_BOX
	if outline ~= self.box then
		self.box = outline
		local size = { outline[4] - outline[1], outline[5] - outline[2], outline[6] - outline[3] }
		part.Size = Vector3.new(size[1], size[2], size[3]) * BLOCK + Vector3.one * (2 * LIFT)
		-- Canvas pixels per block stay the same, so the cracks keep their size.
		for index, face in self.faces do
			local axes = FACE_AXES[index]
			face.gui.CanvasSize = Vector2.new(CANVAS * size[axes[1]], CANVAS * size[axes[2]])
		end
	end
	part.CFrame = CFrame.new(
		Origin.blocksToRender(
			x + (outline[1] + outline[4]) / 2,
			y + (outline[2] + outline[5]) / 2,
			z + (outline[3] + outline[6]) / 2
		)
	)
	if stage ~= self.stage then
		self.stage = stage
		for _, face in self.faces do
			local count = math.ceil(#face.lines * (stage + 1) / STAGES)
			for i, frame in face.lines do
				frame.Visible = i <= count
			end
			face.shade.BackgroundTransparency = 1 - SHADE_PER_STAGE * (stage + 1)
		end
	end
	if not self.visible then
		self.visible = true
		for _, face in self.faces do
			face.gui.Enabled = true
		end
	end
end

function CrackOverlay.hide(self: Self)
	if self.visible then
		self.visible = false
		for _, face in self.faces do
			face.gui.Enabled = false
		end
	end
end

function CrackOverlay.destroy(self: Self)
	self.visible = false
	self.unregister()
	self.part:Destroy()
	table.clear(self.faces)
end

return CrackOverlay
