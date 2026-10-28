--!strict
--[[
	The farm animals' voices (Shared/Entities/MobList, server Mobs/MobWorld), from the server to
	everyone near: each one's hurt and death (Minecraft's entity.<kind>.hurt and .death; Content/
	Define's `mobVoice`), the ouch and the oof told apart by pitch: low for cows, high for
	chickens. The zombies' voices are the Apocalypse pack's.
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local list: { SoundSpec } = {}
	for _, voice in
		{
			{ kind = "cow", hurt = 0.55, death = 0.5 },
			{ kind = "sheep", hurt = 1.35, death = 1.3 },
			{ kind = "pig", hurt = 1.15, death = 1.1 },
			{ kind = "chicken", hurt = 1.9, death = 1.8 },
		} :: { Define.MobVoice }
	do
		define.append(list, define.mobVoice(voice))
	end
	return list
end
