--!strict
--[[
	Fire and explosives: Minecraft's fire, TNT and lit TNT, and the Nuke, which came with TNT (one
	feature: the same lighting, the Tnt behaviour, their decorated faces). The Nuke is this game's,
	a mod's toy, not Minecraft's; it stays with TNT, and its recipe (eight TNT round a Block of
	Uranium) is the Ores pack's, with its core.

	  * Fire (Minecraft's FireBlock): burns on top of a block or clings to the sides of flammable
	    ones, spreads, burns out and lights what it touches (server Behaviours/Fire, rules in
	    Shared/Fire). No item: lit by flint and steel, lava and burning fuel. Light 15, no
	    collision, replaceable (a block placed into it puts it out), broken at once with no drop
	    (punching it out sounds like block.fire.extinguish: SoundList.BLOCK_SOUNDS), washed away by
	    water. Its one shape box is only the carrier of its light: an invisible speck (Neon,
	    see-through), sparse like glow lichen's (GreedyMesher: one PointLight per 8 x 8 x 8 blocks),
	    so a forest fire is not hundreds of lights. The flames are drawn by client Rendering/
	    FireRenderer: the user's animated sheet on Minecraft's fire_floor and fire_side planes,
	    which depend on the neighbours (Fire.sides). Its outline is Minecraft's: a pixel thick slab
	    on the floor (BaseFireBlock.DOWN_AABB); the client aims at a fire clinging to walls by the
	    slabs on those walls instead (Fire.outlineAt).
	  * TNT (Minecraft 1.20.1's TntBlock): breaks at once, no blast resistance, flammable 15 / 100
	    (FireBlock.bootStrap), red with a white band (BlockDecor "Tnt"; texture pack "tnt side",
	    "tnt top", "tnt bottom", blank until made). Flint and steel, fire burning it (lava lights the
	    fire) and a blast reaching it light it: it turns into Lit TNT, Minecraft's PrimedTnt as a
	    block (server Behaviours/Tnt): it falls while its 80 tick fuse burns, then explodes with
	    power 4. Lit TNT glows and flashes (client Rendering/FuseView), can't be broken (an entity
	    in Minecraft) and drops nothing; blasts leave it be. Its `item` is TNT (WAILA's icon, pick
	    block).
	  * The Nuke: a dark steel casing with hazard stripes and the radiation sign (BlockDecor "Nuke";
	    "nuke side", "nuke top", blank), lit the same ways. Lit, it glows red, flashes and wails for
	    10 s, then digs a crater (server World/Nuke; Config.Nuke).
]]

local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return {
	{
		name = "Fire",
		color = { 232, 132, 36 },
		material = "Neon",
		sound = "wool",
		solid = false,
		placeable = false,
		replaceable = true,
		hardness = 0,
		drops = false,
		light = 15,
		lightColor = { 255, 170, 90 },
		shape = { { size = { 2, 2, 2 }, offset = { 0, -4, 0 }, glow = true, transparency = 1 } },
		bounds = { min = { 0, 0, 0 }, max = { 16, 1, 16 } },
		brokenByFluid = true,
		behaviour = "Fire",
	},
	{
		name = "Tnt",
		displayName = "TNT",
		color = { 204, 52, 40 },
		material = "SmoothPlastic",
		sound = "grass",
		hardness = 0,
		decor = "Tnt",
		flammable = { ignite = 15, burn = 100 },
	},
	{
		name = "LitTnt",
		displayName = "Lit TNT",
		color = { 236, 120, 100 },
		material = "SmoothPlastic",
		sound = "grass",
		hardness = 0,
		breakable = false,
		placeable = false,
		blastResistance = 0,
		drops = false,
		item = "Tnt",
		decor = "Tnt",
		light = 9,
		lightColor = { 255, 226, 190 },
		behaviour = "Tnt",
	},
	{
		name = "Nuke",
		color = { 46, 50, 48 },
		material = "Metal",
		sound = "metal",
		hardness = 0,
		decor = "Nuke",
		flammable = { ignite = 15, burn = 100 },
	},
	{
		name = "LitNuke",
		displayName = "Lit Nuke",
		color = { 96, 52, 48 },
		material = "Metal",
		sound = "metal",
		hardness = 0,
		breakable = false,
		placeable = false,
		blastResistance = 0,
		drops = false,
		item = "Nuke",
		decor = "Nuke",
		light = 12,
		lightColor = { 255, 70, 50 },
		behaviour = "Tnt",
	},
} :: { Schema.BlockSpec }
