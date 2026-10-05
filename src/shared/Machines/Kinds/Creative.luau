--!strict
--[[
	The Creative Energy Cube (Mekanism's creative energy cube): infinite energy, given out without
	limit (BlockList `energy = { capacity = math.huge, output = math.huge }`) to the energy network
	around it, so any machine can be tried in creative. It keeps nothing when broken (there is
	nothing to keep) and has no slots; its panel shows the energy bar, full, and what it gives.
]]

local Core = require(script.Parent.Parent.Core)
local Items = require(script.Parent.Parent.Parent.Items)

return Core.define("creative", {
	creative = true,
	panel = { status = { x = 8, y = 36 } },
	status = function(view: Core.View): string?
		if view.output > 0 then
			return `Giving {Items.formatEnergy(view.output)}/t`
		end
		return "Infinite energy"
	end,
})
