--[[
	The fourth data sheet (icevoxel_4.xlsx): every asset id it brought that the game did not have,
	and where each one is used, as decided when it was taken in. A future sheet is checked the same
	way: add a table like SHEET4 (its rows: texture maps per pack entry, music per list, mob voices
	per Sound, main sounds per event) and run it through the same checks.

	  Textures   the pack entries (Shared/TexturePack) whose colour and normal maps they are; the
	             sheet shares maps on purpose ("Ignore double id's this list is intentional"), and
	             entries not on it take a sheet's maps by decision (cracked and mossy concrete:
	             concrete's; the road lines' tops: asphalt's).
	  Music      the MusicList lists they are in (the "Surface NightTime" list is Night).
	  Mob SFX    the Sounds of src/sounds/Zombies.model.json (SoundService.IceVoxelSounds) that
	             play them, by event name.
	  Main SFX   the catalogue events (Sounds/SoundList) whose ids they are: the eating and
	             drinking loops, every block sound type's break and place.

	The fifth sheet (icevoxel.xlsx, SHEET5) brought only main sounds: each the catalogue events
	playing it, the stand-in it replaced as their fallback.
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

-- The fourth sheet's new ids, by where they go.
local SHEET4 = {
	-- Texture maps: { colour, normal, the pack entries using them (sheet row in the comment) }.
	textures = {
		-- Concrete; cracked and mossy concrete (not on the sheet) take its maps.
		{ "83707291495507", "134665376447341", { "concrete", "cracked concrete", "mossy concrete" } },
		-- Andesite, and cracked asphalt ("Yes uses andesite textures").
		{ "135061946280047", "84287333684009", { "andesite", "cracked asphalt" } },
		-- Polished andesite, and asphalt; the road lines' tops (not on the sheet) take asphalt's.
		{
			"70532405855463",
			"84287333684009",
			{ "polished andesite", "asphalt", "road line", "road line yellow" },
		},
		{ "95612339340500", "114812382647958", { "stone bricks" } },
		{ "112502994131665", "97312068579996", { "vine" } },
		{ "136109631002116", "97401111826072", { "mossy cobblestone" } },
		-- "crate": the Supply Crate's every face.
		{ "83206835598770", "98971183237888", { "supply crate side", "supply crate top" } },
		-- "cabinet": the Medicine Cabinet's every face.
		{ "125353153474912", "97000542660093", { "medicine cabinet side", "medicine cabinet top" } },
		-- "moss": all things moss (the moss block and carpet).
		{ "133332486942553", "80266253786825", { "moss block" } },
		{ "126386401149504", "92601327159349", { "smooth stone" } },
		-- (Cracked and mossy bricks take the bricks' maps, which the first sheet brought.)
		{ "78619102429227", "126476239211015", { "bricks", "cracked bricks", "mossy bricks" }, old = true },
	},
	-- Music: { list, id }.
	music = {
		{ "Night", "83363159814829" },
		{ "Night", "110580815646457" },
		{ "Night", "87554050890182" },
		{ "Night", "75930652698872" },
		{ "Night", "88972071265388" },
		{ "Night", "128714671201955" },
		{ "Night", "92470995513267" },
		{ "Cave", "1836908773" },
		{ "Cave", "140269757258221" },
		{ "Cave", "118738985293021" },
		{ "Cave", "106093225151190" },
	},
	-- Mob SFX: { id, the Sounds (by event) that play it }.
	mobs = {
		{ "130156156621885", { "entity.zombie.ambient" } },
		{ "129294628821291", { "entity.zombie.ambient" } },
		{ "106129958887908", { "entity.zombie.ambient" } },
		-- The growl: every zombie voice's hurt.
		{
			"100949226522885",
			{
				"entity.zombie.hurt",
				"entity.zombie_runner.hurt",
				"entity.zombie_brute.hurt",
				"entity.zombie_screamer.hurt",
			},
		},
		-- The deaths: every zombie voice's death, two variants each.
		{
			"129812990954678",
			{
				"entity.zombie.death",
				"entity.zombie_runner.death",
				"entity.zombie_brute.death",
				"entity.zombie_screamer.death",
			},
		},
		{
			"133918674",
			{
				"entity.zombie.death",
				"entity.zombie_runner.death",
				"entity.zombie_brute.death",
				"entity.zombie_screamer.death",
			},
		},
	},
	-- Main SFX: { id, the catalogue events playing it (block.*.<action> for every type but those
	-- that keep their own) }.
	main = {
		{ "124005963174357", { "entity.generic.eating" } },
		{ "79766888063175", { "entity.generic.drinking" } },
		{ "73168198865721", { "block.*.break" }, keep = { "glass", "water" } },
		{ "101534882480796", { "block.*.place" }, keep = { "water" } },
	},
}

-- The fifth sheet's: { id, the catalogue events playing it }.
local SHEET5 = {
	textures = {},
	music = {},
	mobs = {},
	main = {
		-- "Entity Hit": a player's hit landing, light or strong, and a bullet in flesh.
		{
			"139520673393967",
			{ "entity.player.attack.strong", "entity.player.attack.weak", "entity.bullet.flesh" },
		},
		-- "Electric Hum": the light machines.
		{
			"120250063764346",
			{
				"block.electric_furnace.hum",
				"block.electric_heater.hum",
				"block.air_conditioner.hum",
				"block.ammo_press.hum",
			},
		},
		-- "Heavy Electric Hum": the machines drawing the most energy.
		{ "138159989881933", { "block.metal_miner.hum", "block.oil_refinery.hum" } },
		{ "318794788", { "block.lava.ambient" } },
		-- The guns, by calibre, and the same "silenced".
		{ "138905044369113", { "item.firearm.9mm.fire" } },
		{ "89214508659473", { "item.firearm.9mm.suppressed" } },
		{ "5910000043", { "item.firearm.556.fire" } },
		{ "94291108433840", { "item.firearm.556.suppressed" } },
		{ "135793582032227", { "item.firearm.308.fire" } },
		{ "71834414905709", { "item.firearm.308.suppressed" } },
		-- The Geiger counter's click.
		{ "123303121160543", { "ambient.radiation.click" } },
	},
}

-- Every new id of a sheet table (the textures marked `old` left out), each once.
local function newIds(sheet: any): { string }
	local ids, seen = {}, {}
	local function add(id: string)
		if not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	for _, row in sheet.textures do
		if not row.old then
			add(row[1])
			add(row[2])
		end
	end
	for _, row in sheet.music do
		add(row[2])
	end
	for _, row in sheet.mobs do
		add(row[1])
	end
	for _, row in sheet.main do
		add(row[1])
	end
	return ids
end

-- Every Lua or JSON file under `dir` (recursively), as text.
local function sources(dir: string, into: { string }): { string }
	for _, name in fs.readDir(dir) do
		local path = `{dir}/{name}`
		if fs.isDir(path) then
			sources(path, into)
		elseif string.match(name, "%.luau$") or string.match(name, "%.json$") then
			table.insert(into, fs.readFile(path))
		end
	end
	return into
end

return function(t, shared, require, _server, _client)
	local Pack = require(shared.TexturePack)
	local Blocks = require(shared.Blocks)
	local MusicList = require(shared.Sounds.MusicList)
	local Sounds = require(shared.Sounds)
	local SoundList = require(shared.Sounds.SoundList)

	local function asset(id: string): string
		return `rbxassetid://{id}`
	end

	t.test("data sheet 4: forty new ids, every one used", function()
		local ids = newIds(SHEET4)
		t.eq(#ids, 40, "the sheet's forty new asset ids")
		-- Each is somewhere in the game's data (a pack entry, a music list, a shipped Sound, the
		-- catalogue), as the number it is on the sheet.
		local text = table.concat(sources("src", {}), "\n")
		for _, id in ids do
			t.ok(string.find(text, `rbxassetid://{id}"`, 1, true) ~= nil, `{id} is used`)
		end
	end)

	t.test("data sheet 4: the textures' maps in their pack entries, on their blocks", function()
		for _, row in SHEET4.textures do
			local color, normal, names = row[1], row[2], row[3]
			for _, name in names do
				local texture = Pack.Textures[name]
				t.ok(texture ~= nil, `{name} is in the pack`)
				if texture then
					t.eq(texture.Color, asset(color), `{name} colour map`)
					t.eq(texture.Normal, asset(normal), `{name} normal map`)
					t.ok(#Blocks.textureUsers(name) > 0, `{name} is on a block`)
				end
			end
		end
		-- The blocks they are for, face by face.
		local function face(block: string, which: string): string?
			return (Blocks.get(Blocks.id[block]).textures :: any)[which]
		end
		for block, texture in
			{
				Concrete = "concrete",
				CrackedConcrete = "cracked concrete",
				MossyConcrete = "mossy concrete",
				Andesite = "andesite",
				CrackedAsphalt = "cracked asphalt",
				PolishedAndesite = "polished andesite",
				Asphalt = "asphalt",
				StoneBricks = "stone bricks",
				SmoothStone = "smooth stone",
				MossyCobblestone = "mossy cobblestone",
				MossBlock = "moss block",
				MossCarpet = "moss block",
				CrackedBricks = "cracked bricks",
				MossyBricks = "mossy bricks",
			}
		do
			t.eq(face(block, "north"), texture, `{block}'s sides`)
			t.eq(face(block, "top"), texture, `{block}'s top`)
		end
		t.eq(face("RoadLine", "top"), "road line", "the white line's paint")
		t.eq(face("RoadLineYellow", "top"), "road line yellow", "the yellow line's")
		t.eq(face("RoadLine", "north"), "asphalt", "over asphalt")
		t.eq(face("VineEast", "front"), "vine", "the vines' plate")
		t.eq(face("SupplyCrate", "top"), "supply crate top")
		t.eq(face("SupplyCrate", "north"), "supply crate side")
		t.eq(face("MedicineCabinet", "top"), "medicine cabinet top")
		t.eq(face("MedicineCabinet", "north"), "medicine cabinet side")
		-- No Average yet: the game measures them (--list names them).
		for _, row in SHEET4.textures do
			for _, name in row[3] do
				if not row.old then
					t.eq(Pack.Textures[name].Average, nil, `{name}: Average left to the game`)
				end
			end
		end
	end)

	t.test("data sheet 4: the music in its lists", function()
		for _, row in SHEET4.music do
			local list, id = row[1], row[2]
			local found = false
			for _, track in (MusicList :: any)[list] do
				found = found or track.Id == asset(id)
			end
			t.ok(found, `{id} in MusicList.{list}`)
		end
	end)

	t.test("data sheet 4: the zombies' voices in the sounds folder, by event", function()
		local model = serde.decode("json", fs.readFile("src/sounds/Zombies.model.json"))
		local played: { [string]: { [string]: boolean } } = {}
		for _, child in model.Children do
			local id = string.match(child.Properties.SoundId, "^rbxassetid://(%d+)$")
			if id then
				played[id] = played[id] or {}
				played[id][child.Name] = true
			end
		end
		for _, row in SHEET4.mobs do
			local id, names = row[1], row[2]
			local count = 0
			for _ in played[id] or {} do
				count += 1
			end
			t.eq(count, #names, `{id}: played by its {#names} events, no others`)
			for _, name in names do
				t.ok(played[id] and played[id][name], `{id} plays as {name}`)
				t.ok(Sounds.find(name) ~= nil, `{name} is an event`)
			end
		end
	end)

	t.test("data sheet 4: the main sounds as the catalogue's events", function()
		for _, row in SHEET4.main do
			local id, names = row[1], row[2]
			local keep = row.keep or {}
			for _, name in names do
				local action = string.match(name, "^block%.%*%.(%a+)$")
				if action then
					for _, typeName in Blocks.SOUND_TYPES do
						local event = Sounds.get(`block.{typeName}.{action}`) :: any
						if table.find(keep, typeName) then
							t.ok(event.id ~= asset(id), `block.{typeName}.{action} keeps its own`)
						else
							t.eq(event.id, asset(id), `block.{typeName}.{action}`)
							t.ok(event.fallback ~= nil, `block.{typeName}.{action}: the stand-in its fallback`)
						end
					end
				else
					local event = Sounds.get(name) :: any
					t.ok(event ~= nil, `{name} is an event`)
					t.eq(event and event.id, asset(id), `{name} plays {id}`)
				end
			end
		end
	end)

	t.test("data sheet 5: eleven new ids, every one used, as the catalogue's events", function()
		local ids = newIds(SHEET5)
		t.eq(#ids, 11, "the sheet's eleven new asset ids")
		local text = table.concat(sources("src", {}), "\n")
		for _, id in ids do
			t.ok(string.find(text, `rbxassetid://{id}"`, 1, true) ~= nil, `{id} is used`)
			t.ok(table.find(SoundList.FIFTH_SHEET, asset(id)) ~= nil, `{id} is a known upload`)
		end
		t.eq(#SoundList.FIFTH_SHEET, #ids, "and no others")
		for _, row in SHEET5.main do
			local id, names = row[1], row[2]
			for _, name in names do
				local event = Sounds.get(name) :: any
				t.ok(event ~= nil, `{name} is an event`)
				t.eq(event and event.id, asset(id), `{name} plays {id}`)
				local fallback = event and event.fallback
				t.ok(
					fallback ~= nil and string.sub(fallback.id, 1, 18) == "rbxasset://sounds/",
					`{name}: a shipped stand-in its fallback`
				)
			end
		end
		-- One override Sound per kind of hum.
		for _, name in { "block.electric_furnace.hum", "block.electric_heater.hum", "block.ammo_press.hum" } do
			t.eq((Sounds.get(name) :: any).category, "machine.hum", `{name}'s category`)
		end
		for _, name in { "block.metal_miner.hum", "block.oil_refinery.hum" } do
			t.eq((Sounds.get(name) :: any).category, "machine.heavy_hum", `{name}'s category`)
		end
	end)
end
