--[[
	The zombie apocalypse's foundation, the contract its streams build on: the new blocks (ids
	419..438, the Ceiling Lamp's cave twin last), items (4257..4277), effects (Bleeding,
	Infection), sounds, textures and lore; how long a zombie takes to break each block
	(Blocks.zombieBreak, cave twins included, hatches and containers never) and the hatch's toggle
	(Blocks.toggleOf, Blocks/Toggles); the zombie kinds (Shared/Entities/MobList: ids 5..14, looks
	and skin tones packed in a variant, drops, knowledge, sounds, snake case names); the Mobs ops'
	sizes and flags, the retired arrow op and the move op's deltas, and the Survivor message
	(Shared/Net/Protocol); the blood moon's schedule (Apocalypse/BloodMoon); which sounds zombies
	hear (Apocalypse/NoiseRules) and the server's noise bus (Apocalypse/NoiseBus), which hears a
	sound played at a player's feet with the game's audio off (Audio/Sounds); the ruins' and
	bunkers' loot (Generation/ScavengeLoot); bats wearing (Entities/Combat); the new recipes,
	smelting and their Ages; the monsters' old drops still found; the /locate kinds and POI
	types; the no-op cities and bunkers the generator runs with until they come; and the Ruins
	world setting with old worlds' rule (Save/WorldMeta).
]]

local roblox = require("@lune/roblox")

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local LoreList = require(shared.Items.LoreList)
	local Config = require(shared.Config)
	local Crafting = require(shared.Crafting)
	local Smelting = require(shared.Crafting.Smelting)
	local Effects = require(shared.Effects)
	local Sounds = require(shared.Sounds)
	local MobList = require(shared.Entities.MobList)
	local Combat = require(shared.Entities.Combat)
	local Knowledge = require(shared.Progression.Knowledge)
	local Ages = require(shared.Progression.Ages)
	local Protocol = require(shared.Net.Protocol)
	local BloodMoon = require(shared.Apocalypse.BloodMoon)
	local NoiseRules = require(shared.Apocalypse.NoiseRules)
	local Toggles = require(shared.Blocks.Toggles)
	local ScavengeLoot = require(shared.Generation.ScavengeLoot)
	local Locate = require(shared.Generation.Locate)
	local Relief = require(shared.Generation.Relief)
	local Cities = require(shared.Generation.Cities)
	local Bunkers = require(shared.Generation.Bunkers)
	local TerrainGenerator = require(shared.Generation.TerrainGenerator)
	local WorldTypes = require(shared.Generation.WorldTypes)
	local Poi = require(shared.Poi)
	local GameMode = require(shared.GameMode)
	local WorldMeta = require(server.Save.WorldMeta)
	local NoiseBus = require(server.Apocalypse.NoiseBus)
	local ServerSounds = require(server.Audio.Sounds)

	local B, I = Blocks.id, Items.id
	local DAY = 24000

	local BLOCKS = {
		"Asphalt",
		"CrackedAsphalt",
		"RoadLine",
		"RoadLineYellow",
		"Concrete",
		"CrackedConcrete",
		"MossyConcrete",
		"CrackedBricks",
		"MossyBricks",
		"RustyMetal",
		"SupplyCrate",
		"MedicineCabinet",
		"Barricade",
		"BarricadeNorthSouth",
		"ReinforcedBarricade",
		"ReinforcedBarricadeNorthSouth",
		"BunkerHatch",
		"BunkerHatchOpen",
		"CeilingLamp",
		"CaveCeilingLamp",
	}
	local ITEMS = {
		"Bandage",
		"Medkit",
		"Antibiotics",
		"Painkillers",
		"Rag",
		"DuctTape",
		"Nails",
		"ScrapMetal",
		"CannedBeans",
		"CannedPeaches",
		"Crackers",
		"ChocolateBar",
		"MilitaryRation",
		"BottledWater",
		"SodaCan",
		"BaseballBat",
		"SpikedBat",
		"Machete",
		"Crowbar",
		"FireAxe",
		"HerbalPoultice",
	}
	local ZOMBIES = {
		"Zombie",
		"ZombieRunner",
		"ZombieBrute",
		"ZombieCrawler",
		"ZombieScreamer",
		"ZombieSoldier",
		"ZombiePolice",
		"ZombieFirefighter",
		"ZombieWorker",
		"ZombieDoctor",
	}

	-- A deterministic random in [0, 1) (a small LCG).
	local function lcg(seed: number): () -> number
		local state = seed
		return function(): number
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	--[[ The registries ]]

	t.test("apocalypse: the blocks, items, effects, sounds, textures and lore, in their order", function()
		for index, name in BLOCKS do
			t.eq(B[name], 418 + index, `{name}'s id`)
		end
		-- (The seasons' 47 came after: snow layers, heaters, insulation; then the turrets' 14:
		-- twelve turrets, the Metal Miner and the Ammo Press; then the new ores' 15. Was 439, then
		-- 486, then 500.)
		t.eq(B.CaveCeilingLamp, 438, "the Ceiling Lamp's twin was the last block before the seasons")
		t.eq(Blocks.count, 515)
		t.eq(Blocks.caveTwinFor(B.CeilingLamp), B.CaveCeilingLamp)
		t.ok(Blocks.isCaveTwin(B.CaveCeilingLamp), "a cave twin")
		for index, name in ITEMS do
			t.eq(I[name], 4256 + index, `{name}'s id`)
		end
		-- (The weapons' 34 came after, then the turrets' 8, then the new ores' 20: was
		-- "HerbalPoultice", then "Sledgehammer", then "LaserSight"; HerbalPoultice is still 4277.)
		t.eq(Items.list[#Items.list].name, "HazmatBoots", "the last item")
		t.eq(I.HerbalPoultice, 4277, "the apocalypse's last item")
		t.eq(Items.maxStack(I.Bandage), 16)
		t.eq(Items.maxStack(I.Medkit), 4)
		t.eq(Items.maxStack(I.Rag), 64)
		t.eq(Items.maxStack(I.BaseballBat), 1)
		t.eq(Items.get(I.SodaCan).displayName, "Soda")
		t.eq(Effects.id.Bleeding, 26)
		t.eq(Effects.id.Infection, 27)
		-- (Minecraft's Hunger came after the apocalypse's two: 28, Shared/Hunger; then Radiation
		-- Sickness, 29: Shared/Radiation.)
		t.eq(Effects.COUNT, 29)
		t.eq(Effects.get(Effects.id.Bleeding).lethal, false, "bleeding never kills")
		t.eq(Effects.get(Effects.id.Infection).external, true, "Survival keeps the infection")
		for _, name in
			{
				"entity.zombie.ambient",
				"entity.zombie.attack_wooden_door",
				"entity.zombie.break_wooden_door",
				"entity.zombie_screamer.scream",
				"block.bunker_hatch.open",
				"block.bunker_hatch.close",
				"item.bandage.apply",
				"item.medkit.use",
				"item.pills.swallow",
				"ambient.blood_moon.rise",
				"entity.zombie_runner.hurt",
				"entity.zombie_brute.death",
				"entity.zombie_screamer.hurt",
			}
		do
			t.ok(Sounds.find(name) ~= nil, `{name} is a sound`)
		end
		for _, name in { "entity.creeper.primed", "entity.skeleton.shoot", "entity.arrow.hit", "entity.spider.hurt" } do
			t.eq(Sounds.find(name), nil, `{name} went with its monster`)
		end
		t.eq(#Blocks.SOUND_TYPES, 14, "no new block sound type")
		for _, name in
			{
				"asphalt",
				"cracked asphalt",
				"road line",
				"road line yellow",
				"concrete",
				"cracked concrete",
				"mossy concrete",
				"cracked bricks",
				"mossy bricks",
				"rusty metal",
				"supply crate side",
				"supply crate top",
				"medicine cabinet side",
				"medicine cabinet top",
				"bunker hatch",
			}
		do
			t.ok(Blocks.textureOf(name) ~= nil, `the texture {name}`)
		end
		for index, name in BLOCKS do
			local def = Blocks.get(418 + index)
			local item = def.item or name
			if def.placeable ~= false and not Blocks.isCaveTwin(418 + index) then
				t.ok(LoreList[item] ~= nil, `{item}'s lore`)
			end
		end
		for _, name in ITEMS do
			local lore = LoreList[name]
			t.ok(lore ~= nil and #lore <= 90, `{name}'s lore, at most 90 characters`)
		end
		t.ok(string.find(LoreList.Bone, "Zombies", 1, true) ~= nil, "bones: the zombies' now")
		t.ok(string.find(LoreList.FeralClaws, "ruins", 1, true) ~= nil, "Feral Claws: found in ruins")
	end)

	t.test("apocalypse: how long a zombie takes to break each block, and the hatch's toggle", function()
		local expect: { [number]: { string } } = {
			[60] = { "Glass" },
			[120] = { "OakLeaves", "BirchLeaves", "SpruceLeaves", "AcaciaLeaves", "JungleLeaves", "WhiteWool" },
			[300] = {
				"Dirt",
				"Grass",
				"DryGrass",
				"CoarseDirt",
				"Podzol",
				"Mycelium",
				"Sand",
				"Gravel",
				"Snow",
				"MossBlock",
				"PackedMud",
				"OakFence",
				"CaveOakFence",
			},
			[600] = { "Planks", "OakLog", "BirchLog", "SpruceLog", "AcaciaLog", "JungleLog" },
			[900] = { "Barricade", "BarricadeNorthSouth" },
			[2400] = {
				"Stone",
				"Cobblestone",
				"MossyCobblestone",
				"StoneBricks",
				"CrackedStoneBricks",
				"SmoothStone",
				"Brick",
				"CrackedBricks",
				"MossyBricks",
				"Sandstone",
				"CutSandstone",
				"SmoothSandstone",
				"Asphalt",
				"CrackedAsphalt",
				"RoadLine",
				"RoadLineYellow",
			},
			[3000] = { "ReinforcedBarricade", "ReinforcedBarricadeNorthSouth" },
			[6000] = { "Concrete", "CrackedConcrete", "MossyConcrete" },
		}
		for ticks, names in expect do
			for _, name in names do
				t.eq(Blocks.zombieBreak(B[name]), ticks, `{name}: {ticks} ticks`)
			end
		end
		-- Every wooden door half (open and shut), and every fence variant with its arms.
		local doors, fences = 0, 0
		for id = 0, Blocks.count - 1 do
			local name = Blocks.get(id).name
			if string.find(name, "Door", 1, true) then
				doors += 1
				t.eq(Blocks.zombieBreak(id), 240, `{name}: a door's 240`)
			elseif string.find(name, "Fence", 1, true) then
				fences += 1
				t.eq(Blocks.zombieBreak(id), 300, `{name}: a fence's 300`)
			end
		end
		-- (And the seasons' Insulated Door's.)
		t.eq(doors, 192, "six doors' 32 halves")
		t.eq(fences, 17, "the fence's 16 and its cave twin")
		-- Never: ores, metal, obsidian, machines, containers, the hatch, lights, plants, fluids.
		for _, name in
			{
				"IronOre",
				"Obsidian",
				"Chest",
				"Furnace",
				"SupplyCrate",
				"MedicineCabinet",
				"RustyMetal",
				"BunkerHatch",
				"BunkerHatchOpen",
				"CeilingLamp",
				"CaveCeilingLamp",
				"Torch",
				"Water",
				"Bedrock",
			}
		do
			t.eq(Blocks.zombieBreak(B[name]), 0, `{name}: never`)
		end
		t.eq(Blocks.zombieBreak(Blocks.AIR), 0)
		t.eq(buffer.len(Blocks.zombieBreakLut), Blocks.count * 2, "a u16 a block")
		-- The hatch: a use swaps it shut <-> open, each with its sound; nothing else toggles.
		local open, sound = Toggles.use(B.BunkerHatch)
		t.eq(open, B.BunkerHatchOpen)
		t.eq(sound, "block.bunker_hatch.open")
		local shut, closing = Toggles.use(B.BunkerHatchOpen)
		t.eq(shut, B.BunkerHatch)
		t.eq(closing, "block.bunker_hatch.close")
		t.eq(Blocks.toggleOf(B.BunkerHatch), B.BunkerHatchOpen)
		t.eq((Toggles.use(B.Stone)), nil, "stone doesn't toggle")
		t.eq((Toggles.use(-1)), nil, "nor a bad id")
		t.eq((Toggles.use(B.OakDoor)), nil, "doors are DoorUse's")
		t.eq(Blocks.get(B.BunkerHatch).menu, "Toggle")
		t.eq(Blocks.get(B.BunkerHatchOpen).menu, "Toggle")
		t.eq(Blocks.get(B.SupplyCrate).container, 27, "a crate holds a chest's 27")
		t.eq(Blocks.get(B.MedicineCabinet).menu, "Chest")
		t.eq(Blocks.light(B.CeilingLamp), 14)
		-- The north-south barricades are the same item, never placed themselves.
		t.eq(Items.drops(B.BarricadeNorthSouth) and (Items.drops(B.BarricadeNorthSouth) :: any).item, I.Barricade)
		t.eq(table.find(Blocks.placeable, B.BarricadeNorthSouth), nil, "turned by placing, not placed")
		t.eq(table.find(Blocks.placeable, B.BunkerHatchOpen), nil)
		t.ok(table.find(Blocks.placeable, B.Barricade) ~= nil)
		local scrap = Items.drops(B.RustyMetal, I.IronPickaxe) :: any
		t.eq(scrap and scrap.item, I.ScrapMetal, "rusty metal breaks into scrap")
		t.eq(scrap and scrap.count, 3)
	end)

	--[[ The zombies ]]

	t.test("apocalypse: the zombie kinds, their looks, drops, knowledge and sounds", function()
		t.eq(MobList.COUNT, 14, "four animals, ten zombies")
		for index, name in ZOMBIES do
			local id = MobList.find(name) :: number
			t.eq(id, 4 + index, `{name}'s id`)
			t.ok(MobList.isZombie(id), `{name} is a zombie`)
			t.eq(MobList.find(MobList.snake(name)), id, `{MobList.snake(name)} finds {name}`)
		end
		t.eq(MobList.find("zombie_brute"), MobList.find("ZombieBrute"))
		t.eq(MobList.snake("ZombieBrute"), "zombie_brute")
		t.eq(MobList.snake("Zombie"), "zombie")
		t.ok(not MobList.isZombie(MobList.find("Cow") :: number), "a cow isn't")
		for _, gone in { "Creeper", "Skeleton", "Spider" } do
			t.eq(MobList.find(gone), nil, `no {gone}`)
		end
		for _, kind in MobList.kinds do
			-- Drops resolve to items, every kind is priced and makes real sounds.
			for _, drop in kind.kindDrops do
				t.ok(Items.get(drop.item) ~= nil, `{kind.name} drops a real item`)
			end
			t.ok(Knowledge.MOBS[kind.name] ~= nil, `{kind.name} has its knowledge`)
			t.ok(Sounds.find(kind.sounds.hurt) ~= nil and Sounds.find(kind.sounds.death) ~= nil, `{kind.name}'s sounds`)
			if MobList.isZombie(kind) then
				local looks = MobList.looksOf(kind) :: { MobList.Look }
				t.ok(looks ~= nil and #looks >= 1, `{kind.name} has looks`)
				t.ok(kind.rig ~= nil and kind.rig.kind == "R15", `{kind.name} has an R15 rig`)
				-- Every look and skin round trips through a variant (a u8).
				for index, look in looks do
					local extras = (if look.vest then 1 else 0)
						+ (if look.stripes then 1 else 0)
						+ (if look.hat then 1 else 0)
					t.ok(extras <= MobList.MAX_EXTRAS, `{kind.name}'s {look.name}: at most 2 of vest, stripes, hat`)
					for skin = 1, #MobList.SKIN_TONES do
						local variant = MobList.lookVariant(index, skin)
						t.ok(variant >= 1 and variant <= 255, "a u8")
						local back, tone = MobList.look(kind, variant)
						t.eq(back, look, `{kind.name} variant {variant}: its look`)
						t.eq(tone, MobList.SKIN_TONES[skin], `{kind.name} variant {variant}: its skin`)
					end
				end
				-- Random variants are always one of them.
				local random = lcg(kind.id)
				for _ = 1, 300 do
					local variant = MobList.randomVariant(kind, random)
					local look = MobList.look(kind, variant)
					local index = (variant - 1) // 8 + 1
					local skin = (variant - 1) % 8 + 1
					t.ok(index >= 1 and index <= #looks and skin >= 1 and skin <= #MobList.SKIN_TONES, "in range")
					t.eq(look, looks[index])
				end
			end
		end
		t.eq(Knowledge.MOBS.ZombieBrute, 10)
		t.eq(Knowledge.MOBS.ZombieCrawler, 4)
		t.eq(Knowledge.MOBS.ZombieSoldier, 8)
		-- The crawler wears the Zombie's clothes.
		local crawler = MobList.get(MobList.find("ZombieCrawler") :: number) :: MobList.Kind
		t.eq(MobList.looksOf(crawler), (MobList.get(MobList.find("Zombie") :: number) :: MobList.Kind).looks)
		-- A bone now and then from every zombie (bones' old source, the skeleton, is gone).
		for _, name in ZOMBIES do
			local kind = MobList.get(MobList.find(name) :: number) :: MobList.Kind
			local bone = false
			for _, drop in kind.kindDrops do
				bone = bone or drop.item == I.Bone
			end
			t.ok(bone, `{name} may drop a bone`)
		end
	end)

	--[[ The wire ]]

	t.test("apocalypse: the Mobs ops' sizes and flags, the move op, the Survivor message", function()
		local flag = Protocol.MobFlag
		t.eq(flag.Aggressive, 8)
		t.eq(flag.Attack, 16)
		t.eq(flag.Breaking, 32)
		t.eq(flag.Screaming, 64)
		local function size(op: Protocol.MobOp): number
			return buffer.len(Protocol.encodeMobs({ op })) - 2
		end
		t.eq(
			size({ op = "spawn", id = 1, kind = 5, variant = 9, x = 0, y = 0, z = 0, yaw = 0, health = 20, flags = 0 }),
			5 + 17
		)
		t.eq(size({ op = "state", id = 1, x = 0, y = 0, z = 0, yaw = 0, health = 20, flags = 0 }), 5 + 15)
		t.eq(size({ op = "move", id = 1, dx = 0, dy = 0, dz = 0, yaw = 0, health = 20, flags = 0 }), 14)
		t.eq(size({ op = "remove", id = 1 }), 5)
		t.eq(size({ op = "push", id = 1, kx = 0, ky = 0, kz = 0 }), 5 + 12)
		-- Sixty zombies moving: under 1 KB a sync.
		local moves = {}
		for id = 1, 60 do
			table.insert(moves, { op = "move", id = id, dx = 0.1, dy = 0, dz = -0.2, yaw = 1, health = 20, flags = 8 })
		end
		t.ok(buffer.len(Protocol.encodeMobs(moves)) < 1024, "60 moves under 1 KB")
		-- The move's deltas at the i16 limit round trip; op 4 is malformed.
		local limit = Protocol.MOB_DELTA_LIMIT / Protocol.MOB_POSITION_SCALE
		local decoded = Protocol.decodeMobs(
			Protocol.encodeMobs({
				{ op = "move", id = 3, dx = limit, dy = -limit, dz = 1 / 32, yaw = 0, health = 5, flags = 32 },
			}),
			MobList.COUNT
		) :: { any }
		t.eq(decoded[1].dx, limit)
		t.eq(decoded[1].dy, -limit)
		t.eq(decoded[1].dz, 1 / 32)
		t.eq(decoded[1].flags, 32)
		local arrow = buffer.create(2 + 5 + 24)
		buffer.writeu16(arrow, 0, 1)
		buffer.writeu8(arrow, 2, 4)
		t.eq(Protocol.decodeMobs(arrow, MobList.COUNT), nil, "op 4 is retired")
		-- Survivor: 8 bytes, clamped.
		t.eq(Protocol.ServerMessage.Survivor, 32)
		local survivor = Protocol.decodeSurvivor(Protocol.encodeSurvivor(123456, 42, 3)) :: Protocol.Survivor
		t.eq(survivor.alive, 123456)
		t.eq(survivor.kills, 42)
		t.eq(survivor.moons, 3)
		local clamped = Protocol.decodeSurvivor(Protocol.encodeSurvivor(-5, 70000, 1.7)) :: Protocol.Survivor
		t.eq(clamped.alive, 0)
		t.eq(clamped.kills, 65535)
		t.eq(clamped.moons, 1)
		t.eq(Protocol.decodeSurvivor(buffer.create(7)), nil, "a wrong length")
		t.eq(Protocol.decodeSurvivor(buffer.create(9)), nil)
	end)

	--[[ The blood moon and the noise ]]

	t.test("apocalypse: blood moons every third night, ramping in and out", function()
		local s = Config.Apocalypse.BloodMoon
		t.eq(s.First, 3)
		t.eq(s.Every, 3)
		for day = 0, 9 do
			local blood = day == 2 or day == 5 or day == 8
			t.eq(BloodMoon.isBloodDay(day, s), blood, `day {day}`)
		end
		t.eq(BloodMoon.number(2, s), 1)
		t.eq(BloodMoon.number(5, s), 2)
		t.eq(BloodMoon.number(8, s), 3)
		t.eq(BloodMoon.number(3, s), 0)
		local night = 2 * DAY
		t.eq(BloodMoon.intensity(night + 6000, s), 0, "noon")
		t.eq(BloodMoon.intensity(night + s.Start, s), 0, "it starts at 0")
		t.near(BloodMoon.intensity(night + s.Start + s.Ramp / 2, s), 0.5, 1e-9, "half way up")
		t.eq(BloodMoon.intensity(night + s.Start + s.Ramp, s), 1, "full")
		t.eq(BloodMoon.intensity(night + 18000, s), 1, "midnight")
		t.near(BloodMoon.intensity(night + s.End - s.Ramp / 2, s), 0.5, 1e-9, "half way down")
		t.eq(BloodMoon.intensity(night + s.End, s), 0, "gone by End")
		t.eq(BloodMoon.intensity(night + s.End + 100, s), 0)
		t.eq(BloodMoon.intensity(DAY + 18000, s), 0, "an ordinary night")
		t.ok(BloodMoon.active(night + 18000, s) and not BloodMoon.active(night + 1000, s))
		t.eq(BloodMoon.daysUntil(0, s), 2, "the first in two days")
		t.eq(BloodMoon.daysUntil(night + 1000, s), 0, "tonight")
		t.eq(BloodMoon.daysUntil(night + 18000, s), 0, "now")
		t.eq(BloodMoon.daysUntil(night + 23900, s), 3, "over: the next in three")
		t.eq(BloodMoon.daysUntil(3 * DAY + 100, s), 2)
		local off = table.clone(s) :: any
		off.Enabled = false
		t.eq(BloodMoon.isBloodDay(2, off), false, "none when off")
		t.eq(BloodMoon.intensity(night + 18000, off), 0)
		t.eq(BloodMoon.daysUntil(0, off), math.huge)
	end)

	t.test("apocalypse: which sounds zombies hear, and how far", function()
		local s = Config.Apocalypse.Noise
		t.eq(NoiseRules.radius("block.stone.break", s), s.Break)
		t.eq(NoiseRules.radius("block.glass.break", s), s.Glass)
		t.eq(NoiseRules.radius("block.wood.place", s), s.Place)
		t.eq(NoiseRules.radius("block.wooden_door.open", s), s.Door)
		t.eq(NoiseRules.radius("block.bunker_hatch.close", s), s.Door)
		t.eq(NoiseRules.radius("block.chest.open", s), s.Container)
		t.eq(NoiseRules.radius("entity.player.attack.strong", s), s.Hit)
		t.eq(NoiseRules.radius("entity.player.hurt", s), s.Hurt)
		t.eq(NoiseRules.radius("block.stone.hit", s), 0, "mining hits are the client's")
		t.eq(NoiseRules.radius("block.stone.step", s), 0)
		t.eq(NoiseRules.radius("entity.zombie.hurt", s), 0, "a zombie's own sounds draw no crowd")
		t.eq(NoiseRules.radius("entity.zombie.break_wooden_door", s), 0)
		t.eq(NoiseRules.radius("entity.cow.death", s), 0)
		t.eq(NoiseRules.radius("weather.rain", s), 0)
		local lut = NoiseRules.lut(Sounds.events :: any, s)
		t.eq(buffer.len(lut), Sounds.count + 1, "a byte an event")
		t.eq(buffer.readu8(lut, Sounds.id["block.glass.break"]), s.Glass)
		t.eq(buffer.readu8(lut, Sounds.id["entity.zombie.ambient"]), 0)
	end)

	t.test("apocalypse: the noise bus merges, caps and hands over each tick's noises", function()
		local s = Config.Apocalypse.Noise
		NoiseBus.take()
		NoiseBus.emit(10, 64, 10, 6)
		NoiseBus.emit(10 + s.Merge - 1, 64, 10, 9)
		NoiseBus.emit(10 + s.Merge + 1, 64, 10, 3)
		NoiseBus.emit(0, 64, 0, 0)
		NoiseBus.emit(0 / 0, 64, 0, 5)
		local heard = NoiseBus.take()
		t.eq(#heard, 2, "the near two merge; nothing for silence or a bad place")
		t.eq(heard[1].radius, 9, "the louder")
		t.eq(heard[2].radius, 3)
		t.eq(#NoiseBus.take(), 0, "taken: the next tick starts empty")
		for i = 1, s.MaxPerTick + 10 do
			NoiseBus.emit(i * 100, 64, 0, 5)
		end
		t.eq(#NoiseBus.take(), s.MaxPerTick, "at most MaxPerTick a tick")
		NoiseBus.explosion(0, 64, 0, 1)
		NoiseBus.explosion(500, 64, 0, 4)
		heard = NoiseBus.take()
		t.eq(heard[1].radius, s.ExplosionBase + s.ExplosionPerPower, "a small blast")
		t.eq(heard[2].radius, s.ExplosionMax, "TNT's, held to the most")
		NoiseBus.fromSound(Sounds.id["block.glass.break"], 0, 64, 0)
		NoiseBus.fromSound(Sounds.id["entity.zombie.hurt"], 100, 64, 0)
		NoiseBus.fromSound(0, 200, 64, 0)
		heard = NoiseBus.take()
		t.eq(#heard, 1, "only the glass")
		t.eq(heard[1].radius, s.Glass)
	end)

	t.test("apocalypse: a sound at a player's feet is a noise even with the game's audio off", function()
		-- (Audio/Sounds never starts in the specs, as with Config.Sounds.Enabled false. The feet
		-- come from a character, through Movement/Rig, which reads Roblox's Vector3: lent here
		-- from Lune's. A root 2 studs tall without a humanoid stands 3 studs over the feet.)
		local BLOCK = Config.BlockSize
		local root: any = {
			Size = roblox.Vector3.new(2, 2, 1),
			CFrame = roblox.CFrame.new(),
			Position = roblox.Vector3.new(10.5 * BLOCK, 64 * BLOCK + 3, -20.5 * BLOCK),
		}
		function root.IsA(_, class: string): boolean
			return class == "BasePart"
		end
		local character = {
			FindFirstChild = function(_, name: string)
				return if name == "HumanoidRootPart" then root else nil
			end,
			FindFirstChildOfClass = function()
				return nil
			end,
		}
		local lent = Vector3
		Vector3 = roblox.Vector3
		NoiseBus.take()
		local ok, problem = pcall(function()
			ServerSounds.playAt({ Character = character } :: any, "entity.player.hurt")
			ServerSounds.playAt({ Character = nil } :: any, "block.glass.break")
			ServerSounds.playAt({ Character = character } :: any, nil)
		end)
		Vector3 = lent
		t.ok(ok, `played: {problem}`)
		local heard = NoiseBus.take()
		t.eq(#heard, 1, "the hurt player only: no noise without a position or a sound")
		t.eq(heard[1].radius, Config.Apocalypse.Noise.Hurt, "a hurt's radius")
		local noise = heard[1]
		t.ok(
			math.abs(noise.x - 10.5) < 1e-3 and math.abs(noise.y - 64) < 1e-3 and math.abs(noise.z + 20.5) < 1e-3,
			`at the feet ({noise.x}, {noise.y}, {noise.z})`
		)
	end)

	--[[ Loot, weapons, recipes ]]

	t.test("apocalypse: the ruins' and bunkers' loot is real, fixed by place and fits a chest", function()
		local names = {}
		for name, pools in ScavengeLoot.TABLES do
			table.insert(names, name)
			for _, pool in pools do
				for _, entry in pool.entries do
					if entry[1] then
						t.ok(Items.find(entry[1]) ~= nil, `{name}: {entry[1]} is an item`)
						t.ok(entry[3] >= 1 and entry[4] >= entry[3], `{name}: {entry[1]}'s counts`)
					end
				end
			end
		end
		table.sort(names)
		t.eq(
			table.concat(names, " "),
			"bunker_armory bunker_generator bunker_medical bunker_storage car fire_station grocery hardware house medicine_cabinet office pharmacy police",
			"the frozen table names"
		)
		for _, name in names do
			for i = 1, 60 do
				local items = ScavengeLoot.roll(name, 777, i * 13, 40, -i * 7)
				local again = ScavengeLoot.roll(name, 777, i * 13, 40, -i * 7)
				t.eq(#items, #again, "the same place: the same loot")
				t.ok(#items <= ScavengeLoot.SLOTS, "at most 27 stacks")
				local used = {}
				for k, item in items do
					t.eq(item.item, again[k].item)
					t.eq(item.count, again[k].count)
					t.eq(item.slot, again[k].slot)
					t.ok(item.slot >= 1 and item.slot <= 27 and not used[item.slot], "a free slot each")
					used[item.slot] = true
					t.ok(item.count >= 1 and item.count <= Items.maxStack(Items.find(item.item) :: number), "a stack")
				end
			end
		end
		t.eq(#ScavengeLoot.roll("nothing", 1, 0, 0, 0), 0, "an unknown table holds nothing")
		-- The pharmacy always has something (2-4 rolls).
		local found = 0
		for i = 1, 20 do
			found += #ScavengeLoot.roll("pharmacy", 5, i, 0, 0)
		end
		t.ok(found >= 20, `pharmacies are stocked ({found} stacks in 20)`)
	end)

	t.test("apocalypse: bats wear, blades and tools cut, the new recipes craft and smelt", function()
		t.eq(Combat.wear(I.BaseballBat), 1, "a bat wears with each hit")
		t.eq(Combat.wear(I.SpikedBat), 1)
		t.eq(Combat.wear(I.Machete), 1, "a sword-like tool too")
		t.eq((Items.drops(B.Cobweb, I.Machete) :: any).item, I.String, "a machete cuts string from cobwebs")
		local damage = Combat.attackOf(I.FireAxe)
		t.eq(damage, 9, "the fire axe hits 9")
		-- A 3 x 3 grid from { [slot] = item name }.
		local function made(cells: { [number]: string }): Items.Stack?
			local grid = {}
			for slot, name in cells do
				grid[slot] = { item = Items.id[name], count = 1 }
			end
			return Crafting.match(grid, 3)
		end
		local function check(cells: { [number]: string }, result: string, count: number?)
			local stack = made(cells)
			t.eq(stack and stack.item, Items.id[result], result)
			t.eq(stack and stack.count, count or 1, `{result} count`)
		end
		check({ [1] = "WhiteWool" }, "Rag", 3)
		check({ "Rag", "Rag" }, "Bandage", 2)
		check({ "Bandage", "Bandage", "Painkillers", "DuctTape" }, "Medkit")
		check({ "MintLeaves", "GingerRoot", "Rag" }, "HerbalPoultice")
		check({ "IronNugget", "IronNugget" }, "Nails", 4)
		check({ [1] = "Planks", [2] = "Planks", [3] = "Planks", [5] = "Nails" }, "Barricade", 4)
		check({ [1] = "BirchPlanks", [2] = "Planks", [3] = "SprucePlanks", [5] = "Nails" }, "Barricade", 4)
		check({ "Barricade", "ScrapMetal", "ScrapMetal", "Nails" }, "ReinforcedBarricade")
		check({ [2] = "OakLog", [5] = "BirchLog", [8] = "Stick" }, "BaseballBat")
		check({ "BaseballBat", "Nails", "Nails", "Nails" }, "SpikedBat")
		check({ [3] = "IronIngot", [5] = "IronIngot", [7] = "Stick" }, "Machete")
		check({ [1] = "IronIngot", [2] = "IronIngot", [5] = "IronIngot", [8] = "IronIngot" }, "Crowbar")
		check({
			[1] = "Stick",
			[2] = "Planks",
			[3] = "Stick",
			[4] = "Planks",
			[6] = "Planks",
			[7] = "Stick",
			[8] = "Planks",
			[9] = "Stick",
		}, "SupplyCrate")
		check({ [2] = "IronNugget", [4] = "IronNugget", [5] = "GlowDust", [6] = "IronNugget" }, "CeilingLamp", 2)
		check({ [1] = "IronIngot", [2] = "IronIngot", [4] = "IronIngot", [5] = "IronIngot" }, "BunkerHatch")
		check({ [1] = "Gravel", [2] = "Sand", [4] = "Sand", [5] = "Gravel" }, "Concrete", 4)
		check({ "Concrete", "Vine" }, "MossyConcrete")
		check({ "Brick", "Vine" }, "MossyBricks")
		t.eq((Smelting.result(B.Concrete) :: any).item, B.CrackedConcrete)
		t.eq((Smelting.result(B.Brick) :: any).item, B.CrackedBricks)
		t.eq((Smelting.result(I.ScrapMetal) :: any).item, I.IronNugget)
		-- Found only: no recipe makes these.
		local made: { [number]: boolean } = {}
		for _, recipe in Crafting.recipes do
			made[recipe.result] = true
		end
		for _, recipe in Smelting.recipes() do
			made[recipe.result.item] = true
		end
		for _, name in
			{
				"Asphalt",
				"CrackedAsphalt",
				"RoadLine",
				"RoadLineYellow",
				"RustyMetal",
				"MedicineCabinet",
				"Antibiotics",
				"Painkillers",
				"DuctTape",
				"CannedBeans",
				"CannedPeaches",
				"Crackers",
				"ChocolateBar",
				"MilitaryRation",
				"BottledWater",
				"SodaCan",
				"FireAxe",
			}
		do
			t.ok(not made[Items.id[name]], `{name} is found, never made`)
		end
		-- The Ages gate results: iron things wait for the Iron Age, concrete for the Industrial.
		local iron = (Ages.byId("iron") :: any).index
		local industrial = (Ages.byId("industrial") :: any).index
		for _, name in
			{ "Nails", "ReinforcedBarricade", "SpikedBat", "Machete", "Crowbar", "CeilingLamp", "BunkerHatch" }
		do
			t.eq(Ages.ofName(name), iron, `{name}: the Iron Age`)
		end
		for _, name in { "Concrete", "CrackedConcrete", "MossyConcrete" } do
			t.eq(Ages.ofName(name), industrial, `{name}: the Industrial Age`)
		end
		for _, name in
			{
				"Rag",
				"Bandage",
				"Medkit",
				"HerbalPoultice",
				"Barricade",
				"BaseballBat",
				"SupplyCrate",
				"MossyBricks",
				"CrackedBricks",
			}
		do
			t.eq(Ages.ofName(name), 1, `{name}: open from the start`)
		end
	end)

	t.test("apocalypse: what the creepers, skeletons and spiders dropped is still found", function()
		local function inLoot(item: string): boolean
			for _, pools in ScavengeLoot.TABLES do
				for _, pool in pools do
					for _, entry in pool.entries do
						if entry[1] == item then
							return true
						end
					end
				end
			end
			return false
		end
		local crafted: { [number]: boolean } = {}
		for _, recipe in Crafting.recipes do
			crafted[recipe.result] = true
		end
		t.ok(crafted[I.Gunpowder] and inLoot("Gunpowder"), "gunpowder: crafted, and in the ruins")
		t.eq((Items.drops(B.Cobweb, I.IronSword) :: any).item, I.String, "string: from cobwebs")
		t.ok(inLoot("String"), "and in the ruins")
		t.ok(inLoot("Bone"), "bones: in the ruins (and from zombies)")
		t.ok(inLoot("FeralClaws"), "Feral Claws: in the ruins and bunkers")
	end)

	--[[ Generation's hooks ]]

	t.test("apocalypse: /locate kinds, POI types and the no-op cities and bunkers", function()
		t.ok(table.find(Locate.STRUCTURES, "city") ~= nil, "/locate structure city")
		t.ok(table.find(Locate.STRUCTURES, "bunker") ~= nil, "/locate structure bunker")
		t.eq(table.concat(Locate.STRUCTURE_TAGS.ruins, " "), "city bunker", "#ruins")
		t.eq(Config.Locate.Radius.city, 24576)
		t.eq(Config.Locate.Radius.bunker, 6144)
		t.eq(Poi.of(B.SupplyCrate), "supply_crate")
		t.eq(Poi.of(B.MedicineCabinet), "medicine_cabinet")
		t.eq(Poi.of(B.BunkerHatch), "bunker_hatch")
		t.eq(Poi.of(B.BunkerHatchOpen), "bunker_hatch", "open or shut")
		local tags = Poi.tags()
		t.eq(table.concat(tags.scavenge, " "), "chest supply_crate medicine_cabinet")
		t.ok(
			table.find(tags.container, "supply_crate") ~= nil and table.find(tags.container, "medicine_cabinet") ~= nil
		)
		-- No cities: the raw relief, natural ground, nothing blocked, the spawn where it was.
		local raw = Relief.new(42)
		local none = Cities.none(raw)
		t.eq(none.relief, raw)
		t.eq((none.surface(10, 10, 70, 0)), nil)
		t.eq(#none.blocked(-1000, -1000, 1000, 1000), 0)
		t.eq(none.protects(0, 0), false)
		t.eq(none.treeAllowed(0, 0), true)
		t.eq(none.cityAt(0, 0), 0)
		local sx, sz = none.spawnShift(12, -7, function()
			return true
		end)
		t.eq(sx, 12)
		t.eq(sz, -7)
		t.eq((none.locateKind().probe(0, 0)), nil, "/locate finds no city")
		t.eq(none.locateKind().id, "city")
		local noBunkers = Bunkers.none()
		t.eq(#noBunkers.plans(-1000, -1000, 1000, 1000), 0)
		t.eq(noBunkers.locateKind().id, "bunker")
		t.eq((noBunkers.locateKind().probe(0, 0)), nil)
		-- With Ruins on the generator has cities (Generation/Cities: tests/spec/Cities); off it has
		-- none, and away from them (nothing `blocked` there) both generate the same.
		local on = TerrainGenerator.new(42)
		local off = TerrainGenerator.new(42, { ruins = false })
		t.ok(on.prepare ~= nil and off.prepare == nil, "only Ruins on has the cities' caches")
		t.ok(#(on.cities :: any)(-8192, -8192, 8192, 8192) > 0, "city sites with Ruins on")
		t.eq(#(off.cities :: any)(-8192, -8192, 8192, 8192), 0, "none with Ruins off")
		local a, b = on.generate(0, 3, -2), off.generate(0, 3, -2)
		t.ok(buffer.tostring(a.data) == buffer.tostring(b.data), "the same chunk")
		for i = 0, 7 do
			local h1, _, _, top1 = on.column(i * 97, -i * 61)
			local h2, _, _, top2 = off.column(i * 97, -i * 61)
			t.eq(h1, h2)
			t.eq(top1, top2)
		end
	end)

	--[[ The Ruins world setting ]]

	t.test("apocalypse: Ruins is a world setting; worlds saved before it read it as off", function()
		for _, id in { "default", "singleBiome", "largeBiomes" } do
			local worldType = WorldTypes.get(id) :: any
			local ruins = false
			for _, setting in worldType.settings do
				if setting.key == WorldTypes.RUINS then
					ruins = setting.default == true
				end
			end
			t.ok(ruins, `{id} has Ruins, on by default`)
		end
		local function settings(options: { [string]: any }): any
			return {
				name = "Ruins",
				gameMode = GameMode.SURVIVAL,
				difficulty = 2,
				allowCommands = false,
				worldType = "default",
				options = options,
				seed = 1234,
			}
		end
		local function reread(meta: any): any
			return (WorldMeta.settings(WorldMeta.read(WorldMeta.stored(meta)) :: any) :: any).options
		end
		t.eq(reread(WorldMeta.new("w0000aaaa", settings({ structures = true, ruins = true }), 1)).ruins, true)
		t.eq(reread(WorldMeta.new("w0000aaab", settings({ structures = true, ruins = false }), 1)).ruins, false)
		-- (Config.Cities.OldWorlds false: a world from before has no key and keeps its ground.)
		t.eq(Config.Cities.OldWorlds, false)
		t.eq(reread(WorldMeta.new("w0000aaac", settings({ structures = true }), 1)).ruins, false, "an old world")
	end)
end
