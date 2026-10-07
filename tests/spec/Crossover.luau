--[[
	Crossover: where the mobs (server Mobs/*, Shared/Entities/*), the status effects
	(Shared/Effects, server Players/Effects) and progression (Shared/Progression) meet, the glue
	the boot scripts wire: a player's Strength and Weakness on their hits on mobs and Resistance on
	the mobs' hits on them, the mining speed both the effects and the perks change
	(Mining.playerFactor, the client's and the server's), the knowledge a kill gives, and the Age
	every item the mobs and the potions brought belongs to.
]]

return function(t, shared, require, server)
	local Blocks = require(shared.Blocks)
	local Items = require(shared.Items)
	local GameMode = require(shared.GameMode)
	local Mining = require(shared.Mining)
	local Effects = require(shared.Effects)
	local PotionList = require(shared.Effects.PotionList)
	local MobList = require(shared.Entities.MobList)
	local Progression = require(shared.Progression)
	local Ages = require(shared.Progression.Ages)
	local Knowledge = require(shared.Progression.Knowledge)
	local Crafting = require(shared.Crafting)
	local MobWorld = require(server.Mobs.MobWorld)

	local I = Items.id
	local E = Effects.id
	local FLOOR = 20

	-- Stone below FLOOR, air above.
	local function getBlock(_x: number, y: number, _z: number): number?
		return if y < FLOOR then Blocks.id.Stone else Blocks.AIR
	end

	local function newWorld()
		local seed = 7
		return MobWorld.new(getBlock, {
			maxMobs = 50,
			forgetTicks = 6000,
			random = function(): number
				seed = (seed * 1103515245 + 12345) % 2147483648
				return seed / 2147483648
			end,
		})
	end

	-- A survival player at (x, FLOOR, 0.5) swinging `item` fully recovered, with `levels`.
	local function swing(x: number, item: number?, levels: Effects.Levels?): MobWorld.Attacker
		return {
			key = "p",
			x = x,
			y = FLOOR,
			z = 0.5,
			eye = 1.62,
			mode = GameMode.SURVIVAL,
			alive = true,
			item = item,
			ticks = 100,
			levels = levels,
		}
	end

	local ZOMBIE = MobList.find("Zombie") :: number
	local ZOMBIE_ARMOR = (MobList.get(ZOMBIE) :: any).armor

	t.test("crossover: Strength and Weakness change a player's hits on mobs, before the strength", function()
		-- (A fresh world and zombie each time: no hurt cooldown in the way.)
		local function hit(item: number?, levels: Effects.Levels?, ticks: number?): number
			local world = newWorld()
			local id = world:spawn(ZOMBIE, -3.5, FLOOR, 0.5)
			local attacker = swing(-5.5, item, levels)
			attacker.ticks = ticks or 100
			return (world:attack(id, attacker)) :: number
		end
		t.near(hit(I.DiamondSword), Items.damageAfterArmor(7, ZOMBIE_ARMOR, 0), 1e-9, "no effects: the sword's 7")
		t.near(
			hit(I.DiamondSword, { [E.Strength] = 1 }),
			Items.damageAfterArmor(7 + 6, ZOMBIE_ARMOR, 0),
			1e-9,
			"Strength II: +3 a level"
		)
		t.near(
			hit(I.DiamondSword, { [E.Weakness] = 0 }),
			Items.damageAfterArmor(7 - 4, ZOMBIE_ARMOR, 0),
			1e-9,
			"Weakness: -4"
		)
		t.eq(hit(nil, { [E.Weakness] = 0 }), 0, "a weak fist does nothing (Minecraft's: never below 0)")
		-- The attack strength scales the modified damage, as Minecraft's attack_damage attribute.
		local Combat = require(shared.Entities.Combat)
		local _, speed = Combat.attackOf(I.DiamondSword)
		t.near(
			hit(I.DiamondSword, { [E.Strength] = 0 }, 0),
			Items.damageAfterArmor(Combat.damage(7 + 3, Combat.strength(0, speed)), ZOMBIE_ARMOR, 0),
			1e-9,
			"a weak swing scales the Strength damage too"
		)
		-- And a mob's hit on a player: the server's Characters.hurt cuts it by Resistance after armor.
		t.near(Effects.incomingDamage(3, { [E.Resistance] = 0 }), 2.4, 1e-9, "a zombie's 3 under Resistance I")
		t.eq(Effects.incomingDamage(3, { [E.Resistance] = 4 }), 0, "Resistance V: nothing")
	end)

	t.test("crossover: mining speed is the effects' times the perks' (Mining.playerFactor)", function()
		local quarrier = Progression.new()
		quarrier.skills.quarrying = true
		local haste = { [E.Haste] = 1 }
		t.near(Mining.playerFactor(nil, nil, I.StonePickaxe), 1, 1e-12, "nothing: 1")
		t.near(Mining.playerFactor(haste, nil, I.StonePickaxe), 1.4, 1e-12, "Haste II alone (progression off)")
		t.near(Mining.playerFactor(nil, quarrier, I.StonePickaxe), 1.1, 1e-12, "Quarrying alone")
		t.near(Mining.playerFactor(haste, quarrier, I.StonePickaxe), 1.4 * 1.1, 1e-12, "both, multiplied")
		t.near(Mining.playerFactor(haste, quarrier, I.IronPickaxe), 1.4, 1e-12, "Quarrying is for stone tools")
		local fatigue = { [E.MiningFatigue] = 0 }
		t.near(Mining.playerFactor(fatigue, quarrier, I.StonePickaxe), 0.3 * 1.1, 1e-12, "Mining Fatigue too")
		-- What the client predicts and the server checks with: the same ticks.
		local stone = Blocks.id.Stone
		local plain = Mining.ticks(stone, true, false, I.StonePickaxe)
		local fast =
			Mining.ticks(stone, true, false, I.StonePickaxe, Mining.playerFactor(haste, quarrier, I.StonePickaxe))
		t.ok(fast < plain, `faster: {fast} < {plain} ticks`)
		local elapsed = (fast - 1) / Mining.TICK_RATE
		t.ok(
			Mining.mayBreak(stone, elapsed, 1, I.StonePickaxe, Mining.playerFactor(haste, quarrier, I.StonePickaxe)),
			"the server accepts the client's faster break"
		)
		t.ok(not Mining.mayBreak(stone, elapsed, 1, I.StonePickaxe), "which it would not without the factor")
	end)

	t.test("crossover: a mob a player kills is knowledge (every kind priced, the first a discovery)", function()
		for _, kind in MobList.kinds do
			t.ok(Knowledge.MOBS[kind.name] ~= nil, `{kind.name} has its knowledge`)
			t.eq(Knowledge.MOBS[kind.name], if kind.hostile then (if kind.name == "Creeper" then 6 else 5) else 2)
		end
		local state, session = Progression.new(), Knowledge.newSession()
		local budget = 20
		t.eq(Progression.killed(state, session, "Cow", 0, budget), 10 + 2, "the first cow: discovery and 2")
		t.eq(Progression.killed(state, session, "Cow", 0, budget), 1, "the second: 2 x 0.75, the half carried")
		t.near(session.fraction, 0.5, 1e-9)
		t.eq(Progression.killed(state, session, "Creeper", 0, budget), 10 + 6, "a creeper: 6")
		t.eq(state.found.mob and state.found.mob.Creeper, true, "the kind is discovered")
		-- The mobs' meat smelts for Minecraft's 0.35 a piece.
		t.eq(Knowledge.smeltPoints("CookedBeef"), 0.35)
	end)

	t.test("crossover: every item the mobs and the potions brought has its Age", function()
		-- The mobs' drops and what is made of them: the Stone Age (open from the start).
		for _, name in
			{
				"Leather",
				"RawBeef",
				"CookedBeef",
				"RawMutton",
				"CookedMutton",
				"RawPorkchop",
				"CookedPorkchop",
				"RawChicken",
				"CookedChicken",
				"Feather",
				"RottenFlesh",
				"Bone",
				"String",
				"WhiteWool",
				"LeatherHelmet",
				"LeatherChestplate",
				"LeatherLeggings",
				"LeatherBoots",
			}
		do
			t.ok(Items.find(name) ~= nil, `{name} is an item`)
			t.eq(Ages.ofName(name), 1, `{name}: the Stone Age`)
		end
		-- Potions: brewing is the Iron Age's, the strong and long ones the Industrial Age's.
		local iron, industrial = Ages.byId("iron") :: Ages.Age, Ages.byId("industrial") :: Ages.Age
		local count = 0
		for _, variant in PotionList.all() do
			count += 1
			local expected = if variant.from == PotionList.BASE then iron.index else industrial.index
			t.eq(Ages.ofName(variant.item), expected, variant.item)
		end
		t.eq(count, 29, "every potion item")
		-- The gate as the windows use it.
		local stone = Progression.new()
		local ironAge = Progression.new()
		ironAge.age = iron.index
		t.ok(Progression.allows(stone, I.CookedBeef), "cooking meat from the start")
		t.ok(Progression.allows(stone, I.WhiteWool), "wool too")
		t.ok(not Progression.allows(stone, I.PotionOfSwiftness), "no brewing in the Stone Age")
		t.ok(Progression.allows(ironAge, I.PotionOfSwiftness), "the Iron Age brews")
		t.ok(not Progression.allows(ironAge, I.StrongPotionOfSwiftness), "but not level II yet")
		t.ok(not Progression.allows(ironAge, I.LongPotionOfSwiftness), "nor the long one")
		t.eq(Progression.lockText(stone, I.PotionOfHealing), "Requires the Iron Age")
		-- (Recipes brew them: the Progression spec checks every name an Age opens is made by one.)
		local brewed =
			Crafting.match({ { item = I.PurifiedWaterBottle, count = 1 }, { item = I.MintLeaves, count = 1 } }, 2)
		t.eq(brewed and brewed.item, I.PotionOfSwiftness, "a potion is a recipe result")
	end)
end
