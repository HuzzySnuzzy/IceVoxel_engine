--[[
	Generation/WorldTypes: the registry of world types and how the server's choice travels to the
	clients (options as one string).
]]

return function(t, shared, require)
	local WorldTypes = require(shared.Generation.WorldTypes)

	t.test("world types: the Default is there, unknown ids build it", function()
		local default = WorldTypes.get(WorldTypes.DEFAULT)
		t.ok(default ~= nil, "Default")
		t.eq(WorldTypes.list[1].id, WorldTypes.DEFAULT, "first in the menu")
		local generator = WorldTypes.create("no such type", 12345, {})
		t.eq(generator.seed, 12345)
		local h = generator.column(0, 0)
		t.ok(type(h) == "number", "a terrain column")
		t.eq(WorldTypes.get("no such type"), nil)
	end)

	t.test("world types: options as one string, round trip, keys sorted, odd text escaped", function()
		local options = { preset = "minecraft:bedrock,2*dirt;grass=1", height = 64, structures = false, name = "a%b" }
		local text = WorldTypes.encodeOptions(options)
		local back = WorldTypes.decodeOptions(text)
		t.eq(back.preset, options.preset)
		t.eq(back.height, 64)
		t.eq(back.structures, false)
		t.eq(back.name, "a%b")
		t.eq(WorldTypes.encodeOptions({ b = 1, a = 2 }), "a=n:2;b=n:1", "sorted")
		t.eq(WorldTypes.encodeOptions(nil), "")
		t.eq(next(WorldTypes.decodeOptions("")), nil, "empty")
		t.eq(next(WorldTypes.decodeOptions("junk;x=q:1")), nil, "malformed parts skipped")
	end)

	t.test("world types: register adds, or replaces in place", function()
		local count = #WorldTypes.list
		WorldTypes.register({
			id = "spec.flat",
			name = "Spec",
			description = "",
			create = function(seed, options)
				return WorldTypes.create(WorldTypes.DEFAULT, seed, options)
			end,
			hidden = true,
		})
		t.eq(#WorldTypes.list, count + 1)
		WorldTypes.register({
			id = "spec.flat",
			name = "Spec 2",
			description = "",
			create = function(seed, options)
				return WorldTypes.create(WorldTypes.DEFAULT, seed, options)
			end,
			hidden = true,
		})
		t.eq(#WorldTypes.list, count + 1, "replaced")
		t.eq((WorldTypes.get("spec.flat") :: any).name, "Spec 2")
		table.remove(WorldTypes.list, #WorldTypes.list)
	end)
end
