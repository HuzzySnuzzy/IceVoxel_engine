--[[
	The background music's rules (client Audio/MusicRules: Minecraft's MusicManager with the surface
	and caves as its situations) and Minecraft's cave mood (Audio/CaveMood, with the light it reads:
	CaveMood.blockLight and Rendering/SkyExposure.skyLight), on made-up worlds and timelines.
]]

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local MusicRules = require(client.Audio.MusicRules)
	local CaveMood = require(client.Audio.CaveMood)
	local SkyExposure = require(client.Rendering.SkyExposure)

	local SETTINGS = Config.Music
	local COUNTS = { surface = 12, cave = 2 }
	local STONE, AIR = Blocks.id.Stone, Blocks.AIR

	-- A random that rolls `value` every time.
	local function always(value: number): () -> number
		return function()
			return value
		end
	end

	-- Runs the rules for `seconds` at `exposure` in steps of `dt`; returns every action.
	local function run(state: any, seconds: number, exposure: number, random: (() -> number)?, dt: number?): { any }
		local step = dt or 0.1
		local actions = {}
		local elapsed = 0
		while elapsed < seconds - 1e-9 do
			for _, action in MusicRules.step(state, SETTINGS, step, exposure, COUNTS, random or always(0.5)) do
				table.insert(actions, action)
			end
			elapsed += step
		end
		return actions
	end

	--[[ Music ]]

	t.test("music: the first track about FirstDelay seconds after joining, of the place's kind", function()
		local state = MusicRules.new(SETTINGS, "surface")
		t.eq(#run(state, SETTINGS.FirstDelay - 0.2, 1), 0, "not before FirstDelay")
		local actions = run(state, 0.4, 1)
		t.eq(#actions, 1)
		t.eq(actions[1].kind, "play")
		t.eq(actions[1].place, "surface")
		t.eq(state.playing, "surface")
		t.eq(#run(state, 3600, 1), 0, "nothing else while it plays")
		-- Joining in a cave: a cave track.
		local cave = MusicRules.new(SETTINGS, MusicRules.placeOf(SETTINGS, 0))
		t.eq(cave.place, "cave")
		t.eq(run(cave, SETTINGS.FirstDelay + 0.2, 0)[1].place, "cave")
	end)

	t.test("music: Minecraft's 10 to 20 minutes between tracks, never the same twice in a row", function()
		local state = MusicRules.new(SETTINGS, "surface")
		run(state, SETTINGS.FirstDelay + 0.2, 1)
		local last = state.last.surface
		MusicRules.ended(state, SETTINGS, "finished", always(0))
		t.eq(state.wait, SETTINGS.MinDelay, "the shortest wait")
		MusicRules.ended(state, SETTINGS, "finished", always(0.999999))
		t.near(state.wait, SETTINGS.MaxDelay, 1e-3, "the longest")
		t.eq(SETTINGS.MinDelay, 600, "12000 ticks")
		t.eq(SETTINGS.MaxDelay, 1200, "24000 ticks")
		t.eq(state.playing, nil)
		local actions = run(state, SETTINGS.MaxDelay + 1, 1)
		t.eq(#actions, 1)
		t.ok(actions[1].track ~= last, "another track")
		-- Picks: any but the last and the failed; the last again only when nothing else is left.
		t.eq(MusicRules.pick(3, 2, {}, 0), 1)
		t.eq(MusicRules.pick(3, 2, {}, 0.99), 3)
		t.eq(MusicRules.pick(3, 2, { [1] = true }, 0), 3)
		t.eq(MusicRules.pick(1, 1, {}, 0.5), 1, "a single track repeats")
		t.eq(MusicRules.pick(2, 1, { [2] = true }, 0.5), 1, "the only one left")
		t.eq(MusicRules.pick(2, nil, { [1] = true, [2] = true }, 0.5), nil, "all failed")
		t.eq(MusicRules.pick(0, nil, {}, 0.5), nil, "none")
	end)

	t.test("music: underground the surface track fades out and a cave track follows", function()
		local state = MusicRules.new(SETTINGS, "surface")
		run(state, SETTINGS.FirstDelay + 0.2, 1)
		t.eq(state.playing, "surface")
		-- Into a cave: nothing for SwitchSeconds (a cave mouth doesn't flip it), then a fade.
		local actions = run(state, SETTINGS.SwitchSeconds - 0.2, 0.05)
		t.eq(#actions, 0, "not at once")
		t.eq(state.place, "surface")
		actions = run(state, 0.4, 0.05)
		t.eq(#actions, 1)
		t.eq(actions[1].kind, "fade")
		t.eq(state.place, "cave")
		t.ok(state.wait <= SETTINGS.SwitchDelay, "the cave track comes soon")
		-- Audio/Music fades it and reports back; the cave track starts within SwitchDelay.
		MusicRules.ended(state, SETTINGS, "faded", always(0.5))
		actions = run(state, SETTINGS.SwitchDelay + 0.2, 0.05)
		t.eq(#actions, 1)
		t.eq(actions[1].kind, "play")
		t.eq(actions[1].place, "cave")
		-- Back up: the cave track fades and a surface one follows.
		actions = run(state, SETTINGS.SwitchSeconds + 0.2, 1)
		t.eq(actions[1].kind, "fade")
		MusicRules.ended(state, SETTINGS, "faded", always(0.5))
		t.eq(run(state, SETTINGS.SwitchDelay + 0.2, 1)[1].place, "surface")
		-- Between the thresholds nothing changes, however long.
		local gap = (SETTINGS.CaveExposure + SETTINGS.SurfaceExposure) / 2
		t.eq(#run(state, 600, gap), 0)
		t.eq(state.place, "surface")
		-- A dip shorter than SwitchSeconds starts over.
		run(state, SETTINGS.SwitchSeconds - 1, 0)
		run(state, 0.2, 1)
		t.eq(#run(state, SETTINGS.SwitchSeconds - 1, 0), 0)
		t.eq(state.place, "surface")
	end)

	t.test("music: going underground while nothing plays brings a cave track soon", function()
		local state = MusicRules.new(SETTINGS, "surface")
		run(state, SETTINGS.FirstDelay + 0.2, 1)
		MusicRules.ended(state, SETTINGS, "finished", always(0.5))
		t.ok(state.wait > 600, "a long wait on the surface")
		local actions = run(state, SETTINGS.SwitchSeconds + SETTINGS.SwitchDelay + 0.5, 0)
		t.eq(#actions, 1)
		t.eq(actions[1].kind, "play")
		t.eq(actions[1].place, "cave")
	end)

	t.test("music: surface music never starts underground, nor cave music above it", function()
		-- A long random walk in and out of caves: every track starts in its own place, and a track
		-- of the wrong kind is always fading within SwitchSeconds + a step.
		local seed = 12345
		local function rand(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end
		local state = MusicRules.new(SETTINGS, "surface")
		local exposure = 1
		local wrongFor = 0
		for _ = 1, 200000 do
			if rand() < 0.002 then
				exposure = if exposure > 0.5 then 0 else 1
			end
			for _, action in MusicRules.step(state, SETTINGS, 0.1, exposure, COUNTS, rand) do
				if action.kind == "play" then
					t.eq(action.place, MusicRules.placeOf(SETTINGS, exposure), "starts where the player is")
				end
			end
			-- Audio/Music: fades take FadeSeconds, tracks last a few minutes.
			if state.playing and state.fading and rand() < 0.1 / SETTINGS.FadeSeconds then
				MusicRules.ended(state, SETTINGS, "faded", rand)
			elseif state.playing and not state.fading and rand() < 0.1 / 180 then
				MusicRules.ended(state, SETTINGS, "finished", rand)
			end
			if state.playing and state.playing ~= MusicRules.placeOf(SETTINGS, exposure) and not state.fading then
				wrongFor += 0.1
			else
				wrongFor = 0
			end
			t.ok(wrongFor <= SETTINGS.SwitchSeconds + 0.2, "a track of the wrong kind fades out")
		end
	end)

	t.test("music: a track that fails to load is skipped from then on", function()
		local state = MusicRules.new(SETTINGS, "cave")
		local first = run(state, SETTINGS.FirstDelay + 0.2, 0)[1]
		MusicRules.ended(state, SETTINGS, "failed", always(0.5), first.track)
		t.ok(state.failed.cave[first.track], "marked")
		t.ok(state.wait <= SETTINGS.SwitchDelay, "another soon")
		local second = run(state, SETTINGS.SwitchDelay + 0.2, 0)[1]
		t.ok(second.track ~= first.track)
		MusicRules.ended(state, SETTINGS, "failed", always(0.5), second.track)
		-- Both cave tracks failed: nothing plays, and it looks again after MinDelay.
		t.eq(#run(state, SETTINGS.SwitchDelay + 0.2, 0), 0)
		t.eq(state.playing, nil)
		t.ok(state.wait > SETTINGS.MinDelay - SETTINGS.SwitchDelay - 1, "a usual wait")
	end)

	--[[ Cave mood ]]

	-- A random nextInt that cycles through `values` (each in [0, n)).
	local function cycling(values: { number }): (n: number) -> number
		local i = 0
		return function(n: number): number
			i += 1
			return values[(i - 1) % #values + 1] % n
		end
	end

	t.test("cave mood: 1/6000 a tick in the dark, a sound after 6000 ticks, two blocks beyond", function()
		t.eq(CaveMood.TICK_DELAY, 6000)
		t.eq(CaveMood.SEARCH_EXTENT, 8)
		t.eq(CaveMood.SOUND_OFFSET, 2)
		local state = CaveMood.new()
		local function dark(_x: number, _y: number, _z: number): (number?, number)
			return 0, 0
		end
		-- Always the block 8 east, 0 up, 0 south of the eyes' block (nextInt 16, 8, 8).
		local nextInt = cycling({ 16, 8, 8 })
		local ticks = 0
		local x, y, z
		repeat
			ticks += 1
			x, y, z = CaveMood.tick(state, 0.5, 64.5, 0.5, dark, nextInt)
		until x or ticks > 7000
		t.ok(ticks >= 6000 and ticks <= 6001, `the mood filled after {ticks} ticks (five minutes)`)
		t.eq(state.mood, 0, "and starts over")
		-- The block's centre is 8 blocks east of the eyes: the sound 10 away.
		t.near(x :: number, 10.5, 1e-9)
		t.near(y :: number, 64.5, 1e-9)
		t.near(z :: number, 0.5, 1e-9)
	end)

	t.test("cave mood: daylight takes it back, a torch's light holds it, unloaded blocks count for nothing", function()
		local function light(sky: number?, block: number)
			return function(_x: number, _y: number, _z: number): (number?, number)
				return sky, block
			end
		end
		local nextInt = cycling({ 3, 11, 5 })
		local state = CaveMood.new()
		state.mood = 0.5
		CaveMood.tick(state, 0, 64, 0, light(15, 0), nextInt)
		t.near(state.mood, 0.499, 1e-12, "full sky light: 0.001 a tick")
		CaveMood.tick(state, 0, 64, 0, light(3, 0), nextInt)
		t.near(state.mood, 0.499 - 0.0002, 1e-12, "sky light 3: a fifth of that")
		local before = state.mood
		CaveMood.tick(state, 0, 64, 0, light(0, 1), nextInt)
		t.eq(state.mood, before, "block light 1: no change")
		CaveMood.tick(state, 0, 64, 0, light(0, 14), nextInt)
		t.near(state.mood, before - 13 / 6000, 1e-12, "a torch nearby")
		before = state.mood
		CaveMood.tick(state, 0, 64, 0, light(nil, 0), nextInt)
		t.eq(state.mood, before, "unloaded")
		state.mood = 0.0001
		CaveMood.tick(state, 0, 64, 0, light(15, 0), nextInt)
		t.eq(state.mood, 0, "never below 0")
		-- The picks reach 8 blocks each way from the eyes, floored like BlockPos.containing.
		local seen: { [number]: boolean } = {}
		local probe = CaveMood.new()
		local all = cycling({ 0, 0, 0, 16, 16, 16 })
		for _ = 1, 2 do
			CaveMood.tick(probe, 0.7, 64.2, -0.3, function(bx: number, by: number, bz: number): (number?, number)
				seen[bx] = true
				seen[by] = true
				seen[bz] = true
				return 15, 0
			end, all)
		end
		t.ok(seen[-8] and seen[8] and seen[56] and seen[72] and seen[-9] and seen[7], "floored offsets")
	end)

	t.test("cave mood: block light spreads one less a block through open cells, not through rock", function()
		local TORCH, GLOWSTONE = Blocks.id.Torch, Blocks.id.GlowBlock
		t.ok(Blocks.light(TORCH) > 0 and Blocks.light(GLOWSTONE) > 0, "light sources")
		-- A stone world with a 1 x 1 x 20 air tunnel along x at y = 64, z = 0.
		local placed: { [string]: number } = {}
		local function getBlock(x: number, y: number, z: number): number?
			local key = `{x},{y},{z}`
			if placed[key] then
				return placed[key]
			end
			return if y == 64 and z == 0 and x >= 0 and x < 20 then AIR else STONE
		end
		placed["0,64,0"] = TORCH
		local torch = Blocks.light(TORCH)
		t.eq(CaveMood.blockLight(getBlock, 0, 64, 0), torch, "at the torch")
		t.eq(CaveMood.blockLight(getBlock, 3, 64, 0), torch - 3, "three blocks along")
		t.eq(CaveMood.blockLight(getBlock, 19, 64, 0), math.max(torch - 19, 0), "far along")
		-- A parallel tunnel two blocks away through rock gets nothing from it.
		local function besides(x: number, y: number, z: number): number?
			if y == 64 and z == 2 and x >= 0 and x < 20 then
				return AIR
			end
			return getBlock(x, y, z)
		end
		t.eq(CaveMood.blockLight(besides, 1, 64, 2), 0, "light doesn't go through rock")
		t.eq(CaveMood.blockLight(getBlock, 5, 64, 1), 0, "rock is dark")
		-- An opaque light source lights the open cell next to it, and has its own light.
		placed["0,64,0"] = nil
		placed["10,65,0"] = GLOWSTONE
		local glow = Blocks.light(GLOWSTONE)
		t.eq(CaveMood.blockLight(getBlock, 10, 64, 0), glow - 1, "under glowstone")
		t.eq(CaveMood.blockLight(getBlock, 12, 64, 0), glow - 3)
		t.eq(CaveMood.blockLight(getBlock, 10, 65, 0), glow, "inside it")
		-- Unknown cells stop it.
		t.eq(
			CaveMood.blockLight(function()
				return nil
			end, 0, 0, 0),
			0
		)
	end)

	t.test("cave mood: sky light under the open sky, at a cave mouth and deep inside", function()
		-- Ground 64 everywhere (stone below), a tunnel 1 x 1 at y = 60 from a shaft at x = 0.
		local function ground(_x: number, _z: number): number
			return 64
		end
		local function getBlock(x: number, y: number, z: number): number?
			if x == 0 and z == 0 and y >= 60 then
				return AIR
			end
			if y == 60 and z == 0 and x >= 0 and x < 30 then
				return AIR
			end
			if x == 40 then
				return nil
			end
			return if y < 64 then STONE else AIR
		end
		t.eq(SkyExposure.skyLight(5, 70, 5, ground, getBlock), 15, "outdoors")
		t.eq(SkyExposure.skyLight(0, 60, 0, ground, getBlock), 15, "at the foot of the shaft")
		t.eq(SkyExposure.skyLight(3, 60, 0, ground, getBlock), 12, "three blocks into the tunnel")
		t.eq(SkyExposure.skyLight(20, 60, 0, ground, getBlock), 0, "deep in")
		t.eq(SkyExposure.skyLight(5, 50, 5, ground, getBlock), 0, "in the rock")
		t.eq(SkyExposure.skyLight(40, 70, 0, ground, getBlock), nil, "not loaded")
	end)
end
