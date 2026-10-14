--[[
	The body temperature in the picture (client Rendering/TemperatureGrade): the colour drains as
	the player freezes and turns vivid as they overheat, by at most half a step of Saturation
	either way, in proportion to how far the extreme has got, eased in over time.
]]

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Temperature = require(shared.ToughAsNails.Temperature)
	local TemperatureGrade = require(client.Rendering.TemperatureGrade)

	local s = Config.ToughAsNails.Grading
	local FULL = Temperature.EXTREME_TICKS

	t.test("temperature grade: desaturated freezing, oversaturated overheating, half a step at most", function()
		t.near(s.Freezing, -0.5, 1e-9, "the asked change when freezing")
		t.near(s.Overheating, 0.5, 1e-9, "and when overheating")
		t.eq(TemperatureGrade.saturation(0, 0), 0, "a comfortable body: the picture as it is")
		t.near(TemperatureGrade.saturation(FULL, 0), -0.5, 1e-9, "frozen through: half the colour gone")
		t.near(TemperatureGrade.saturation(0, FULL), 0.5, 1e-9, "overheated: half again as vivid")
		t.near(TemperatureGrade.saturation(FULL / 2, 0), -0.25, 1e-9, "halfway there, half of it")
		t.near(TemperatureGrade.saturation(0, FULL / 4), 0.125, 1e-9)
		t.near(TemperatureGrade.saturation(FULL * 3, 0), -0.5, 1e-9, "never past the full change")
		local last = 1
		for frozen = 0, FULL, 20 do
			local value = TemperatureGrade.saturation(frozen, 0)
			t.ok(value <= last and value >= -0.5, `colder, greyer ({frozen})`)
			last = value
		end
		local off = table.clone(s)
		off.Enabled = false
		t.eq(TemperatureGrade.saturation(FULL, 0, off), 0, "switched off")
	end)

	t.test("temperature grade: eases towards the target, never overshoots", function()
		local shown = 0
		local seconds = 0
		while shown > -0.49 and seconds < 20 do
			local before = shown
			shown = TemperatureGrade.ease(shown, -0.5, 1 / 60, s)
			t.ok(shown < before and shown >= -0.5, "moves towards it, not past")
			seconds += 1 / 60
		end
		t.ok(seconds > s.Seconds and seconds < s.Seconds * 6, `about {s.Seconds} s time constant (took {seconds})`)
		local instant = table.clone(s)
		instant.Seconds = 0
		t.eq(TemperatureGrade.ease(0, 0.5, 1 / 60, instant), 0.5, "Seconds 0: at once")
	end)
end
