return function(t, shared, require, _server, client)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local ChunkLayout = require(shared.World.ChunkLayout)
	local Hash = require(shared.Util.Hash)
	local Relief = require(shared.Generation.Relief)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local CaveReach = require(client.Streaming.CaveReach)

	local SIZE = ChunkLayout.SIZE
	local CAVE, STONE, AIR = Blocks.CAVE_AIR, Blocks.id.Stone, Blocks.AIR
	local gen = TerrainGenerator.new(12345)
	local relief = Relief.new(12345)

	t.test("caves stay below the surface and grow with depth", function()
		local margin = Config.Caves.SurfaceMargin
		local rng = Hash.rng(21)
		-- Air share per depth band: 22-158 and 158-316 blocks below the surface.
		local shallow, deep = { 0, 0 }, { 0, 0 }
		for _ = 1, 40 do
			local cx, cz = rng:int(-4000, 4000), rng:int(-4000, 4000)
			local r = gen.generate(0, cx, cz)
			for lz = 0, SIZE - 1, 3 do
				for lx = 0, SIZE - 1, 3 do
					local h = gen.column(cx * SIZE + lx, cz * SIZE + lz)
					for y = math.max(h - margin, 0), math.min(h - 1, r.height - 1) do
						t.ok(ChunkLayout.get(r.data, lx, y, lz) ~= CAVE, `cave air {h - y} blocks below the surface`)
					end
					for y = 1, math.min(h - 22, r.height - 1) do
						local depth = h - y
						local band = if depth < 158 then shallow elseif depth < 316 then deep else nil
						if band then
							band[2] += 1
							if ChunkLayout.get(r.data, lx, y, lz) == CAVE then
								band[1] += 1
							end
						end
					end
				end
			end
		end
		-- The datapack measures 8-16% air between 20 and 700 blocks deep.
		local a, b = shallow[1] / shallow[2], deep[1] / math.max(deep[2], 1)
		t.ok(a > 0.04 and a < 0.25, `air 22-158 blocks deep: {a}`)
		t.ok(deep[2] == 0 or b < 0.4, `air 158-316 blocks deep: {b}`)
	end)

	t.test("the Underlands open up under the highest mountains", function()
		-- Find a column of very high terrain.
		local rng = Hash.rng(4)
		local x, z
		for _ = 1, 200000 do
			local px, pz = rng:int(-60000, 60000), rng:int(-60000, 60000)
			if relief.height(px, pz, 0) > 720 then
				x, z = px, pz
				break
			end
		end
		assert(x and z, "no terrain above 720 found")
		local cx, cz = x // SIZE, z // SIZE
		local r = gen.generate(0, cx, cz)
		-- Longest vertical run of cave air in the chunk.
		local longest = 0
		for lz = 0, SIZE - 1, 5 do
			for lx = 0, SIZE - 1, 5 do
				local run = 0
				for y = 1, r.height - 1 do
					if ChunkLayout.get(r.data, lx, y, lz) == CAVE then
						run += 1
						longest = math.max(longest, run)
					else
						run = 0
					end
				end
			end
		end
		t.ok(longest >= 100, `the cavern under {x}, {z} is only {longest} blocks tall`)
	end)

	t.test("cave reach: open caverns reveal further than tunnels", function()
		-- A world of stone with a straight 1x2 tunnel along x and a 60 block hall.
		local function world(hall: boolean)
			return function(x: number, y: number, z: number): number?
				if hall and math.abs(x) <= 30 and math.abs(z) <= 30 and y >= 0 and y <= 40 then
					return CAVE
				end
				if z == 0 and (y == 10 or y == 11) then
					return CAVE
				end
				return STONE
			end
		end
		local tunnel = CaveReach.probe(world(false), 0.5, 10.5, 0.5, 96)
		t.ok(tunnel < 4, `a tunnel looks {tunnel} blocks open`)
		local hall = CaveReach.probe(world(true), 0.5, 10.5, 0.5, 96)
		t.ok(hall >= 25, `a 60 block hall looks {hall} blocks open`)
		local unloaded = CaveReach.probe(function()
			return nil
		end, 0, 0, 0, 96)
		t.eq(unloaded, 96, "unloaded blocks let rays through")
		local outside = CaveReach.probe(function()
			return AIR
		end, 0, 0, 0, 50)
		t.eq(outside, 50)
	end)

	t.test("cave reach: the radius grows at once and shrinks after a delay, in steps", function()
		local tracker = CaveReach.tracker(48, 96, 16, 2)
		t.eq(tracker:update(nil, 0), 48, "above ground")
		t.eq(tracker:update(3, 1), 48, "a tunnel keeps the minimum")
		t.eq(tracker:update(50, 2), 80, "open space: rounded up with a step of margin")
		t.eq(tracker:update(500, 3), 96, "capped")
		t.eq(tracker:update(10, 4), 96, "does not shrink at once")
		t.eq(tracker:update(10, 5.5), 96)
		t.eq(tracker:update(10, 6.1), 48, "shrinks after the delay")
		t.eq(tracker:update(20, 7), 48)
		t.eq(tracker:update(70, 7.1), 96, "grows again at once")
	end)
end
