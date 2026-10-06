--[[
	Tough As Nails' gear for the climate: the Campfire (Minecraft's block, recipe and drops; its
	flames on fire's renderer; a heat source that warms 5 steps within 2 blocks and outweighs the
	snow of a tundra there; standing in it hurts like Minecraft's campfire without setting anyone
	alight), boiling dirty water clean on it (every dirty container, a canteen keeping its sips,
	creative's rule, who may), Straw from grass by hand, Straw and Leaf armor (leather's points, a
	step of warmth or cooling a piece, what full and partial sets do to the coldest and the hottest
	targets, a tundra simulated tick by tick), the Thermometer's recipe, and the new sounds.
]]

return function(t, shared, require, server)
	local Biomes = require(shared.Biomes)
	local Blocks = require(shared.Blocks)
	local Config = require(shared.Config)
	local Crafting = require(shared.Crafting)
	local Fire = require(shared.Fire)
	local GameMode = require(shared.GameMode)
	local Items = require(shared.Items)
	local Sounds = require(shared.Sounds)
	local ToughAsNails = require(shared.ToughAsNails)
	local Burning = require(server.Players.Burning)
	local Climate = require(server.Players.Climate)
	local EditRules = require(server.Network.EditRules)

	local Temperature = ToughAsNails.Temperature
	local Drinks = ToughAsNails.Drinks
	local Boiling = ToughAsNails.Boiling
	local I, B = Items.id, Blocks.id
	local SURVIVAL, CREATIVE, ADVENTURE, SPECTATOR =
		GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.ADVENTURE, GameMode.SPECTATOR
	local ICY, COLD, WARM, HOT = Temperature.ICY, Temperature.COLD, Temperature.WARM, Temperature.HOT
	local NOON, MIDNIGHT = 6000, 18000

	-- The crafting result of a 3 x 3 grid ({ [slot] = item id }).
	local function craft(cells: { [number]: number }): Items.Stack?
		local grid = {}
		for slot, item in cells do
			grid[slot] = { item = item, count = 1 }
		end
		return Crafting.match(grid, 3)
	end

	-- A random that answers `values` in turn.
	local function rolls(values: { number }): () -> number
		local i = 0
		return function(): number
			i += 1
			return values[i]
		end
	end

	local function climate(name: string): number
		return assert(Biomes.byName(name)).temperature
	end

	-- An environment (Temperature.Environment) on plains by day, with `overrides`.
	local function env(overrides: { [string]: any }?): Temperature.Environment
		local base: { [string]: any } = {
			climate = climate("Plains"),
			y = 80,
			surface = 80,
			skyOpen = true,
			night = false,
			wet = false,
			sprinting = false,
			heated = false,
			nearHeat = false,
			cooled = false,
			burning = false,
			armorWarmth = 0,
			armorCooling = 0,
		}
		for key, value in overrides or {} do
			base[key] = value
		end
		return base :: any
	end

	-- The armor slots worn: `material` ("Straw", "Leaf") on the first `pieces` of head, chest,
	-- legs and feet.
	local PIECES = { "Helmet", "Chestplate", "Leggings", "Boots" }
	local function wearing(material: string, pieces: number): { [number]: Items.Stack? }
		local armor: { [number]: Items.Stack? } = {}
		for slot = 1, pieces do
			armor[slot] = { item = I[material .. PIECES[slot]], count = 1 }
		end
		return armor
	end

	--[[ The Campfire ]]

	t.test("campfire: Minecraft's block (shaped, lit, walk-through, axe, strength 2), dropping itself", function()
		local def = Blocks.get(B.Campfire)
		t.eq(Blocks.light(B.Campfire), 15, "light 15")
		t.ok(not def.solid, "walked into, as the hull has full cubes only")
		t.ok(Blocks.obstruction(B.Campfire) ~= nil, "but never placed inside a player")
		t.ok(not Blocks.isSturdy(B.Campfire), "nothing hangs on it")
		t.ok(not Blocks.isFlammable(B.Campfire), "not in FireBlock.bootStrap")
		local outline = assert(Blocks.outline(B.Campfire))
		t.eq(outline[5], 7 / 16, "Minecraft's 7 pixel tall shape")
		t.eq(def.hardness, 2)
		t.eq(def.tool, "axe")
		t.eq(def.blastResistance, 2, "strength 2: hardness and blast resistance")
		t.ok(def.shape ~= nil and #def.shape == 5, "four logs and the embers")
		local glows = 0
		for _, box in def.shape :: { any } do
			if box.glow then
				glows += 1
			end
		end
		t.eq(glows, 1, "the embers carry the light")
		local drop = Items.drops(B.Campfire, nil)
		t.eq(drop and drop.item, I.Campfire, "drops itself (there is no Silk Touch)")
		t.eq(drop and drop.count, 1)
		t.eq((Items.drops(B.Campfire, I.WoodenAxe) :: Items.Stack).item, I.Campfire, "with an axe too")
		t.eq(def.textures, nil, "no texture of its own: shaped boxes")
	end)

	t.test("campfire: its flames are fire's, on Minecraft's two crossed planes", function()
		t.ok(Fire.isFlame(B.Campfire) and Fire.isFlame(B.Fire), "both show flames")
		t.ok(not Fire.isFlame(B.Torch) and not Fire.isFlame(nil))
		local function get(x: number, y: number, z: number): number?
			return if x == 0 and y == 0 and z == 0 then B.Campfire elseif y < 0 then B.Stone else Blocks.AIR
		end
		t.eq(Fire.lookAt(get, 0, 0, 0), Fire.CAMPFIRE_LOOK, "a campfire's look")
		t.eq(Fire.lookAt(get, 1, 0, 0), 0, "fire on stone: the floor's")
		local planes = Fire.planes(Fire.CAMPFIRE_LOOK)
		t.eq(#planes, 2, "two planes")
		for _, plane in planes do
			t.eq(plane.faces, "double", "seen from both sides")
			t.eq(plane.size[2], 16, "16 pixels tall")
			t.near(plane.size[1], 14.4 * math.sqrt(2), 1e-9, "14.4 rescaled across the diagonal")
			t.ok(plane.size[1] < 16 * math.sqrt(2), "inside the cell")
			t.eq(plane.offset[2], 1, "from a pixel above the floor")
			t.eq(math.abs(plane.orientation[2]), 45, "diagonal")
		end
		t.eq(planes[1].orientation[2], -planes[2].orientation[2], "crossing")
	end)

	t.test("campfire: Minecraft's recipe (sticks round a coal or charcoal over three logs)", function()
		local S, L = I.Stick, I.OakLog
		local made = craft({ [2] = S, [4] = S, [5] = I.Coal, [6] = S, [7] = L, [8] = L, [9] = L })
		t.eq(made and made.item, I.Campfire)
		t.eq(made and made.count, 1)
		made = craft({ [2] = S, [4] = S, [5] = I.Charcoal, [6] = S, [7] = I.SpruceLog, [8] = I.BirchLog, [9] = L })
		t.eq(made and made.item, I.Campfire, "charcoal, any logs")
		t.eq(craft({ [2] = S, [4] = S, [6] = S, [7] = L, [8] = L, [9] = L }), nil, "no coal: nothing")
		t.eq(
			craft({ [2] = S, [4] = S, [5] = I.Coal, [6] = S, [7] = I.Planks, [8] = L, [9] = L }),
			nil,
			"logs, not planks"
		)
	end)

	t.test("campfire: a heat source, 5 steps within 2 blocks, and it outweighs the snow there", function()
		t.ok(Climate.isHeating(B.Campfire), "Config.ToughAsNails.HeatingBlocks")
		t.ok(table.find(Config.ToughAsNails.HeatingBlocks, "Campfire") ~= nil)
		-- A tundra: snow underfoot everywhere (a cold source), a campfire at `distance`.
		local function tundraTarget(distance: number?, dayTime: number, armor: { [number]: Items.Stack? }?): number
			local campfire = if distance then { distance, 64, 0 } else nil
			local view = {
				getBlock = function(x: number, y: number, z: number): number?
					if campfire and x == campfire[1] and y == campfire[2] and z == campfire[3] then
						return B.Campfire
					end
					return if y < 64 then B.Snow else Blocks.AIR
				end,
				column = function(_x: number, _z: number): (number, number)
					return 64, assert(Biomes.byName("Tundra")).index
				end,
				skyOpen = function(_x: number, _y: number, _z: number): boolean
					return true
				end,
			}
			local warmth, cooling = Climate.insulation(armor or {})
			local e = Climate.environment(view, 0.5, 64, 0.5, dayTime, {
				wet = false,
				sprinting = false,
				burning = false,
				armorWarmth = warmth,
				armorCooling = cooling,
			})
			return Temperature.target(e)
		end
		t.eq(tundraTarget(nil, NOON), -10, "a tundra by day: icy")
		t.eq(tundraTarget(nil, MIDNIGHT), -10, "and by night (the scale's end)")
		t.eq(tundraTarget(1, MIDNIGHT), -5, "by a campfire at night: +5, the snow no longer cools")
		t.eq(Temperature.zone(tundraTarget(2, MIDNIGHT)), COLD, "2 blocks away: out of the ice")
		t.eq(tundraTarget(4, MIDNIGHT), -10, "4 blocks away: +3 against the snow's -3")
		t.eq(tundraTarget(1, NOON, wearing("Straw", 4)), -1, "a straw set by the fire: neutral")
		-- On plains (no cold around) a campfire in range warms 3, close 5.
		t.eq(Temperature.target(env({ heated = true })), 3)
		t.eq(Temperature.target(env({ heated = true, nearHeat = true })), 5)
		t.eq(Temperature.target(env({ heated = true, cooled = true })), 0, "farther than 2: they cancel")
		t.eq(Temperature.target(env({ heated = true, nearHeat = true, cooled = true })), 5, "within 2: the fire wins")
	end)

	t.test("campfire: standing in it hurts like Minecraft's (half a heart, cooldown, armor), no burning", function()
		local function get(x: number, y: number, z: number): number?
			return if x == 0 and y == 0 and z == 0 then B.Campfire elseif y < 0 then B.Stone else Blocks.AIR
		end
		local touching = Burning.touchingAt(get, 0.5, 0, 0.5, 0.6, 1.8)
		t.ok(bit32.btest(touching, Burning.CAMPFIRE), "standing in a campfire")
		t.ok(not bit32.btest(touching, Burning.FIRE), "which is no fire block")
		t.eq(Burning.touchingAt(get, 0.5, 1, 0.5, 0.6, 1.8), 0, "above it")
		t.ok(bit32.btest(Burning.touchingAt(get, 1.25, 0, 0.5, 0.6, 1.8), Burning.CAMPFIRE), "the box reaches in")
		local state = Burning.newPlayer()
		local total, hurts = 0, 0
		for _ = 1, 100 do
			local damage = Burning.tickPlayer(state, SURVIVAL, touching)
			total += damage
			if damage > 0 then
				hurts += 1
			end
		end
		t.eq(total, 10, "half a heart every 10 ticks (the hurt cooldown): 5 hearts in 5 s")
		t.eq(hurts, 10)
		t.ok(not Burning.onFire(state), "a campfire sets nobody alight")
		t.eq(state.heat, 0, "nor counts towards catching fire")
		-- Armor softens it (leather-like points, as straw's 7).
		local soft = Burning.newPlayer()
		local damage = Burning.tickPlayer(soft, SURVIVAL, touching, 7, 0)
		t.ok(damage > 0 and damage < 1, `armor softens it ({damage})`)
		t.eq((Burning.tickPlayer(Burning.newPlayer(), CREATIVE, touching)), 0, "creative: nothing")
		-- Dropped items lie in it unharmed (its entityInside hurts living entities only).
		local item = Burning.newItem()
		for _ = 1, 40 do
			t.eq((Burning.tickItem(item, touching)), false)
		end
		t.eq(item.health, Burning.ITEM_HEALTH, "an item in a campfire is not hurt")
		t.eq(item.fire, 0)
	end)

	--[[ Boiling ]]

	t.test("boiling: dirty water on a campfire, the campfire's own use (who and what)", function()
		local bottle = { item = I.DirtyWaterBottle, count = 3 }
		t.ok(Boiling.applies(B.Campfire, bottle, SURVIVAL, false), "survival")
		t.ok(Boiling.applies(B.Campfire, bottle, ADVENTURE, false), "adventure too (CampfireBlock.use)")
		t.ok(Boiling.applies(B.Campfire, bottle, CREATIVE, false), "creative")
		t.ok(not Boiling.applies(B.Campfire, bottle, SPECTATOR, false), "never spectators")
		t.ok(not Boiling.applies(B.Campfire, bottle, SURVIVAL, true), "not sneaking (secondary use)")
		t.ok(not Boiling.applies(B.Furnace, bottle, SURVIVAL, false), "a campfire only")
		t.ok(not Boiling.applies(nil, bottle, SURVIVAL, false), "an unknown block")
		t.ok(not Boiling.applies(B.Campfire, nil, SURVIVAL, false), "an empty hand")
		for _, item in { I.PurifiedWaterBottle, I.GlassBottle, I.PurifiedWaterCanteen, I.Canteen, I.Stick } do
			t.ok(not Boiling.boils({ item = item, count = 1 }), `{Items.get(item).name} doesn't boil`)
		end
		for dirty, purified in Drinks.PURIFIED_OF do
			t.ok(Boiling.boils({ item = dirty, count = 1 }), `{Items.get(dirty).name} boils`)
			local held = Boiling.boil({ item = dirty, count = 1 }, false, function()
				return false
			end)
			t.eq(held and held.item, purified, `{Items.get(dirty).name} boils into its purified twin`)
		end
		t.ok(Sounds.find(Boiling.SOUND) ~= nil, "its sound is an event")
		t.eq(Sounds.get(Boiling.SOUND).side, "server")
	end)

	t.test("boiling: one container a click (createFilledResult), a canteen keeps its sips", function()
		local never = function(_item: number): boolean
			return false
		end
		-- A stack of bottles: one boiled, into the inventory.
		local held, give = Boiling.boil({ item = I.DirtyWaterBottle, count = 3 }, false, never)
		t.eq(held and held.item, I.DirtyWaterBottle)
		t.eq(held and held.count, 2, "one used up")
		t.eq(give and give.item, I.PurifiedWaterBottle, "the purified one goes into the inventory")
		t.eq(give and give.count, 1)
		-- The last one is replaced.
		held, give = Boiling.boil({ item = I.DirtyWaterBottle, count = 1 }, false, never)
		t.eq(held and held.item, I.PurifiedWaterBottle, "the last one: replaced")
		t.eq(held and held.count, 1)
		t.eq(give, nil)
		-- Canteens keep the sips drunk.
		held, give = Boiling.boil({ item = I.DirtyWaterCanteen, count = 1, damage = 2 }, false, never)
		t.eq(held and held.item, I.PurifiedWaterCanteen)
		t.eq(held and held.damage, 2, "two sips drunk stay drunk")
		t.eq(Drinks.sips(held), 1, "one sip left")
		t.eq(give, nil)
		held = Boiling.boil({ item = I.DirtyWaterCanteen, count = 1 }, false, never)
		t.eq(held and held.damage, nil, "a full one stays full")
		t.eq(Drinks.sips(held), 3)
		-- Creative: keeps the dirty one, gets a purified one only without one.
		local stack = { item = I.DirtyWaterBottle, count = 1 }
		held, give = Boiling.boil(stack, true, never)
		t.eq(held, stack, "creative keeps it")
		t.eq(give and give.item, I.PurifiedWaterBottle)
		held, give = Boiling.boil(stack, true, function(item: number): boolean
			return item == I.PurifiedWaterBottle
		end)
		t.eq(held, stack)
		t.eq(give, nil, "and has one already")
		-- Anything else comes back as it was.
		local purified = { item = I.PurifiedWaterBottle, count = 4 }
		held, give = Boiling.boil(purified, false, never)
		t.eq(held, purified)
		t.eq(give, nil)
	end)

	--[[ Straw ]]

	t.test("straw: grass broken without Shears gives Straw now and then; Shears the grass", function()
		local function strawOf(block: number, roll: number): number?
			local stack = Items.strawDrop(block, rolls({ roll }))
			return if stack then stack.item else nil
		end
		t.eq(strawOf(B.ShortGrass, 0.49), I.Straw, "short grass: half the time")
		t.eq(strawOf(B.ShortGrass, 0.5), nil)
		t.eq(strawOf(B.TallGrass, 0.999), I.Straw, "tall grass: always")
		t.eq(strawOf(B.Fern, 0), nil, "not ferns")
		t.eq(strawOf(B.Stone, 0), nil)
		t.eq((Items.strawDrop(B.TallGrass, rolls({ 0 })) :: Items.Stack).count, 1, "one")
		-- What a survival player breaking them gets (EditRules.drops).
		local byHand = EditRules.drops(B.TallGrass, false, nil)
		t.eq(byHand and byHand.item, I.Straw, "tall grass by hand")
		local withSword = EditRules.drops(B.TallGrass, false, I.IronSword)
		t.eq(withSword and withSword.item, I.Straw, "or any tool but Shears")
		local sheared = EditRules.drops(B.ShortGrass, false, I.Shears)
		t.eq(sheared and sheared.item, I.ShortGrass, "Shears harvest the grass itself")
		t.eq(EditRules.drops(B.TallGrass, true, nil), nil, "creative: nothing")
		-- Over many breaks, short grass gives about half.
		local got = 0
		for _ = 1, 2000 do
			local stack = EditRules.drops(B.ShortGrass, false, nil)
			if stack and stack.item == I.Straw then
				got += 1
			end
		end
		t.ok(got > 850 and got < 1150, `about half of 2000 ({got})`)
	end)

	--[[ Straw and Leaf armor ]]

	t.test("armor: Straw and Leaf, leather's points, a step of warmth or cooling a piece", function()
		for i, piece in PIECES do
			for _, material in { "Straw", "Leaf" } do
				local id = I[material .. piece]
				local def = assert(Items.get(id))
				t.eq(Items.armorSlot(id), i, `{def.name} slot`)
				t.eq(def.armor and def.armor.defense, ({ 1, 3, 2, 1 })[i], `{def.name}: leather's points`)
				t.eq(def.armor and def.armor.toughness, 0)
				t.eq(Items.maxStack(id), 1)
				local tan = assert(def.tan)
				t.eq(tan.warmth, if material == "Straw" then 1 else 0, `{def.name} warmth`)
				t.eq(tan.cooling, if material == "Leaf" then 1 else 0, `{def.name} cooling`)
				t.ok(not tan.freezeImmune, `{def.name} is not freeze immune (leather is)`)
				t.eq(Sounds.armorEquip(id), Sounds.find("item.armor.equip_leather"), `{def.name} sounds like leather`)
			end
		end
		t.eq(Items.get(I.StrawHelmet).displayName, "Straw Helmet")
		t.eq(Items.armorPoints(wearing("Straw", 4)), 7, "a full set: 7 points, as leather")
		local warmth, cooling, immune = Climate.insulation(wearing("Straw", 4))
		t.eq(warmth, 4)
		t.eq(cooling, 0)
		t.ok(not immune)
		warmth, cooling = Climate.insulation(wearing("Leaf", 4))
		t.eq(warmth, 0)
		t.eq(cooling, 4)
	end)

	t.test("armor: recipes from Straw and any leaves, in the armor shapes", function()
		local S, L = I.Straw, I.OakLeaves
		t.eq((craft({ S, S, S, S, nil :: any, S }) :: Items.Stack).item, I.StrawHelmet)
		t.eq((craft({ S, nil :: any, S, S, S, S, S, S, S }) :: Items.Stack).item, I.StrawChestplate, "8 straw")
		t.eq((craft({ S, S, S, S, nil :: any, S, S, nil :: any, S }) :: Items.Stack).item, I.StrawLeggings)
		t.eq((craft({ S, nil :: any, S, S, nil :: any, S }) :: Items.Stack).item, I.StrawBoots)
		local mixed = craft({ L, I.SpruceLeaves, I.JungleLeaves, I.BirchLeaves, nil :: any, I.AcaciaLeaves })
		t.eq(mixed and mixed.item, I.LeafHelmet, "any leaves, mixed")
		t.eq((craft({ L, nil :: any, L, L, L, L, L, L, L }) :: Items.Stack).item, I.LeafChestplate)
		t.eq((craft({ L, L, L, L, nil :: any, L, L, nil :: any, L }) :: Items.Stack).item, I.LeafLeggings)
		t.eq((craft({ L, nil :: any, L, L, nil :: any, L }) :: Items.Stack).item, I.LeafBoots)
		t.eq(
			craft({ I.ShortGrass, I.ShortGrass, I.ShortGrass, I.ShortGrass, nil :: any, I.ShortGrass }),
			nil,
			"grass is no straw"
		)
	end)

	t.test("armor: a straw set keeps a tundra out of ICY, day and night; leaves a desert out of HOT", function()
		local function tundra(night: boolean, pieces: number, overrides: { [string]: any }?): number
			local warmth = Climate.insulation(wearing("Straw", pieces))
			local e = env({ climate = climate("Tundra"), night = night, armorWarmth = warmth })
			for key, value in overrides or {} do
				(e :: any)[key] = value
			end
			return Temperature.target(e)
		end
		t.eq(tundra(false, 0), -10, "a tundra by day, nothing worn: icy")
		t.eq(tundra(false, 4), -6, "a full straw set by day: -6")
		t.eq(Temperature.zone(tundra(false, 4)), COLD, "out of ICY")
		t.eq(tundra(true, 4), -6, "by night too (the scale stops at -10)")
		t.eq(tundra(true, 4, { wet = true, cooled = true }), -6, "wet on snow: still -6")
		t.eq(Temperature.zone(tundra(false, 3)), COLD, "three pieces: -7, just")
		t.eq(Temperature.zone(tundra(false, 2)), ICY, "two pieces: not enough")
		local taiga = env({ climate = climate("Taiga"), night = true, armorWarmth = 4 })
		t.eq(Temperature.target(taiga), -5, "a taiga's night (-9) with a set: -5")
		t.eq(
			Temperature.target(env({ climate = climate("Desert"), armorWarmth = 4 })),
			9,
			"straw does nothing in the heat"
		)

		local function desert(pieces: number, overrides: { [string]: any }?): number
			local _, cooling = Climate.insulation(wearing("Leaf", pieces))
			local e = env({ climate = climate("Desert"), armorCooling = cooling })
			for key, value in overrides or {} do
				(e :: any)[key] = value
			end
			return Temperature.target(e)
		end
		t.eq(Temperature.zone(desert(0)), HOT, "a desert by day: hot")
		t.eq(desert(4), 5, "a full leaf set: 5")
		t.eq(Temperature.zone(desert(4)), WARM, "out of HOT")
		t.eq(desert(4, { sprinting = true, heated = true, nearHeat = true }), 6, "the hottest target (10): 6")
		t.eq(Temperature.zone(desert(1)), HOT, "one piece: 8, still hot")
		t.eq(Temperature.zone(desert(2)), WARM, "two pieces: 7")
		t.eq(
			Temperature.target(env({ climate = climate("Tundra"), armorCooling = 4 })),
			-10,
			"leaves do nothing in the cold"
		)
	end)

	t.test("armor: ten minutes in a tundra in a straw set, tick by tick: never frozen", function()
		local warmth = Climate.insulation(wearing("Straw", 4))
		local state = Temperature.new()
		local hurt = 0
		for tick = 1, 12000 do
			if tick % 20 == 1 then
				local night = tick > 6000
				state.target =
					Temperature.target(env({ climate = climate("Tundra"), night = night, armorWarmth = warmth }), state)
			end
			hurt += Temperature.tick(state, SURVIVAL)
		end
		t.eq(state.value, -6, "settled at -6")
		t.eq(state.frozen, 0, "never icy")
		t.eq(hurt, 0, "never hurt")
		-- Without it: icy within a minute, frozen 20 s later.
		local bare = Temperature.new()
		local bareHurt = 0
		for _ = 1, 12000 do
			bare.target = Temperature.target(env({ climate = climate("Tundra") }), bare)
			bareHurt += Temperature.tick(bare, SURVIVAL)
		end
		t.ok(bareHurt > 0, "nothing worn: it hurts")
	end)

	--[[ The Thermometer ]]

	t.test("thermometer: an iron nugget over glass over glow dust; an item that doesn't stack", function()
		local made = craft({ [2] = I.IronNugget, [5] = I.Glass, [8] = I.GlowDust })
		t.eq(made and made.item, I.Thermometer)
		t.eq(made and made.count, 1)
		made = craft({ [1] = I.IronNugget, [4] = I.Glass, [7] = I.GlowDust })
		t.eq(made and made.item, I.Thermometer, "anywhere in the grid")
		t.eq(craft({ [2] = I.IronNugget, [5] = I.Glass, [8] = I.Coal }), nil, "glow dust, the game's redstone")
		t.eq(Items.maxStack(I.Thermometer), 1)
		t.eq(Items.get(I.Thermometer).armor, nil, "held, not worn")
		t.ok(#(Items.get(I.Thermometer).model :: { any }) > 0, "a model")
		t.ok(#(Items.get(I.Straw).model :: { any }) > 0)
	end)
end
