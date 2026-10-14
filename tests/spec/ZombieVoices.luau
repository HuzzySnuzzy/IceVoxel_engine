--[[
	The zombies' groans (client Entities/ZombieVoices): at most one every 1.5 s however many
	zombies are near, only the nearest 8 within reach groan, each on its own period of 6 to 20 s
	from its id, and none beyond the reach.
]]

return function(t, _shared, require, _server, client)
	local ZombieVoices = require(client.Entities.ZombieVoices)

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
end
