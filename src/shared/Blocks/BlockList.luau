--!strict
--[[
	Every block type in the game. A block's numeric id is its position in this list minus one, so:

	  * ALWAYS ADD NEW BLOCKS AT THE END. Reordering changes ids, which breaks saved edits.
	  * Air must stay first (id 0): freshly created chunk buffers are zero-filled, i.e. all air.

	Fields (everything except `name` is optional):
	  name          Unique name, used as `Blocks.id.Name`.
	  render        "Opaque" (default), "Transparent" (glass-like), "Fluid" (only the surface is drawn)
	                or "None" (never drawn).
	  color         { r, g, b } in 0-255.
	  material      Name of an Enum.Material, e.g. "Slate".
	  transparency  Part transparency for Transparent / Fluid blocks.
	  reflectance   Part reflectance.
	  solid         Collides with characters. Default true for drawn blocks.
	  replaceable   Placing a block may overwrite it (air, fluids). Default false.
	  breakable     Players can break it. Default true.
	  placeable     Is an item players can hold and place (creative inventory, drops). Default true
	                for drawn, solid blocks.
	  behaviour     Name of a server block behaviour (see ServerScriptService.IceVoxel.Behaviours).
	  friction      How slippery the block is to walk on (Minecraft's block friction): 0.6 by
	                default, 0.98 for ice. Higher keeps more of the speed from tick to tick.
	  fluid         { group, level, tickDelay } for fluids (filled in by `fluid()` below).
	  hardness      Minecraft's destroy time: survival players mine it by hand in hardness x 1.5
	                seconds (0 = instantly). Default 1.
	  drops         Name of the item a survival player gets for breaking it (default: the block
	                itself), or false for nothing (e.g. glass, leaves).
	  container     Number of item slots: right clicking the block opens them (e.g. a chest), and
	                breaking it drops what is inside.

	Textures (optional, see "Block textures" in the README):
	  texture       Name of a MaterialVariant in MaterialService whose BaseMaterial is `material`
	                (e.g. "IV_Stone" with BaseMaterial Slate, StudsPerTile = BlockSize, Pattern Regular).
	                `color` stays the block's colour on the map; the part is tinted with `tint`.
	  tint          { r, g, b } multiplied with the texture. Default white (the texture's own colours).
	  faces         { Top = "rbxassetid://...", ... }: extra images drawn on single faces of full
	                detail parts, e.g. a grass top over a dirt texture. Costs one instance per face.
]]

export type BlockSpec = {
	name: string,
	render: string?,
	color: { number }?,
	material: string?,
	transparency: number?,
	reflectance: number?,
	solid: boolean?,
	replaceable: boolean?,
	breakable: boolean?,
	placeable: boolean?,
	behaviour: string?,
	friction: number?,
	fluid: { group: string, level: number, tickDelay: number }?,
	hardness: number?,
	drops: (string | false)?,
	container: number?,
	texture: string?,
	tint: { number }?,
	faces: { [string]: string }?,
}

local list: { BlockSpec } = {
	{ name = "Air", render = "None", solid = false, replaceable = true, breakable = false },
	-- Air produced by cave carving. Behaves exactly like air, but the mesher can treat it as solid
	-- rock so cave walls far from the camera are not drawn.
	{ name = "CaveAir", render = "None", solid = false, replaceable = true, breakable = false },
	{ name = "Bedrock", color = { 45, 45, 50 }, material = "Basalt", breakable = false, placeable = false },
	{ name = "Stone", color = { 125, 125, 128 }, material = "Slate", hardness = 1.5, drops = "Cobblestone" },
	{ name = "Cobblestone", color = { 110, 110, 112 }, material = "Cobblestone", hardness = 2 },
	{ name = "Dirt", color = { 121, 85, 58 }, material = "Ground", hardness = 0.5 },
	{
		name = "Grass",
		color = { 92, 158, 62 },
		material = "Grass",
		behaviour = "Grass",
		hardness = 0.6,
		drops = "Dirt",
	},
	{
		name = "DryGrass",
		color = { 168, 162, 84 },
		material = "Grass",
		behaviour = "Grass",
		hardness = 0.6,
		drops = "Dirt",
	},
	{ name = "Snow", color = { 238, 242, 248 }, material = "Snow", hardness = 0.2 },
	{ name = "Sand", color = { 220, 206, 160 }, material = "Sand", behaviour = "Gravity", hardness = 0.5 },
	{ name = "Sandstone", color = { 206, 188, 138 }, material = "Sandstone", hardness = 0.8 },
	{ name = "Gravel", color = { 132, 126, 122 }, material = "Pebble", behaviour = "Gravity", hardness = 0.6 },
	{ name = "Ice", color = { 165, 205, 240 }, material = "Glacier", friction = 0.98, hardness = 0.5, drops = false },
	{ name = "OakLog", color = { 106, 82, 52 }, material = "Wood", hardness = 2 },
	{ name = "OakLeaves", color = { 68, 128, 46 }, material = "LeafyGrass", hardness = 0.2, drops = false },
	{ name = "BirchLog", color = { 216, 212, 198 }, material = "Wood", hardness = 2 },
	{ name = "BirchLeaves", color = { 112, 150, 68 }, material = "LeafyGrass", hardness = 0.2, drops = false },
	{ name = "SpruceLog", color = { 74, 54, 34 }, material = "Wood", hardness = 2 },
	{ name = "SpruceLeaves", color = { 44, 88, 56 }, material = "LeafyGrass", hardness = 0.2, drops = false },
	{ name = "AcaciaLog", color = { 118, 108, 98 }, material = "Wood", hardness = 2 },
	{ name = "AcaciaLeaves", color = { 108, 138, 40 }, material = "LeafyGrass", hardness = 0.2, drops = false },
	{ name = "JungleLog", color = { 96, 76, 44 }, material = "Wood", hardness = 2 },
	{ name = "JungleLeaves", color = { 40, 120, 30 }, material = "LeafyGrass", hardness = 0.2, drops = false },
	{ name = "Cactus", color = { 64, 122, 52 }, material = "Grass", hardness = 0.4 },
	{ name = "CoalOre", color = { 58, 58, 62 }, material = "Rock", hardness = 3 },
	{ name = "IronOre", color = { 176, 142, 118 }, material = "Rock", hardness = 3 },
	{ name = "GoldOre", color = { 222, 190, 72 }, material = "Rock", hardness = 3 },
	{ name = "DiamondOre", color = { 92, 202, 212 }, material = "Rock", hardness = 3 },
	{ name = "Planks", color = { 170, 134, 84 }, material = "WoodPlanks", hardness = 2 },
	{ name = "Brick", color = { 160, 82, 62 }, material = "Brick", hardness = 2 },
	{
		name = "Glass",
		render = "Transparent",
		color = { 210, 235, 245 },
		material = "Glass",
		transparency = 0.6,
		hardness = 0.3,
		drops = false,
	},
}

--[[
	Fluids get one block per level: level 0 is a source block, 1-7 are flowing blocks getting weaker,
	and 8 is "falling" fluid fed from above. They share one appearance so the mesher merges them.
]]
local function fluid(group: string, spec: BlockSpec, tickDelay: number)
	for level = 0, 8 do
		local name = if level == 0 then group elseif level == 8 then group .. "Falling" else group .. "Flow" .. level
		table.insert(list, {
			name = name,
			render = "Fluid",
			color = spec.color,
			material = spec.material,
			transparency = spec.transparency,
			reflectance = spec.reflectance,
			solid = false,
			replaceable = true,
			placeable = level == 0,
			hardness = 100,
			drops = false,
			behaviour = "Fluid",
			fluid = { group = group, level = level, tickDelay = tickDelay },
		})
	end
end

fluid("Water", {
	name = "Water",
	color = { 44, 106, 196 },
	material = "Glass",
	transparency = 0.45,
	reflectance = 0.05,
}, 5)

-- Add new blocks below this line (and never above, see the note at the top).

-- Mountains, rivers and islands (terrain generator).
table.insert(
	list,
	{ name = "PackedIce", color = { 141, 180, 236 }, material = "Ice", friction = 0.98, hardness = 0.5, drops = false }
)
table.insert(list, { name = "Calcite", color = { 222, 223, 218 }, material = "Marble", hardness = 0.75 })
table.insert(list, { name = "PackedMud", color = { 142, 106, 79 }, material = "Mud", hardness = 1 })
table.insert(list, {
	name = "Mycelium",
	color = { 122, 104, 116 },
	material = "Grass",
	behaviour = "Grass",
	hardness = 0.6,
	drops = "Dirt" :: string,
})
table.insert(list, {
	name = "Podzol",
	color = { 106, 74, 38 },
	material = "Ground",
	behaviour = "Grass",
	hardness = 0.5,
	drops = "Dirt" :: string,
})
table.insert(list, { name = "CoarseDirt", color = { 112, 80, 56 }, material = "Ground", hardness = 0.5 })
-- Stone varieties and ores by altitude (Ores.luau).
table.insert(list, { name = "Andesite", color = { 134, 134, 136 }, material = "Rock", hardness = 1.5 })
table.insert(list, { name = "Diorite", color = { 190, 190, 190 }, material = "Limestone", hardness = 1.5 })
table.insert(list, { name = "Granite", color = { 150, 103, 85 }, material = "Granite", hardness = 1.5 })
table.insert(list, { name = "EmeraldOre", color = { 62, 168, 94 }, material = "Rock", hardness = 3 })
-- Containers (server Players/Containers): right clicking opens the slots, breaking drops them.
table.insert(
	list,
	{ name = "Chest", color = { 162, 118, 58 }, material = "WoodPlanks", hardness = 2.5, container = 27 }
)

return list
