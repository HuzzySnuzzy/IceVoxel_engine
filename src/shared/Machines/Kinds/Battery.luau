--!strict
--[[
	Mekanism's Energy Cubes (kind "battery"), named Batteries: BlockList `BasicBattery`,
	`AdvancedBattery`, `EliteBattery` and `UltimateBattery`, each with `energy = { capacity, input,
	output }` from Mekanism's EnergyCubeTier (Transmitters/Tiers `batteryCapacity`, `batteryRate`):

	    Basic      4 MJ     4 kJ/t in and out
	    Advanced   16 MJ    16 kJ/t
	    Elite      64 MJ    64 kJ/t
	    Ultimate   256 MJ   256 kJ/t

	The same rate in and out makes it storage (Shared/Machines.role), and the energy networks
	(server Machines/EnergyNet) give storage the backup's part every tick: what the generators have
	left after the machines took what they need charges it, up to its rate; when the generators
	fall short (a Heat Generator out of fuel, a Solar Panel at night) it covers what the machines
	still need, up to its rate, so they keep running. Batteries never charge each other. It has no
	tick of its own and no slots: the networks move its energy, and the header's INPUT and OUTPUT
	say what they put in and took out last tick.

	Its status (WAILA, the panel) reads those: "Charging 150 J/t", "Discharging 50 J/t", else
	"Full", "Empty" or "Idle". Its panel: the status line, then its input and output last tick and
	its rate (`lines`), and the energy bar.

	Its item keeps its charge (Shared/Machines sustained data: `energy`), so it stacks to 1
	(BlockList `maxStack`); its tooltip says "Energy: 1.2 MJ" and its icon has Mekanism's energy bar
	where a tool's durability bar goes (Ui/MenuLayout.energyItemBar). Crafting the next tier around
	one keeps its charge (Crafting/Recipes `keep`, Mekanism's MekDataShapedRecipe). In the world its
	gauges fill with its charge (client Rendering/TransmitterModel.machineBoxes, from its Machines
	record).

	Mekanism's charge and discharge slots (energy items) and side configuration are not here.
]]

local Core = require(script.Parent.Parent.Core)
local Items = require(script.Parent.Parent.Parent.Items)

local function rate(joules: number): string
	return `{Items.formatEnergy(joules)}/t`
end

return Core.define("battery", {
	panel = {
		status = { x = 8, y = 20 },
		lines = { x = 8, y = 34 },
	},
	status = function(view: Core.View): string?
		local net = view.input - view.output
		if net > 0 then
			return `Charging {rate(net)}`
		elseif net < 0 then
			return `Discharging {rate(-net)}`
		elseif view.capacity > 0 and view.energy >= view.capacity then
			return "Full"
		elseif view.energy <= 0 then
			return "Empty"
		end
		return "Idle"
	end,
	-- What the network put in and took out last tick, and the most it may each tick.
	lines = function(view: Core.View): { string }
		local energy = Core.energyOf(view.block)
		local most = if energy then math.max(energy.input or 0, energy.output or 0) else 0
		return {
			`Input: {rate(view.input)}`,
			`Output: {rate(view.output)}`,
			`Max rate: {rate(most)}`,
		}
	end,
})
