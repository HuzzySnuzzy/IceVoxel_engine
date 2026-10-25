--!strict
--[[
	Content/Define's plants (Content/Define lists them): Minecraft 1.20.1's ground foliage
	(BushBlock and its family) as BlockList made them, the boxes they are drawn with and the
	generators of their entries (Content/Schema's `plant`).

	Every plant is shaped, not solid, breaks at once, sounds like grass, is washed away by flowing
	water (and drops), stands on its soil (`plant`, `support` "Down") and is kept up by the
	server's Plant behaviour (or its own: saplings, herbs). Tall plants are two blocks: the lower
	half is the item, the upper half names it (`item`) and drops nothing.

	Minecraft draws plants as crossed textured quads. Here they are a few thin boxes each (pixels
	from the cell's centre, the ground at y = GROUND) until their Sprite texture is filled in
	(Shared/TexturePack: the client then draws two crossed images instead, with textures on), and
	every box is one Part per plant in the world: at most 4. Blades and fronds lean out in
	different directions; flowers are a thin stem with a head. Plants are drawn at a scattered
	offset and turn (`scatter`), so every box stays inside 2..14 (grass, ferns, dead bushes and
	tall plants) or 5..11 (flowers and mushrooms) whichever way it is turned. Those are Minecraft's
	outlines too, except for tall plants: DoublePlantBlock keeps a block's default shape, so each
	half is aimed at and outlined as a full block (TALL_BOUNDS).

	What burns (Minecraft's FireBlock.bootStrap): every flower and tall flower, both halves, at 60
	/ 100 (`flower`, `tulip` and `tallFlower` give it); no sapling and no mushroom. A pack's grass,
	ferns and herbs give theirs on their entries.
]]

local Schema = require(script.Parent.Parent.Schema)

type BlockSpec = Schema.BlockSpec
type ShapeBox = Schema.ShapeBox
type Bounds = Schema.Bounds
type PlantSpec = Schema.PlantSpec
type FlammableSpec = Schema.FlammableSpec

local Plants = {}

local SMOOTH = "SmoothPlastic"
-- The ground, the bottom face of the cell.
Plants.GROUND = -8
local GROUND = Plants.GROUND

-- Minecraft's outlines: a flower's and a mushroom's (5..11 across), a sapling's, and a tall
-- plant's halves (the whole cell).
Plants.FLOWER_BOUNDS = { min = { 5, 0, 5 }, max = { 11, 10, 11 } } :: Bounds
Plants.MUSHROOM_BOUNDS = { min = { 5, 0, 5 }, max = { 11, 6, 11 } } :: Bounds
Plants.SAPLING_BOUNDS = { min = { 2, 0, 2 }, max = { 14, 12, 14 } } :: Bounds
Plants.TALL_BOUNDS = { min = { 0, 0, 0 }, max = { 16, 16, 16 } } :: Bounds

-- Flower stems and leaves (not tinted).
Plants.STEM = { 70, 126, 42 }
Plants.LEAF = { 60, 114, 38 }
Plants.LEAF_LIGHT = { 88, 146, 54 }
local STEM, LEAF, LEAF_LIGHT = Plants.STEM, Plants.LEAF, Plants.LEAF_LIGHT

-- Flowers' fire odds (Minecraft's FireBlock.bootStrap).
local FLOWER_FIRE: FlammableSpec = { ignite = 60, burn = 100 }

--[[ Boxes ]]

-- The unit vector `lean` degrees from upright towards `facing` (degrees about the vertical axis
-- from east: 0 = east (+X), 90 = south (+Z)).
function Plants.leaning(lean: number, facing: number): { number }
	local t, f = math.rad(lean), math.rad(facing)
	return { math.cos(f) * math.sin(t), math.cos(t), math.sin(f) * math.sin(t) }
end

-- The point `distance` pixels from `from` along a blade leaning `lean` towards `facing`.
function Plants.along(from: { number }, lean: number, facing: number, distance: number): { number }
	local d = Plants.leaning(lean, facing)
	return { from[1] + d[1] * distance, from[2] + d[2] * distance, from[3] + d[3] * distance }
end
local along = Plants.along

--[[
	A thin box from `foot` ({ x, y, z }) leaning `lean` degrees from upright towards `facing`:
	`size` = { width, length, thickness }. Its foot stays put whatever the lean:
	CFrame.Angles(0, 180 - facing, lean) leans it about its own Z axis, then turns it. `flat`: its
	broad face looks out and up (a leaf); otherwise the lean is in the plane of its broad face, so
	the splay of grass blades and fronds shows from the side.
]]
function Plants.slat(
	foot: { number },
	size: { number },
	lean: number,
	facing: number,
	colour: { number },
	flat: boolean
): ShapeBox
	return {
		size = if flat then { size[3], size[2], size[1] } else { size[1], size[2], size[3] },
		offset = along(foot, lean, facing, size[2] / 2),
		rotation = { 0, 180 - facing, lean },
		color = colour,
		material = SMOOTH,
	}
end
local slat = Plants.slat

-- A grass blade, frond, stem or twig: leaning in the plane of its broad face.
function Plants.blade(foot: { number }, size: { number }, lean: number, facing: number, colour: { number }): ShapeBox
	return slat(foot, size, lean, facing, colour, false)
end
local blade = Plants.blade

-- A leaf: its broad face looks out and up.
function Plants.leaf(foot: { number }, size: { number }, lean: number, facing: number, colour: { number }): ShapeBox
	return slat(foot, size, lean, facing, colour, true)
end
local leaf = Plants.leaf

-- A box at `offset` (a flower head, a cap, a bush), turned by `rotation` (degrees, CFrame.Angles
-- order). (BlockList's `lump`.)
function Plants.plantBox(size: { number }, offset: { number }, colour: { number }, rotation: { number }?): ShapeBox
	return { size = size, offset = offset, rotation = rotation, color = colour, material = SMOOTH }
end
local plantBox = Plants.plantBox

-- A flower's stem from the ground, `height` pixels, leaning `lean` towards `facing`.
function Plants.stem(height: number, lean: number?, facing: number?): ShapeBox
	return blade({ 0, GROUND, 0 }, { 0.8, height, 0.8 }, lean or 0, facing or 0, STEM)
end
local stem = Plants.stem

--[[ Entries ]]

--[[
	`spec` made a plant (see the header): its material (default SmoothPlastic), not solid, broken
	at once, grass sounds, washed away, the Plant behaviour unless it has its own, scattered; an
	upper half (`plant.bottom`) names its lower half as its `item` and drops nothing, anything else
	stands on its soil (`support` "Down"). A plant with `placeable = false` is no item of its own
	either: an item places it (its `places`: the herbs, planted by their leaves and roots).
	At most 4 boxes. Returns `spec`.
]]
function Plants.plant(spec: BlockSpec): BlockSpec
	local info = spec.plant :: PlantSpec
	local upper = info.bottom ~= nil
	spec.material = spec.material or SMOOTH
	spec.solid = false
	spec.placeable = not upper and spec.placeable ~= false
	spec.hardness = 0
	spec.sound = "grass"
	spec.brokenByFluid = true
	spec.behaviour = spec.behaviour or "Plant"
	spec.scatter = true
	if upper then
		spec.item = info.bottom
		spec.drops = false
	else
		spec.support = "Down"
	end
	assert(spec.shape and #spec.shape <= 4, `Plant {spec.name} has more than 4 boxes`)
	return spec
end
local plant = Plants.plant

-- A tall plant's item: the lower half's boxes and then `extra` (the top's blossoms or blades).
function Plants.tallIcon(lower: { ShapeBox }, extra: { ShapeBox }): { ShapeBox }
	local icon = table.clone(lower)
	for _, box in extra do
		table.insert(icon, box)
	end
	return icon
end

--[[
	A tall plant's two halves (Minecraft's DoublePlantBlock), `lower` and `upper` made plants and
	joined: the lower half stands on its soil (`lower.plant.soil`, default "dirt") with the upper as
	its `top`, the upper names it as its `bottom`; both are aimed at as full blocks unless they say
	otherwise. Returns { lower, upper }.
]]
function Plants.tallPlant(lower: BlockSpec, upper: BlockSpec): { BlockSpec }
	local soil = if lower.plant then lower.plant.soil else nil
	lower.plant = { soil = soil or "dirt", top = upper.name }
	upper.plant = { bottom = lower.name }
	lower.bounds = lower.bounds or Plants.TALL_BOUNDS
	upper.bounds = upper.bounds or Plants.TALL_BOUNDS
	return { plant(lower), plant(upper) }
end

--[[
	A tall flower `name` (its upper half "<name>Top") in `colour`: the lower half's boxes `lower`,
	the upper's `upper`, its item the lower half and then `extra`. Burns as flowers do.
]]
function Plants.tallFlower(
	name: string,
	colour: { number },
	lower: { ShapeBox },
	upper: { ShapeBox },
	extra: { ShapeBox },
	displayName: string?
): { BlockSpec }
	return Plants.tallPlant({
		name = name,
		displayName = displayName,
		color = colour,
		shape = lower,
		icon = Plants.tallIcon(lower, extra),
		flammable = FLOWER_FIRE,
	}, {
		name = name .. "Top",
		displayName = displayName or name,
		color = colour,
		shape = upper,
		flammable = FLOWER_FIRE,
	})
end

-- A flower on dirt (Minecraft's 5..11 outline) in `colour`, drawn with `shape`; burns.
function Plants.flower(name: string, colour: { number }, shape: { ShapeBox }, displayName: string?): BlockSpec
	return plant({
		name = name,
		displayName = displayName,
		color = colour,
		plant = { soil = "dirt" },
		shape = shape,
		bounds = Plants.FLOWER_BOUNDS,
		flammable = FLOWER_FIRE,
	})
end

-- A tulip: a cup of `colour` on a stem between two long leaves.
function Plants.tulip(name: string, colour: { number }): BlockSpec
	return Plants.flower(name, colour, {
		stem(6),
		leaf({ 0, GROUND, 0 }, { 1.6, 5, 0.4 }, 22, 45, LEAF),
		leaf({ 0, GROUND, 0 }, { 1.6, 4.4, 0.4 }, 26, 225, LEAF_LIGHT),
		plantBox({ 2.6, 3.4, 2.6 }, { 0, -0.6, 0 }, colour, { 0, 45, 0 }),
	})
end

-- A mushroom (Minecraft's MushroomBlock soil set, `plant.soil` "mushroom") drawn with `shape`.
function Plants.mushroom(name: string, colour: { number }, shape: { ShapeBox }, displayName: string): BlockSpec
	return plant({
		name = name,
		displayName = displayName,
		color = colour,
		plant = { soil = "mushroom" },
		shape = shape,
		bounds = Plants.MUSHROOM_BOUNDS,
	})
end

--[[
	A sapling (Minecraft's SaplingBlock) on dirt-type soil, grown into its tree by a random tick
	under the open sky (server Behaviours/Sapling): drawn as its texture pack sprite, else as a stem
	with two leaf lumps of `colour`. Minecraft's outline: 2..14 across, 12 high.
]]
function Plants.sapling(name: string, colour: { number }, displayName: string): BlockSpec
	return plant({
		name = name,
		displayName = displayName,
		color = colour,
		behaviour = "Sapling",
		plant = { soil = "dirt" },
		shape = {
			stem(6),
			plantBox({ 4.5, 3, 4.5 }, { 0, -2.5, 0 }, colour),
			plantBox({ 3, 2.5, 3 }, { 0, -0.5, 0 }, colour, { 0, 45, 0 }),
		},
		bounds = Plants.SAPLING_BOUNDS,
	})
end

--[[
	A herb (Tough As Nails' water and teas): `spec` (its name, colour, `shape` inside `bounds`, its
	texture, how it burns...) made a plant on dirt that is no item of its own (its item plants it,
	its `places`), spreading slowly (server Behaviours/Herb). Returns `spec`.
]]
function Plants.herb(spec: BlockSpec): BlockSpec
	spec.placeable = false
	spec.behaviour = "Herb"
	spec.plant = { soil = "dirt" }
	return plant(spec)
end

return Plants
