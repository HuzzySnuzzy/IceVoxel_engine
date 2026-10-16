--!strict
--[[
	Every shown character's body turning as in DayZ, drawn by each client from what it already has
	(nothing is sent): at Camera + 6, the legs twist up to 45 degrees towards a strafe and walk
	backwards when backpedalling (Player/BodyRules; the hips' C0 with the animation kept, the waist
	turned back by as much), and the local player's upper body leads an idle turn and takes the
	freelook's yaw beyond the neck's (UpperTorso.Waist, from Player/CameraRig's aim and freelook).
	R6 rigs are left alone.

	FOUNDATION STUB: `start` is frozen and does nothing yet (no joint is written: today's bodies).
]]

local BodyTwist = {}

local started = false

function BodyTwist.start()
	if started then
		return
	end
	started = true
end

return BodyTwist
