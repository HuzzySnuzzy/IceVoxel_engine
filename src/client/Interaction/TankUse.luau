--!strict
--[[
	Does a bucket clicked on a machine with fluid tanks fill or empty one of them, as far as the
	client knows? Then Interaction/BlockInteraction sends the use (UseItem) instead of opening the
	machine's screen; else the screen opens, as Mekanism's BlockFluidTank.use opens its GUI when
	FluidUtils.handleTankInteraction moves nothing. The server decides (Transmitters/UseRules:
	Machines.pourBucket, Machines.fillBucket); this asks the same of the machine's kind (its tanks,
	Shared/Machines) and of the tanks' contents in its last Machines record (Rendering/
	TransmitterRenderer.machine; without a record, the server's default: every tank empty).

	  Full bucket   (Water, Lava, Oil, Fuel Bucket) an input tank takes its fluid
	                (Machines.bucketTank) and has room for all 1000 mB: empty or holding that fluid.
	  Empty bucket  a tank (output or input) holds 1000 mB of a fluid buckets carry.
	A record without tanks (a server that sends none) says nothing about them: a full bucket then
	goes to a machine with a tank taking its fluid, an empty one to a machine with output tanks.

	Pure (tests/spec/LavaOilClient).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Fluids = require(Shared.Fluids)
local Items = require(Shared.Items)
local Machines = require(Shared.Machines)
local Protocol = require(Shared.Net.Protocol)

local TankUse = {}

local BUCKET = Items.id.Bucket
-- (No record: the server's default record, its tanks empty.)
local NO_TANKS: { Protocol.MachineTank } = table.freeze({})

--[[
	Does `item` (an empty or full bucket) used on the machine `block` act on its tanks, by the
	machine's last record `record` (nil: none came)? false for other items and blocks.
]]
function TankUse.acts(block: number, item: number, record: Protocol.MachineRecord?): boolean
	local specs = Machines.tanks(block)
	if #specs == 0 then
		return false
	end
	local tanks = if record then record.tanks else NO_TANKS
	if item == BUCKET then
		if tanks == nil then
			return Machines.givesFluid(block)
		end
		for id in specs do
			local tank = tanks[id]
			if tank and tank.amount >= Fluids.BUCKET and Fluids.carriable(tank.fluid) then
				return true
			end
		end
		return false
	end
	local fluid = Fluids.ofBucket(item)
	if not Fluids.carriable(fluid) or Machines.bucketTank(block, item) == nil then
		return false
	end
	if tanks == nil then
		return true
	end
	for _, id in Machines.inputTanks(block) do
		local spec = specs[id]
		if table.find(spec.fluids, fluid) then
			local tank = tanks[id]
			local amount = if tank then tank.amount else 0
			-- (A tank holds one fluid at a time: Machines.tankRoom.)
			local held = if tank and amount > 0 then tank.fluid else fluid
			if held == fluid and spec.capacity - amount >= Fluids.BUCKET then
				return true
			end
		end
	end
	return false
end

return TankUse
