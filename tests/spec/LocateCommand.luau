--[[
	/locate and /tp as the server runs them (Players/LocateCommand, Players/TeleportCommand):
	usage, who may, Minecraft's texts exactly (success, not found, unknown ids and tags), "~"
	against a y per kind, floored distances, the coordinates' link (its bytes, the "/tp @s x y z"
	it suggests) through the Notice message (and an old notice decoding as before), the
	arguments the chat completes, the searches' queue (never more than its budget plus one probe a
	frame, one job per player, full, cancelled, timed out, failing), a whole search on a real
	generator; /tp's coordinates ("~", "~n", block centres), targets, permission, limits, landing
	rule and texts.
]]

return function(t, shared, require, server)
	local Config = require(shared.Config)
	local Protocol = require(shared.Net.Protocol)
	local Locate = require(shared.Generation.Locate)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local GameMode = require(shared.GameMode)
	local LocateCommand = require(server.Players.LocateCommand)
	local TeleportCommand = require(server.Players.TeleportCommand)
	local WorldServer = require(server.World.WorldServer)

	local registries = LocateCommand.registries({ "outpost" })
	local function context(mayUse: boolean?)
		return { mayUse = mayUse ~= false, registries = registries }
	end

	--[[ Parsing and permission ]]

	t.test("locate command: usage, permission, unknown ids and tags (Minecraft's texts)", function()
		t.eq(LocateCommand.run("hello", context()), nil, "ordinary chat")
		t.ok(LocateCommand.matches("  /LOCATE structure x"))
		t.ok(not LocateCommand.matches("/locates"))
		local function says(text: string, mayUse: boolean?): string
			local result = LocateCommand.run(text, context(mayUse)) :: any
			t.eq(result.request, nil, text)
			return result.feedback[1]
		end
		t.eq(says("/locate"), LocateCommand.USAGE)
		t.eq(says("/locate village plains"), LocateCommand.USAGE)
		t.eq(says("/locate structure"), LocateCommand.USAGE)
		t.eq(says("/locate structure outpost extra"), LocateCommand.USAGE)
		t.eq(says("/locate structure outpost", false), LocateCommand.DENIED)
		t.eq(says("/locate structure village"), 'There is no structure with type "village"')
		t.eq(says("/locate structure #village"), 'There is no structure with type "#village"')
		t.eq(says("/locate biome ocean"), "Can't find element 'ocean' of type 'minecraft:worldgen/biome'")
		t.eq(says("/locate biome #ocean"), "Can't find tag 'ocean' of type 'minecraft:worldgen/biome'")
		t.eq(says("/locate poi bed"), "Can't find element 'bed' of type 'minecraft:point_of_interest_type'")
		t.eq(says("/locate poi #village"), "Can't find tag 'village' of type 'minecraft:point_of_interest_type'")
		local ok = LocateCommand.run("/locate Structure minecraft:Outpost", context()) :: any
		t.eq(#ok.feedback, 0)
		t.eq(ok.request.type, "structure")
		t.eq(ok.request.resolved.label, "outpost")
		local poi = LocateCommand.run("/locate poi #machine", context()) :: any
		t.ok(table.find(poi.request.resolved.members, "electric_furnace") ~= nil, "the machine tag")
		t.ok(table.find(poi.request.resolved.members, "battery") ~= nil)
		t.ok(table.find(poi.request.resolved.members, "chest") == nil)
	end)

	--[[ Answers ]]

	t.test("locate command: answers, y per kind, floored distance, the link", function()
		local request = (LocateCommand.run("/locate structure outpost", context()) :: any).request
		local found: Locate.Found = { id = "outpost", x = 1142, y = 0, z = 582, showY = false, distance = 1281.9 }
		local text, link = LocateCommand.success(request, found)
		t.eq(text, "The nearest outpost is at [1142, ~, 582] (1281 blocks away)")
		t.eq(string.sub(text, link.first, link.last), "[1142, ~, 582]", "the link covers the coordinates")
		t.eq(link.suggest, "/tp @s 1142 ~ 582")
		local tag = (LocateCommand.run("/locate structure #mineshaft", context()) :: any).request
		local under: Locate.Found =
			{ id = "mineshaft_overgrown", x = -46, y = 27, z = -13, showY = true, distance = 47.99 }
		local tagText, tagLink = LocateCommand.success(tag, under)
		t.eq(tagText, "The nearest #mineshaft (mineshaft_overgrown) is at [-46, 27, -13] (47 blocks away)")
		t.eq(tagLink.suggest, "/tp @s -46 27 -13")
		t.eq(string.sub(tagText, tagLink.first, tagLink.last), "[-46, 27, -13]")
		t.eq(
			LocateCommand.notFound(request),
			'Could not find a structure of type "outpost" nearby',
			"structure not found"
		)
		local biome = (LocateCommand.run("/locate biome #forest", context()) :: any).request
		t.eq(LocateCommand.notFound(biome), 'Could not find a biome of type "#is_forest" within reasonable distance')
		local poi = (LocateCommand.run("/locate poi chest", context()) :: any).request
		t.eq(
			LocateCommand.notFound(poi),
			'Could not find a point of interest of type "chest" within reasonable distance'
		)
		t.ok(string.find(LocateCommand.logLine(poi, 12.4, { probes = 3, verified = 1 }), "took 12 ms", 1, true) ~= nil)
	end)

	t.test("locate command: the link travels in the Notice message; old notices decode", function()
		local text = "The nearest chest is at [1, 2, 3] (4 blocks away)"
		local b = Protocol.encodeNotice(text, { first = 25, last = 33, suggest = "/tp @s 1 2 3" })
		local decoded, link = Protocol.decodeNotice(b)
		t.eq(decoded, text)
		t.ok(link ~= nil, "a link")
		t.eq((link :: any).first, 25)
		t.eq((link :: any).last, 33)
		t.eq((link :: any).suggest, "/tp @s 1 2 3")
		local plain, none = Protocol.decodeNotice(Protocol.encodeNotice("hello"))
		t.eq(plain, "hello")
		t.eq(none, nil, "no link")
		-- A link past the text is dropped, the text kept.
		local bad = buffer.create(2 + 5 + 6)
		buffer.writeu16(bad, 0, 5)
		buffer.writestring(bad, 2, "hello")
		buffer.writeu16(bad, 7, 3)
		buffer.writeu16(bad, 9, 9)
		buffer.writeu16(bad, 11, 0)
		local kept, dropped = Protocol.decodeNotice(bad)
		t.eq(kept, "hello")
		t.eq(dropped, nil)
	end)

	t.test("locate command: the arguments the chat completes", function()
		local text = LocateCommand.arguments(registries)
		local lines = string.split(text, "\n")
		t.eq(lines[1], "|structure,biome,poi")
		t.eq(string.sub(lines[2], 1, 10), "structure|")
		t.ok(string.find(lines[2], ",#mineshaft,", 1, true) ~= nil, "tags")
		t.ok(string.find(lines[2], "outpost", 1, true) ~= nil, "library structures")
		t.ok(
			string.find(lines[3], "birch_forest", 1, true) ~= nil
				and string.find(lines[3], "#is_forest", 1, true) ~= nil
		)
		t.ok(string.find(lines[4], "chest", 1, true) ~= nil and string.find(lines[4], "#workstation", 1, true) ~= nil)
	end)

	--[[ The queue ]]

	-- A fake clock (seconds) and a job of `ops` steps of `cost` seconds each, yielding after each.
	local function fakeClock()
		local now = 0
		return function(): number
			return now
		end, function(dt: number)
			now += dt
		end
	end

	t.test("locate command: the queue never takes more than its budget plus one step a frame", function()
		local clock, advance = fakeClock()
		local budget = 0.003
		local queue = LocateCommand.newQueue(budget, 20, 8, clock)
		local done: { string } = {}
		local function job(key: string, ops: number, cost: number): LocateCommand.Job
			return {
				key = key,
				run = function(yield: () -> ())
					for _ = 1, ops do
						advance(cost)
						yield()
					end
					table.insert(done, key)
				end,
				timedOut = function()
					table.insert(done, key .. ":timeout")
				end,
				failed = function()
					table.insert(done, key .. ":failed")
				end,
			}
		end
		t.ok(LocateCommand.submit(queue, job("a", 1000, 0.00002)))
		t.ok(LocateCommand.submit(queue, job("b", 300, 0.0005)))
		t.ok(LocateCommand.submit(queue, job("c", 3, 0.0001)))
		local frames, worst = 0, 0
		while LocateCommand.pending(queue) > 0 do
			frames += 1
			worst = math.max(worst, LocateCommand.step(queue))
			advance(1 / 60 - budget)
			t.ok(frames < 1000, "finishes")
		end
		t.ok(worst <= budget + 0.0005 + 1e-9, `worst slice {worst * 1000} ms`)
		t.eq(table.concat(done, ","), "a,b,c", "in order")
		-- 0.02 s of work at 3 ms a frame: at least 7 frames, and no more than one extra per job.
		t.ok(frames >= math.floor(0.02 / budget), `{frames} frames for a`)
	end)

	t.test("locate command: one job a player, a full queue, cancelling, timeouts, failures", function()
		local clock, advance = fakeClock()
		local queue = LocateCommand.newQueue(0.003, 1, 3, clock)
		local said: { string } = {}
		local function job(key: string, ops: number, fail: boolean?): LocateCommand.Job
			return {
				key = key,
				run = function(yield: () -> ())
					for _ = 1, ops do
						advance(0.001)
						yield()
					end
					if fail then
						error("broken")
					end
					table.insert(said, key)
				end,
				timedOut = function()
					table.insert(said, key .. ":timeout")
				end,
				failed = function(message: string)
					table.insert(
						said,
						key .. ":failed:" .. (if string.find(message, "broken", 1, true) then "broken" else "?")
					)
				end,
			}
		end
		t.ok(LocateCommand.submit(queue, job("p1", 5)))
		t.ok(LocateCommand.submit(queue, job("p1", 2)), "a player's new search replaces theirs")
		t.eq(LocateCommand.pending(queue), 1)
		t.ok(LocateCommand.submit(queue, job("p2", 2000)))
		t.ok(LocateCommand.submit(queue, job("p3", 1, true)))
		t.ok(not LocateCommand.submit(queue, job("p4", 1)), "full")
		LocateCommand.cancel(queue, "p4")
		local frames = 0
		while LocateCommand.pending(queue) > 0 and frames < 2000 do
			frames += 1
			LocateCommand.step(queue)
			advance(1 / 60)
		end
		t.eq(said[1], "p1", "the replacement ran")
		t.eq(said[2], "p2:timeout", "a search past the timeout gives up")
		t.eq(said[3], "p3:failed:broken", "an error is reported")
		-- Cancelling a running job: it is never resumed again.
		local ran = 0
		LocateCommand.submit(queue, {
			key = "q",
			run = function(yield: () -> ())
				for _ = 1, 100 do
					ran += 1
					advance(0.001)
					yield()
				end
			end,
			timedOut = function() end,
			failed = function() end,
		})
		LocateCommand.step(queue)
		local after = ran
		LocateCommand.cancel(queue, "q")
		LocateCommand.step(queue)
		t.eq(ran, after, "not resumed")
		t.eq(LocateCommand.pending(queue), 0)
	end)

	--[[ A whole search ]]

	t.test("locate command: searches on a real generator (structure, tag, biome, poi)", function()
		local gen = TerrainGenerator.new(12345)
		local world = WorldServer.new(gen)
		local function search(text: string, x: number, y: number, z: number): (Locate.Found?, any)
			local request = (LocateCommand.run(text, context()) :: any).request
			local stats = { probes = 0, verified = 0 }
			return LocateCommand.search(request, gen, world, x, y, z, nil, stats), request
		end
		local outpost, request = search("/locate structure outpost", 0.5, 80, 0.5)
		t.ok(outpost ~= nil and not (outpost :: any).showY, "an outpost, y not shown")
		local text = LocateCommand.success(request, outpost :: any)
		t.ok(string.find(text, ", ~, ", 1, true) ~= nil, text)
		local mine = search("/locate structure #mineshaft", 3000, 80, -2000)
		t.ok(mine and (mine :: any).showY, "a mineshaft shows its y")
		local cave = search("/locate structure #cave", 0, 80, 0)
		t.ok(cave ~= nil, "a cave")
		local jungle = search("/locate biome jungle", 0, 80, 0)
		t.ok(jungle and (jungle :: any).id == "jungle", "a jungle")
		local forests = search("/locate biome #is_forest", 0, 80, 0) :: any
		t.ok(forests and table.find(Locate.BIOME_TAGS.is_forest, forests.id) ~= nil, "a forest of the tag")
		world:setBlock(10, 120, 20, require(shared.Blocks).id.Furnace)
		local furnace = search("/locate poi #workstation", 0, 120, 0) :: any
		t.ok(furnace and furnace.id == "furnace" and furnace.x == 10 and furnace.z == 20, "a placed furnace")
		t.eq(math.floor(furnace.distance), math.floor(math.sqrt(10 * 10 + 20 * 20)), "the distance")
		-- 40 blocks below: still the horizontal distance, as Minecraft's answer.
		local below = search("/locate poi #workstation", 0, 160, 0) :: any
		t.ok(below and below.x == 10 and below.y == 120 and below.z == 20, "the furnace from above")
		t.eq(math.floor(below.distance), math.floor(math.sqrt(10 * 10 + 20 * 20)), "horizontal, not 3D")
		t.eq(Config.Locate.PoiRadius, 256, "Minecraft's radius")
	end)

	--[[ /tp ]]

	local function player(name: string, x: number?, y: number, z: number, mode: string?)
		return { key = name, name = name, displayName = name, mode = mode or GameMode.SURVIVAL, x = x, y = y, z = z }
	end

	local function tpContext(mayUse: boolean?, safe: ((number, number, number) -> boolean)?, column: number?)
		local steve = player("Steve", 10.5, 70, -4.5)
		local alex = player("Alex", 100.25, 64, 200.75, GameMode.CREATIVE)
		local ghost = player("Ghost", nil, 0, 0)
		return {
			mayUse = mayUse ~= false,
			source = steve,
			players = { steve, alex, ghost },
			isSafe = safe or function(): boolean
				return true
			end,
			column = function(): number?
				return column
			end,
		}
	end

	local function moves(result): string
		local out = {}
		for _, move in result.moves do
			table.insert(out, `{move.key}@{move.x},{move.y},{move.z}`)
		end
		return table.concat(out, " ")
	end

	t.test("tp command: coordinates, targets, texts", function()
		t.eq(TeleportCommand.run("/locate x", tpContext()), nil)
		t.ok(TeleportCommand.matches("/teleport @s 1 2 3"))
		local r = TeleportCommand.run("/tp 100 64 -20", tpContext()) :: any
		t.eq(moves(r), "Steve@100.5,64,-19.5", "whole x and z are block centres")
		t.eq(r.feedback[1], "Teleported Steve to 100.500000, 64.000000, -19.500000")
		r = TeleportCommand.run("/tp ~ ~2 ~-3.5", tpContext()) :: any
		t.eq(moves(r), "Steve@10.5,72,-8", "relative to the feet")
		r = TeleportCommand.run("/tp 1.25 ~ ~", tpContext()) :: any
		t.eq(moves(r), "Steve@1.25,70,-4.5", "decimals as written")
		r = TeleportCommand.run("/tp @a 0 100 0", tpContext()) :: any
		t.eq(moves(r), "Steve@0.5,100,0.5 Alex@0.5,100,0.5 Ghost@0.5,100,0.5")
		t.eq(r.feedback[1], "Teleported 3 entities to 0.500000, 100.000000, 0.500000")
		r = TeleportCommand.run("/tp Alex", tpContext()) :: any
		t.eq(moves(r), "Steve@100.25,64,200.75", "to a player")
		t.eq(r.feedback[1], "Teleported Steve to Alex")
		r = TeleportCommand.run("/tp al st", tpContext()) :: any
		t.eq(moves(r), "Alex@10.5,70,-4.5", "a player to a player, by prefix")
		t.eq((TeleportCommand.run("/tp Ghost", tpContext()) :: any).feedback[1], "No player was found")
		t.eq((TeleportCommand.run("/tp Nobody", tpContext()) :: any).feedback[1], "No player was found")
		t.eq(
			(TeleportCommand.run("/tp @a", tpContext()) :: any).feedback[1],
			TeleportCommand.NOT_SINGLE,
			"one destination"
		)
		t.eq((TeleportCommand.run("/tp", tpContext()) :: any).feedback[1], TeleportCommand.USAGE)
		t.eq((TeleportCommand.run("/tp 1 2", tpContext()) :: any).feedback[1], "No player was found", "two players")
		t.eq((TeleportCommand.run("/tp a b c", tpContext()) :: any).feedback[1], TeleportCommand.USAGE)
		t.eq((TeleportCommand.run("/tp 1 2 3", tpContext(false)) :: any).feedback[1], TeleportCommand.DENIED)
		t.eq((TeleportCommand.run("/tp 2000000 64 0", tpContext()) :: any).feedback[1], TeleportCommand.INVALID)
		t.eq((TeleportCommand.run("/tp 0 5000 0", tpContext()) :: any).feedback[1], TeleportCommand.INVALID)
		t.eq(#(TeleportCommand.run("/tp 0 5000 0", tpContext()) :: any).moves, 0)
	end)

	t.test("tp command: survival players land safe, creative ones exactly (a /locate link's ~)", function()
		-- Only y 40 is safe; the column's safe top is 90.
		local function safe(_x: number, y: number, _z: number): boolean
			return y == 40
		end
		local r = TeleportCommand.run("/tp @s 7 40 7", tpContext(true, safe, 90)) :: any
		t.eq(moves(r), "Steve@7.5,40,7.5", "a safe spot as asked")
		r = TeleportCommand.run("/tp @s 7 39 7", tpContext(true, safe, 90)) :: any
		t.eq(moves(r), "Steve@7.5,40,7.5", "on top of the block found (a chest)")
		r = TeleportCommand.run("/tp @s 7 46 7", tpContext(true, safe, 90)) :: any
		t.eq(moves(r), "Steve@7.5,40,7.5", "a written y: the safe spot within 16 of it, not the top")
		t.eq(r.feedback[1], "Teleported Steve to 7.500000, 40.000000, 7.500000", "where they landed")
		r = TeleportCommand.run("/tp @s 7 30 7", tpContext(true, safe, 90)) :: any
		t.eq(moves(r), "Steve@7.5,40,7.5", "or above it")
		r = TeleportCommand.run("/tp @s 7 60 7", tpContext(true, safe, 90)) :: any
		t.eq(moves(r), "Steve@7.5,90,7.5", "20 off: the column's safe top")
		r = TeleportCommand.run("/tp @s 7 ~ 7", tpContext(true, safe, 90)) :: any
		t.eq(moves(r), "Steve@7.5,90,7.5", "a link's ~ lands on the column's safe top")
		t.eq(r.feedback[1], "Teleported Steve to 7.500000, 90.000000, 7.500000", "where they landed")
		r = TeleportCommand.run("/tp @s 7 ~-30 7", tpContext(true, safe, 90)) :: any
		t.eq(moves(r), "Steve@7.5,40,7.5", "~n is a written y")
		r = TeleportCommand.run("/tp @s 7 ~ 7", tpContext(true, safe, nil)) :: any
		t.eq(moves(r), "Steve@7.5,70,7.5", "no safe spot at all: as asked")
		-- No safe top: the nearest column with one, else afloat, else as asked.
		local context = tpContext(true, function()
			return false
		end, nil) :: any
		context.near = function(x: number, z: number): (number?, number, number)
			return x + 3, 66, z - 2
		end
		context.waterSurface = function(): number?
			return 62
		end
		r = TeleportCommand.run("/tp @s 7 ~ 7", context) :: any
		t.eq(moves(r), "Steve@10.5,66,5.5", "the nearest safe column (a lake's shore)")
		context.near = function(): (number?, number, number)
			return nil, 0, 0
		end
		r = TeleportCommand.run("/tp @s 7 30 7", context) :: any
		t.eq(moves(r), "Steve@7.5,62,7.5", "none near: afloat on the water (not its bed)")
		r = TeleportCommand.run("/tp @a 7 30 7", context) :: any
		t.eq(moves(r), "Steve@7.5,62,7.5 Alex@7.5,30,7.5 Ghost@7.5,62,7.5", "each mode its own landing")
		t.eq(r.feedback[1], "Teleported 3 entities to 7.500000, 30.000000, 7.500000", "several: where asked")
		r = TeleportCommand.run("/tp Alex 7 ~ 7", tpContext(true, safe, 90)) :: any
		t.eq(moves(r), "Alex@7.5,70,7.5", "creative: exactly (relative to who typed it)")
	end)

	t.test("tp command: on real worlds, /locate's links and moves in a cave land survival players safe", function()
		local SafeSpot = require(server.Players.SafeSpot)
		local Blocks = require(shared.Blocks)
		-- Safe ground, or afloat at the top of open water.
		local function landedWell(world: any, move: any): boolean
			local bx, by, bz = math.floor(move.x), math.floor(move.y), math.floor(move.z)
			return SafeSpot.isSafe(world, bx, by, bz) or SafeSpot.waterSurface(world, bx, bz) == by
		end
		local count = 0
		for _, seed in { 12345, 99 } do
			local gen = TerrainGenerator.new(seed)
			local world = WorldServer.new(TerrainGenerator.new(seed))
			local kinds = {}
			for _, kind in (gen :: any).locateKinds() do
				kinds[kind.id] = kind
			end
			for _, p in { { 0, 0 }, { 3000, -2000 } } do
				-- (Standing on the surface where they typed it: the link's ~ is that height.)
				local source = player("Steve", p[1] + 0.5, gen.column(p[1], p[2]), p[2] + 0.5)
				for _, id in { "lake", "lava_lake", "oil_geyser", "cave_entrance", "ravine" } do
					local found = Locate.nearest({ kinds[id] }, p[1], p[2]) :: any
					if found == nil then
						continue
					end
					local link = LocateCommand.suggestion(found)
					local r =
						TeleportCommand.run(link, TeleportCommand.worldContext(world, true, source, { source })) :: any
					local move = r.moves[1]
					count += 1
					t.ok(landedWell(world, move), `seed {seed}, {id}: {link} landed at {move.x}, {move.y}, {move.z}`)
				end
			end
		end
		t.ok(count >= 15, `{count} links`)
		-- A biome answer's y is its surface: under the sea, the seabed. Afloat instead.
		local seaWorld = WorldServer.new(TerrainGenerator.new(4242))
		local source = player("Steve", -2000.5, 70, -1400.5)
		t.ok(seaWorld.generator.column(-2096, -1496) < Config.SeaLevel, "the spot is under the sea")
		local r = TeleportCommand.run(
			"/tp @s -2096 30 -1496",
			TeleportCommand.worldContext(seaWorld, true, source, { source })
		) :: any
		local move = r.moves[1]
		t.ok(landedWell(seaWorld, move) and move.y >= Config.SeaLevel - 1, `afloat: {move.y}`)
		-- In a mineshaft room (seed 12345): a small move stays in the room, not on the surface.
		local mineWorld = WorldServer.new(TerrainGenerator.new(12345))
		local miner = player("Steve", -45.5, 27, -12.5)
		t.ok(SafeSpot.isSafe(mineWorld, -46, 27, -13), "standing in the room")
		for _, command in { "/tp ~ ~2 ~", "/tp ~ ~10 ~", "/tp ~1 ~ ~" } do
			r = TeleportCommand.run(command, TeleportCommand.worldContext(mineWorld, true, miner, { miner })) :: any
			move = r.moves[1]
			t.ok(landedWell(mineWorld, move) and move.y < 45, `{command}: {move.x}, {move.y}, {move.z}`)
			t.eq(
				r.feedback[1],
				`Teleported Steve to {TeleportCommand.formatNumber(move.x)}, {TeleportCommand.formatNumber(move.y)}, {TeleportCommand.formatNumber(
					move.z
				)}`,
				"the answer says where"
			)
			t.ok(Blocks.isSolid(mineWorld:getBlock(-46, 46, -13)), "rock above the room")
		end
	end)
end
