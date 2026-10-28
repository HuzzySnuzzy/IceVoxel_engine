--!strict
--[[
	The interface: buttons, tabs, page arrows (client Audio/SoundPlayer.click), flat for the local
	player alone, at the ui volume.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	return {
		{
			name = "ui.button.click",
			id = define.SHIPPED.TICK,
			volume = 0.5,
			duration = 0.25,
			ui = true,
			source = "ui",
			side = "client",
		},
	}
end
