return function(t, shared, require)
	local Config = require(shared.Config)
	local Blocks = require(shared.Blocks)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local MapPainter = require(shared.Map.MapPainter)
	local FluidFlow = require(shared.World.FluidFlow)

	t.test("map tiles are deterministic RGBA and show water as blue", function()
		local gen = TerrainGenerator.new(12345)
		local paint = MapPainter.new(gen)
		local a = paint(-512, 300, 8, 32)
		t.eq(buffer.len(a), 32 * 32 * 4)
		t.eq(buffer.tostring(a), buffer.tostring(MapPainter.new(TerrainGenerator.new(12345))(-512, 300, 8, 32)))

		-- Find a water pixel and a land pixel in a bigger tile and check their colours.
		local size, scale, ox, oz = 64, 16, -2048, -2048
		local tile = paint(ox, oz, scale, size)
		local sawWater, sawLand = false, false
		for py = 0, size - 1 do
			for px = 0, size - 1 do
				local h = gen.column(ox + px * scale + scale // 2, oz + py * scale + scale // 2)
				local o = (py * size + px) * 4
				local r, g, b, alpha =
					buffer.readu8(tile, o),
					buffer.readu8(tile, o + 1),
					buffer.readu8(tile, o + 2),
					buffer.readu8(tile, o + 3)
				t.eq(alpha, 255, "opaque pixels")
				if h < Config.SeaLevel - 3 then
					sawWater = true
					t.ok(b > r and b >= g, `water pixel should be blue ({r},{g},{b})`)
				elseif h > Config.SeaLevel + 3 then
					sawLand = true
				end
			end
		end
		t.ok(sawWater and sawLand, "tile has both water and land")
	end)

	t.test("fluid flow points downstream and is zero in still water", function()
		local blocks: { [string]: number } = {}
		local function set(x: number, y: number, z: number, id: number)
			blocks[`{x},{y},{z}`] = id
		end
		local function get(x: number, y: number, z: number): number?
			return blocks[`{x},{y},{z}`] or Blocks.AIR
		end
		local water = function(level: number)
			return Blocks.fluidId("Water", level)
		end
		for x = -3, 3 do
			for z = -3, 3 do
				set(x, -1, z, Blocks.id.Stone)
			end
		end
		-- Still pool of sources.
		for x = -3, 3 do
			set(x, 0, -3, water(0))
		end
		local fx, fy, fz = FluidFlow.at(get, 0, 0, -3)
		t.eq(fx, 0)
		t.eq(fz, 0, "still sources")
		t.eq(fy, 0)

		-- A stream getting weaker towards +X.
		set(0, 0, 2, water(1))
		set(1, 0, 2, water(2))
		set(-1, 0, 2, water(0))
		fx, fy, fz = FluidFlow.at(get, 0, 0, 2)
		t.ok(fx > 0.99, `flows towards +X (got {fx}, {fz})`)

		-- Water next to a drop flows towards it.
		set(3, 0, 0, water(3))
		set(3, -1, 1, water(8))
		set(3, 0, 1, Blocks.AIR)
		fx, fy, fz = FluidFlow.at(get, 3, 0, 0)
		t.ok(fz > 0.7, `flows towards the drop (got {fx}, {fz})`)

		set(-2, 0, 0, water(8))
		local _, down = FluidFlow.at(get, -2, 0, 0)
		t.eq(down, -1, "falling water pushes down")
		t.eq(select(1, FluidFlow.at(get, 0, -1, 0)), 0, "solid blocks do not flow")
	end)
end
