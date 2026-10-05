--!strict
--[[
	Mekanism's tier numbers for transmitters and fluid tanks (Mekanism 10.x for Minecraft 1.20.1:
	TransporterTier, PipeTier and FluidTankTier), with nothing required, so BlockList can read
	them too. Shared/Transmitters re-exports everything here; use that.

	Tier 1..4 = Basic, Advanced, Elite, Ultimate.

	  transporterPull   items a Logistical Transporter takes per pull from each PULL side
	  transporterSpeed  progress an item makes per tick inside the transporter (100 = one block):
	                    Basic 5 is 20 ticks (one second) a block, Ultimate 50 two blocks a second
	  pipeCapacity      mB a Mechanical Pipe adds to its network's buffer
	  pipePull          mB per tick a pipe takes from a tank through each PULL side
	  tankCapacity      mB a Fluid Tank holds
	  tankOutput        mB per tick a tank gives out at most (Mekanism's output rate)
	  colour            the tier's colour on frames (Mekanism's: Basic dark grey, Advanced red,
	                    Elite dark aqua, Ultimate purple)
]]

export type Tier = {
	name: string,
	colour: { number },
	transporterPull: number,
	transporterSpeed: number,
	pipeCapacity: number,
	pipePull: number,
	tankCapacity: number,
	tankOutput: number,
}

local Tiers = {}

local TIERS: { Tier } = {
	{
		name = "Basic",
		colour = { 72, 72, 78 },
		transporterPull = 1,
		transporterSpeed = 5,
		pipeCapacity = 2000,
		pipePull = 250,
		tankCapacity = 32000,
		tankOutput = 1000,
	},
	{
		name = "Advanced",
		colour = { 196, 44, 44 },
		transporterPull = 16,
		transporterSpeed = 10,
		pipeCapacity = 8000,
		pipePull = 1000,
		tankCapacity = 64000,
		tankOutput = 4000,
	},
	{
		name = "Elite",
		colour = { 0, 160, 160 },
		transporterPull = 32,
		transporterSpeed = 20,
		pipeCapacity = 32000,
		pipePull = 8000,
		tankCapacity = 128000,
		tankOutput = 16000,
	},
	{
		name = "Ultimate",
		colour = { 136, 46, 170 },
		transporterPull = 64,
		transporterSpeed = 50,
		pipeCapacity = 128000,
		pipePull = 32000,
		tankCapacity = 256000,
		tankOutput = 64000,
	},
}
for _, tier in TIERS do
	table.freeze(tier.colour)
	table.freeze(tier)
end
Tiers.TIERS = table.freeze(TIERS)

-- mB in a Minecraft bucket.
Tiers.BUCKET = 1000
-- Simulation ticks per second (Minecraft's 20).
Tiers.TICK_RATE = 20
-- Ticks between two pulls of a transporter's PULL sides (Mekanism's pull delay).
Tiers.PULL_DELAY = 10
-- An item's progress through one transporter, from entering it to leaving it.
Tiers.BLOCK_PROGRESS = 100
--[[
	Path cost of passing a transporter (Mekanism's LogisticalTransporterBase.getCost: the Ultimate
	speed over the transporter's own, so Basic 10, Advanced 5, Elite 2.5, Ultimate 1; use
	Transmitters.pathCost) and of a Restrictive Transporter (RestrictiveTransporter.getCost):
	routes take the faster transporters and avoid restrictive ones unless there is no other way.
	TRANSPORTER_COST is the cheapest, an Ultimate transporter's.
]]
Tiers.TRANSPORTER_COST = 1
Tiers.RESTRICTIVE_COST = 1000

return table.freeze(Tiers)
