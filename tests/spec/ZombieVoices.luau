--[[
	The zombies' groans (client Entities/ZombieVoices): at most one every 1.5 s however many
	zombies are near, only the nearest 8 within reach groan, each on its own period of 6 to 20 s
	from its id, and none beyond the reach. And their real voices (src/sounds/Zombies.model.json,
	SoundService.IceVoxelSounds): every zombie kind's hurt and death replaced by name, the kinds
	kept apart by pitch as the stand-ins were, with their variety, the stand-ins kept.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

return function(t, shared, require, _server, client)
	local ZombieVoices = require(client.Entities.ZombieVoices)
	local SoundRules = require(client.Audio.SoundRules)
	local Sounds = require(shared.Sounds)
	local MobList = require(shared.Entities.MobList)

	-- `n` zombies (ids 1..n) at `first`, `first + gap`... blocks, nearest first.
	local function crowd(n: number, first: number, gap: number): ({ number }, { number })
		local ids, distances = {}, {}
		for i = 1, n do
			ids[i] = i
			distances[i] = first + (i - 1) * gap
		end
		return ids, distances
	end

	-- Every groan over `seconds` at 60 frames a second: { time, id }.
	local function listen(
		voices: ZombieVoices.Voices,
		seconds: number,
		ids: { number },
		distances: { number },
		radius: number?
	): { { number } }
		local groans = {}
		for frame = 1, seconds * 60 do
			local now = frame / 60
			local id = ZombieVoices.step(voices, now, #ids, ids, distances, radius)
			if id then
				table.insert(groans, { now, id })
			end
		end
		return groans
	end

	t.test("zombie voices: at most one groan every 1.5 s with 60 zombies near", function()
		local ids, distances = crowd(60, 1, 0.3)
		local groans = listen(ZombieVoices.new(), 120, ids, distances)
		for i = 2, #groans do
			local gap = groans[i][1] - groans[i - 1][1]
			t.ok(gap >= ZombieVoices.GAP - 1e-9, `groans {gap} s apart`)
		end
		-- Eight zombies with 6-20 s periods are due often enough to fill most of the slots.
		t.ok(#groans <= 120 / ZombieVoices.GAP + 1, `no more than one a slot ({#groans})`)
		t.ok(#groans >= 30, `a crowd groans steadily ({#groans} in 2 minutes)`)
	end)

	t.test("zombie voices: only the nearest 8 within reach groan", function()
		local ids, distances = crowd(60, 2, 0.4)
		local groans = listen(ZombieVoices.new(), 300, ids, distances)
		local who = {}
		for _, groan in groans do
			who[groan[2]] = (who[groan[2]] or 0) + 1
		end
		for id in who do
			t.ok(id <= ZombieVoices.NEAREST, `only the nearest groan ({id})`)
		end
		local voices = 0
		for _ in who do
			voices += 1
		end
		t.eq(voices, ZombieVoices.NEAREST, "each of the nearest 8 has its say")
		-- Out of reach: none, and a shorter reach (the event's 16 blocks) is kept.
		local far = listen(ZombieVoices.new(), 120, { 1 }, { ZombieVoices.RADIUS + 1 })
		t.eq(#far, 0, "nothing beyond 24 blocks")
		local outside = listen(ZombieVoices.new(), 120, { 1 }, { 20 }, 16)
		t.eq(#outside, 0, "nothing beyond the reach given")
	end)

	t.test("zombie voices: each zombie groans on its own 6-20 s period, from its id", function()
		local periods = {}
		for id = 1, 500 do
			local period = ZombieVoices.period(id)
			t.ok(period >= 6 and period <= 20, `zombie {id}: {period} s`)
			t.eq(ZombieVoices.period(id), period, "the same on every client")
			periods[math.floor(period)] = true
		end
		local spread = 0
		for _ in periods do
			spread += 1
		end
		t.ok(spread >= 12, `periods spread over the range ({spread} whole seconds)`)
		-- One zombie alone: its groans are its period apart.
		local id = 77
		local groans = listen(ZombieVoices.new(), 200, { id }, { 5 })
		t.ok(#groans >= 8, `it groans ({#groans})`)
		for i = 2, #groans do
			t.near(groans[i][1] - groans[i - 1][1], ZombieVoices.period(id), 1 / 60 + 1e-9, "on its period")
		end
		-- Forgotten (gone), it starts over when heard again.
		local voices = ZombieVoices.new()
		ZombieVoices.step(voices, 1, 1, { id }, { 5 })
		t.ok(voices.due[id] ~= nil, "timed once heard")
		ZombieVoices.forget(voices, id)
		t.eq(voices.due[id], nil, "forgotten")
		t.ok(ZombieVoices.PITCH.brute < 1 and ZombieVoices.PITCH.lurch > 1, "a brute groans lower, a screamer higher")
	end)

	t.test("zombie voices: the shipped recordings voice every zombie kind, apart and varied", function()
		local model = serde.decode("json", fs.readFile("src/sounds/Zombies.model.json"))
		t.eq(model.ClassName, "Folder")
		local byName: { [string]: { any } } = {}
		for _, child in model.Children do
			t.eq(child.ClassName, "Sound")
			local event = Sounds.get(child.Name)
			t.ok(event ~= nil, `{child.Name} is an event`)
			t.ok(event == nil or event.category ~= child.Name, `{child.Name} names an event, not a category`)
			t.ok(string.match(child.Properties.SoundId, "^rbxassetid://%d+$") ~= nil, child.Properties.SoundId)
			t.ok(child.Properties.Volume > 0 and child.Properties.Volume <= 1, `{child.Name}: a sane volume`)
			byName[child.Name] = byName[child.Name] or {}
			table.insert(byName[child.Name], child.Properties)
		end
		-- Never a category's name: entity.mob.hurt and .death cover the cows, sheep, pigs and
		-- chickens too.
		for _, category in { "entity.mob.hurt", "entity.mob.death" } do
			t.eq(byName[category], nil, `nothing named {category}`)
		end
		-- The groans: three variants, picked at random (with the gait's pitch: ZombieVoices.PITCH).
		t.eq(#(byName["entity.zombie.ambient"] or {}), 3, "three groans")
		-- Every zombie kind's own hurt and death events have recordings: a growl when hurt, the two
		-- deaths when it dies.
		local speeds: { [string]: number } = {}
		local kinds = 0
		for _, kind in MobList.kinds do
			if MobList.isZombie(kind) then
				kinds += 1
				for _, name in { kind.sounds.hurt, kind.sounds.death } do
					local shipped = byName[name]
					t.ok(shipped ~= nil, `{kind.name}: {name} has a recording`)
					t.eq(#(shipped or {}), if name == kind.sounds.hurt then 1 else 2, `{name}: its variants`)
					for _, props in shipped or {} do
						local speed = props.PlaybackSpeed or 1
						t.eq(speeds[name] or speed, speed, `{name}: one pitch for its variants`)
						speeds[name] = speed
					end
				end
			end
		end
		t.eq(kinds, 10, "the ten zombie kinds")
		-- The kinds apart, in the stand-ins' order: the brute lowest, then the zombie, the runner a
		-- little higher, the screamer higher. A replacement plays at its PlaybackSpeed varied by
		-- the event's variance as a share of its pitch (SoundRules.playback). As with the
		-- stand-ins, the spreads never overlap: the highest growl of one kind is still below the
		-- lowest of the next (and each kind still varies).
		local SETTINGS = { Volume = 1, Sources = {} }
		local ORDER = { "zombie_brute", "zombie", "zombie_runner", "zombie_screamer" }
		for _, action in { "hurt", "death" } do
			local lows, highs, mids = {}, {}, {}
			for i, kind in ORDER do
				local name = `entity.{kind}.{action}`
				local event = Sounds.get(name) :: any
				local override = { id = "rbxassetid://1", volume = 1, speed = speeds[name] }
				lows[i] = SoundRules.playback(event, override, nil, 1, 1, 0, SETTINGS).pitch
				mids[i] = SoundRules.playback(event, override, nil, 1, 1, 0.5, SETTINGS).pitch
				highs[i] = SoundRules.playback(event, override, nil, 1, 1, 0.999999, SETTINGS).pitch
				t.near(mids[i], speeds[name], 1e-9, `{name}: its own speed in the middle`)
				t.ok(highs[i] - lows[i] > 0.04, `{name} varies ({lows[i]} to {highs[i]})`)
				-- The stand-in the recording replaces stays the event's own sound.
				t.ok(string.find(event.id, "^rbxasset://sounds/") ~= nil, `{name}: its stand-in stays`)
			end
			for i = 2, #ORDER do
				t.ok(mids[i] > mids[i - 1], `{ORDER[i]} {action} above {ORDER[i - 1]}`)
				t.ok(mids[i] > highs[i - 1], `{ORDER[i]} {action} beyond {ORDER[i - 1]}'s spread`)
				t.ok(mids[i - 1] < lows[i], `{ORDER[i - 1]} {action} below {ORDER[i]}'s spread`)
				t.ok(lows[i] > highs[i - 1], `{ORDER[i]} {action} never overlaps {ORDER[i - 1]}`)
			end
		end
		t.eq(speeds["entity.zombie.hurt"], 1, "the zombie's voice as recorded")
	end)
end
