--!strict
--[[
	Weapons in the manner of DayZ (Shared/Weapons: WeaponList holds their numbers, WeaponState what a
	stack's item data keeps; server Weapons/, client Interaction/Firearms). Box models in their
	colours until their icons are made; the client builder may tune the models and tilts.

	Firearms (a 9mm pistol, a .357 revolver, a 9mm submachine gun, a pump and a double-barrel
	shotgun, a bolt-action and a semi-automatic 7.62 rifle, a 5.56 assault rifle, a scoped .308
	hunting rifle, a .22 small-bore rifle and a crossbow) stack to 1 and wear as they fire
	(`durability`; they never break, they stop firing when Ruined); their `attack` is the bash of a
	lowered gun. Handguns lie flat, long guns tilted 30 degrees, barrels to the right. Magazines wear
	as their rounds are fired. Ammunition stacks: 9mm, .357, buckshot and slug shells, .22, 5.56,
	7.62, .308 and crossbow bolts. Attachments: a red dot sight and a rifle scope, a suppressor and
	an improvised one (a bottle and tape) that wear, and a weapon flashlight. Melee: a kitchen knife
	and a hunting knife (swords), a pipe wrench (no tool, it wears like the bats) and a sledgehammer
	(a pickaxe), modelled upright and tilted like Minecraft's tools. A gun's boxes are its design's,
	drawn at its WeaponList `scale` so it fits the icon's cube (the pack's _models `drawn`).
]]

local Define = require(script.Parent.Parent.Parent.Parent.Define)
local Schema = require(script.Parent.Parent.Parent.Parent.Schema)
local models = require(script.Parent.Parent._models)

type ModelBox = Schema.ModelBox

local GUNMETAL, POLY, STOCK, DARK = models.GUNMETAL, models.POLY, models.STOCK, models.DARK
local GUN_STEEL, BRASS, OLIVE, TIP_COPPER = models.GUN_STEEL, models.BRASS, models.OLIVE, models.TIP_COPPER

return function(_define: Define.Context): { Schema.ItemSpec }
	local box, cartridges, shells, boltRifle, drawn =
		models.box, models.cartridges, models.shells, models.boltRifle, models.drawn

	local hunting = boltRifle(DARK)
	table.insert(hunting, box({ 10, 2.4, 2.4 }, { -1, 4.5, 0 }, POLY, "SmoothPlastic"))
	table.insert(hunting, box({ 1, 3, 3 }, { 4, 4.5, 0 }, POLY, "SmoothPlastic"))
	table.insert(hunting, box({ 1, 3, 3 }, { -6, 4.5, 0 }, POLY, "SmoothPlastic"))
	local THREE = { -3, 0, 3 }
	local rounds556 = cartridges(THREE, { 1.8, 6 }, BRASS, { 1, 1.5 }, { 120, 120, 124 }, 5)
	for _, x in THREE do
		table.insert(rounds556, box({ 1.2, 1.5, 1.2 }, { x, 3.7, 0 }, BRASS))
	end

	return {
		--[[ Firearms ]]
		{
			name = "Pistol",
			displayName = "9mm Pistol",
			durability = 1500,
			attack = { damage = 3, speed = 1.0 },
			color = GUNMETAL,
			material = "Metal",
			model = drawn("Pistol", {
				box({ 11, 3, 2.5 }, { 0.5, 2, 0 }, GUNMETAL),
				box({ 9, 1.5, 2.4 }, { 0, 0.25, 0 }, POLY, "SmoothPlastic"),
				box({ 3, 6, 2.6 }, { -3.5, -3, 0 }, POLY, "SmoothPlastic", -12),
				box({ 3, 1, 1 }, { -0.5, -1.2, 0 }, POLY, "SmoothPlastic"),
			}),
			tilt = 0,
		},
		{
			name = "Revolver",
			durability = 1500,
			attack = { damage = 3, speed = 1.0 },
			color = GUN_STEEL,
			material = "Metal",
			model = drawn("Revolver", {
				box({ 8, 1.6, 1.6 }, { 4, 2, 0 }, GUN_STEEL),
				box({ 4, 3.4, 3 }, { -1, 1.6, 0 }, GUN_STEEL),
				box({ 5, 3, 2 }, { -1, 1.5, 0 }, GUNMETAL),
				box({ 3, 6, 2.6 }, { -4, -2.5, 0 }, STOCK, "Wood", -20),
			}),
			tilt = 0,
		},
		{
			name = "Smg",
			displayName = "SMG",
			durability = 2000,
			attack = { damage = 3, speed = 1.0 },
			color = POLY,
			material = "Metal",
			model = drawn("Smg", {
				box({ 12, 4, 3 }, { 0, 1, 0 }, POLY, "SmoothPlastic"),
				box({ 4, 1.5, 1.5 }, { 8, 1.5, 0 }, GUN_STEEL),
				box({ 2.5, 5, 2.6 }, { -2, -3, 0 }, POLY, "SmoothPlastic", -10),
				box({ 6, 2, 2 }, { -9, 1, 0 }, POLY, "SmoothPlastic"),
			}),
			tilt = 0,
		},
		{
			name = "PumpShotgun",
			durability = 800,
			attack = { damage = 4, speed = 1.0 },
			color = STOCK,
			material = "Metal",
			model = drawn("PumpShotgun", {
				box({ 20, 1.6, 1.6 }, { 3, 2, 0 }, GUN_STEEL),
				box({ 14, 1.4, 1.4 }, { 1, 0.4, 0 }, GUN_STEEL),
				box({ 5, 2.2, 2.4 }, { 6, 0.3, 0 }, STOCK, "Wood"),
				box({ 7, 3.5, 2.6 }, { -6, 1, 0 }, GUNMETAL),
				box({ 9, 3.5, 2.4 }, { -14, 0, 0 }, STOCK, "Wood", 8),
			}),
			tilt = 30,
		},
		{
			name = "DoubleBarrelShotgun",
			displayName = "Double-Barrel Shotgun",
			durability = 600,
			attack = { damage = 4, speed = 1.0 },
			color = STOCK,
			material = "Metal",
			model = drawn("DoubleBarrelShotgun", {
				box({ 18, 1.5, 1.5 }, { 4, 2.4, 0 }, GUN_STEEL),
				box({ 18, 1.5, 1.5 }, { 4, 0.9, 0 }, GUN_STEEL),
				box({ 5, 3.5, 2.6 }, { -7, 1.4, 0 }, GUNMETAL),
				box({ 6, 1.8, 2.4 }, { 2, 0, 0 }, STOCK, "Wood"),
				box({ 10, 4, 2.4 }, { -14, 0, 0 }, STOCK, "Wood", 10),
			}),
			tilt = 30,
		},
		{
			name = "BoltActionRifle",
			displayName = "Bolt-Action Rifle",
			durability = 1200,
			attack = { damage = 4, speed = 1.0 },
			color = STOCK,
			material = "Metal",
			model = drawn("BoltActionRifle", boltRifle(STOCK)),
			tilt = 30,
		},
		{
			name = "SemiAutoRifle",
			displayName = "Semi-Auto Rifle",
			durability = 1500,
			attack = { damage = 4, speed = 1.0 },
			color = DARK,
			material = "Metal",
			model = drawn("SemiAutoRifle", {
				box({ 24, 3, 2.4 }, { -2, 0, 0 }, DARK, "Wood"),
				box({ 12, 1.2, 1.2 }, { 13, 1.6, 0 }, GUN_STEEL),
				box({ 8, 2.6, 2 }, { -1, 2.2, 0 }, GUNMETAL),
				box({ 3, 3, 2 }, { -1, -1.5, 0 }, GUNMETAL),
			}),
			tilt = 30,
		},
		{
			name = "AssaultRifle",
			durability = 2500,
			attack = { damage = 4, speed = 1.0 },
			color = POLY,
			material = "Metal",
			model = drawn("AssaultRifle", {
				box({ 12, 4, 2.8 }, { 0, 1.5, 0 }, POLY, "SmoothPlastic"),
				box({ 7, 3, 3 }, { 7, 2, 0 }, POLY, "SmoothPlastic"),
				box({ 8, 1.4, 1.4 }, { 10, 2, 0 }, GUN_STEEL),
				box({ 7, 3, 2.4 }, { -10, 1, 0 }, POLY, "SmoothPlastic"),
				box({ 2.5, 5, 2.6 }, { -2, -2.5, 0 }, POLY, "SmoothPlastic", -15),
				box({ 8, 1, 2 }, { 0, 4, 0 }, POLY, "SmoothPlastic"),
			}),
			tilt = 30,
		},
		{
			name = "HuntingRifle",
			durability = 1200,
			attack = { damage = 4, speed = 1.0 },
			color = DARK,
			material = "Metal",
			model = drawn("HuntingRifle", hunting),
			tilt = 30,
		},
		{
			name = "SmallBoreRifle",
			displayName = "Small-Bore Rifle",
			durability = 2500,
			attack = { damage = 3, speed = 1.0 },
			color = STOCK,
			material = "Metal",
			model = drawn("SmallBoreRifle", {
				box({ 18, 3, 2.2 }, { -2, 0, 0 }, STOCK, "Wood"),
				box({ 9, 1, 1 }, { 11, 1.6, 0 }, GUN_STEEL),
				box({ 6, 2.4, 2 }, { -1, 2, 0 }, GUNMETAL),
			}),
			tilt = 30,
		},
		{
			name = "Crossbow",
			durability = 600,
			attack = { damage = 3, speed = 1.0 },
			color = STOCK,
			material = "Wood",
			model = drawn("Crossbow", {
				box({ 16, 2.5, 2.4 }, { 0, 0, 0 }, STOCK, "Wood"),
				box({ 1.5, 16, 1.5 }, { 7, 1, 0 }, POLY, "SmoothPlastic"),
				box({ 1, 15, 0.4 }, { 3, 1, 0 }, { 230, 230, 220 }, "Fabric"),
				box({ 2, 3, 1.5 }, { 9.5, 1, 0 }, GUN_STEEL, "Metal"),
			}),
			tilt = 30,
		},

		--[[ Magazines ]]
		{
			name = "PistolMagazine",
			displayName = "9mm Pistol Magazine",
			durability = 1500,
			color = POLY,
			material = "SmoothPlastic",
			model = {
				box({ 2.4, 8, 2 }, { 0, 0, 0 }, POLY),
				box({ 3, 1, 2.4 }, { 0, -4.3, 0 }, POLY),
			},
		},
		{
			name = "SmgMagazine",
			displayName = "SMG Magazine",
			durability = 2000,
			color = POLY,
			material = "SmoothPlastic",
			model = {
				box({ 3, 12, 2.2 }, { 0, 0, 0 }, POLY),
				box({ 3.6, 1, 2.6 }, { 0, -6.3, 0 }, POLY),
			},
		},
		{
			name = "RifleMagazine",
			displayName = "Assault Rifle Magazine",
			durability = 2500,
			color = OLIVE,
			material = "SmoothPlastic",
			model = {
				box({ 3.5, 12, 2.4 }, { 0, 0, 0 }, OLIVE, nil, 12),
				box({ 4, 1, 2.8 }, { 1.2, -6, 0 }, POLY, nil, 12),
			},
		},
		{
			name = "HuntingMagazine",
			displayName = "Hunting Rifle Magazine",
			durability = 1200,
			color = POLY,
			material = "SmoothPlastic",
			model = { box({ 3, 4, 2.4 }, { 0, 0, 0 }, POLY) },
		},
		{
			name = "SmallBoreMagazine",
			displayName = ".22 Magazine",
			durability = 2500,
			color = POLY,
			material = "SmoothPlastic",
			model = {
				box({ 4, 4, 2.4 }, { 0, 0, 0 }, POLY),
				{
					size = { 2.6, 2.6, 2.6 },
					offset = { 0, 0, 1 },
					color = GUNMETAL,
					material = "Metal",
					shape = "Cylinder",
				},
			},
		},

		--[[ Ammunition ]]
		{
			name = "Rounds9mm",
			displayName = "9mm Rounds",
			maxStack = 60,
			color = BRASS,
			material = "Metal",
			model = cartridges(THREE, { 2, 4 }, BRASS, { 1.6, 1.6 }, { 180, 120, 70 }, 2.6, "Ball"),
		},
		{
			name = "Rounds357",
			displayName = ".357 Rounds",
			maxStack = 40,
			color = BRASS,
			material = "Metal",
			model = cartridges(THREE, { 2, 5.5 }, BRASS, { 1.6, 1.6 }, { 200, 200, 205 }, 3.35, "Ball"),
		},
		{
			name = "Buckshot",
			displayName = "12 Gauge Buckshot",
			maxStack = 30,
			color = { 170, 40, 36 },
			material = "SmoothPlastic",
			model = shells({ 170, 40, 36 }),
		},
		{
			name = "Slugs",
			displayName = "12 Gauge Slugs",
			maxStack = 30,
			color = { 50, 110, 60 },
			material = "SmoothPlastic",
			model = shells({ 50, 110, 60 }),
		},
		{
			name = "Rounds22",
			displayName = ".22 Rounds",
			-- (The design's 100 is past every slot's limit of 64: Inventory/Menu caps stacks there.)
			maxStack = 64,
			color = BRASS,
			material = "Metal",
			model = cartridges({ -4.5, -1.5, 1.5, 4.5 }, { 1.2, 3 }, BRASS, { 1, 1 }, { 170, 110, 70 }),
		},
		{
			name = "Rounds556",
			displayName = "5.56 Rounds",
			maxStack = 60,
			color = BRASS,
			material = "Metal",
			model = rounds556,
		},
		{
			name = "Rounds762",
			displayName = "7.62 Rounds",
			maxStack = 40,
			color = { 120, 120, 110 },
			material = "Metal",
			model = cartridges(THREE, { 2.2, 6 }, { 120, 120, 110 }, { 1.6, 2 }, TIP_COPPER, 4),
		},
		{
			name = "Rounds308",
			displayName = ".308 Rounds",
			maxStack = 40,
			color = BRASS,
			material = "Metal",
			model = cartridges(THREE, { 2.4, 8 }, BRASS, { 1.6, 2.4 }, TIP_COPPER, 5),
		},
		{
			name = "CrossbowBolt",
			maxStack = 16,
			color = STOCK,
			material = "Wood",
			model = {
				box({ 1, 14, 1 }, { 0, 0, 0 }, STOCK),
				box({ 2, 2, 1 }, { 0, 7.5, 0 }, GUN_STEEL, "Metal", 45),
				box({ 3, 3, 0.4 }, { 0, -6, 0 }, { 180, 40, 40 }, "Fabric"),
			},
			tilt = -45,
		},

		--[[ Attachments ]]
		{
			name = "RedDotSight",
			maxStack = 1,
			color = POLY,
			material = "SmoothPlastic",
			model = {
				box({ 6, 1.5, 3 }, { 0, -2, 0 }, POLY),
				box({ 4, 4, 3 }, { 0, 0.5, 0 }, POLY),
				box({ 2.5, 2.5, 0.4 }, { 0, 0.5, 1.6 }, { 220, 60, 60 }, "Glass"),
			},
		},
		{
			name = "RifleScope",
			maxStack = 1,
			color = POLY,
			material = "SmoothPlastic",
			model = {
				box({ 14, 2.6, 2.6 }, { 0, 0, 0 }, POLY),
				box({ 3, 3.6, 3.6 }, { -6, 0, 0 }, POLY),
				box({ 4, 4, 4 }, { 6, 0, 0 }, POLY),
				box({ 2, 2, 2 }, { 0, 2, 0 }, POLY),
			},
		},
		{
			name = "Suppressor",
			durability = 400,
			color = POLY,
			material = "Metal",
			model = {
				box({ 12, 3.2, 3.2 }, { 0, 0, 0 }, POLY),
				box({ 1, 3.4, 3.4 }, { -5.5, 0, 0 }, GUN_STEEL),
			},
		},
		{
			name = "ImprovisedSuppressor",
			durability = 40,
			color = { 150, 190, 215 },
			material = "Glass",
			model = {
				box({ 9, 4, 4 }, { 0, 0, 0 }, { 150, 190, 215 }, "Glass"),
				box({ 1.5, 4.4, 4.4 }, { -2.5, 0, 0 }, { 150, 154, 158 }, "Fabric"),
				box({ 1.5, 4.4, 4.4 }, { 2, 0, 0 }, { 150, 154, 158 }, "Fabric"),
			},
		},
		{
			name = "WeaponFlashlight",
			maxStack = 1,
			color = POLY,
			material = "SmoothPlastic",
			model = {
				box({ 6, 2.6, 2.6 }, { 0, 0, 0 }, POLY),
				box({ 2, 3.6, 3.6 }, { 3.5, 0, 0 }, POLY),
				box({ 0.4, 2.8, 2.8 }, { 4.7, 0, 0 }, { 255, 240, 180 }, "Glass"),
			},
		},

		--[[ Melee ]]
		{
			name = "KitchenKnife",
			tool = { kind = "sword", speed = 2, level = 0 },
			attack = { damage = 4, speed = 2.0 },
			durability = 100,
			color = GUN_STEEL,
			material = "Metal",
			model = {
				box({ 2, 9, 0.6 }, { 0, 3, 0 }, GUN_STEEL),
				box({ 0.6, 9, 0.7 }, { -0.8, 3, 0 }, { 200, 204, 208 }),
				box({ 1.8, 5, 1.4 }, { 0, -4.5, 0 }, POLY, "SmoothPlastic"),
			},
			tilt = -45,
		},
		{
			name = "HuntingKnife",
			tool = { kind = "sword", speed = 4, level = 1 },
			attack = { damage = 5, speed = 1.8 },
			durability = 250,
			color = GUN_STEEL,
			material = "Metal",
			model = {
				box({ 2.6, 9, 0.8 }, { 0, 3, 0 }, GUN_STEEL),
				box({ 1.8, 1.8, 0.8 }, { 0, 7.5, 0 }, GUN_STEEL, nil, 45),
				box({ 4, 1, 1.6 }, { 0, -1.5, 0 }, GUN_STEEL),
				box({ 2, 5, 1.8 }, { 0, -4.5, 0 }, DARK, "Wood"),
			},
			tilt = -45,
		},
		{
			name = "PipeWrench",
			attack = { damage = 6, speed = 1.0 },
			durability = 300,
			color = { 170, 40, 30 },
			material = "Metal",
			model = {
				box({ 2, 14, 1.6 }, { 0, -1, 0 }, { 170, 40, 30 }),
				box({ 5, 2.5, 2 }, { -1, 7, 0 }, GUN_STEEL),
				box({ 2, 4, 2 }, { -3, 5.5, 0 }, GUN_STEEL),
				box({ 2, 1, 2.2 }, { 0, 5, 0 }, GUN_STEEL),
			},
			tilt = -45,
		},
		{
			name = "Sledgehammer",
			-- (Speed 4, the stone pickaxe's, as the Crowbar's: WAILA names a tier's slowest tool.)
			tool = { kind = "pickaxe", speed = 4, level = 1 },
			attack = { damage = 8, speed = 0.6 },
			durability = 300,
			color = GUNMETAL,
			material = "Metal",
			model = {
				box({ 1.5, 17, 1.5 }, { 0, -1.5, 0 }, STOCK, "Wood"),
				box({ 7, 4, 4 }, { 0, 7.5, 0 }, GUNMETAL),
			},
			tilt = -45,
		},
	}
end
