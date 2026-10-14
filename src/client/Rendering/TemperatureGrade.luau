--!strict
--[[
	The body temperature in the picture (Tough As Nails' extremes): the world loses its colour as
	the player freezes and turns too vivid as they overheat, so the edge of dying shows before the
	hurts start. It reads the hypothermia and hyperthermia the server last sent (Player/
	SurvivalState: `frozen` and `heat`, 0..Temperature.EXTREME_TICKS; they build only in the ICY and
	HOT zones, 20 s to full, then the half hearts come) and grades its own ColorCorrectionEffect
	("IceVoxelTemperature" in Lighting, made and owned here; Roblox composes it with the weather's,
	the effects', the fluids' and the blood moon's corrections).

	  `saturation(frozen, heat, s)`  pure: Freezing (-0.5) x the share frozen plus Overheating
	                                 (+0.5) x the share overheated (only one builds at a time; both
	                                 at once simply add), 0 with Enabled off. -1 would be black and
	                                 white, so -0.5 is half the colour gone: noticeable, not
	                                 overdone.
	  `ease(shown, target, dt, s)`   pure: the shown value follows the target with time constant
	                                 Seconds (the server sends the extremes in steps).
	  `start()`                      the glue: every frame eases towards the state's saturation and
	                                 writes it when it moved; disabled at 0, so a clear body costs
	                                 nothing in the picture.
	Creative and spectator players never build the extremes (Temperature.tick), so they never see
	it. Config.ToughAsNails.Grading has the numbers; Temperature off sends nothing, so nothing shows.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Temperature = require(Shared.ToughAsNails.Temperature)

export type Settings = {
	Enabled: boolean,
	Freezing: number,
	Overheating: number,
	Seconds: number,
}

local TemperatureGrade = {}

-- The ColorCorrectionEffect this module owns.
TemperatureGrade.CORRECTION = "IceVoxelTemperature"

local function settings(): Settings
	return Config.ToughAsNails.Grading
end

-- The Saturation for hypothermia `frozen` and hyperthermia `heat` (ticks, see the header).
function TemperatureGrade.saturation(frozen: number, heat: number, s: Settings?): number
	local grading = s or settings()
	if not grading.Enabled then
		return 0
	end
	local full = Temperature.EXTREME_TICKS
	local frost = math.clamp(frozen / full, 0, 1)
	local hot = math.clamp(heat / full, 0, 1)
	return grading.Freezing * frost + grading.Overheating * hot
end

-- `shown` moved towards `target` over `dt` seconds (time constant Seconds; at once with 0).
function TemperatureGrade.ease(shown: number, target: number, dt: number, s: Settings?): number
	local seconds = (s or settings()).Seconds
	if seconds <= 0 then
		return target
	end
	return target + (shown - target) * math.exp(-math.max(dt, 0) / seconds)
end

local started = false

function TemperatureGrade.start()
	if started then
		return
	end
	started = true
	local SurvivalState = require(script.Parent.Parent.Player.SurvivalState)
	local correction: ColorCorrectionEffect? = nil
	local shown = 0
	-- Written value in thousandths (to write only changes).
	local written = 0
	RunService.RenderStepped:Connect(function(dt: number)
		local status = SurvivalState.get()
		local target = if status then TemperatureGrade.saturation(status.frozen, status.heat) else 0
		shown = TemperatureGrade.ease(shown, target, dt)
		if math.abs(shown - target) < 0.001 then
			shown = target
		end
		local value = math.round(shown * 1000)
		if value == written then
			return
		end
		written = value
		if correction == nil or correction.Parent ~= Lighting then
			local made = Instance.new("ColorCorrectionEffect")
			made.Name = TemperatureGrade.CORRECTION
			made.Enabled = false
			made.Parent = Lighting
			correction = made
		end
		local effect = correction :: ColorCorrectionEffect
		effect.Saturation = value / 1000
		effect.Enabled = value ~= 0
	end)
end

return TemperatureGrade
