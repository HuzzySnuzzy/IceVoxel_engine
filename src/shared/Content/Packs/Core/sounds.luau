--!strict
--[[
	Progression's sounds, with the Ages (Shared/Progression, client Player/ProgressionState):
	knowledge gained plays Minecraft's entity.experience_orb.pickup (at most a few a second), a
	level gained entity.player.levelup (Minecraft plays it every 5 levels; here every level, the
	skill point it gives being worth hearing), and an Age reached ui.toast.challenge_complete with
	its banner (Minecraft's challenge advancement toast). The player's own client plays them, flat.
	Stand-ins: the menu's tick pitched up into a chime, then lower and longer for the fanfare.
]]

local Define = require(script.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Schema)

type SoundSpec = Schema.SoundSpec

return function(define: Define.Context): { SoundSpec }
	local TICK = define.SHIPPED.TICK
	return {
		{
			name = "entity.experience_orb.pickup",
			id = TICK,
			volume = 0.3,
			pitch = 1.8,
			pitchVariance = 0.25,
			duration = 0.2,
			ui = true,
			source = "ui",
			side = "client",
		},
		{
			name = "entity.player.levelup",
			id = TICK,
			volume = 0.6,
			pitch = 1.25,
			duration = 0.6,
			ui = true,
			source = "ui",
			side = "client",
		},
		{
			name = "ui.toast.challenge_complete",
			id = TICK,
			volume = 0.7,
			pitch = 0.75,
			duration = 1.2,
			ui = true,
			source = "ui",
			side = "client",
		},
	}
end
