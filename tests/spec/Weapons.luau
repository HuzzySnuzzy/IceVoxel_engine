--[[
	Weapons in the manner of DayZ (Shared/Weapons; the weapons design's FOUNDATION): the 34 items
	in their ids, the registry (Weapons/WeaponList through Shared/Weapons' checks), lore and icons,
	the 22 sounds, the four key bindings, Config.Weapons, the codecs (Net/WeaponSync's Fire, Weapon
	and Shots, Protocol's weapon action and Attack's heavy flag), the weapon state in item data
	(Weapons/WeaponState: clamping, firing, the HUD's detail, the icons' count, the look),
	Inventory/Menu's `fire` action against the client's prediction and the server's
	Players/InventoryState.fire, a bash never wearing a gun, the HANDS line, the heavy Attack's
	wiring, the two recipes and the crossbow bolt's Age.
]]

return function(t, shared, require, server, client)
	local Items = require(shared.Items)
	local Weapons = require(shared.Weapons)
	local WeaponList = require(shared.Weapons.WeaponList)
	local WeaponState = require(shared.Weapons.WeaponState)
	local LoreList = require(shared.Items.LoreList)
	local TexturePack = require(shared.TexturePack)
	local Sounds = require(shared.Sounds)
	local NoiseRules = require(shared.Apocalypse.NoiseRules)
	local KeyBindings = require(shared.KeyBindings)
	local PlayerSettings = require(shared.PlayerSettings)
	local Config = require(shared.Config)
	local Protocol = require(shared.Net.Protocol)
	local WeaponSync = require(shared.Net.WeaponSync)
	local Types = require(shared.Inventory.Types)
	local Menu = require(shared.Inventory.Menu)
	local Combat = require(shared.Entities.Combat)
	local Crafting = require(shared.Crafting)
	local Ages = require(shared.Progression.Ages)
	local GameMode = require(shared.GameMode)
	local Blocks = require(shared.Blocks)
	local MobList = require(shared.Entities.MobList)
	local Prediction = require(client.Inventory.Prediction)
	local Theme = require(client.Ui.Theme)
	local InventoryState = require(server.Players.InventoryState)
	local MobWorld = require(server.Mobs.MobWorld)

	local I = Items.id
	local SURVIVAL, CREATIVE, SPECTATOR = GameMode.SURVIVAL, GameMode.CREATIVE, GameMode.SPECTATOR

	-- The 34 items, in id order (4278..4311).
	local NAMES = {
		"Pistol",
		"Revolver",
		"Smg",
		"PumpShotgun",
		"DoubleBarrelShotgun",
		"BoltActionRifle",
		"SemiAutoRifle",
		"AssaultRifle",
		"HuntingRifle",
		"SmallBoreRifle",
		"Crossbow",
		"PistolMagazine",
		"SmgMagazine",
		"RifleMagazine",
		"HuntingMagazine",
		"SmallBoreMagazine",
		"Rounds9mm",
		"Rounds357",
		"Buckshot",
		"Slugs",
		"Rounds22",
		"Rounds556",
		"Rounds762",
		"Rounds308",
		"CrossbowBolt",
		"RedDotSight",
		"RifleScope",
		"Suppressor",
		"ImprovisedSuppressor",
		"WeaponFlashlight",
		"KitchenKnife",
		"HuntingKnife",
		"PipeWrench",
		"Sledgehammer",
	}

	-- A stack of `item` with weapon data `data` (cleaned) and wear `damage`.
	local function stack(item: number, data: { [string]: any }?, damage: number?): Items.Stack
		return { item = item, count = 1, damage = damage, data = Items.cleanData(data) }
	end

	-- A loaded pistol: a round chambered, a magazine with `n` rounds.
	local function pistol(n: number, extra: { [string]: any }?): Items.Stack
		local data: { [string]: any } = { ch = I.Rounds9mm, mag = I.PistolMagazine }
		if n > 0 then
			data.n, data.ammo = n, I.Rounds9mm
		end
		for key, value in extra or {} do
			data[key] = value
		end
		return stack(I.Pistol, data)
	end

	--[[ Items ]]

	t.test("weapons: the 34 items in ids 4278..4311, appended after the apocalypse's", function()
		t.eq(#NAMES, 34)
		for index, name in NAMES do
			t.eq(I[name], 4277 + index, `{name}'s id`)
		end
		t.eq(I.HerbalPoultice, 4277, "the apocalypse's last item before them")
		t.eq(Items.list[#Items.list].name, "Sledgehammer", "the last item")
		local names = {
			Pistol = "9mm Pistol",
			Smg = "SMG",
			DoubleBarrelShotgun = "Double-Barrel Shotgun",
			BoltActionRifle = "Bolt-Action Rifle",
			SmallBoreMagazine = ".22 Magazine",
			Rounds556 = "5.56 Rounds",
			Buckshot = "12 Gauge Buckshot",
			RifleMagazine = "Assault Rifle Magazine",
			CrossbowBolt = "Crossbow Bolt",
			WeaponFlashlight = "Weapon Flashlight",
		}
		for name, text in names do
			t.eq(Items.displayName(I[name]), text, `{name}'s name`)
		end
		local stacks = {
			Rounds9mm = 60,
			Rounds357 = 40,
			Buckshot = 30,
			Slugs = 30,
			Rounds22 = 64,
			Rounds556 = 60,
			Rounds762 = 40,
			Rounds308 = 40,
			CrossbowBolt = 16,
			RedDotSight = 1,
			RifleScope = 1,
			WeaponFlashlight = 1,
		}
		for name, max in stacks do
			t.eq(Items.maxStack(I[name]), max, `{name} stacks to {max}`)
		end
		for _, name in { "Pistol", "AssaultRifle", "PistolMagazine", "Suppressor", "KitchenKnife" } do
			t.eq(Items.maxStack(I[name]), 1, `{name} stacks to 1`)
		end
		local durability = {
			Pistol = 1500,
			Revolver = 1500,
			Smg = 2000,
			PumpShotgun = 800,
			DoubleBarrelShotgun = 600,
			BoltActionRifle = 1200,
			SemiAutoRifle = 1500,
			AssaultRifle = 2500,
			HuntingRifle = 1200,
			SmallBoreRifle = 2500,
			Crossbow = 600,
			PistolMagazine = 1500,
			SmgMagazine = 2000,
			RifleMagazine = 2500,
			HuntingMagazine = 1200,
			SmallBoreMagazine = 2500,
			Suppressor = 400,
			ImprovisedSuppressor = 40,
			KitchenKnife = 100,
			HuntingKnife = 250,
			PipeWrench = 300,
			Sledgehammer = 300,
		}
		for name, uses in durability do
			t.eq((Items.get(I[name]) :: any).durability, uses, `{name}'s durability`)
		end
		for _, name in { "RedDotSight", "RifleScope", "WeaponFlashlight", "Rounds9mm" } do
			t.eq((Items.get(I[name]) :: any).durability, nil, `{name} doesn't wear`)
		end
		-- The bash of a lowered gun, and the melee weapons' light attacks.
		local bash = { Pistol = 3, Smg = 3, PumpShotgun = 4, AssaultRifle = 4, SmallBoreRifle = 3, Crossbow = 3 }
		for name, damage in bash do
			t.eq((Combat.attackOf(I[name])), damage, `{name}'s bash`)
		end
		t.eq(select(2, Combat.attackOf(I.KitchenKnife)), 2.0, "a knife's speed")
		t.eq((Combat.attackOf(I.Sledgehammer)), 8)
		t.eq((Items.tool(I.KitchenKnife) :: any).kind, "sword")
		t.eq((Items.tool(I.Sledgehammer) :: any).kind, "pickaxe")
		t.eq(Items.tool(I.PipeWrench), nil, "a wrench is no tool")
		-- Handguns lie flat, long guns tilt up, melee weapons like tools.
		t.eq((Items.get(I.Pistol) :: any).tilt, 0)
		t.eq((Items.get(I.AssaultRifle) :: any).tilt, 30)
		t.eq((Items.get(I.Sledgehammer) :: any).tilt, -45)
		for _, name in NAMES do
			local def = Items.get(I[name]) :: any
			t.ok(def.model and #def.model >= 1, `{name} has a model`)
		end
	end)

	t.test("weapons: every new item has lore and a blank icon", function()
		for _, name in NAMES do
			local lore = LoreList[name]
			t.ok(type(lore) == "string" and lore ~= "" and #lore <= 90, `{name}'s lore`)
			t.eq(TexturePack.Icons[name], "", `{name}'s icon is blank until made`)
			t.eq(Items.icon(I[name]), nil, `{name} draws its model`)
		end
	end)

	--[[ The registry ]]

	t.test("weapons: the registry lists every weapon in item order with its numbers", function()
		t.eq(#Weapons.FIREARMS, 11)
		t.eq(#Weapons.MAGAZINES, 5)
		t.eq(#Weapons.AMMO, 9)
		t.eq(#Weapons.ATTACHMENTS, 5)
		t.eq(#Weapons.MELEE, 9)
		for _, list in { Weapons.FIREARMS, Weapons.MAGAZINES, Weapons.AMMO, Weapons.ATTACHMENTS, Weapons.MELEE } do
			for i = 2, #list do
				t.ok(list[i - 1] < list[i], "item order")
			end
			t.ok(table.isfrozen(list), "frozen")
		end
		t.eq(Weapons.FIREARMS[1], I.Pistol)
		t.eq(Weapons.FIREARMS[11], I.Crossbow)
		for name in WeaponList.firearms do
			t.ok(Weapons.firearm(I[name]), `{name} is a firearm`)
		end
		for name in WeaponList.ammo do
			t.ok(Weapons.ammo(I[name]), `{name} is ammunition`)
		end
		for name in WeaponList.magazines do
			t.ok(Weapons.magazine(I[name]), `{name} is a magazine`)
		end
		for name in WeaponList.attachments do
			t.ok(Weapons.attachment(I[name]), `{name} is an attachment`)
		end
		for name in WeaponList.melee do
			t.ok(Weapons.melee(I[name]), `{name} is a melee weapon`)
		end
		for _, other in { I.Stick, I.IronSword, I.Bandage } do
			t.eq(Weapons.firearm(other), nil)
			t.eq(Weapons.ammo(other), nil)
			t.eq(Weapons.magazine(other), nil)
			t.eq(Weapons.attachment(other), nil)
			t.eq(Weapons.melee(other), nil)
		end
		t.eq(Weapons.firearm(nil), nil, "nil asks nothing")
	end)

	t.test("weapons: every gun's feed, calibre, mounts, attachments, modes and look agree", function()
		for _, item in Weapons.FIREARMS do
			local spec = Weapons.firearm(item) :: Weapons.FirearmSpec
			local def = Items.get(item) :: any
			t.ok(def.durability and def.durability > 0 and def.maxStack == 1 and def.attack, `{spec.name}'s item`)
			t.ok(#Weapons.ammoFor(spec.calibre) >= 1, `{spec.name} has ammunition`)
			for _, round in Weapons.ammoFor(spec.calibre) do
				t.ok(Weapons.takes(item, round), `{spec.name} takes its calibre`)
			end
			if spec.magazine then
				local mag = Weapons.magazine(spec.magazine) :: Weapons.MagazineSpec
				t.eq(mag.calibre, spec.calibre, `{spec.name}'s magazine's calibre`)
				t.ok(table.find(mag.fits, item) ~= nil, `{spec.name}'s magazine fits it`)
				t.eq(WeaponState.capacity(item), mag.capacity, `{spec.name}'s capacity is its magazine's`)
				t.ok(spec.reloadTicks > 0 and spec.chamberTicks > 0, `{spec.name}'s reload`)
			else
				t.eq(WeaponState.capacity(item), spec.internal, `{spec.name}'s internal magazine`)
				t.ok(spec.roundTicks > 0, `{spec.name} loads a round at a time`)
			end
			for _, mode in spec.modes do
				t.ok(mode.rpm > 0 and (mode.kind == "semi" or mode.kind == "auto"), `{spec.name}'s modes`)
			end
			t.eq(spec.modes[1].kind, "semi", `{spec.name} starts on single shots`)
			for _, part in spec.fits do
				local attachment = Weapons.attachment(part) :: Weapons.AttachmentSpec
				t.ok(spec.mounts[attachment.slot], `{spec.name} has a {attachment.slot} mount`)
				t.ok(Weapons.fits(part, item), "fits both ways")
			end
			t.ok(Sounds.find(spec.sound) ~= nil, `{spec.name}'s fire sound {spec.sound}`)
			t.ok(#spec.look.grip >= 2 and #spec.look.muzzle >= 2, `{spec.name}'s look`)
			t.ok(table.isfrozen(spec), "frozen")
		end
		for _, item in Weapons.ATTACHMENTS do
			local attachment = Weapons.attachment(item) :: Weapons.AttachmentSpec
			for _, gun in attachment.fits do
				local spec = Weapons.firearm(gun) :: Weapons.FirearmSpec
				t.ok(spec.mounts[attachment.slot], `{attachment.name} fits {spec.name}'s {attachment.slot} mount`)
				t.ok(table.find(spec.fits, item) ~= nil, `{spec.name} lists {attachment.name}`)
			end
		end
		for _, item in Weapons.MAGAZINES do
			local mag = Weapons.magazine(item) :: Weapons.MagazineSpec
			t.ok(mag.capacity > 0, `{mag.name}'s capacity`)
			t.eq(WeaponState.capacity(item), mag.capacity)
		end
		-- The design's numbers.
		local revolver = Weapons.firearm(I.Revolver) :: Weapons.FirearmSpec
		t.eq(revolver.internal, 5, "five and the chamber: six")
		t.eq(revolver.jams, false)
		t.eq((Weapons.firearm(I.Crossbow) :: Weapons.FirearmSpec).internal, 0, "a crossbow holds its chamber only")
		t.eq((Weapons.firearm(I.Crossbow) :: Weapons.FirearmSpec).sound, "item.crossbow.fire")
		t.eq((Weapons.firearm(I.Pistol) :: Weapons.FirearmSpec).sound, "item.firearm.pistol.fire")
		local hunting = Weapons.firearm(I.HuntingRifle) :: Weapons.FirearmSpec
		t.eq(hunting.scope, 4, "a built-in x4 scope")
		t.eq(hunting.mounts.optic, false, "and no optic mount")
		local smg = Weapons.firearm(I.Smg) :: Weapons.FirearmSpec
		t.eq(#smg.modes, 2)
		t.eq(smg.modes[2].kind, "auto")
		t.eq(smg.modes[2].rpm, 700)
		t.eq((Weapons.firearm(I.PumpShotgun) :: Weapons.FirearmSpec).cycle, true, "a pump cycles")
		t.eq((Weapons.firearm(I.Pistol) :: Weapons.FirearmSpec).cycle, false)
		t.eq(WeaponState.capacity(I.Pistol), 15)
		t.eq(WeaponState.capacity(I.AssaultRifle), 30)
		t.eq(WeaponState.capacity(I.Stick), 0)
		local buckshot = Weapons.ammo(I.Buckshot) :: Weapons.AmmoSpec
		t.eq(buckshot.pellets, 8)
		t.eq(buckshot.cone, 3.5)
		t.eq((Weapons.ammo(I.CrossbowBolt) :: Weapons.AmmoSpec).recover, true, "a switch (the chance: BoltRecover)")
		t.eq((Weapons.ammo(I.Rounds9mm) :: Weapons.AmmoSpec).recover, false)
		local suppressor = Weapons.attachment(I.Suppressor) :: Weapons.AttachmentSpec
		t.eq(suppressor.noise, 0.25)
		t.eq(suppressor.spread, 0.9)
		t.eq(suppressor.suppressed, true)
		t.eq(suppressor.glow, false)
		local improvised = Weapons.attachment(I.ImprovisedSuppressor) :: Weapons.AttachmentSpec
		t.eq(improvised.noise, 0.45)
		t.eq(improvised.spread, 1)
		t.eq(improvised.glow, true)
		t.eq((Weapons.attachment(I.RifleScope) :: Weapons.AttachmentSpec).zoom, 4)
		t.eq(((Weapons.attachment(I.WeaponFlashlight) :: Weapons.AttachmentSpec).beam :: any).range, 24)
		local knife = Weapons.melee(I.KitchenKnife) :: Weapons.MeleeSpec
		t.eq(knife.heavy, 7)
		t.eq(knife.finisher, true)
		t.eq((Weapons.melee(I.FireAxe) :: Weapons.MeleeSpec).heavy, 16)
		t.eq((Weapons.melee(I.Sledgehammer) :: Weapons.MeleeSpec).guard, 0.7)
	end)

	t.test("weapons: calibres, fits and the condition levels", function()
		t.ok(Weapons.takes(I.Pistol, I.Rounds9mm))
		t.ok(Weapons.takes(I.Smg, I.Rounds9mm), "one calibre, two guns")
		t.ok(Weapons.takes(I.PistolMagazine, I.Rounds9mm), "magazines take their calibre")
		t.ok(Weapons.takes(I.PumpShotgun, I.Slugs) and Weapons.takes(I.PumpShotgun, I.Buckshot))
		t.ok(not Weapons.takes(I.Pistol, I.Rounds357), "another calibre")
		t.ok(not Weapons.takes(I.RifleMagazine, I.Rounds762))
		t.ok(not Weapons.takes(I.Rounds9mm, I.Rounds9mm), "a round takes nothing")
		t.ok(not Weapons.takes(I.Pistol, I.Stick))
		t.ok(not Weapons.takes(nil, I.Rounds9mm))
		t.eq(table.concat(Weapons.ammoFor("12g"), ","), `{I.Buckshot},{I.Slugs}`)
		t.eq(table.concat(Weapons.ammoFor("762"), ","), `{I.Rounds762}`)
		t.eq(#Weapons.ammoFor("nope"), 0)
		t.ok(Weapons.fits(I.Suppressor, I.Pistol))
		t.ok(not Weapons.fits(I.Suppressor, I.BoltActionRifle), "a suppressor doesn't fit the bolt-action")
		t.ok(Weapons.fits(I.ImprovisedSuppressor, I.BoltActionRifle), "a bottle does")
		t.ok(not Weapons.fits(I.RedDotSight, I.HuntingRifle), "a scoped rifle takes no optic")
		t.ok(Weapons.fits(I.WeaponFlashlight, I.PumpShotgun))
		t.ok(not Weapons.fits(I.WeaponFlashlight, I.Revolver))
		t.ok(not Weapons.fits(I.Pistol, I.Pistol), "a gun is no attachment")
		t.ok(not Weapons.fits(nil, I.Pistol))
		t.eq(Weapons.level(1), 1)
		t.eq(Weapons.level(0.81), 1)
		t.eq(Weapons.level(0.8), 2, "Theme's levels: above 0.8 is Pristine")
		t.eq(Weapons.level(0.6), 3)
		t.eq(Weapons.level(0.41), 3)
		t.eq(Weapons.level(0.21), 4)
		t.eq(Weapons.level(0.2), 5, "0.2 and less is Ruined")
		t.eq(Weapons.level(0), 5)
		for index, above in Weapons.CONDITIONS do
			t.eq(Theme.CONDITIONS[index].above, above, `level {index}'s bound is Theme's`)
		end
		t.eq(Theme.CONDITIONS[Weapons.RUINED].name, "Ruined")
	end)

	--[[ Sounds, key bindings, Config ]]

	t.test("weapons: the 22 sound events, after the eating and drinking loops", function()
		local SIDES = {
			["item.firearm.pistol.fire"] = "client",
			["item.firearm.revolver.fire"] = "client",
			["item.firearm.smg.fire"] = "client",
			["item.firearm.shotgun.fire"] = "client",
			["item.firearm.rifle.fire"] = "client",
			["item.firearm.heavy.fire"] = "client",
			["item.firearm.small.fire"] = "client",
			["item.crossbow.fire"] = "client",
			["item.firearm.suppressed"] = "client",
			["item.firearm.far"] = "client",
			["item.firearm.dry"] = "client",
			["item.firearm.jam"] = "client",
			["item.firearm.reload"] = "predicted",
			["item.firearm.load_round"] = "predicted",
			["item.firearm.chamber"] = "predicted",
			["item.firearm.unload"] = "client",
			["item.firearm.attach"] = "client",
			["entity.bullet.impact"] = "client",
			["entity.bullet.flesh"] = "client",
			["item.melee.swing"] = "client",
			["item.melee.heavy"] = "client",
			["item.melee.block"] = "server",
		}
		local count = 0
		local first = Sounds.id["entity.generic.drinking"] + 1
		for name, side in SIDES do
			count += 1
			local event = Sounds.get(name)
			t.ok(event ~= nil, `{name} exists`)
			t.eq(event.side, side, `{name}'s side`)
			t.eq(event.source, "players", `{name}'s source`)
			local index = Sounds.id[name]
			t.ok(index >= first and index < first + 22, `{name} is among the weapons' (after the rest)`)
			t.eq(NoiseRules.radius(name, Config.Apocalypse.Noise), 0, `{name} is no noise of NoiseRules'`)
		end
		t.eq(count, 22)
		t.eq(Sounds.count, first + 21, "the weapons' are the last events")
		t.eq(Sounds.get("item.firearm.rifle.fire").category, "item.firearm.fire", "a Sound replaces every class")
		t.eq(Sounds.get("item.firearm.heavy.fire").maxDistance, 224)
		t.eq(Sounds.get("item.firearm.far").maxDistance, 256)
		for _, item in Weapons.FIREARMS do
			t.ok(Sounds.find((Weapons.firearm(item) :: Weapons.FirearmSpec).sound), "every gun's fire sound")
		end
	end)

	t.test("weapons: the reload, fire mode, light and sights keys, settings 161..164, no conflicts", function()
		local KEYS = {
			{ "reload", "Reload / Clear Jam", "R" },
			{ "fireMode", "Fire Mode", "F" },
			{ "weaponLight", "Weapon Light", "L" },
			{ "sights", "Toggle Sights", "V" },
		}
		for index, key in KEYS do
			local action = KeyBindings.action(key[1])
			t.eq(action.name, key[2], `{key[1]}'s name`)
			t.eq(action.default, key[3], `{key[1]}'s default`)
			t.eq(action.category, "gameplay")
			t.eq(action.context, "game", "in the world only (R is JEI's in screens)")
			t.ok(action.tooltip ~= "", `{key[1]}'s tooltip`)
			t.eq(PlayerSettings.entry(KeyBindings.settingKey(key[1])).id, 160 + index, `{key[1]}'s setting id`)
			t.eq(KeyBindings.ACTIONS[160 - KeyBindings.KEY_BASE + 1 + index].id, key[1], "appended in order")
		end
		t.eq(next(KeyBindings.conflicting({})), nil, "the defaults conflict nowhere")
		t.eq(KeyBindings.action("jeiRecipes").default, "R", "JEI's R stays, in screens")
		t.ok(#PlayerSettings.ENTRIES <= 255)
	end)

	t.test("weapons: Config.Weapons", function()
		local W = Config.Weapons
		t.eq(W.Enabled, true)
		t.eq(W.PvP, true)
		local numbers = {
			ZombieHead = 3,
			MobHead = 2,
			PlayerHead = 2,
			HelmetShare = 0.6,
			Gravity = 9.8,
			MaxRange = 256,
			SegmentSeconds = 0.05,
			GlassShare = 0.7,
			BulletKnockback = 0.1,
			PelletKnockback = 0.05,
			BleedChance = 0.5,
			ShoulderSpread = 1.8,
			MovingSpread = 2,
			CrouchSpread = 0.8,
			MovingSway = 2.5,
			CrouchSway = 0.6,
			HurtSway = 1.5,
			ShoulderSway = 1.3,
			HoldBreathSeconds = 3,
			OutOfBreathSeconds = 3,
			HoldBreathSway = 0.15,
			OutOfBreathSway = 1.5,
			RecoilRecover = 0.6,
			RecoilRecoverSeconds = 0.25,
			CrouchRecoil = 0.8,
			ShoulderRecoil = 1.2,
			RaiseTicks = 6,
			UnjamTicks = 40,
			ModeTicks = 4,
			RaisedSpeed = 0.65,
			SightsSpeed = 0.5,
			GuardSpeed = 0.5,
			IronSightsZoom = 1.15,
			ImpactNoise = 8,
			SuppressedMinNoise = 8,
			OriginSlack = 2.5,
			DirectionSlack = 0.01,
			ShotsPerSecond = 20,
			LagCompMax = 2,
			ShotBroadcast = 256,
			FarSound = 64,
			TracerSeconds = 0.06,
			BoltRecover = 0.7,
		}
		for key, value in numbers do
			t.eq((W :: any)[key], value, `Config.Weapons.{key}`)
		end
		for _, key in { "ShatterGlass", "PassLeaves", "ShoulderDot", "Tracers" } do
			t.eq((W :: any)[key], true, `Config.Weapons.{key}`)
		end
		t.eq(table.concat(W.ShatterBlocks, ","), "Glass")
		t.eq(table.concat(W.JamChance, ","), "0,0.002,0.01,0.04,1")
		t.eq(table.concat(W.ShoulderOffset, ","), "1.6,0.4,0")
		t.eq(W.Melee.Enabled, true)
		t.eq(W.Melee.HeavyHold, 0.45)
		t.eq(W.Melee.HeavyKnockback, 0.8)
		t.eq(W.Melee.HeavyExhaustion, 3)
		t.eq(W.Melee.GuardCone, 0.5)
		t.eq(W.Melee.FinisherCone, 0.5)
		t.eq(W.Melee.FinisherMaxHealth, 30)
		t.ok(WeaponSync.DIRECTION_SLACK == W.DirectionSlack, "the codec's slack is the server's")
	end)

	--[[ Codecs ]]

	t.test("weapons: Fire round trips in 46 bytes; every malformed one is refused", function()
		t.eq(Protocol.ClientMessage.Fire, 27)
		t.eq(Protocol.ClientMessage.Weapon, 28)
		t.eq(Protocol.ServerMessage.Shots, 33)
		local fire: WeaponSync.Fire = {
			seq = 4000000000,
			shot = 65535,
			slot = 3,
			item = I.AssaultRifle,
			sights = true,
			moving = false,
			crouching = true,
			breath = true,
			ox = 999999.125,
			oy = 64.5,
			oz = -2000.75,
			dx = 0,
			dy = 0.6,
			dz = 0.8,
		}
		local b = WeaponSync.encodeFire(fire)
		t.eq(buffer.len(b), WeaponSync.FIRE_BYTES)
		t.eq(WeaponSync.FIRE_BYTES, 46)
		local back = WeaponSync.decodeFire(b) :: WeaponSync.Fire
		t.ok(back ~= nil, "decodes")
		for _, key in { "seq", "shot", "slot", "item", "sights", "moving", "crouching", "breath", "ox", "oy", "oz" } do
			t.eq((back :: any)[key], (fire :: any)[key], `{key} survives`)
		end
		t.near(back.dy, 0.6, 1e-6)
		t.near(back.dz, 0.8, 1e-6)
		-- The counters wrap.
		local wrapped = WeaponSync.decodeFire(WeaponSync.encodeFire({
			seq = 1,
			shot = 65537,
			slot = 1,
			item = I.Pistol,
			sights = false,
			moving = true,
			crouching = false,
			breath = false,
			ox = 0,
			oy = 0,
			oz = 0,
			dx = 1,
			dy = 0,
			dz = 0,
		})) :: WeaponSync.Fire
		t.eq(wrapped.shot, 1)
		t.eq(wrapped.moving, true)
		t.eq(wrapped.sights, false)
		-- Malformed: a field changed from the good one.
		local function with(changes: { [string]: any }): WeaponSync.Fire?
			local copy = table.clone(fire)
			for key, value in changes do
				(copy :: any)[key] = value
			end
			return WeaponSync.decodeFire(WeaponSync.encodeFire(copy))
		end
		t.ok(with({ ox = Protocol.MAX_COORDINATE + 64 }) ~= nil, "at the limit")
		t.eq(with({ ox = Protocol.MAX_COORDINATE + 65 }), nil, "an origin beyond the world")
		t.eq(with({ oz = -(Protocol.MAX_COORDINATE + 65) }), nil)
		t.eq(with({ oy = 4097 }), nil, "y beyond 4096")
		t.eq(with({ ox = 0 / 0 }), nil, "NaN")
		t.eq(with({ oy = math.huge }), nil, "infinite")
		t.eq(with({ dx = 0 / 0 }), nil, "a NaN direction")
		t.eq(with({ dy = 0.6, dz = 0.82 }), nil, "a direction too long")
		t.ok(with({ dx = 0, dy = 0, dz = 1.009 }) ~= nil, "within the slack")
		t.eq(with({ dx = 0, dy = 0, dz = 0.98 }), nil, "too short")
		t.eq(with({ slot = 0 }), nil, "slot 0")
		t.eq(with({ slot = 10 }), nil, "slot 10")
		local flags = WeaponSync.encodeFire(fire)
		buffer.writeu8(flags, 9, 16)
		t.eq(WeaponSync.decodeFire(flags), nil, "unknown flags")
		local short = buffer.create(45)
		buffer.copy(short, 0, b, 0, 45)
		t.eq(WeaponSync.decodeFire(short), nil, "cut short")
		local long = buffer.create(47)
		buffer.copy(long, 0, b)
		t.eq(WeaponSync.decodeFire(long), nil, "too long")
	end)

	t.test("weapons: Weapon ops round trip; others are refused", function()
		for name, op in WeaponSync.Op do
			t.eq(WeaponSync.decodeWeapon(WeaponSync.encodeWeapon(op)), op, name)
		end
		t.eq(WeaponSync.Op.Raise, 1)
		t.eq(WeaponSync.Op.Unguard, 4)
		t.eq(WeaponSync.decodeWeapon(WeaponSync.encodeWeapon(0)), nil)
		t.eq(WeaponSync.decodeWeapon(WeaponSync.encodeWeapon(5)), nil)
		t.eq(WeaponSync.decodeWeapon(buffer.create(2)), nil, "a wrong length")
		t.eq(WeaponSync.decodeWeapon(buffer.create(0)), nil)
	end)

	t.test("weapons: Shots round trip at 26 + 13 n bytes a shot; every malformed one is refused", function()
		local Hit = WeaponSync.Hit
		local pellets = {}
		for i = 1, 8 do
			table.insert(pellets, { x = 10 + i, y = 70.5, z = -5 - i, hit = (i - 1) % 7 })
		end
		local shots: { WeaponSync.Shot } = {
			{
				shooter = 123456789,
				item = I.PumpShotgun,
				shot = 7,
				suppressed = false,
				jammed = true,
				refused = false,
				ox = 1.5,
				oy = 65.62,
				oz = -3.25,
				pellets = pellets,
			},
			{
				shooter = -1,
				item = I.Pistol,
				shot = 65535,
				suppressed = true,
				jammed = false,
				refused = false,
				ox = 0,
				oy = 0,
				oz = 0,
				pellets = { { x = 1, y = 2, z = 3, hit = Hit.PlayerHead } },
			},
			{
				shooter = 42,
				item = I.Smg,
				shot = 9,
				suppressed = false,
				jammed = false,
				refused = true,
				ox = 0,
				oy = 0,
				oz = 0,
				pellets = {},
			},
		}
		local b = WeaponSync.encodeShots(shots)
		t.eq(buffer.len(b), 1 + 3 * 26 + 13 * 9)
		local back = WeaponSync.decodeShots(b) :: { WeaponSync.Shot }
		t.ok(back ~= nil and #back == 3, "three shots")
		for i, shot in shots do
			local got = back[i]
			for _, key in { "shooter", "item", "shot", "suppressed", "jammed", "refused", "ox", "oz" } do
				t.eq((got :: any)[key], (shot :: any)[key], `shot {i}'s {key}`)
			end
			t.near(got.oy, shot.oy, 1e-4)
			t.eq(#got.pellets, #shot.pellets, `shot {i}'s pellets`)
			for j, pellet in shot.pellets do
				t.eq(got.pellets[j].hit, pellet.hit)
				t.eq(got.pellets[j].x, pellet.x)
				t.eq(got.pellets[j].z, pellet.z)
			end
		end
		t.eq(Hit.None, 0)
		t.eq(Hit.PlayerHead, 6)
		-- At most MAX_SHOTS a message.
		local many = {}
		for i = 1, 70 do
			many[i] = shots[3]
		end
		t.eq(#(WeaponSync.decodeShots(WeaponSync.encodeShots(many)) :: any), WeaponSync.MAX_SHOTS)
		-- Malformed.
		local function patched(offset: number, value: number): buffer
			local copy = buffer.create(buffer.len(b))
			buffer.copy(copy, 0, b)
			buffer.writeu8(copy, offset, value)
			return copy
		end
		t.eq(WeaponSync.decodeShots(buffer.create(0)), nil, "empty")
		t.eq(WeaponSync.decodeShots(patched(0, 0)), nil, "no shots")
		t.eq(WeaponSync.decodeShots(patched(0, 65)), nil, "more than MAX_SHOTS")
		t.eq(WeaponSync.decodeShots(patched(1 + 12, 8)), nil, "unknown flags")
		t.eq(WeaponSync.decodeShots(patched(1 + 25, 13)), nil, "more than MAX_PELLETS")
		t.eq(WeaponSync.decodeShots(patched(1 + 26 + 12, 7)), nil, "an unknown hit")
		local refusedWithPellets = table.clone(shots[2])
		refusedWithPellets.refused = true
		t.eq(WeaponSync.decodeShots(WeaponSync.encodeShots({ refusedWithPellets })), nil, "a refused shot with pellets")
		local fractional = table.clone(shots[3])
		fractional.shooter = 1.5
		t.eq(WeaponSync.decodeShots(WeaponSync.encodeShots({ fractional })), nil, "a UserId is whole")
		local nan = table.clone(shots[3])
		nan.ox = 0 / 0
		t.eq(WeaponSync.decodeShots(WeaponSync.encodeShots({ nan })), nil, "NaN")
		local far = table.clone(shots[2])
		far.pellets = { { x = Protocol.MAX_COORDINATE + 100, y = 0, z = 0, hit = 0 } }
		t.eq(WeaponSync.decodeShots(WeaponSync.encodeShots({ far })), nil, "a pellet beyond the world")
		local cut = buffer.create(buffer.len(b) - 1)
		buffer.copy(cut, 0, b, 0, buffer.len(cut))
		t.eq(WeaponSync.decodeShots(cut), nil, "cut short")
		local long = buffer.create(buffer.len(b) + 1)
		buffer.copy(long, 0, b)
		t.eq(WeaponSync.decodeShots(long), nil, "too long")
	end)

	t.test("weapons: inventory action kind 8 and Attack's heavy flag on the wire", function()
		local seq, action = Protocol.decodeInventoryAction(
			Protocol.encodeInventoryAction(42, { kind = "weapon", op = 6, slot = 45, part = 3 })
		)
		t.eq(seq, 42)
		local weapon = action :: any
		t.eq(weapon.kind, "weapon")
		t.eq(weapon.op, 6)
		t.eq(weapon.slot, 45)
		t.eq(weapon.part, 3)
		local held = Protocol.encodeInventoryAction(7, { kind = "weapon", op = 1, slot = -1, part = 0 })
		t.eq(buffer.len(held), 9)
		local _, reload = Protocol.decodeInventoryAction(held)
		t.eq((reload :: any).slot, -1, "the held weapon")
		local function patched(offset: number, value: number): buffer
			local copy = buffer.create(9)
			buffer.copy(copy, 0, held)
			buffer.writeu8(copy, offset, value)
			return copy
		end
		t.eq((Protocol.decodeInventoryAction(patched(5, 0))), nil, "op 0")
		t.eq((Protocol.decodeInventoryAction(patched(5, 7))), nil, "op 7")
		t.eq((Protocol.decodeInventoryAction(patched(8, 7))), nil, "part 7")
		local long = buffer.create(10)
		buffer.copy(long, 0, held)
		t.eq((Protocol.decodeInventoryAction(long)), nil, "a wrong length")
		t.ok(
			not pcall(Protocol.encodeInventoryAction, 1, { kind = "fire", item = I.Pistol }),
			"a shot rides the Fire message"
		)
		-- Attack: 4 bytes light, 5 with the heavy flag.
		local light = Protocol.encodeAttack(123456)
		t.eq(buffer.len(light), 4)
		local id, heavy = Protocol.decodeAttack(light)
		t.eq(id, 123456)
		t.eq(heavy, false)
		local strong = Protocol.encodeAttack(99, true)
		t.eq(buffer.len(strong), 5)
		local id2, heavy2 = Protocol.decodeAttack(strong)
		t.eq(id2, 99)
		t.eq(heavy2, true)
		local zero = buffer.create(5)
		buffer.writeu32(zero, 0, 5)
		t.eq(select(2, Protocol.decodeAttack(zero)), false, "flags 0: a light one")
		buffer.writeu8(zero, 4, 2)
		t.eq((Protocol.decodeAttack(zero)), nil, "unknown flags")
		t.eq((Protocol.decodeAttack(buffer.create(6))), nil)
		t.eq((Protocol.decodeAttack(buffer.create(3))), nil)
	end)

	--[[ Weapon state ]]

	t.test("weapon state: sane clamps a gun's and a magazine's data, and leaves other stacks", function()
		local clean = pistol(10)
		t.eq(WeaponState.sane(clean), clean, "already sane: the same table")
		local odd = stack(I.Pistol, {
			ch = I.Rounds357,
			jam = true,
			mag = I.PistolMagazine,
			magD = 99999,
			n = 400,
			ammo = I.Rounds9mm,
			mode = 7,
			optic = I.RifleScope,
			muzzle = I.Suppressor,
			muzzleD = 1e9,
			light = I.WeaponFlashlight,
			lit = true,
			junk = 1,
		})
		local sane = WeaponState.sane(odd)
		t.ok(sane ~= odd, "a copy")
		local data = sane.data :: any
		t.eq(data.ch, nil, "a .357 round in a 9mm chamber goes")
		t.eq(data.jam, nil, "no jam without a round")
		t.eq(data.n, 15, "at most the magazine's capacity")
		t.eq(data.ammo, I.Rounds9mm)
		t.eq(data.mag, I.PistolMagazine)
		t.eq(data.magD, 1500, "the magazine's wear at most its durability")
		t.eq(data.mode, nil, "a one-mode gun")
		t.eq(data.optic, nil, "a rifle scope doesn't fit a pistol")
		t.eq(data.muzzle, I.Suppressor)
		t.eq(data.muzzleD, 400)
		t.eq(data.light, I.WeaponFlashlight)
		t.eq(data.lit, true)
		t.eq(data.junk, nil, "unknown keys go")
		t.ok(table.isfrozen(data), "frozen data")
		t.ok(Items.validData(data))
		t.eq(WeaponState.sane(sane), sane, "sane twice is the same")
		-- A detachable feed: rounds only with its own magazine attached.
		t.eq(WeaponState.sane(stack(I.Pistol, { n = 5, ammo = I.Rounds9mm, magD = 3 })).data, nil, "no magazine")
		t.eq(
			WeaponState.sane(stack(I.Pistol, { mag = I.SmgMagazine, n = 20, ammo = I.Rounds9mm })).data,
			nil,
			"another gun's magazine"
		)
		-- An internal feed: no magazine, at most its rounds, rounds of its calibre.
		local revolver = WeaponState.sane(stack(I.Revolver, { n = 9, ammo = I.Rounds357, mag = I.PistolMagazine }))
		t.eq((revolver.data :: any).n, 5)
		t.eq((revolver.data :: any).mag, nil)
		t.eq(WeaponState.sane(stack(I.Revolver, { n = 3, ammo = I.Rounds9mm })).data, nil, "another calibre's rounds")
		t.eq(WeaponState.sane(stack(I.Revolver, { n = 3 })).data, nil, "rounds of no kind")
		t.eq(WeaponState.sane(stack(I.Revolver, { n = -2, ammo = I.Rounds357 })).data, nil)
		t.eq(((WeaponState.sane(stack(I.Revolver, { n = 2.7, ammo = I.Rounds357 })).data) :: any).n, 2, "whole rounds")
		-- Modes: 1 is the default, beyond the gun's go.
		t.eq(((WeaponState.sane(stack(I.Smg, { mode = 2 })).data) :: any).mode, 2)
		t.eq(WeaponState.sane(stack(I.Smg, { mode = 1 })).data, nil, "the default needs no key")
		t.eq(((WeaponState.sane(stack(I.Smg, { mode = 3 })).data) :: any).mode, 2, "clamped to the last")
		t.eq(WeaponState.sane(stack(I.Smg, { mode = 0 })).data, nil)
		t.eq(WeaponState.sane(stack(I.Pistol, { mode = 2 })).data, nil, "one mode only")
		t.eq(WeaponState.sane(stack(I.Smg, { lit = true })).data, nil, "no light to be lit")
		t.eq(WeaponState.sane(stack(I.Smg, { light = I.RedDotSight })).data, nil, "an optic in the light slot")
		local fresh = WeaponState.sane(stack(I.Smg, { muzzle = I.Suppressor, muzzleD = 0 })).data :: any
		t.eq(fresh.muzzle, I.Suppressor)
		t.eq(fresh.muzzleD, nil, "no wear needs no key")
		t.eq(WeaponState.sane(stack(I.Revolver, { optic = I.RedDotSight })).data, nil, "no mounts")
		-- A magazine.
		local magazine = WeaponState.sane(stack(I.PistolMagazine, { n = 99, ammo = I.Rounds9mm, ch = I.Rounds9mm }))
		t.eq((magazine.data :: any).n, 15)
		t.eq((magazine.data :: any).ch, nil, "magazines have no chamber")
		t.eq(WeaponState.sane(stack(I.PistolMagazine, { n = 4, ammo = I.Rounds556 })).data, nil)
		-- Anything else as it is.
		local tank = { item = I.Stick, count = 3, data = Items.cleanData({ n = 99 }) }
		t.eq(WeaponState.sane(tank), tank)
		local fluid = { item = I.Rounds9mm, count = 30 }
		t.eq(WeaponState.sane(fluid), fluid)
	end)

	t.test("weapon state: the readers", function()
		local gun = pistol(10, { muzzle = I.ImprovisedSuppressor, muzzleD = 12, magD = 7, optic = I.RedDotSight })
		t.eq(WeaponState.chamber(gun), I.Rounds9mm)
		t.eq(WeaponState.jammed(gun), false)
		local n, ammo = WeaponState.rounds(gun)
		t.eq(n, 10)
		t.eq(ammo, I.Rounds9mm)
		local mag, magWear = WeaponState.magazine(gun)
		t.eq(mag, I.PistolMagazine)
		t.eq(magWear, 7)
		local muzzle, muzzleWear = WeaponState.attachment(gun, "muzzle")
		t.eq(muzzle, I.ImprovisedSuppressor)
		t.eq(muzzleWear, 12)
		local optic, opticWear = WeaponState.attachment(gun, "optic")
		t.eq(optic, I.RedDotSight)
		t.eq(opticWear, 0, "optics don't wear")
		t.eq((WeaponState.attachment(gun, "light")), nil)
		t.eq(WeaponState.mode(gun), "semi")
		t.eq(WeaponState.modeIndex(gun), 1)
		t.eq(WeaponState.mode(stack(I.AssaultRifle, { mode = 2 })), "auto")
		t.eq(WeaponState.modeIndex(stack(I.AssaultRifle, { mode = 2 })), 2)
		t.eq(WeaponState.mode({ item = I.Stick, count = 1 }), "semi")
		local empty = stack(I.Pistol)
		t.eq(WeaponState.chamber(empty), nil)
		t.eq((WeaponState.rounds(empty)), 0)
		t.eq(select(2, WeaponState.rounds(empty)), nil)
		t.eq((WeaponState.magazine(empty)), nil)
		t.eq(WeaponState.fraction(I.Pistol, nil), 1)
		t.eq(WeaponState.fraction(I.Pistol, 750), 0.5)
		t.eq(WeaponState.fraction(I.Pistol, 9999), 0)
		t.eq(WeaponState.fraction(I.RedDotSight, 5), 1, "no durability: whole")
	end)

	t.test("weapon state: firing empties the chamber, feeds, wears, jams only on a feed", function()
		local loaded = pistol(2, { muzzle = I.ImprovisedSuppressor })
		local one = WeaponState.fire(loaded, false, false) :: Items.Stack
		t.ok(one ~= nil and one ~= loaded, "fired: a new stack")
		t.eq(WeaponState.chamber(one), I.Rounds9mm, "the next round fed")
		t.eq((WeaponState.rounds(one)), 1)
		t.eq(one.damage, 1, "the gun wore 1")
		t.eq(select(2, WeaponState.magazine(one)), 1, "the magazine wore 1")
		t.eq(select(2, WeaponState.attachment(one, "muzzle")), 1, "the suppressor wore 1")
		t.ok(table.isfrozen(one.data :: any))
		t.eq(WeaponState.chamber(loaded), I.Rounds9mm, "the old stack is untouched")
		local two = WeaponState.fire(one, false, false) :: Items.Stack
		t.eq(WeaponState.chamber(two), I.Rounds9mm)
		local n, ammo = WeaponState.rounds(two)
		t.eq(n, 0, "the magazine ran dry")
		t.eq(ammo, nil, "no rounds, no kind")
		local three = WeaponState.fire(two, false, false) :: Items.Stack
		t.eq(WeaponState.chamber(three), nil, "the last round fired")
		t.eq(three.damage, 3)
		t.eq(WeaponState.fire(three, false, false), nil, "empty: refused")
		local ok, why = WeaponState.canFire(three, false)
		t.eq(ok, false)
		t.eq(why, "empty")
		t.ok((WeaponState.canFire(three, true)), "creative fires without a round")
		t.eq(WeaponState.fire(three, false, true), three, "creative: the same stack, free")
		t.eq(WeaponState.fire(loaded, true, true), loaded, "and no jam")
		-- A jam sticks the round just fed; the last round never jams.
		local jammed = WeaponState.fire(loaded, true, false) :: Items.Stack
		t.eq(WeaponState.jammed(jammed), true)
		t.eq(WeaponState.chamber(jammed), I.Rounds9mm, "the round stays in the chamber")
		local stuck, reason = WeaponState.canFire(jammed, false)
		t.eq(stuck, false)
		t.eq(reason, "jammed")
		t.eq(WeaponState.fire(jammed, false, false), nil)
		t.eq(WeaponState.fire(jammed, false, true), nil, "creative can't fire a jammed gun either")
		local last = pistol(0)
		local spent = WeaponState.fire(last, true, false) :: Items.Stack
		t.eq(WeaponState.jammed(spent), false, "nothing fed, nothing jams")
		t.eq(WeaponState.chamber(spent), nil)
		-- Wear stops at each part's durability (guns and magazines never break).
		local worn = stack(I.Pistol, {
			ch = I.Rounds9mm,
			mag = I.PistolMagazine,
			magD = 1500,
			muzzle = I.ImprovisedSuppressor,
			muzzleD = 40,
		}, 100)
		local after = WeaponState.fire(worn, false, false) :: Items.Stack
		t.eq(select(2, WeaponState.magazine(after)), 1500, "a Ruined magazine stays")
		t.eq(select(2, WeaponState.attachment(after, "muzzle")), 40, "a Ruined bottle stays")
		t.eq(after.damage, 101)
		-- Ruined (durability left at or below 0.2) never fires.
		local ruined = stack(I.Pistol, { ch = I.Rounds9mm }, 1200)
		local nope, ruin = WeaponState.canFire(ruined, false)
		t.eq(nope, false)
		t.eq(ruin, "ruined")
		t.eq(WeaponState.fire(ruined, false, true), nil, "not even in creative")
		t.ok((WeaponState.canFire(stack(I.Pistol, { ch = I.Rounds9mm }, 1199), false)), "badly damaged fires")
		-- An internal feed: the chamber from the tube.
		local pump = stack(I.PumpShotgun, { ch = I.Slugs, n = 1, ammo = I.Slugs })
		local pumped = WeaponState.fire(pump, false, false) :: Items.Stack
		t.eq(WeaponState.chamber(pumped), I.Slugs)
		t.eq((WeaponState.rounds(pumped)), 0)
		t.eq(WeaponState.fire({ item = I.Stick, count = 1 }, false, false), nil, "no firearm")
		t.eq(WeaponState.canFire({ item = I.Stick, count = 1 }, true), false)
		-- Odd data fires no more than the gun holds.
		local stuffed = stack(I.DoubleBarrelShotgun, { ch = I.Buckshot, n = 50, ammo = I.Buckshot })
		local fired = 0
		local current: Items.Stack? = stuffed
		while current and WeaponState.canFire(current, false) do
			current = WeaponState.fire(current, false, false)
			fired += 1
		end
		t.eq(fired, 2, "two barrels")
	end)

	t.test("weapon state: the detail line, the icon's count and the look", function()
		t.eq(WeaponState.detail(pistol(12)), "12 / 15 +1")
		t.eq(WeaponState.detail(stack(I.Pistol, { mag = I.PistolMagazine, n = 3, ammo = I.Rounds9mm })), "3 / 15")
		t.eq(WeaponState.detail(stack(I.Pistol, { ch = I.Rounds9mm })), "No magazine +1")
		t.eq(WeaponState.detail(stack(I.Pistol)), "No magazine")
		t.eq(
			WeaponState.detail(stack(I.Smg, { mag = I.SmgMagazine, n = 30, ammo = I.Rounds9mm, mode = 2 })),
			"30 / 30 AUTO"
		)
		t.eq(WeaponState.detail(stack(I.Smg)), "No magazine SEMI")
		t.eq(WeaponState.detail(stack(I.Revolver, { ch = I.Rounds357, n = 3, ammo = I.Rounds357 })), "4 / 6")
		t.eq(WeaponState.detail(stack(I.Revolver)), "0 / 6")
		t.eq(WeaponState.detail(stack(I.Crossbow, { ch = I.CrossbowBolt })), "1 / 1")
		t.eq(WeaponState.detail(WeaponState.fire(pistol(4), true, false)), "JAMMED")
		t.eq(WeaponState.detail(stack(I.PistolMagazine, { n = 7, ammo = I.Rounds9mm })), "7 / 15")
		t.eq(WeaponState.detail(stack(I.PistolMagazine)), "0 / 15")
		t.eq(WeaponState.detail({ item = I.Stick, count = 1 }), nil)
		t.eq(WeaponState.detail(nil), nil)
		t.eq(WeaponState.shownCount(pistol(12)), 13, "the magazine and the chamber")
		t.eq(WeaponState.shownCount(stack(I.Pistol, { ch = I.Rounds9mm })), 1)
		t.eq(WeaponState.shownCount(stack(I.Pistol)), nil, "nothing to show")
		t.eq(WeaponState.shownCount(stack(I.PistolMagazine, { n = 7, ammo = I.Rounds9mm })), 7)
		t.eq(WeaponState.shownCount(stack(I.PistolMagazine)), nil)
		t.eq(WeaponState.shownCount({ item = I.Rounds9mm, count = 30 }), nil, "ammunition counts itself")
		t.eq(
			WeaponState.lookKey(stack(I.Pistol, { mag = I.PistolMagazine, muzzle = I.Suppressor })),
			`{I.PistolMagazine},0,{I.Suppressor},0,0`
		)
		t.eq(
			WeaponState.lookKey(stack(I.AssaultRifle, { optic = I.RifleScope, light = I.WeaponFlashlight, lit = true })),
			`0,{I.RifleScope},0,{I.WeaponFlashlight},1`
		)
		t.eq(WeaponState.lookKey(stack(I.Pistol)), "0,0,0,0,0")
		t.eq(WeaponState.lookKey(nil), "")
		t.eq(WeaponState.lookKey({ item = I.Stick, count = 1 }), "", "no firearm")
		-- The HUD's and HANDS' line (Ui/Theme) takes the detail before the durability.
		local lines = Theme.handsLines(pistol(12)) :: any
		t.eq(lines.detail, "12 / 15 +1")
		t.eq(lines.name, "9mm Pistol")
		t.ok(lines.condition ~= nil, "the condition dot stays")
		t.eq((Theme.handsLines(stack(I.KitchenKnife)) :: any).detail, "Durability 100 / 100", "others as before")
	end)

	--[[ The fire action ]]

	t.test("weapons: Menu's fire action acts on the held slot only, in every mode that interacts", function()
		local loaded = pistol(5)
		local inventory = Types.newInventory()
		inventory.slots[1] = loaded
		inventory.slots[2] = loaded
		local window = Types.newWindow(inventory)
		local fire: Types.Action = { kind = "fire", item = I.Pistol }
		t.ok(Menu.allows(fire, SURVIVAL) and Menu.allows(fire, CREATIVE), "allowed where a player interacts")
		t.ok(not Menu.allows(fire, SPECTATOR), "not for spectators")
		t.ok(Menu.allows({ kind = "weapon", op = 1, slot = -1, part = 0 }, SURVIVAL))
		t.ok(not Menu.allows({ kind = "weapon", op = 1, slot = -1, part = 0 }, SPECTATOR))
		t.eq(#Menu.apply(window, fire, false), 0, "throws nothing")
		t.eq((WeaponState.rounds(inventory.slots[1] :: Items.Stack)), 4, "the held gun fed a round")
		t.eq(inventory.slots[2], loaded, "the other slot is untouched")
		local held = inventory.slots[1]
		Menu.apply(window, { kind = "fire", item = I.Smg }, false)
		t.eq(inventory.slots[1], held, "another item named: nothing")
		inventory.selected = 3
		Menu.apply(window, fire, false)
		t.eq(inventory.slots[1], held, "not in hand: nothing")
		inventory.selected = 1
		Menu.apply(window, fire, true)
		t.eq(inventory.slots[1], held, "creative: rounds are free")
		Menu.apply(window, { kind = "fire", item = I.Pistol, jam = true }, false)
		t.eq(WeaponState.jammed(inventory.slots[1] :: Items.Stack), true, "the server's jam")
		local jammed = inventory.slots[1]
		Menu.apply(window, fire, false)
		t.eq(inventory.slots[1], jammed, "a jammed gun doesn't fire")
	end)

	t.test("weapons: a predicted shot agrees with the server's; refused ones are acknowledged", function()
		local function snapshot(state, key)
			return Protocol.decodeInventory(Protocol.encodeInventory(state:snapshot(key)))
		end
		local state = InventoryState.new()
		state:join("p")
		local window = state:window("p") :: Types.Window
		window.inventory.slots[1] = pistol(3)
		local prediction = Prediction.new()
		prediction:receive(snapshot(state, "p"), SURVIVAL)
		local seq = prediction:push({ kind = "fire", item = I.Pistol }, SURVIVAL)
		t.eq(seq, 1)
		local predicted = prediction:window().inventory.slots[1] :: Items.Stack
		t.eq((WeaponState.rounds(predicted)), 2, "predicted at once")
		local before = state:fire("p", seq, I.Pistol, false, false) :: Items.Stack
		t.ok(before ~= nil, "fired")
		t.eq(WeaponState.chamber(before), I.Rounds9mm, "the gun as it was: the round fired")
		t.eq((WeaponState.rounds(before)), 3)
		local server = window.inventory.slots[1] :: Items.Stack
		t.ok(Items.stacksMatch(server, predicted), "the server's shot is the one predicted")
		prediction:receive(snapshot(state, "p"), SURVIVAL)
		t.eq(#prediction.pending, 0, "acknowledged")
		t.ok(Items.stacksMatch(prediction:window().inventory.slots[1] :: Items.Stack, server))
		-- A jam only the server rolled: the snapshot brings it.
		local seq2 = prediction:push({ kind = "fire", item = I.Pistol }, SURVIVAL)
		state:fire("p", seq2, I.Pistol, true, false)
		t.eq(WeaponState.jammed(prediction:window().inventory.slots[1] :: Items.Stack), false, "not predicted")
		prediction:receive(snapshot(state, "p"), SURVIVAL)
		t.eq(WeaponState.jammed(prediction:window().inventory.slots[1] :: Items.Stack), true, "the server's")
		-- Refused (jammed now; another item; no player): acknowledged, nothing changes.
		local seq3 = prediction:push({ kind = "fire", item = I.Pistol }, SURVIVAL)
		local jammedGun = window.inventory.slots[1]
		t.eq(state:fire("p", seq3, I.Pistol, false, false), nil, "a jammed gun")
		t.eq(window.inventory.slots[1], jammedGun)
		t.eq((state:get("p") :: any).ack, seq3, "acknowledged all the same")
		t.eq(state:fire("p", seq3 + 1, I.Smg, false, false), nil, "another item")
		t.eq((state:get("p") :: any).ack, seq3 + 1)
		t.eq(state:fire("nobody", 1, I.Pistol, false, false), nil)
		-- A fire action never comes as an inventory action.
		window.inventory.slots[2] = pistol(3)
		window.inventory.selected = 2
		state:apply("p", seq3 + 2, { kind = "fire", item = I.Pistol }, false)
		t.eq((WeaponState.rounds(window.inventory.slots[2] :: Items.Stack)), 3, "only through `fire`")
		-- Creative fires for free, the gun handed back all the same.
		local free = state:fire("p", seq3 + 3, I.Pistol, false, true) :: Items.Stack
		t.ok(free ~= nil)
		t.eq((WeaponState.rounds(window.inventory.slots[2] :: Items.Stack)), 3, "nothing used")
	end)

	--[[ Melee and bashing ]]

	t.test("weapons: a bash never wears a gun; melee weapons wear as their kind", function()
		for _, item in Weapons.FIREARMS do
			t.eq(Combat.wear(item), 0, `{(Weapons.firearm(item) :: any).name}'s bash`)
		end
		t.eq(Combat.wear(I.PistolMagazine), 0)
		t.eq(Combat.wear(I.BaseballBat), 1, "a bat as before")
		t.eq(Combat.wear(I.PipeWrench), 1, "a wrench like a bat")
		t.eq(Combat.wear(I.KitchenKnife), 1, "a knife is a sword")
		t.eq(Combat.wear(I.Sledgehammer), 2, "a sledgehammer is a pickaxe")
		t.eq(Combat.wear(I.IronSword), 1)
	end)

	t.test("weapons: a heavy Attack reaches MobWorld and lands at least a light one's", function()
		local FLOOR = 64
		local function getBlock(_x: number, y: number, _z: number): number?
			return if y < FLOOR then Blocks.id.Stone else Blocks.AIR
		end
		local world = MobWorld.new(getBlock, {
			maxMobs = 10,
			forgetTicks = 6000,
			random = function(): number
				return 0.5
			end,
		})
		local zombie = MobList.find("Zombie") :: number
		local light = world:spawn(zombie, 2.5, FLOOR, 0.5)
		local heavy = world:spawn(zombie, 2.5, FLOOR, 4.5)
		local function attacker(z: number, isHeavy: boolean): MobWorld.Attacker
			return {
				key = "p",
				x = 0.5,
				y = FLOOR,
				z = z,
				eye = 1.62,
				mode = SURVIVAL,
				alive = true,
				item = I.BaseballBat,
				ticks = 100,
				heavy = isHeavy,
			}
		end
		local lightLanded = world:attack(light, attacker(0.5, false)) :: number
		local heavyLanded = world:attack(heavy, attacker(4.5, true)) :: number
		t.ok(lightLanded > 0, "a light hit lands")
		t.ok(heavyLanded >= lightLanded, "a heavy one at least as hard")
	end)

	--[[ Recipes and Ages ]]

	t.test("weapons: an improvised suppressor and crossbow bolts are made; bolts in the Iron Age", function()
		t.eq(#Crafting.recipes, 215, "213 and the weapons' two")
		local suppressor = Crafting.match({
			[1] = { item = I.GlassBottle, count = 1 },
			[2] = { item = I.DuctTape, count = 1 },
		}, 2)
		t.ok(suppressor ~= nil and suppressor.item == I.ImprovisedSuppressor, "a bottle and tape")
		local bolts = Crafting.match({
			[2] = { item = I.IronNugget, count = 1 },
			[5] = { item = I.Stick, count = 1 },
			[8] = { item = I.Feather, count = 1 },
		}, 3)
		t.ok(bolts ~= nil and bolts.item == I.CrossbowBolt, "a nugget over a stick over a feather")
		t.eq((bolts :: any).count, 4)
		local made: { [number]: boolean } = {}
		for _, recipe in Crafting.recipes do
			made[recipe.result] = true
		end
		for _, item in Weapons.FIREARMS do
			t.ok(not made[item], "no gun is made")
		end
		for _, item in Weapons.MAGAZINES do
			t.ok(not made[item], "no magazine is made")
		end
		for _, item in Weapons.AMMO do
			t.ok(not made[item] or item == I.CrossbowBolt, "only bolts are made")
		end
		t.eq(Ages.ofName("CrossbowBolt"), (Ages.byId("iron") :: any).index, "bolts: the Iron Age")
		t.eq(Ages.ofName("ImprovisedSuppressor"), 1, "a bottle and tape from the start")
	end)
end
