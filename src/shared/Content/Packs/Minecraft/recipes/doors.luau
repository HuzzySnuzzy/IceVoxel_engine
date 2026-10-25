--!strict
--[[
	Doors (Minecraft's): six planks of a wood in two columns of three make three of its doors.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	local list: { Schema.Recipe } = {}
	for _, pair in
		{
			{ "Planks", "OakDoor" },
			{ "SprucePlanks", "SpruceDoor" },
			{ "BirchPlanks", "BirchDoor" },
			{ "JunglePlanks", "JungleDoor" },
			{ "AcaciaPlanks", "AcaciaDoor" },
		}
	do
		table.insert(list, define.shaped({ "##", "##", "##" }, { ["#"] = pair[1] }, pair[2], 3))
	end
	return list
end
