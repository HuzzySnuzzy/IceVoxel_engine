--[[
	The weather's own sounds (src/sounds/Weather.model.json, SoundService.IceVoxelSounds: Sounds
	named like the events they replace, several of one name are variants) and the wind's loop
	(client Weather/WindSound): every Sound replaces an event the catalogue has, with a real asset
	id; the thunder has its variants; the wind is louder in a stronger wind, a storm and high up,
	silent in a cave, quieter and duller under a roof.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Sounds = require(shared.Sounds)
	local WindSound = require(client.Weather.WindSound)
	local SoundRules = require(client.Audio.SoundRules)

	t.test("weather sounds: every shipped Sound replaces a known event with a real asset", function()
		local project = serde.decode("json", fs.readFile("default.project.json"))
		local folder = project.tree.SoundService[Config.Sounds.OverrideFolder]
		t.ok(folder ~= nil, "the project puts the override folder in SoundService")
		t.eq(folder["$path"], "src/sounds")
		local model = serde.decode("json", fs.readFile("src/sounds/Weather.model.json"))
		local counts: { [string]: number } = {}
		for _, child in model.Children do
			t.eq(child.ClassName, "Sound")
			t.ok(Sounds.id[child.Name] ~= nil, `{child.Name} is an event`)
			t.ok(string.match(child.Properties.SoundId, "^rbxassetid://%d+$") ~= nil, child.Properties.SoundId)
			t.ok(child.Properties.Volume > 0 and child.Properties.Volume <= 1, "a sane volume")
			counts[child.Name] = (counts[child.Name] or 0) + 1
		end
		t.eq(counts["entity.lightning_bolt.thunder"], 4, "four near thunder variants")
		t.eq(counts["entity.lightning_bolt.thunder.far"], 10, "ten distant thunder variants")
		t.eq(counts["weather.rain"], 1, "the rain loop")
		t.eq(counts["weather.rain.far"], 1, "the distant hiss uses the rain loop too")
		t.eq(counts["weather.wind"], 1, "the wind loop")
		local event = Sounds.get(Sounds.id["weather.wind"]) :: any
		t.eq(event.side, "client")
		t.eq(event.source, "ambient")
	end)

	t.test("weather sounds: beds heard from all around play flat, never on the listener", function()
		local positioned, flat = SoundRules.bedSplit(0.8, 0, 0)
		t.eq(positioned, 0, "the rain on the player and the wind: no source to swap ears")
		t.eq(flat, 0.8)
		positioned, flat = SoundRules.bedSplit(0.8, 0.6, 0.8)
		t.near(positioned, 0.8, 1e-9, "a full direction: all from that side")
		t.near(flat, 0, 1e-9)
		positioned, flat = SoundRules.bedSplit(1, 3, 0)
		t.near(positioned, 1, 1e-9, "longer than 1 counts as 1")
		t.near(flat, 0, 1e-9)
		positioned, flat = SoundRules.bedSplit(1, 0.3, 0.4)
		t.near(positioned, 0.5, 1e-9, "halfway: half each")
		t.near(positioned + flat, 1, 1e-9, "the two add to the level")
		local project = serde.decode("json", fs.readFile("default.project.json"))
		t.eq(project.tree.SoundService["$properties"].DopplerScale, 0, "no Doppler shift as the camera swings")
	end)

	t.test("weather sounds: the wind follows the wind, storms, height, the sky and roofs", function()
		local calm = WindSound.volume(0, 0, 0, 0, 1, 0)
		t.ok(calm > 0, "a breeze in calm air outdoors")
		t.ok(WindSound.volume(3, 0, 0, 0, 1, 0) > calm, "louder in a stronger wind")
		t.ok(WindSound.volume(1, 1, 0, 0, 1, 0) > WindSound.volume(1, 0, 0, 0, 1, 0), "louder in rain")
		t.ok(WindSound.volume(1, 0.5, 0.5, 0, 1, 0) >= WindSound.volume(1, 1, 0, 0, 1, 0), "thunder counts double")
		t.ok(WindSound.volume(1, 0, 0, 250, 1, 0) > WindSound.volume(1, 0, 0, 0, 1, 0), "louder high up")
		t.eq(WindSound.volume(3, 1, 1, 400, 0, 0), 0, "silent in a cave")
		t.ok(WindSound.volume(1, 0, 0, 0, 1, 1) < WindSound.volume(1, 0, 0, 0, 1, 0), "quieter under a roof")
		local wind = Config.Weather.Wind
		t.near(WindSound.volume(100, 1, 1, 10000, 1, 0), wind.Volume * wind.Max, 1e-9, "at most Max")
		local low, mid, high = WindSound.muffle(0)
		t.eq(low + mid + high, 0, "flat in the open")
		low, mid, high = WindSound.muffle(1)
		t.ok(high < mid and mid <= low, "duller under a roof")
	end)
end
