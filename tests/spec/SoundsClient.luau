--[[
	The client's sounds (Audio/SoundRules): how an event plays (volumes, pitch, fallbacks,
	developer overrides, hearing range), the voice pool and its caps, Minecraft's footsteps,
	swimming and splashes, other characters' ground and water, the mining hit cadence and the cave
	delay; and that the client plays every event it has to, and none of the server's.
]]

local fs = require("@lune/fs")

return function(t, shared, require, _server, client)
	local Blocks = require(shared.Blocks)
	local Sounds = require(shared.Sounds)
	local SoundRules = require(client.Audio.SoundRules)

	local B = Blocks.id
	local SETTINGS = { Volume = 1, Sources = { blocks = 1, players = 1, ambient = 1, ui = 1 } }

	local function event(name: string)
		local found = Sounds.get(name)
		assert(found, `no event {name}`)
		return found
	end

	--[[ Playback ]]

	t.test("sounds client: an event plays its file at its volume and pitch, cut at its duration", function()
		local step = event("block.stone.step")
		local playback = SoundRules.playback(step, nil, nil, 1, 1, 0.5, SETTINGS)
		t.eq(playback.id, step.id, "file")
		t.near(playback.volume, step.volume, 1e-9, "volume")
		-- A roll of 0.5 is the middle of the variance.
		t.near(playback.pitch, step.pitch, 1e-9, "pitch")
		t.eq(playback.duration, step.duration, "duration")
		t.near(playback.length, step.duration / step.pitch, 1e-9, "real length")
		t.eq(playback.range, Sounds.DEFAULT_DISTANCE, "heard 16 blocks away")
		-- The variance either way.
		t.near(
			SoundRules.playback(step, nil, nil, 1, 1, 0, SETTINGS).pitch,
			step.pitch - step.pitchVariance,
			1e-9,
			"low"
		)
		t.near(
			SoundRules.playback(step, nil, nil, 1, 1, 0.999999, SETTINGS).pitch,
			step.pitch + step.pitchVariance,
			1e-5,
			"high"
		)
		-- Files played whole have no length.
		local pickup = SoundRules.playback(event("entity.item.pickup"), nil, nil, 1, 1, 0.5, SETTINGS)
		t.eq(pickup.duration, nil, "whole file")
		t.eq(pickup.length, nil, "no cut")
	end)

	t.test("sounds client: cue and settings volumes multiply, louder cues carry further", function()
		local hurt = event("entity.player.hurt")
		local settings = { Volume = 0.5, Sources = { blocks = 1, players = 0.4, ambient = 1, ui = 1 } }
		local playback = SoundRules.playback(hurt, nil, nil, 2, 1.5, 0.5, settings)
		t.near(playback.volume, hurt.volume * 2 * 0.5 * 0.4, 1e-9, "event x cue x master x source")
		t.near(playback.pitch, hurt.pitch * 1.5, 1e-9, "cue pitch")
		t.eq(playback.range, hurt.maxDistance * 2, "a cue at 2 is heard twice as far")
		t.eq(SoundRules.playback(hurt, nil, nil, 0.5, 1, 0.5, settings).range, hurt.maxDistance, "quieter: no less")
		-- Sources not in the settings count as 1; Roblox's volume tops out at 10, the pitch never
		-- reaches 0.
		local loud = SoundRules.playback(hurt, nil, nil, 2.55, 0, 0.5, { Volume = 100, Sources = {} })
		t.eq(loud.volume, SoundRules.MAX_VOLUME, "volume clamped")
		t.eq(loud.pitch, SoundRules.MIN_PITCH, "pitch floor")
		t.eq(SoundRules.playback(hurt, nil, nil, 1, 1, 0.5, { Volume = 0, Sources = {} }).volume, 0, "muted")
	end)

	t.test("sounds client: a file that failed to load plays the event's fallback", function()
		local glass = event("block.glass.break")
		local fallback = glass.fallback
		t.ok(fallback, "glass break has a fallback")
		assert(fallback)
		local normal = SoundRules.playback(glass, nil, { [fallback.id] = true }, 1, 1, 0.5, SETTINGS)
		t.eq(normal.id, glass.id, "only its own file's failure counts")
		local played = SoundRules.playback(glass, nil, { [glass.id] = true }, 1, 1, 0.5, SETTINGS)
		t.eq(played.id, fallback.id, "fallback file")
		t.near(played.volume, fallback.volume, 1e-9, "fallback volume (final)")
		t.near(played.pitch, fallback.pitch, 1e-9, "fallback pitch (final)")
		t.eq(played.duration, fallback.duration, "fallback duration")
		-- Varied by the same share as the event's own pitch.
		local low = SoundRules.playback(glass, nil, { [glass.id] = true }, 1, 1, 0, SETTINGS)
		t.near(low.pitch, fallback.pitch * (1 - glass.pitchVariance / glass.pitch), 1e-9, "relative variance")
		-- Events without a fallback keep their file.
		local hurt = event("entity.player.hurt")
		t.eq(SoundRules.playback(hurt, nil, { [hurt.id] = true }, 1, 1, 0.5, SETTINGS).id, hurt.id, "no fallback")
	end)

	t.test("sounds client: the listener is the camera, at most a few blocks from the eyes", function()
		local reach = SoundRules.LISTENER_REACH
		-- First person and Minecraft's third person: the camera itself.
		local x, y, z = SoundRules.listenerAt(10, 65.6, 20, 10, 65.6, 20, reach)
		t.ok(x == 10 and y == 65.6 and z == 20, "first person")
		x, y, z = SoundRules.listenerAt(10, 65.6, 24, 10, 65.6, 20, reach)
		t.ok(x == 10 and y == 65.6 and z == 24, "within reach")
		-- Zoomed far out (Roblox's 128 studs): pulled in along the same line.
		x, y, z = SoundRules.listenerAt(10 + 30, 65.6 + 40, 20, 10, 65.6, 20, reach)
		t.near(x, 10 + reach * 0.6, 1e-9, "x on the line")
		t.near(y, 65.6 + reach * 0.8, 1e-9, "y on the line")
		t.near(z, 20, 1e-9, "z on the line")
		local d = math.sqrt((x - 10) ^ 2 + (y - 65.6) ^ 2 + (z - 20) ^ 2)
		t.near(d, reach, 1e-9, "at the reach")
		-- The server sends sounds to players whose feet are within hearing plus BroadcastSlack:
		-- that covers a listener at the eyes (under 2 blocks up) plus the reach.
		local Config = require(shared.Config)
		t.ok(reach + 2 <= Config.Sounds.BroadcastSlack, "within the server's broadcast slack")
	end)

	t.test("sounds client: a file fails only when its Sound never loads", function()
		-- Loaded, or reported loaded: never failed, never waited for.
		for _, report in { "ok", "failed", "none" } do
			local reported = if report == "none" then nil else report
			t.ok(not SoundRules.loadFailed(true, reported :: any), `a loaded Sound counts ({report})`)
			t.ok(not SoundRules.loadPending(true, reported :: any, 0), `nothing to wait for ({report})`)
		end
		t.ok(not SoundRules.loadFailed(false, "ok"), "reported loaded")
		t.ok(not SoundRules.loadPending(false, "ok", 0), "reported loaded: no wait")
		-- Not loaded: waited for, a reported failure only briefly (local files may load anyway).
		t.ok(SoundRules.loadPending(false, nil, SoundRules.LOAD_TIMEOUT - 0.1), "silent: waited for")
		t.ok(not SoundRules.loadPending(false, nil, SoundRules.LOAD_TIMEOUT), "silent: until the timeout")
		t.ok(SoundRules.loadPending(false, "failed", 0), "reported failed: a grace")
		t.ok(not SoundRules.loadPending(false, "failed", SoundRules.FAILED_GRACE), "then given up")
		t.ok(SoundRules.FAILED_GRACE < SoundRules.LOAD_TIMEOUT, "the grace is shorter")
		t.ok(SoundRules.loadFailed(false, nil), "never loaded: failed")
		t.ok(SoundRules.loadFailed(false, "failed"), "reported failed and never loaded: failed")
	end)

	t.test("sounds client: a developer's Sound plays with its own volume and speed, whole", function()
		local hit = event("block.wood.hit")
		local override = { id = "rbxassetid://123", volume = 0.9, speed = 1.2 }
		local playback = SoundRules.playback(hit, override, { [hit.id] = true }, 1, 1, 0.5, SETTINGS)
		t.eq(playback.id, "rbxassetid://123", "its file, even when the built-in failed")
		t.near(playback.volume, 0.9, 1e-9, "its volume")
		t.near(playback.pitch, 1.2, 1e-9, "its speed")
		t.eq(playback.duration, nil, "played whole")
		t.eq(playback.length, nil, "never cut")
		t.eq(playback.range, hit.maxDistance, "heard as far as the event")
		local low = SoundRules.playback(hit, override, nil, 1, 1, 0, SETTINGS)
		t.near(low.pitch, 1.2 * (1 - hit.pitchVariance / hit.pitch), 1e-9, "varied like the event")
		local scaled = SoundRules.playback(hit, override, nil, 0.5, 2, 0.5, { Volume = 0.5, Sources = {} })
		t.near(scaled.volume, 0.9 * 0.5 * 0.5, 1e-9, "times the cue and settings")
		t.near(scaled.pitch, 2.4, 1e-9, "times the cue's pitch")
	end)

	t.test("sounds client: overrides by event name first, then category, variants at random", function()
		local index = {
			["block.break"] = { "category" },
			["block.stone.break"] = { "a", "b", "c" },
		}
		local stone = Sounds.lookupNames("block.stone.break")
		t.eq(SoundRules.chooseOverride(index, stone, 0), "a", "first variant")
		t.eq(SoundRules.chooseOverride(index, stone, 0.5), "b", "middle variant")
		t.eq(SoundRules.chooseOverride(index, stone, 0.999999), "c", "last variant")
		t.eq(SoundRules.chooseOverride(index, Sounds.lookupNames("block.wood.break"), 0.3), "category", "category")
		t.eq(SoundRules.chooseOverride(index, Sounds.lookupNames("block.wood.place"), 0.3), nil, "none")
		t.eq(SoundRules.chooseOverride({ ["block.stone.break"] = {} }, stone, 0.3), nil, "empty list")
		local armor = Sounds.lookupNames("item.armor.equip_iron")
		t.eq(SoundRules.chooseOverride({ ["item.armor.equip"] = { "any" } }, armor, 0.3), "any", "armor category")
	end)

	--[[ Voices ]]

	t.test("sounds client: voices are reused, kinds capped, the oldest taken when full", function()
		local pool = SoundRules.newPool(4)
		t.eq(SoundRules.acquire(pool, "block.break", 8, 1), 1, "first free")
		t.eq(SoundRules.acquire(pool, "block.hit", 2, 2), 2, "second free")
		t.eq(SoundRules.acquire(pool, "block.hit", 2, 3), 3, "third free")
		-- A third hit at once takes the oldest hit, not a free voice.
		t.eq(SoundRules.acquire(pool, "block.hit", 2, 4), 2, "capped: oldest hit")
		t.eq(SoundRules.playing(pool, "block.hit"), 2, "still two hits")
		t.eq(SoundRules.acquire(pool, "block.place", 8, 5), 4, "last free")
		-- Full: the oldest of all (the break at 1).
		t.eq(SoundRules.acquire(pool, "ui.button.click", 8, 6), 1, "oldest overall")
		SoundRules.release(pool, 3)
		t.eq(SoundRules.acquire(pool, "block.step", 6, 7), 3, "a released voice is free")
		-- Caps by kind: hits overlap little, footsteps more, the rest a lot.
		t.eq(SoundRules.voiceKey(event("block.stone.hit")), "block.hit", "category key")
		t.eq(SoundRules.voiceKey(event("entity.player.hurt")), "entity.player.hurt", "name key")
		t.eq(SoundRules.capOf("block.hit"), 3, "hits")
		t.eq(SoundRules.capOf("entity.player.hurt"), SoundRules.DEFAULT_CAP, "default")
	end)

	--[[ Footsteps, swimming, splashes ]]

	local function walking(below: number?, overrides: { [string]: any }?)
		local motion = {
			dx = 0.2,
			dy = 0,
			dz = 0,
			ticks = 1,
			onGround = true,
			inWater = false,
			swimming = false,
			silent = false,
			below = below,
		}
		for key, value in overrides or {} do
			(motion :: any)[key] = value
		end
		return motion
	end

	t.test("sounds client: a footstep every 1.67 blocks walked, on the block underfoot", function()
		local walker = SoundRules.newWalker()
		local steps = {}
		-- 49 ticks at 0.2 blocks: 9.8 blocks.
		for tick = 1, 49 do
			local step = SoundRules.move(walker, walking(B.Stone))
			if step then
				t.eq(step, B.Stone, "the block underfoot")
				table.insert(steps, tick)
			end
		end
		-- Steps when 0.6 x distance passes 1, 2, 3...: after 1.67, 3.33, 5, 6.67, 8.33 blocks.
		t.eq(#steps, 5, "five steps in 9.8 blocks")
		t.eq(steps[1], 9, "first after 1.8 blocks (0.6 x 1.8 > 1)")
		t.eq(steps[2], 17, "then every 1.67")
		-- Diagonal movement counts its length.
		local diagonal = SoundRules.newWalker()
		local count = 0
		for _ = 1, 50 do
			if SoundRules.move(diagonal, walking(B.Stone, { dx = 0.2, dz = 0.2 })) then
				count += 1
			end
		end
		t.eq(count, 8, "14 blocks diagonally")
		-- Vertical movement is not walking.
		local climbing = SoundRules.newWalker()
		for _ = 1, 50 do
			t.eq(SoundRules.move(climbing, walking(B.Stone, { dx = 0, dy = 0.5 })), nil, "no steps")
		end
	end)

	t.test("sounds client: no steps sneaking, flying, on fluids or nothing; landing steps at once", function()
		for _, motion in
			{
				walking(B.Stone, { silent = true }),
				walking(Blocks.fluidId("Water", 0)),
				walking(B.Air),
				walking(nil),
			}
		do
			local walker = SoundRules.newWalker()
			for _ = 1, 50 do
				t.eq(SoundRules.move(walker, motion), nil, "silent")
			end
		end
		-- Jumping along: no steps in the air, the one due plays on landing.
		local walker = SoundRules.newWalker()
		for _ = 1, 20 do
			t.eq(SoundRules.move(walker, walking(B.Stone, { onGround = false })), nil, "in the air")
		end
		t.eq(SoundRules.move(walker, walking(B.Grass)), B.Grass, "landing")
		t.eq(SoundRules.move(walker, walking(B.Grass)), nil, "then the next 1.67 blocks on")
		-- Sneaking does not count the distance either (Minecraft adds none without sound).
		local sneaker = SoundRules.newWalker()
		for _ = 1, 50 do
			SoundRules.move(sneaker, walking(B.Stone, { silent = true }))
		end
		t.eq(sneaker.moveDist, 0, "no distance")
	end)

	t.test("sounds client: swimming sounds in water, splashes falling in", function()
		local water = Blocks.fluidId("Water", 0)
		local swimmer = SoundRules.newWalker()
		local swims = 0
		for _ = 1, 49 do
			local step, swim, splash =
				SoundRules.move(swimmer, walking(water, { onGround = false, inWater = true, swimming = true }))
			t.eq(step, nil, "no steps swimming")
			t.eq(splash, nil, "no splash: in water from the first tick")
			if swim then
				swims += 1
				t.ok(swim >= SoundRules.SWIM_MIN and swim <= SoundRules.SWIM_MAX, `swim volume {swim}`)
			end
		end
		t.eq(swims, 5, "a swim sound every 1.67 blocks")
		-- Walking on the bottom in water: footsteps.
		local wader = SoundRules.newWalker()
		local steps = 0
		for _ = 1, 49 do
			if SoundRules.move(wader, walking(B.Sand, { inWater = true })) then
				steps += 1
			end
		end
		t.eq(steps, 5, "steps on the bottom")
		-- Falling in splashes once, faster louder.
		local function splashAt(vy: number): number?
			local diver = SoundRules.newWalker()
			SoundRules.move(diver, walking(B.Air, { onGround = false, dx = 0, dy = vy }))
			local _, _, splash =
				SoundRules.move(diver, walking(water, { onGround = false, inWater = true, dx = 0, dy = vy }))
			local _, _, again =
				SoundRules.move(diver, walking(water, { onGround = false, inWater = true, dx = 0, dy = vy }))
			t.eq(again, nil, "once")
			return splash
		end
		local slow, fast = splashAt(-0.1), splashAt(-1.5)
		t.ok(slow and fast, "splashes")
		assert(slow and fast)
		t.ok(fast > slow, "a high fall is louder")
		t.eq(slow, SoundRules.SPLASH_MIN, "a gentle entry is quiet")
		t.eq(fast, SoundRules.SPLASH_MAX, "capped")
		-- Speeds per tick: the same movement over two ticks is half as fast.
		local twoTicks = SoundRules.splashVolume(walking(water, { dx = 0, dy = -0.8, ticks = 2 }))
		t.near(twoTicks, SoundRules.splashVolume(walking(water, { dx = 0, dy = -0.4 })), 1e-9, "per tick")
	end)

	t.test("sounds client: other characters' ground and water from their feet", function()
		local water = Blocks.fluidId("Water", 0)
		local blocks = {
			["0,63,0"] = B.Stone,
			["1,63,5"] = B.Stone,
			["0,62,10"] = B.Sand,
			["0,63,10"] = water,
			["0,64,10"] = water,
		}
		local function getBlock(x: number, y: number, z: number): number?
			return blocks[`{x},{y},{z}`] or B.Air
		end
		local onGround, inWater, below = SoundRules.observe(getBlock, 0.5, 64, 0.5)
		t.ok(onGround and not inWater, "standing on stone")
		t.eq(below, B.Stone, "stone underfoot")
		onGround = SoundRules.observe(getBlock, 0.5, 64.5, 0.5)
		t.ok(not onGround, "half a block up: in the air")
		onGround = SoundRules.observe(getBlock, 0.5, 64.05, 0.5)
		t.ok(onGround, "within the tolerance")
		-- At an edge: the feet over air, the hull over the stone next to it.
		onGround, _, below = SoundRules.observe(getBlock, 0.8, 64, 5.5)
		t.ok(onGround, "standing at the edge")
		t.eq(below, B.Stone, "the block stood on")
		onGround, inWater, below = SoundRules.observe(getBlock, 0.5, 64.3, 10.5)
		t.ok(not onGround and inWater, "swimming")
		t.eq(below, water, "water underfoot")
		onGround, inWater, below = SoundRules.observe(getBlock, 0.5, 63, 10.5)
		t.ok(onGround and inWater, "walking on the bottom")
		t.eq(below, B.Sand, "sand underfoot")
	end)

	t.test("sounds client: climbing steps on the ladder every 1.67 blocks climbed, off the ground", function()
		-- Minecraft's climb: 0.1176 blocks a tick straight up, the ladder under the feet.
		local function climbing(below: number?, overrides: { [string]: any }?)
			local motion = walking(below, { dx = 0, dy = 0.1176, onGround = false, climbing = true })
			for key, value in overrides or {} do
				(motion :: any)[key] = value
			end
			return motion
		end
		local walker = SoundRules.newWalker()
		local steps = {}
		for tick = 1, 60 do
			local step = SoundRules.move(walker, climbing(B.Ladder))
			if step then
				t.eq(step, B.Ladder, "the ladder's own step")
				table.insert(steps, tick)
			end
		end
		-- 0.6 x 0.1176 a tick passes 1, 2, 3, 4 at ticks 15, 29, 43, 57: every 1.67 blocks.
		t.eq(#steps, 4, "four steps in 7 blocks")
		t.eq(steps[1], 15, "first after 1.76 blocks")
		t.eq(steps[2], 29, "then every 14.2 ticks")
		t.eq(Sounds.block(B.Ladder, "step"), event("block.ladder.step").index, "a ladder sounds like one")
		t.eq(Sounds.block(B.Rope, "step"), event("block.rope.step").index, "rope like rope")
		t.eq(Sounds.block(B.CaveVineNorth, "step"), event("block.vine.step").index, "vines like vines")
		-- Sliding down counts the same.
		local slider = SoundRules.newWalker()
		local slides = 0
		for _ = 1, 60 do
			if SoundRules.move(slider, climbing(B.Vine, { dy = -0.15 })) then
				slides += 1
			end
		end
		t.eq(slides, 5, "0.6 x 0.15 x 60 = 5.4")
		-- Over the floor under the bottom rung the step passes silently, and is not owed.
		local bottom = SoundRules.newWalker()
		for _ = 1, 14 do
			SoundRules.move(bottom, climbing(B.Ladder))
		end
		t.eq(SoundRules.move(bottom, climbing(B.Stone)), nil, "no stone step in the air")
		t.eq(bottom.nextStep, 2, "the step was taken")
		-- Without `climbing`, vertical movement in the air stays silent (the old rule).
		local air = SoundRules.newWalker()
		for _ = 1, 60 do
			t.eq(SoundRules.move(air, climbing(B.Ladder, { climbing = false })), nil, "not climbing")
		end
		-- Flying is silent; sneaking on a ladder is not (the controller only silences it on the ground).
		local flyer = SoundRules.newWalker()
		for _ = 1, 60 do
			t.eq(SoundRules.move(flyer, climbing(B.Ladder, { silent = true })), nil, "flying")
		end
		-- Another character's feet in a ladder cell, off the ground: climbing.
		local blocks = { ["0,63,0"] = B.Stone, ["0,64,0"] = B.Ladder, ["0,65,0"] = B.Ladder }
		local function getBlock(x: number, y: number, z: number): number?
			return blocks[`{x},{y},{z}`] or B.Air
		end
		local onGround, _, below, isClimbing = SoundRules.observe(getBlock, 0.5, 65.4, 0.5)
		t.ok(not onGround and isClimbing, "climbing")
		t.eq(below, B.Ladder, "on the ladder")
		local standing, _, _, climbsStanding = SoundRules.observe(getBlock, 0.5, 64, 0.5)
		t.ok(standing and not climbsStanding, "standing at its foot is walking")
	end)

	--[[ Mining hits, ambience ]]

	t.test("sounds client: mining hits every 4 ticks on one block, from its first", function()
		local clock = SoundRules.newHitClock()
		local due = {}
		for tick = 1, 12 do
			if SoundRules.hitTick(clock, 1, 2, 3, B.Stone) then
				table.insert(due, tick)
			end
		end
		t.eq(table.concat(due, ","), "1,5,9", "every 4 ticks")
		t.ok(SoundRules.hitTick(clock, 1, 2, 4, B.Stone), "another block starts over")
		t.ok(not SoundRules.hitTick(clock, 1, 2, 4, B.Stone), "then waits")
		t.ok(SoundRules.hitTick(clock, 1, 2, 4, B.Dirt), "the block changed: starts over")
		SoundRules.resetHits(clock)
		t.ok(SoundRules.hitTick(clock, 1, 2, 4, B.Dirt), "after a reset")
	end)

	t.test("sounds client: furnaces crackle every few seconds", function()
		local seconds = 1 / (SoundRules.CRACKLE_CHANCE * 20)
		t.ok(seconds > 2 and seconds < 8, `a crackle every {seconds} s`)
	end)

	--[[ Coverage ]]

	-- Every client source file, joined.
	local function clientSource(): string
		local parts = {}
		local function scan(dir: string)
			for _, entry in fs.readDir(dir) do
				local path = `{dir}/{entry}`
				if fs.isDir(path) then
					scan(path)
				elseif string.sub(entry, -5) == ".luau" then
					table.insert(parts, fs.readFile(path))
				end
			end
		end
		scan("src/client")
		return table.concat(parts, "\n")
	end

	t.test("sounds client: the client plays every event it must, and never the server's", function()
		local source = clientSource()
		local function uses(pattern: string): boolean
			return string.find(source, pattern) ~= nil
		end
		-- Terraria's sounds whose players are still being built (the cast and mana full: the mana
		-- HUD and magic). Each comes off this list with the code that plays it (the double jump
		-- did with Player/EquipmentLooks.airJump).
		local pending: { [string]: boolean } = {
			["item.magic.cast"] = true,
			["entity.player.mana_full"] = true,
		}
		for _, sound in Sounds.events do
			local quoted = `"{sound.name}"`
			if pending[sound.name] then
				t.ok(not string.find(source, quoted, 1, true), `{sound.name} is played now: take it off the list`)
			elseif sound.side == "server" then
				t.ok(not string.find(source, quoted, 1, true), `{sound.name} is the server's to play`)
			elseif sound.category and string.sub(sound.category, 1, 6) == "block." then
				-- Block events go by action: playBlock(block, "hit", ...) / Sounds.block(block, "step").
				local action = string.sub(sound.category, 7)
				t.ok(
					uses(`playBlock%([^)]*"{action}"`) or uses(`Sounds%.block%([^)]*"{action}"`),
					`the client plays block {action} sounds`
				)
			elseif sound.name == "entity.player.small_fall" or sound.name == "entity.player.big_fall" then
				t.ok(uses("Sounds%.fall%("), "the client plays its hurting landings")
			elseif sound.category == "ambient.cave" then
				-- (The cave moods are picked from Sounds.MOODS.)
				t.ok(uses("Sounds%.MOODS"), "the client plays the cave moods")
			else
				t.ok(string.find(source, quoted, 1, true), `the client plays {sound.name}`)
			end
		end
		-- Server messages are routed to the player.
		t.ok(uses("ServerMessage%.Sound"), "Sound messages are handled")
	end)
end
