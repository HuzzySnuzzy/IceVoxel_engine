--!strict
--[[
	Minecraft's bucket: three iron ingots in a V (the fluids fill it: Shared/Fluids).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

return function(define: Define.Context): { Schema.Recipe }
	return {
		define.shaped({ "I I", " I " }, { I = "IronIngot" }, "Bucket"),
	}
end
