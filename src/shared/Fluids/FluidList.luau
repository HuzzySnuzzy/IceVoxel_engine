--!strict
--[[
	Every fluid in the game. A fluid's id is its position in this list (0 is "none"), so:

	  * ALWAYS ADD NEW FLUIDS AT THE END. The ids are sent (Protocol `Tanks`, `Transmitters`) and
	    saved in items (a Fluid Tank's sustained `fluid`), and they must fit a u8.

	Pure data that requires nothing, so Blocks and Items may read it; Shared/Fluids turns it into
	the registry (ids, block and bucket lookups) and checks it against BlockList and ItemList.

	Fields (all required unless marked optional):
	  name           The fluid's name and its BlockList group: `fluid("<name>", ...)` makes the
	                 blocks <name> (the source, the "<name>" item), <name>Flow1..7 and
	                 <name>Falling (Blocks.fluidId).
	  displayName    Shown in tooltips, WAILA and JEI (optional: default the name).
	  bucket         ItemList name of its full bucket (1000 mB): what an empty Bucket becomes on
	                 its source, and what pours one.
	  color          { r, g, b } 0-255: the blocks' colour (checked), and what pipes, tanks, gauges
	                 and JEI's fluid stacks draw.
	  light          Light the blocks give off, 0..15 (checked against BlockList).
	  physics        Which branch of Minecraft's LivingEntity.travel moves an entity in it:
	                 "water" (moveRelative 0.02, then `drag` sideways and 0.8 up and down) or
	                 "lava" (moveRelative 0.02, then `drag` all ways while it is deeper than the
	                 jump threshold, else `drag` sideways and 0.8 vertically, gravity / 4).
	  drag           The horizontal speed kept per tick in it (Minecraft: water 0.8, 0.9
	                 sprinting; lava 0.5).
	  push           How hard its flow pushes entities per tick (Entity.updateFluidHeightAndDo-
	                 FluidPushing: water 0.014, lava 0.0023333 in the overworld).
	  swim           Players may swim in it (Minecraft: water only).
	  damage         Health points (half hearts) it takes from a player standing in it, once
	                 every `damageInterval` ticks (Minecraft's lava: 4, every 10 ticks: the hurt
	                 cooldown), 0 for none.
	  damageInterval Ticks between two of those hurts.
	  burnSeconds    Seconds a player keeps burning after leaving it (Minecraft's lava sets 15),
	                 at Fluids.BURN_DAMAGE every Fluids.BURN_INTERVAL ticks; 0 for none.
	  extinguishes   It puts burning players out (Minecraft's water).
	  furnaceFuel    Ticks its bucket burns in a furnace (Minecraft's lava bucket 20 000; the
	                 empty bucket stays in the fuel slot), 0: no fuel.
	  carriable      Buckets, Mechanical Pipes and Fluid Tanks may carry it.
	  fogColor       { r, g, b } the view is tinted with while the eye is in it.
	  fogStart       Blocks from the eye where that fog starts (Minecraft's FogRenderer: water
	                 -8, lava 0.25) ...
	  fogEnd         ... and where it is thick (water 96, lava 1).
	  fillSound      Sound event (Shared/Sounds) of a bucket taking it (Fluid.getPickupSound).
	  emptySound     Sound event of a bucket pouring it (BucketItem.playEmptySound).
]]

export type FluidSpec = {
	name: string,
	displayName: string?,
	bucket: string,
	color: { number },
	light: number,
	physics: string,
	drag: number,
	push: number,
	swim: boolean,
	damage: number,
	damageInterval: number,
	burnSeconds: number,
	extinguishes: boolean,
	furnaceFuel: number,
	carriable: boolean,
	fogColor: { number },
	fogStart: number,
	fogEnd: number,
	fillSound: string,
	emptySound: string,
}

local list: { FluidSpec } = {
	-- 1: Minecraft's water. Its fog colour is the default biome's water fog (#050533).
	{
		name = "Water",
		bucket = "WaterBucket",
		color = { 44, 106, 196 },
		light = 0,
		physics = "water",
		drag = 0.8,
		push = 0.014,
		swim = true,
		damage = 0,
		damageInterval = 0,
		burnSeconds = 0,
		extinguishes = true,
		furnaceFuel = 0,
		carriable = true,
		fogColor = { 5, 5, 51 },
		fogStart = -8,
		fogEnd = 96,
		fillSound = "item.bucket.fill",
		emptySound = "item.bucket.empty",
	},
	-- 2: Minecraft 1.20.1's lava in the overworld (LavaFluid, Entity.lavaHurt, FogRenderer's lava
	-- fog 0.6 / 0.1 / 0 at 0.25..1 blocks).
	{
		name = "Lava",
		bucket = "LavaBucket",
		color = { 212, 90, 20 },
		light = 15,
		physics = "lava",
		drag = 0.5,
		push = 0.0023333333333333335,
		swim = false,
		damage = 4,
		damageInterval = 10,
		burnSeconds = 15,
		extinguishes = false,
		furnaceFuel = 20000,
		carriable = true,
		fogColor = { 153, 26, 0 },
		fogStart = 0.25,
		fogEnd = 1,
		fillSound = "item.bucket.fill_lava",
		emptySound = "item.bucket.empty_lava",
	},
	-- 3: BuildCraft's oil: black, glossy and thick. It moves players like lava (Movement) but does
	-- not hurt, is no furnace fuel (the Oil Refinery makes fuel of it) and sounds thick like lava
	-- in a bucket. Its fog: nearly black, as short as Minecraft's powder snow (0..2).
	{
		name = "Oil",
		bucket = "OilBucket",
		color = { 24, 22, 26 },
		light = 0,
		physics = "lava",
		drag = 0.5,
		push = 0.0023333333333333335,
		swim = false,
		damage = 0,
		damageInterval = 0,
		burnSeconds = 0,
		extinguishes = false,
		furnaceFuel = 0,
		carriable = true,
		fogColor = { 10, 9, 12 },
		fogStart = 0,
		fogEnd = 2,
		fillSound = "item.bucket.fill_lava",
		emptySound = "item.bucket.empty_lava",
	},
	-- 4: BuildCraft's fuel, refined from oil: thin and amber. Players move and swim in it as in
	-- water; it burns in the Combustion Generator, not in furnaces (they burn solid fuels only).
	-- Its fog: amber, a third of water's.
	{
		name = "Fuel",
		bucket = "FuelBucket",
		color = { 232, 172, 44 },
		light = 0,
		physics = "water",
		drag = 0.8,
		push = 0.014,
		swim = true,
		damage = 0,
		damageInterval = 0,
		burnSeconds = 0,
		extinguishes = false,
		furnaceFuel = 0,
		carriable = true,
		fogColor = { 150, 100, 12 },
		fogStart = -8,
		fogEnd = 32,
		fillSound = "item.bucket.fill",
		emptySound = "item.bucket.empty",
	},
}

-- Add new fluids above this line, at the end (never reorder: the ids are saved and sent).

return list
