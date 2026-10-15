--!strict
--[[
	The weapons' numbers in the manner of DayZ (data only, keyed by item name as Items/Foods is;
	Shared/Weapons reads and checks it as it loads, and answers by item id). The items themselves
	(name, model, durability, stack size, the bash or light attack) are Items/ItemList's; what makes
	them weapons is here:

	  firearms     how each gun shoots: its class (the fire sound's and the HUD's), its calibre, its
	               feed (a detachable magazine item, or an internal magazine of `internal` rounds;
	               every gun also has a one-round chamber), its fire modes in order (the stack's
	               data `mode` is the index, 1 the first) with their rates (rounds a minute, the
	               whole cycle: a pump's or a bolt's is in it), the damage scale on its ammunition's,
	               the spread, recoil and sway (degrees), the noise (blocks the infected hear it), the
	               distance its sights are zeroed at (blocks), the ticks of a magazine swap, of
	               chambering and of loading one round by hand, whether it jams, which attachment
	               mounts it has, its `scale` and its `look`: where the hand holds it, the barrel's
	               end, the sight line and the mounts (pixels in the item's model space, x along the
	               barrel, y up; ItemModels dresses and aims it with them). `scale` (default 1) is the
	               share of the design's pixels the gun is drawn at: Items/ItemList scales its boxes
	               and Shared/Weapons its look by it, so a long gun fits the icon's cube (10 pixels
	               each way: tests/spec/Meshing) and keeps its proportions to the others'.
	  ammo         a round by calibre: damage (half hearts at full range), pellets and their cone
	               (degrees), muzzle velocity (blocks a second: for the drop and the zero only, a hit
	               lands at once), the range of full damage, the share left at the longest flight
	               (`falloffMin`), and whether a spent one can be picked up again (`recover`: the
	               crossbow's bolts; how often is Config.Weapons.BoltRecover's alone, the one place
	               that chance is tuned)
	  magazines    detachable magazines: calibre, capacity and the guns they fit
	  attachments  optics (`zoom`), muzzle devices (`noise` share, `spread` share, `suppressed`
	               sound and no flash, `glow` false: tracers without glow) and the weapon light
	               (`beam`: range in blocks, cone angle, brightness), each with the guns it fits
	  melee        the melee rework's weapons (Shared/Weapons/Melee): a heavy attack's damage,
	               the guard's share of a zombie's hit it blocks, and whether it kills an unaware
	               zombie from behind (`finisher`)

	Balance numbers are FOUNDATION's (the weapons design, section 3); the client builder may tune
	the `look` blocks only. A new weapon is an item in ItemList (appended) and an entry here.

	  Weapon               class     calibre feed               modes (rpm)          dmg   jams
	  Pistol               pistol    9mm     PistolMagazine     semi 300             1.0   yes
	  Revolver             revolver  357     internal 5         semi 120             1.0   no
	  Smg                  smg       9mm     SmgMagazine        semi 400, auto 700   0.85  yes
	  PumpShotgun          shotgun   12g     internal 5         semi 60              1.0   yes
	  DoubleBarrelShotgun  shotgun   12g     internal 1         semi 240             1.0   no
	  BoltActionRifle      heavy     762     internal 4         semi 40              1.1   yes
	  SemiAutoRifle        rifle     762     internal 10        semi 240             0.9   yes
	  AssaultRifle         rifle     556     RifleMagazine      semi 300, auto 700   1.0   yes
	  HuntingRifle         heavy     308     HuntingMagazine    semi 45              1.0   yes
	  SmallBoreRifle       small     22      SmallBoreMagazine  semi 300             1.0   yes
	  Crossbow             crossbow  bolt    internal 0         semi 12              1.0   no
]]

-- A point in an item's model (pixels): { x, y } or { x, y, z } (z 0 when left out).
export type Point = { number }

-- Where ItemModels holds, aims and dresses a firearm (pixels, the model before its tilt).
export type Look = {
	-- Where the hand holds it.
	grip: Point,
	-- The barrel's end (tracers and flashes start here; a muzzle device mounts here).
	muzzle: Point,
	-- The sight line's height.
	sight: number,
	-- Mounts: the magazine (it hangs below this point), an optic, the weapon light.
	mag: Point?,
	optic: Point?,
	light: Point?,
}

export type FireModeKind = "semi" | "auto"
export type FireMode = { kind: FireModeKind, rpm: number }

export type FirearmData = {
	class: string,
	calibre: string,
	-- Detachable feed: the magazine item's name. nil: an internal magazine of `internal` rounds.
	magazine: string?,
	internal: number?,
	modes: { FireMode },
	damageScale: number,
	spread: number,
	recoil: number,
	recoilYaw: number,
	sway: number,
	noise: number,
	zero: number,
	-- Ticks: a magazine swap, chambering, one round by hand (0: none).
	reloadTicks: number,
	chamberTicks: number,
	roundTicks: number,
	jams: boolean,
	-- Mounts it has: "optic", "muzzle", "light".
	mounts: { string },
	-- A pump or a bolt: the client plays the chamber sound after each shot.
	cycle: boolean?,
	-- A built-in scope's zoom (no optic mount).
	scope: number?,
	-- The share of these pixels the model and the look are drawn at (default 1).
	scale: number?,
	look: Look,
}

export type AmmoData = {
	calibre: string,
	damage: number,
	pellets: number,
	-- The pellets' cone (degrees, half angle); 0 for one projectile.
	cone: number,
	velocity: number,
	range: number,
	falloffMin: number,
	-- A spent one may drop again where it stopped (the chance: Config.Weapons.BoltRecover).
	recover: boolean?,
}

export type MagazineData = { calibre: string, capacity: number, fits: { string } }

export type Beam = { range: number, angle: number, brightness: number }

export type AttachmentData = {
	-- "optic" | "muzzle" | "light"
	slot: string,
	-- Optic: field of view divided by this in the sights.
	zoom: number?,
	-- Muzzle device: the shot's noise times this, its spread times this (default 1), the
	-- suppressed sound with no muzzle flash, and (false) tracers without glow.
	noise: number?,
	spread: number?,
	suppressed: boolean?,
	glow: boolean?,
	-- Weapon light: its spotlight.
	beam: Beam?,
	fits: { string },
}

export type MeleeData = { heavy: number, guard: number, finisher: boolean }

local function semi(rpm: number): FireMode
	return { kind = "semi", rpm = rpm }
end

local function auto(rpm: number): FireMode
	return { kind = "auto", rpm = rpm }
end

local WeaponList = {}

WeaponList.firearms = {
	Pistol = {
		class = "pistol",
		calibre = "9mm",
		magazine = "PistolMagazine",
		modes = { semi(300) },
		damageScale = 1.0,
		spread = 0.8,
		recoil = 2.0,
		recoilYaw = 0.3,
		sway = 0.5,
		noise = 48,
		zero = 25,
		reloadTicks = 40,
		chamberTicks = 10,
		roundTicks = 0,
		jams = true,
		mounts = { "optic", "muzzle", "light" },
		look = {
			grip = { -3.5, -3 },
			muzzle = { 6, 2 },
			sight = 3.6,
			mag = { -3.5, 2 },
			optic = { 0, 3.5 },
			light = { 3, -1.6 },
		},
	},
	Revolver = {
		class = "revolver",
		calibre = "357",
		internal = 5,
		modes = { semi(120) },
		damageScale = 1.0,
		spread = 0.6,
		recoil = 3.5,
		recoilYaw = 0.3,
		sway = 0.5,
		noise = 56,
		zero = 25,
		reloadTicks = 0,
		chamberTicks = 0,
		roundTicks = 16,
		jams = false,
		mounts = {},
		look = { grip = { -4, -2.5 }, muzzle = { 8, 2 }, sight = 3.4 },
	},
	Smg = {
		class = "smg",
		calibre = "9mm",
		magazine = "SmgMagazine",
		modes = { semi(400), auto(700) },
		damageScale = 0.85,
		spread = 1.2,
		recoil = 1.2,
		recoilYaw = 0.3,
		sway = 0.45,
		noise = 48,
		zero = 30,
		reloadTicks = 45,
		chamberTicks = 10,
		roundTicks = 0,
		jams = true,
		mounts = { "optic", "muzzle", "light" },
		scale = 0.8,
		look = {
			grip = { -2, -3 },
			muzzle = { 10, 1.5 },
			sight = 3.1,
			mag = { 2, -1 },
			optic = { 0, 3.2 },
			light = { 8, -0.6 },
		},
	},
	PumpShotgun = {
		class = "shotgun",
		calibre = "12g",
		internal = 5,
		modes = { semi(60) },
		damageScale = 1.0,
		spread = 0.8,
		recoil = 5.0,
		recoilYaw = 0.3,
		sway = 0.6,
		noise = 72,
		zero = 20,
		reloadTicks = 0,
		chamberTicks = 0,
		roundTicks = 14,
		jams = true,
		mounts = { "optic", "light" },
		cycle = true,
		scale = 0.58,
		look = {
			grip = { -9, -0.5 },
			muzzle = { 13, 2 },
			sight = 2.9,
			optic = { -6, 3 },
			light = { 11, -1.2 },
		},
	},
	DoubleBarrelShotgun = {
		class = "shotgun",
		calibre = "12g",
		internal = 1,
		modes = { semi(240) },
		damageScale = 1.0,
		spread = 0.9,
		recoil = 6.0,
		recoilYaw = 0.3,
		sway = 0.6,
		noise = 72,
		zero = 20,
		reloadTicks = 0,
		chamberTicks = 0,
		roundTicks = 14,
		jams = false,
		mounts = {},
		scale = 0.58,
		look = { grip = { -10, -0.5 }, muzzle = { 13, 1.65 }, sight = 3.2 },
	},
	BoltActionRifle = {
		class = "heavy",
		calibre = "762",
		internal = 4,
		modes = { semi(40) },
		damageScale = 1.1,
		spread = 0.1,
		recoil = 6.0,
		recoilYaw = 0.3,
		sway = 0.4,
		noise = 96,
		zero = 100,
		reloadTicks = 0,
		chamberTicks = 0,
		roundTicks = 16,
		jams = true,
		mounts = { "optic", "muzzle" },
		cycle = true,
		scale = 0.58,
		look = { grip = { -7, -1 }, muzzle = { 19, 1.6 }, sight = 3.2, optic = { -2, 3.4 } },
	},
	SemiAutoRifle = {
		class = "rifle",
		calibre = "762",
		internal = 10,
		modes = { semi(240) },
		damageScale = 0.9,
		spread = 0.25,
		recoil = 3.5,
		recoilYaw = 0.3,
		sway = 0.45,
		noise = 88,
		zero = 100,
		reloadTicks = 0,
		chamberTicks = 0,
		roundTicks = 12,
		jams = true,
		mounts = { "optic", "muzzle" },
		scale = 0.58,
		look = { grip = { -7, -1 }, muzzle = { 19, 1.6 }, sight = 3.6, optic = { -1, 3.7 } },
	},
	AssaultRifle = {
		class = "rifle",
		calibre = "556",
		magazine = "RifleMagazine",
		modes = { semi(300), auto(700) },
		damageScale = 1.0,
		spread = 0.35,
		recoil = 1.6,
		recoilYaw = 0.3,
		sway = 0.4,
		noise = 80,
		zero = 100,
		reloadTicks = 50,
		chamberTicks = 12,
		roundTicks = 0,
		jams = true,
		mounts = { "optic", "muzzle", "light" },
		scale = 0.58,
		look = {
			grip = { -2, -2.5 },
			muzzle = { 14, 2 },
			sight = 4.6,
			mag = { 2, -0.5 },
			optic = { 0, 4.6 },
			light = { 8, -0.9 },
		},
	},
	HuntingRifle = {
		class = "heavy",
		calibre = "308",
		magazine = "HuntingMagazine",
		modes = { semi(45) },
		damageScale = 1.0,
		spread = 0.08,
		recoil = 6.5,
		recoilYaw = 0.3,
		sway = 0.35,
		noise = 96,
		zero = 100,
		reloadTicks = 45,
		chamberTicks = 16,
		roundTicks = 0,
		jams = true,
		mounts = {},
		scope = 4,
		scale = 0.58,
		look = { grip = { -7, -1 }, muzzle = { 19, 1.6 }, sight = 4.5, mag = { -1, -1.5 } },
	},
	SmallBoreRifle = {
		class = "small",
		calibre = "22",
		magazine = "SmallBoreMagazine",
		modes = { semi(300) },
		damageScale = 1.0,
		spread = 0.3,
		recoil = 0.8,
		recoilYaw = 0.3,
		sway = 0.4,
		noise = 24,
		zero = 50,
		reloadTicks = 35,
		chamberTicks = 10,
		roundTicks = 0,
		jams = true,
		mounts = { "optic", "muzzle" },
		scale = 0.58,
		look = { grip = { -6, -1 }, muzzle = { 15.5, 1.6 }, sight = 3.3, mag = { 0, -1.5 }, optic = { -1, 3.4 } },
	},
	Crossbow = {
		class = "crossbow",
		calibre = "bolt",
		internal = 0,
		modes = { semi(12) },
		damageScale = 1.0,
		spread = 0.2,
		recoil = 1.0,
		recoilYaw = 0.3,
		sway = 0.4,
		noise = 6,
		zero = 30,
		reloadTicks = 0,
		chamberTicks = 0,
		roundTicks = 60,
		jams = false,
		mounts = { "optic" },
		scale = 0.58,
		look = { grip = { -5, -1.5 }, muzzle = { 10.5, 1.3 }, sight = 2, optic = { -2, 2 } },
	},
} :: { [string]: FirearmData }

WeaponList.ammo = {
	Rounds9mm = { calibre = "9mm", damage = 7, pellets = 1, cone = 0, velocity = 350, range = 40, falloffMin = 0.5 },
	Rounds357 = { calibre = "357", damage = 10, pellets = 1, cone = 0, velocity = 430, range = 45, falloffMin = 0.5 },
	Buckshot = { calibre = "12g", damage = 2.5, pellets = 8, cone = 3.5, velocity = 400, range = 10, falloffMin = 0.2 },
	Slugs = { calibre = "12g", damage = 16, pellets = 1, cone = 0, velocity = 450, range = 60, falloffMin = 0.5 },
	Rounds22 = { calibre = "22", damage = 5, pellets = 1, cone = 0, velocity = 370, range = 80, falloffMin = 0.5 },
	Rounds556 = { calibre = "556", damage = 11, pellets = 1, cone = 0, velocity = 900, range = 140, falloffMin = 0.5 },
	Rounds762 = { calibre = "762", damage = 20, pellets = 1, cone = 0, velocity = 760, range = 180, falloffMin = 0.5 },
	Rounds308 = { calibre = "308", damage = 24, pellets = 1, cone = 0, velocity = 850, range = 220, falloffMin = 0.5 },
	CrossbowBolt = {
		calibre = "bolt",
		damage = 16,
		pellets = 1,
		cone = 0,
		velocity = 60,
		range = 60,
		falloffMin = 0.6,
		recover = true,
	},
} :: { [string]: AmmoData }

WeaponList.magazines = {
	PistolMagazine = { calibre = "9mm", capacity = 15, fits = { "Pistol" } },
	SmgMagazine = { calibre = "9mm", capacity = 30, fits = { "Smg" } },
	RifleMagazine = { calibre = "556", capacity = 30, fits = { "AssaultRifle" } },
	HuntingMagazine = { calibre = "308", capacity = 5, fits = { "HuntingRifle" } },
	SmallBoreMagazine = { calibre = "22", capacity = 10, fits = { "SmallBoreRifle" } },
} :: { [string]: MagazineData }

WeaponList.attachments = {
	RedDotSight = {
		slot = "optic",
		zoom = 1.4,
		fits = { "Pistol", "Smg", "PumpShotgun", "AssaultRifle", "SemiAutoRifle", "SmallBoreRifle", "Crossbow" },
	},
	RifleScope = {
		slot = "optic",
		zoom = 4,
		fits = { "BoltActionRifle", "SemiAutoRifle", "AssaultRifle", "SmallBoreRifle" },
	},
	Suppressor = {
		slot = "muzzle",
		noise = 0.25,
		spread = 0.9,
		suppressed = true,
		glow = false,
		fits = { "Pistol", "Smg", "AssaultRifle", "SemiAutoRifle", "SmallBoreRifle" },
	},
	ImprovisedSuppressor = {
		slot = "muzzle",
		noise = 0.45,
		suppressed = true,
		fits = { "Pistol", "Smg", "AssaultRifle", "SemiAutoRifle", "SmallBoreRifle", "BoltActionRifle" },
	},
	WeaponFlashlight = {
		slot = "light",
		beam = { range = 24, angle = 45, brightness = 3 },
		fits = { "Pistol", "Smg", "PumpShotgun", "AssaultRifle" },
	},
} :: { [string]: AttachmentData }

-- (The light attack is ItemList's `attack`; Machete, the bats, the Crowbar and the Fire Axe are
-- the zombie apocalypse's.)
WeaponList.melee = {
	KitchenKnife = { heavy = 7, guard = 0.3, finisher = true },
	HuntingKnife = { heavy = 9, guard = 0.35, finisher = true },
	Machete = { heavy = 11, guard = 0.5, finisher = false },
	BaseballBat = { heavy = 10, guard = 0.6, finisher = false },
	SpikedBat = { heavy = 13, guard = 0.6, finisher = false },
	Crowbar = { heavy = 9, guard = 0.6, finisher = false },
	FireAxe = { heavy = 16, guard = 0.6, finisher = false },
	PipeWrench = { heavy = 11, guard = 0.6, finisher = false },
	Sledgehammer = { heavy = 18, guard = 0.7, finisher = false },
} :: { [string]: MeleeData }

return WeaponList
