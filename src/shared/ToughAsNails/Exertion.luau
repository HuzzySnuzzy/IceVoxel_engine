--!strict
--[[
	Movement that costs thirst, pure: Minecraft 1.20.1's Player.checkMovementStatistics and
	Player.jumpFromGround, whose food exhaustion TAN's thirst counts too (Thirst.EXHAUSTION).

	Movement is the client's (Player/MovementController), as in Minecraft, whose server takes the
	client's positions and sprint flag. So the client measures each movement tick (`record`, with
	the tick's move and the hull's flags after it):
	  swimming                       the whole move (3D)         water centimetres
	  eyes under water               the whole move (3D)         water centimetres
	  wading (in water)              the horizontal move         water centimetres
	  on the ground, sprinting       the horizontal move         sprint centimetres
	  a jump (sprinting or not)                                  jumps / sprint jumps
	(flying and spectating cost nothing; Minecraft's walking, crouching and climbing cost nothing
	either) and reports it (Protocol Exertion: whole centimetres, Minecraft's Math.round of each
	move x 100) about once a second, with whether it sprints now (the temperature's sprinting).
	The server bounds a report by the time since the last one (`clamp`: MAX_CM_PER_SECOND,
	MAX_JUMPS_PER_SECOND, so a client can't drain anyone faster than running can) and turns it
	into exhaustion (`exhaustion`: 0.1 a sprinted metre, 0.01 a metre in water, 0.05 a jump, 0.2
	a sprint jump).
]]

local Thirst = require(script.Parent.Thirst)

export type Report = {
	sprintCm: number,
	waterCm: number,
	jumps: number,
	sprintJumps: number,
	-- Sprinting at the time of the report.
	sprinting: boolean,
}

-- The hull flags `record` reads (Movement/PlayerPhysics State).
export type Hull = {
	swimming: boolean,
	eyeInWater: boolean,
	inWater: boolean,
	onGround: boolean,
	sprinting: boolean,
	flying: boolean,
	noClip: boolean,
}

local Exertion = {}

-- The most a report may carry for each second since the last one (sprint jumping runs
-- 7.1 m/s, swimming less) and the u16 / u8 the wire holds.
Exertion.MAX_CM_PER_SECOND = 1000
Exertion.MAX_JUMPS_PER_SECOND = 3
Exertion.MAX_CM = 65535
Exertion.MAX_JUMPS = 255
-- Seconds between two reports from the client.
Exertion.INTERVAL = 1

function Exertion.new(): Report
	return { sprintCm = 0, waterCm = 0, jumps = 0, sprintJumps = 0, sprinting = false }
end

-- Is there nothing to report but the sprint flag?
function Exertion.isEmpty(report: Report): boolean
	return report.sprintCm == 0 and report.waterCm == 0 and report.jumps == 0 and report.sprintJumps == 0
end

-- Clears the counts (after sending), keeping the sprint flag.
function Exertion.reset(report: Report)
	report.sprintCm, report.waterCm, report.jumps, report.sprintJumps = 0, 0, 0, 0
end

--[[
	Adds one movement tick of `hull` (its flags after the tick) that moved (dx, dy, dz) blocks and
	jumped or not (see the header).
]]
function Exertion.record(report: Report, hull: Hull, dx: number, dy: number, dz: number, jumped: boolean)
	report.sprinting = hull.sprinting
	if hull.flying or hull.noClip then
		return
	end
	if jumped then
		if hull.sprinting then
			report.sprintJumps = math.min(report.sprintJumps + 1, Exertion.MAX_JUMPS)
		else
			report.jumps = math.min(report.jumps + 1, Exertion.MAX_JUMPS)
		end
	end
	local horizontal = math.round(math.sqrt(dx * dx + dz * dz) * 100)
	if hull.swimming or hull.eyeInWater then
		local whole = math.round(math.sqrt(dx * dx + dy * dy + dz * dz) * 100)
		report.waterCm = math.min(report.waterCm + whole, Exertion.MAX_CM)
	elseif hull.inWater then
		report.waterCm = math.min(report.waterCm + horizontal, Exertion.MAX_CM)
	elseif hull.onGround and hull.sprinting then
		report.sprintCm = math.min(report.sprintCm + horizontal, Exertion.MAX_CM)
	end
end

-- `report` bounded by what `seconds` of movement can do (see the header): a new report.
function Exertion.clamp(report: Report, seconds: number): Report
	local cm = math.floor(math.max(seconds, 0) * Exertion.MAX_CM_PER_SECOND)
	local jumps = math.floor(math.max(seconds, 0) * Exertion.MAX_JUMPS_PER_SECOND)
	local sprintCm = math.min(report.sprintCm, cm)
	local waterCm = math.min(report.waterCm, cm - sprintCm)
	local sprintJumps = math.min(report.sprintJumps, jumps)
	return {
		sprintCm = sprintCm,
		waterCm = waterCm,
		jumps = math.min(report.jumps, jumps - sprintJumps),
		sprintJumps = sprintJumps,
		sprinting = report.sprinting,
	}
end

-- The exhaustion a report costs (Minecraft's FoodConstants, see the header).
function Exertion.exhaustion(report: Report): number
	local costs = Thirst.EXHAUSTION
	return report.sprintCm * 0.01 * costs.sprintMetre
		+ report.waterCm * 0.01 * costs.waterMetre
		+ report.jumps * costs.jump
		+ report.sprintJumps * costs.sprintJump
end

return Exertion
