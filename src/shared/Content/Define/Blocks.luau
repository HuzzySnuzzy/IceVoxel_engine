--!strict
--[[
	Content/Define's block helpers (Content/Define lists them): BlockList's generators of a general
	shape, each making whole entries (Content/Schema's BlockSpec) or the boxes of their `shape`:
	fluids and their cave twins, cave twins, torches and lanterns, Mekanism's transmitters, cables
	and tanks, doors (all 32 halves), fences (all 16 variants), layered blocks (snow layers) and
	machine blocks. Boxes are in pixels from the cell's centre (Schema's `shape`); directions are
	Minecraft's (North = -Z, East = +X).
]]

local Schema = require(script.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec
type ShapeBox = Schema.ShapeBox
type Bounds = Schema.Bounds
type Faces = Schema.Faces

local Blocks = {}

--[[
	A block's own fields of Content/Schema's per-entry ones, which only the block that is the item
	carries: its lore, its texture pack faces, the Age and skill that open its recipes, its fuel
	and its tags. A generator's other blocks (a fluid's flows, a door's other halves, a fence's
	arms) and cave twins never copy them: they are no items, and they take their item's or twin's
	faces (Blocks: a variant group's entry, a twin's twin's).
]]
local OWN_FIELDS = { "lore", "texture", "age", "skill", "fuel", "tags" }

--[[ Directions and walls ]]

-- The horizontal directions as offsets (Minecraft's: north = -Z), and each one's opposite.
Blocks.DIRECTIONS = table.freeze({
	North = { 0, 0, -1 },
	South = { 0, 0, 1 },
	West = { -1, 0, 0 },
	East = { 1, 0, 0 },
}) :: { [string]: { number } }
Blocks.OPPOSITE =
	table.freeze({ North = "South", South = "North", West = "East", East = "West" }) :: { [string]: string }
local DIRECTIONS, OPPOSITE = Blocks.DIRECTIONS, Blocks.OPPOSITE

-- The whole cell, aimed at as a full block (transmitters, tanks, tall plants).
Blocks.FULL_BOUNDS = { min = { 0, 0, 0 }, max = { 16, 16, 16 } } :: Bounds
local FULL_BOUNDS = Blocks.FULL_BOUNDS

-- A box given against the wall to the south (+Z: `support` "South"), turned onto the wall on
-- side `support`: x across the wall, y up, z towards the wall.
function Blocks.onWall(box: ShapeBox, support: string): ShapeBox
	local s, o = box.size, box.offset
	local turned = table.clone(box)
	if support == "South" then
		turned.size, turned.offset = { s[1], s[2], s[3] }, { o[1], o[2], o[3] }
	elseif support == "North" then
		turned.size, turned.offset = { s[1], s[2], s[3] }, { -o[1], o[2], -o[3] }
	elseif support == "East" then
		turned.size, turned.offset = { s[3], s[2], s[1] }, { o[3], o[2], -o[1] }
	else
		turned.size, turned.offset = { s[3], s[2], s[1] }, { -o[3], o[2], o[1] }
	end
	return turned
end
local onWall = Blocks.onWall

-- The outline of a panel `depth` pixels thick against the wall on side `support`.
function Blocks.wallBounds(support: string, depth: number): Bounds
	local lo, hi = { 0, 0, 0 }, { 16, 16, 16 }
	local d = DIRECTIONS[support]
	for k = 1, 3 do
		if d[k] < 0 then
			hi[k] = depth
		elseif d[k] > 0 then
			lo[k] = 16 - depth
		end
	end
	return { min = lo, max = hi }
end
local wallBounds = Blocks.wallBounds

--[[ Fluids and cave twins ]]

--[[
	A fluid's nine blocks (BlockList's `fluid`): level 0 is the source (`group`, the item), 1-7
	are flowing blocks getting weaker ("<Group>Flow<n>") and 8 is falling fluid fed from above
	("<Group>Falling"), sharing one look so the mesher merges them: `spec`'s colour, material,
	transparency, reflectance, light and blast resistance; not solid, replaceable, hardness 100, no
	drop, server Behaviours/Fluid, ticking every `tickDelay`. `flowing`: fields of the flowing and
	falling levels only (flowing fuel burns like a fuse, its source explodes). `spec`'s own fields
	(OWN_FIELDS: its lore...) and `heats` / `cools` are the source's alone: the source is the
	fluid's item, and a fluid's name warms or cools at every level (ToughAsNails/Temperature).
	Every group is a fluid of Shared/Fluids (FluidList: its id, bucket, colour and light; checked
	at load), and its flow rules are Behaviours/Fluid's RULES.
]]
function Blocks.fluid(group: string, spec: BlockSpec, tickDelay: number, flowing: { [string]: any }?): { BlockSpec }
	local list: { BlockSpec } = {}
	local source = table.clone(OWN_FIELDS)
	table.insert(source, "heats")
	table.insert(source, "cools")
	for level = 0, 8 do
		local name = if level == 0 then group elseif level == 8 then group .. "Falling" else group .. "Flow" .. level
		local entry: BlockSpec = {
			name = name,
			render = "Fluid",
			color = spec.color,
			material = spec.material,
			transparency = spec.transparency,
			reflectance = spec.reflectance,
			light = spec.light,
			lightColor = spec.lightColor,
			solid = false,
			replaceable = true,
			placeable = level == 0,
			hardness = 100,
			blastResistance = spec.blastResistance,
			drops = false,
			behaviour = "Fluid",
			fluid = { group = group, level = level, tickDelay = tickDelay },
		}
		if level > 0 and flowing then
			for field, value in flowing do
				(entry :: any)[field] = value
			end
		end
		if level == 0 then
			for _, field in source do
				(entry :: any)[field] = (spec :: any)[field]
			end
		end
		table.insert(list, entry)
	end
	return list
end

--[[
	The cave twin of `spec` (Schema's `caveTwin`): a copy named "Cave<Name>" that generation places
	in caves, which looks, drops and behaves exactly like it but counts as cave air while caves are
	hidden; nothing places it, and its item is its twin's (so it has none of `spec`'s own fields,
	OWN_FIELDS: lore, faces, Age...). `extra`: fields put over the copy (the mineshafts' vines are
	`seasonless`).
]]
function Blocks.caveTwin(spec: BlockSpec, extra: { [string]: any }?): BlockSpec
	local twin = table.clone(spec)
	twin.name = "Cave" .. spec.name
	twin.placeable = false
	twin.item = spec.item or spec.name
	twin.caveTwin = spec.name
	for _, field in OWN_FIELDS do
		(twin :: any)[field] = nil
	end
	if extra then
		for field, value in extra do
			(twin :: any)[field] = value
		end
	end
	return twin
end

-- A fluid source's cave twin (CaveLava, CaveOil): `caveTwin`, shown by the source's name ("Lava").
-- (Without `heats` / `cools`: the fluid's name warms or cools its cave twin too, Temperature.)
function Blocks.caveFluid(source: BlockSpec): BlockSpec
	local twin = Blocks.caveTwin(source)
	twin.displayName = source.displayName or source.name
	twin.heats, twin.cools = nil, nil
	return twin
end

--[[ Torches and lanterns ]]

local TORCH_WOOD = { 104, 76, 42 }
local FLAME = { 255, 206, 110 }
local LANTERN_GLOW = { 255, 188, 92 }

-- A standing torch whose stick's bottom centre is at `bottom`: a 2 x 8 x 2 stick under a 2 x 2 x 2
-- flame (10 pixels, Minecraft's torch model), the flame's `glow` box carrying the light.
function Blocks.torch(bottom: { number }): { ShapeBox }
	local x, y, z = bottom[1], bottom[2], bottom[3]
	return {
		{ size = { 2, 8, 2 }, offset = { x, y + 4, z }, color = TORCH_WOOD, material = "Wood" },
		{ size = { 2, 2, 2 }, offset = { x, y + 9, z }, color = FLAME, material = "Neon", glow = true },
	}
end

--[[
	`boxes` leaned `angle` degrees about the X (axis "x") or Z axis through `pivot` (Minecraft's
	element rotation): the offsets turn about the pivot and each box turns by the same angle. The
	rotation matrices are Roblox's (CFrame.Angles), so the renderer draws exactly this.
]]
function Blocks.lean(boxes: { ShapeBox }, pivot: { number }, axis: string, angle: number): { ShapeBox }
	local r = math.rad(angle)
	local c, s = math.cos(r), math.sin(r)
	local out = {}
	for _, box in boxes do
		local dx, dy, dz = box.offset[1] - pivot[1], box.offset[2] - pivot[2], box.offset[3] - pivot[3]
		local offset, rotation
		if axis == "x" then
			offset = { pivot[1] + dx, pivot[2] + dy * c - dz * s, pivot[3] + dy * s + dz * c }
			rotation = { angle, 0, 0 }
		else
			offset = { pivot[1] + dx * c - dy * s, pivot[2] + dx * s + dy * c, pivot[3] + dz }
			rotation = { 0, 0, angle }
		end
		table.insert(out, {
			size = box.size,
			offset = offset,
			rotation = rotation,
			color = box.color,
			material = box.material,
			glow = box.glow,
		})
	end
	return out
end
local lean = Blocks.lean

--[[
	A wall torch facing `facing`, away from the wall it hangs on (Minecraft's wall_torch `facing`):
	its boxes and outline. The torch's foot touches the middle of that wall 3.5 pixels up and it
	leans 22.5 degrees out (template_torch_wall); the outline is Minecraft's, 5 x 10 x 5 pixels
	against the wall, 3 to 13 up.
]]
function Blocks.wallTorch(facing: string): ({ ShapeBox }, Bounds)
	local d = DIRECTIONS[facing]
	-- The foot, on the wall behind the torch.
	local pivot = { -d[1] * 8, -4.5, -d[3] * 8 }
	local boxes = if d[1] ~= 0
		-- Turning about +Z by -a moves the top towards +X: lean out, away from the wall.
		then lean(Blocks.torch(pivot), pivot, "z", -d[1] * 22.5)
		else lean(Blocks.torch(pivot), pivot, "x", d[3] * 22.5)
	local lo = { 5.5, 3, 5.5 }
	local hi = { 10.5, 13, 10.5 }
	local axis = if d[1] ~= 0 then 1 else 3
	-- Against the wall: 0..5 when it is on the low side (facing +), 11..16 otherwise.
	if d[axis] > 0 then
		lo[axis], hi[axis] = 0, 5
	else
		lo[axis], hi[axis] = 11, 16
	end
	return boxes, { min = lo, max = hi }
end

--[[
	A lantern standing at `y` (its floor's height, -8: on the block below), or `hanging` under the
	block above: an iron frame (bottom and top plates, four corner posts), a glowing core seen
	between the posts, a cap and a handle (Minecraft's 6 x 7 x 6 body under a 4 x 2 x 4 top).
	Hanging, it sits a pixel higher with a chain up to the block above.
]]
function Blocks.lantern(y: number, hanging: boolean): { ShapeBox }
	local boxes: { ShapeBox } = {
		{ size = { 5, 5, 5 }, offset = { 0, y + 3.5, 0 }, color = LANTERN_GLOW, material = "Neon", glow = true },
		{ size = { 6, 1, 6 }, offset = { 0, y + 0.5, 0 } },
		{ size = { 6, 1, 6 }, offset = { 0, y + 6.5, 0 } },
		{ size = { 4, 2, 4 }, offset = { 0, y + 8, 0 } },
	}
	for _, corner in { { -2.5, -2.5 }, { 2.5, -2.5 }, { -2.5, 2.5 }, { 2.5, 2.5 } } do
		table.insert(boxes, { size = { 1, 5, 1 }, offset = { corner[1], y + 3.5, corner[2] } })
	end
	if hanging then
		-- The chain, from the cap to the ceiling.
		table.insert(boxes, { size = { 1, 6, 1 }, offset = { 0, y + 12, 0 } })
	else
		table.insert(boxes, { size = { 3, 2, 0.5 }, offset = { 0, y + 10, 0 } })
	end
	return boxes
end

--[[ Mekanism's transmitters and tanks (Shared/Transmitters) ]]

-- Glass of transmitters and tanks: its see-through look (the frames are opaque).
Blocks.GLASS_TRANSPARENCY = 0.5
local GLASS_TRANSPARENCY = Blocks.GLASS_TRANSPARENCY
local TANK_GLASS = { 190, 214, 226 }
local STEEL = { 112, 116, 124 }
local CABLE_CORE = { 176, 58, 44 }

-- An opaque metal box in `colour` (frames).
function Blocks.metalBox(size: { number }, offset: { number }, colour: { number }): ShapeBox
	return { size = size, offset = offset, color = colour, material = "Metal", transparency = 0 }
end
local metalBox = Blocks.metalBox

-- A see-through glass box in `colour`.
function Blocks.glassBox(size: { number }, offset: { number }, colour: { number }): ShapeBox
	return { size = size, offset = offset, color = colour, material = "Glass", transparency = GLASS_TRANSPARENCY }
end
local glassBox = Blocks.glassBox

--[[
	A transmitter's core, 8 pixels wide: the glass cube first, then the twelve frame edges, a pixel
	thick. The X edges run the whole length; the Y and Z edges fit between them, so no two boxes
	share a face.
]]
local function transmitterCore(frame: { number }, glassColour: { number }): { ShapeBox }
	local boxes: { ShapeBox } = { glassBox({ 7, 7, 7 }, { 0, 0, 0 }, glassColour) }
	for _, a in { -3.5, 3.5 } do
		for _, b in { -3.5, 3.5 } do
			table.insert(boxes, metalBox({ 8, 1, 1 }, { 0, a, b }, frame))
			table.insert(boxes, metalBox({ 1, 6, 1 }, { a, 0, b }, frame))
			table.insert(boxes, metalBox({ 1, 1, 6 }, { a, b, 0 }, frame))
		end
	end
	return boxes
end

-- The item's model: the core with an arm to the west and east, each ending in a collar.
local function transmitterIcon(core: { ShapeBox }, frame: { number }, glassColour: { number }): { ShapeBox }
	local boxes = table.clone(core)
	for _, side in { -1, 1 } do
		table.insert(boxes, glassBox({ 3.5, 6, 6 }, { side * 5.75, 0, 0 }, glassColour))
		table.insert(boxes, metalBox({ 1, 7, 7 }, { side * 7.5, 0, 0 }, frame))
	end
	return boxes
end

--[[
	A Logistical Transporter or Mechanical Pipe (`spec`: its name and `transmitter`): Mekanism's
	8 x 8 x 8 pixel core, a glass cube of `glassColour` in a frame of twelve edges in `frame` (its
	tier's colour), the item a core with two arms. The client draws the arms towards what it
	connects to (Rendering/TransmitterRenderer). Aimed at over its whole cell; not solid (the
	movement hull only knows full cubes) but obstructing; hardness 1 with a pickaxe, metal sounds,
	drops itself. Returns `spec`, filled in.
]]
function Blocks.transmitter(spec: BlockSpec, frame: { number }, glassColour: { number }): BlockSpec
	local core = transmitterCore(frame, glassColour)
	spec.color = frame
	spec.material = "Metal"
	spec.transparency = GLASS_TRANSPARENCY
	spec.sound = "metal"
	spec.solid = false
	spec.placeable = true
	spec.obstructs = true
	spec.hardness = 1
	spec.tool = "pickaxe"
	spec.shape = core
	spec.icon = transmitterIcon(core, frame, glassColour)
	spec.bounds = FULL_BOUNDS
	return spec
end

-- A Universal Cable's core, 6 pixels wide: the conductor, then the twelve frame edges.
local function cableCore(frame: { number }): { ShapeBox }
	local boxes: { ShapeBox } = { metalBox({ 5, 5, 5 }, { 0, 0, 0 }, CABLE_CORE) }
	for _, a in { -2.5, 2.5 } do
		for _, b in { -2.5, 2.5 } do
			table.insert(boxes, metalBox({ 6, 1, 1 }, { 0, a, b }, frame))
			table.insert(boxes, metalBox({ 1, 4, 1 }, { a, 0, b }, frame))
			table.insert(boxes, metalBox({ 1, 1, 4 }, { a, b, 0 }, frame))
		end
	end
	-- (The conductor is SmoothPlastic, so it reads as a coloured core inside a metal frame.)
	boxes[1].material = "SmoothPlastic"
	return boxes
end

-- The item's model: the core with an arm to the west and east, each ending in a collar.
local function cableIcon(core: { ShapeBox }, frame: { number }): { ShapeBox }
	local boxes = table.clone(core)
	for _, side in { -1, 1 } do
		local arm = metalBox({ 4.5, 4, 4 }, { side * 5.25, 0, 0 }, CABLE_CORE)
		arm.material = "SmoothPlastic"
		table.insert(boxes, arm)
		table.insert(boxes, metalBox({ 1, 5, 5 }, { side * 7.5, 0, 0 }, frame))
	end
	return boxes
end

--[[
	A Universal Cable (`spec`: its name and `transmitter`): Mekanism's small transmitter, a 6 pixel
	core (Mekanism's 5..11 box), a red-ish conductor in a frame of twelve edges in `frame` (its
	tier's colour). Like every transmitter it is aimed at over its whole cell, not solid but
	obstructing, breaks fast and drops itself. Returns `spec`, filled in.
]]
function Blocks.cable(spec: BlockSpec, frame: { number }): BlockSpec
	local core = cableCore(frame)
	spec.color = frame
	spec.material = "Metal"
	spec.sound = "metal"
	spec.solid = false
	spec.placeable = true
	spec.obstructs = true
	spec.hardness = 1
	spec.tool = "pickaxe"
	spec.shape = core
	spec.icon = cableIcon(core, frame)
	spec.bounds = FULL_BOUNDS
	return spec
end

--[[
	A Fluid Tank (`spec`: its name and `tank`): a solid cube (torches may hang on it) of glass sides
	inside steel plates at the top and bottom, posts in `posts` (its tier's colour) at the corners;
	the client's water shows through the glass. Hardness 2 with a pickaxe, metal sounds. Returns
	`spec`, filled in.
]]
function Blocks.tank(spec: BlockSpec, posts: { number }): BlockSpec
	local boxes: { ShapeBox } = {
		glassBox({ 14, 14, 14 }, { 0, 0, 0 }, TANK_GLASS),
		metalBox({ 16, 2, 16 }, { 0, -7, 0 }, STEEL),
		metalBox({ 16, 2, 16 }, { 0, 7, 0 }, STEEL),
	}
	for _, x in { -7, 7 } do
		for _, z in { -7, 7 } do
			table.insert(boxes, metalBox({ 2, 12, 2 }, { x, 0, z }, posts))
		end
	end
	spec.color = STEEL
	spec.material = "Metal"
	spec.transparency = GLASS_TRANSPARENCY
	spec.sound = "metal"
	spec.hardness = 2
	spec.tool = "pickaxe"
	-- (A solid cube, so torches may hang on it.)
	spec.sturdy = true
	spec.shape = boxes
	spec.bounds = FULL_BOUNDS
	return spec
end

--[[ Doors (Minecraft's DoorBlock; Shared/Blocks/Doors) ]]

--[[
	A door's wood (`door`): its name ("Oak": the door is "OakDoor"), its planks' colour, its upper
	half's frame around the windows (`upper`, from the colour: the boxes the windows leave open,
	made with `doorPiece`) and, closed, its insulation (Blocks `insulation`; default a wooden door's
	0.1); and the door's own fields (OWN_FIELDS: its lore, Age, fuel...), which its item carries:
	`texture` is its lower halves' faces, `topTexture` its upper halves' ("<Wood>DoorTop"'s).
]]
export type DoorWood = {
	wood: string,
	color: { number },
	upper: (c: { number }) -> { ShapeBox },
	insulation: number?,
	lore: string?,
	texture: Faces?,
	topTexture: Faces?,
	age: string?,
	skill: string?,
	fuel: number?,
	tags: { string }?,
}

--[[
	A box of a door half's design: pixels across the door (u: -8 at the hinge .. 8), up the half
	(v: -8 .. 8), filling that much of the panel, `thick` pixels thick (3: the panel; more stands
	proud on both sides), authored against the wall to the south as `onWall` takes it.
]]
function Blocks.doorPiece(u0: number, u1: number, v0: number, v1: number, thick: number?, color: { number }?): ShapeBox
	local t = thick or 3
	return {
		size = { u1 - u0, v1 - v0, t },
		offset = { (u0 + u1) / 2, (v0 + v1) / 2, 6.5 },
		color = color,
	}
end
local piece = Blocks.doorPiece

-- `c` darkened by `by`, rounded down (a door's raised middle).
function Blocks.darker(c: { number }, by: number): { number }
	return { math.floor(c[1] * by), math.floor(c[2] * by), math.floor(c[3] * by) }
end
local darker = Blocks.darker

local HANDLE = { 72, 72, 76 }
local FACINGS = { "North", "South", "West", "East" }
local CLOCKWISE = { North = "East", East = "South", South = "West", West = "North" }
local COUNTER = { North = "West", West = "South", South = "East", East = "North" }
-- Which end of a panel against `side` the authored +u end turns to (`onWall`), per direction.
local PLUS_END: { [string]: string } = { South = "East", North = "West", East = "North", West = "South" }
-- A box of the design for a left hinge, mirrored (u flipped) for the other end.
local function mirrored(box: ShapeBox): ShapeBox
	local copy = table.clone(box)
	copy.offset = { -box.offset[1], box.offset[2], box.offset[3] }
	return copy
end

--[[
	A door of `wood`: all 32 halves (4 facings x 2 hinges x open or not x 2 halves, `door`), named
	"<Wood>Door" + facing (none for North) + "Right" (a right hinge) + "Open" + "Top" (the upper
	half). The lower half facing North, hinged left, closed, is the item; every other one names it
	as its `item`, and the upper halves drop nothing. Its panel is 3 pixels thick (`bounds`), across
	the cell's side nearest the player who placed it while closed, against its hinge side while
	open; players, mobs and items bump into it (`collides`) though it is not solid. Strength 3, an
	axe, wood sounds; right clicking opens it (`menu` "Door", server World/DoorUse); a zombie needs
	BreakDoorGoal's 240 ticks for any half; closed, it is a room's wall face (`insulation`).

	Drawn from boxes: the lower half a panel with a raised middle and an iron handle on the side
	away from the hinge, the upper half the wood's frame (`upper`). Its first box is a see-through
	plate the texture pack's door pictures go on (the `Front` of the wood's `texture` and
	`topTexture`, <Wood>Door's and <Wood>DoorTop's faces), in place of the other boxes. The design
	is drawn for a left hinge and mirrored for a right one. The item is the whole door at half
	size, upright, as Minecraft's door item.
]]
function Blocks.door(wood: DoorWood): { BlockSpec }
	local list: { BlockSpec } = {}
	local base = wood.wood .. "Door"
	local plate: ShapeBox = { size = { 16, 16, 3 }, offset = { 0, 0, 6.5 }, transparency = 1 }
	local lower: { ShapeBox } = {
		plate,
		piece(-8, 8, -8, 8),
		piece(-5, 5, -5, 5, 4, darker(wood.color, 0.85)),
		{ size = { 1.5, 3, 5 }, offset = { 5.75, 4.5, 6.5 }, color = HANDLE, material = "Metal" },
	}
	local upper: { ShapeBox } = { plate }
	for _, box in wood.upper(wood.color) do
		table.insert(upper, box)
	end
	for _, facing in FACINGS do
		for _, hinge in { "Left", "Right" } do
			for _, open in { false, true } do
				-- The panel's side and the end its hinge is at (DoorBlock.getShape): closed,
				-- across the side facing the placer, hinged on their left or right; open,
				-- turned onto that hinge side, hinged at the old panel's side.
				local hingeSide = if hinge == "Left" then COUNTER[facing] else CLOCKWISE[facing]
				local back = OPPOSITE[facing]
				local side = if open then hingeSide else back
				local hingeEnd = if open then back else hingeSide
				local flip = PLUS_END[side] == hingeEnd
				for _, half in { "lower", "upper" } do
					local isUpper = half == "upper"
					local boxes: { ShapeBox } = {}
					local design: { ShapeBox } = if isUpper then upper else lower
					for _, box in design do
						table.insert(boxes, onWall(if flip then mirrored(box) else box, side))
					end
					local name = base
						.. (if facing == "North" then "" else facing)
						.. (if hinge == "Right" then "Right" else "")
						.. (if open then "Open" else "")
						.. (if isUpper then "Top" else "")
					local item = name == base
					local spec: BlockSpec = {
						name = name,
						displayName = wood.wood .. " Door",
						color = wood.color,
						material = "WoodPlanks",
						sound = "wood",
						solid = false,
						collides = true,
						placeable = item,
						item = if item then nil else base,
						hardness = 3,
						tool = "axe",
						shape = boxes,
						bounds = wallBounds(side, 3),
						support = if isUpper then nil else "Down",
						drops = if isUpper then false else nil,
						menu = "Door",
						behaviour = "Door",
						door = { facing = facing, hinge = hinge, open = open, upper = isUpper },
						-- (BreakDoorGoal's 240 ticks, every half.)
						zombieBreak = 240,
						-- (Closed, a room's wall face; open, its air flows through.)
						insulation = if open then nil else wood.insulation or 0.1,
					}
					if name == base .. "Top" then
						spec.texture = wood.topTexture
					end
					if item then
						for _, field in OWN_FIELDS do
							(spec :: any)[field] = (wood :: any)[field]
						end
						-- (The item: the whole door at half size, upright, as Minecraft's door item
						-- is drawn; ItemModels centres it on the panel's bounds.)
						local icon: { ShapeBox } = {}
						for k, halfBoxes in { lower, upper } do
							for _, box in halfBoxes do
								local o, sz = box.offset, box.size
								local copy = table.clone(box)
								copy.size = { sz[1] / 2, sz[2] / 2, sz[3] }
								copy.offset = { o[1] / 2, o[2] / 2 + (if k == 1 then -4 else 4), o[3] }
								table.insert(icon, copy)
							end
						end
						spec.icon = icon
					end
					table.insert(list, spec)
				end
			end
		end
	end
	return list
end

--[[ Fences (Minecraft's FenceBlock) ]]

-- A fence post's arm bits per side (`fence`).
local FENCE_SIDES: { { bit: number, side: string } } = {
	{ bit = 1, side = "North" },
	{ bit = 2, side = "South" },
	{ bit = 4, side = "West" },
	{ bit = 8, side = "East" },
}

-- A fence post with arms to the sides of `mask`: its shape, outline and collision.
local function fencePost(mask: number): ({ ShapeBox }, Bounds, { Bounds })
	local shape: { ShapeBox } = { { size = { 4, 16, 4 }, offset = { 0, 0, 0 } } }
	local lo, hi = { 6, 0, 6 }, { 10, 16, 10 }
	local collision: { Bounds } = { { min = { 6, 0, 6 }, max = { 10, 24, 10 } } }
	for _, entry in FENCE_SIDES do
		if bit32.band(mask, entry.bit) ~= 0 then
			-- (Rails authored against the wall to the south, `onWall` turns them.)
			table.insert(shape, onWall({ size = { 2, 3, 6 }, offset = { 0, -0.5, 5 } }, entry.side))
			table.insert(shape, onWall({ size = { 2, 3, 6 }, offset = { 0, 5.5, 5 } }, entry.side))
			local arm = wallBounds(entry.side, 6)
			for k = 1, 3, 2 do
				if arm.min[k] == 0 and arm.max[k] == 16 then
					arm.min[k], arm.max[k] = 6, 10
				end
			end
			for k = 1, 3 do
				lo[k] = math.min(lo[k], arm.min[k])
				hi[k] = math.max(hi[k], arm.max[k])
			end
			table.insert(collision, { min = { arm.min[1], 0, arm.min[3] }, max = { arm.max[1], 24, arm.max[3] } })
		end
	end
	return shape, { min = lo, max = hi }, collision
end

--[[
	A fence's 16 variants (`fence`, the arms' bits: 1 North, 2 South, 4 West, 8 East), each `base`
	(the fence's own fields: its name, look, strength, fire odds...) with its post and arms: a
	4 x 4 pixel post, and two rails (2 pixels wide, 3 tall, at 6..9 and 12..15) out to every side
	of its mask. The lone post (mask 0) is `base.name` and the item, and the only one with `base`'s
	own fields (OWN_FIELDS: its lore, faces, fuel...); the others are named after their sides
	("OakFenceNorthEast") and name it as their `item`. Solid, but colliding only with its post and
	arms (`collision`), 1.5 blocks high, as Minecraft's; its outline the post and arms 4 pixels
	wide; server Behaviours/Fence picks the variant (Blocks.fenceConnections).
]]
function Blocks.fence(base: BlockSpec): { BlockSpec }
	local list: { BlockSpec } = {}
	for mask = 0, 15 do
		local shape, bounds, collision = fencePost(mask)
		local spec = table.clone(base)
		for _, entry in FENCE_SIDES do
			if bit32.band(mask, entry.bit) ~= 0 then
				spec.name ..= entry.side
			end
		end
		if mask ~= 0 then
			for _, field in OWN_FIELDS do
				(spec :: any)[field] = nil
			end
		end
		spec.solid = true
		spec.placeable = mask == 0
		spec.item = if mask == 0 then nil else base.name
		spec.shape = shape
		spec.bounds = bounds
		spec.collision = collision
		spec.fence = mask
		spec.behaviour = "Fence"
		table.insert(list, spec)
	end
	return list
end

--[[ Layers and machines ]]

--[[
	A layered block's eight heights (Minecraft's SnowLayerBlock), "<Name>1" .. "<Name>8", each
	`base` with `layer` n: 2 pixels a layer (`bounds`), drawn as transparent boxes that hide nothing
	and merge like glass (no `shape`), their tops lowered to the layers' height by the renderer.
	Layer 1 has no collision box and is replaceable; layers 2..8 collide one layer lower than they
	look and only the eighth is sturdy and keeps `base.insulation` (a room's wall face; fewer let a
	room's air through). "<Name>1" is the item; the others drop and are placed as it, each dropping
	n of `base.drops`. Walking in it multiplies the speed by `speeds[n]`. The item is a single layer.
	What `base` says of the item (its lore, Age, fuel...: ITEM_FIELDS) and its `texture` (the
	texture pack's entry, which covers every layer) are layer 1's alone.
]]
local ITEM_FIELDS = { "lore", "age", "skill", "fuel", "tags", "texture" }
function Blocks.layers(base: BlockSpec, speeds: { number }): { BlockSpec }
	local list: { BlockSpec } = {}
	for n = 1, 8 do
		local layered = n >= 2
		local spec = table.clone(base)
		if layered then
			for _, field in ITEM_FIELDS do
				(spec :: any)[field] = nil
			end
		end
		spec.name = `{base.name}{n}`
		spec.render = "Transparent"
		spec.transparency = 0
		spec.layer = n
		spec.solid = layered
		spec.sturdy = n == 8
		spec.replaceable = n == 1
		spec.placeable = n == 1
		spec.item = if n == 1 then nil else `{base.name}1`
		spec.dropCount = n
		spec.bounds = { min = { 0, 0, 0 }, max = { 16, 2 * n, 16 } }
		spec.collision = if layered then { { min = { 0, 0, 0 }, max = { 16, 2 * (n - 1), 16 } } } else nil
		spec.speedFactor = speeds[n]
		spec.insulation = if n == 8 then base.insulation else nil
		-- (The item: a single layer, as Minecraft's snow item.)
		spec.icon = { { size = { 16, 2, 16 }, offset = { 0, -7, 0 } } }
		table.insert(list, spec)
	end
	return list
end

--[[
	`spec` (its name, colour, `machine` kind of Shared/Machines and `energy`, Schema's: capacity 0
	for a fuel-only kind; its lore, Age...) made a Mekanism style machine block: hardness 3.5, a
	pickaxe to drop anything, metal sounds, drawn with its BlockDecor faces (decor: its name).
	BlockList's heatMachine: the seasons' stoves, heaters and coolers. Returns `spec`.
]]
function Blocks.machine(spec: BlockSpec): BlockSpec
	spec.material = "Metal"
	spec.sound = "metal"
	spec.hardness = 3.5
	spec.tool = "pickaxe"
	spec.toolLevel = 0
	spec.decor = spec.name
	return spec
end

return Blocks
