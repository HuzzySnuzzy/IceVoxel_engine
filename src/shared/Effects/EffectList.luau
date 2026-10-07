--!strict
--[[
	Every status effect (Minecraft 1.20.1's MobEffect, with this game's and Tough As Nails' own). An
	effect's id is its position in this list, so:

	  * ALWAYS ADD NEW EFFECTS AT THE END. The ids are sent (Protocol `Effects`) and must fit a u8.

	Pure data that requires nothing, so Items (potions) and Fluids (FluidList `effects`) may read
	it; Shared/Effects turns it into the registry and the rules everything shares.

	Fields (all optional but `name`, `command`, `color`, `category` and `icon`):
	  name         Unique name, `Effects.id.Name`, and what data names it by (FluidList, PotionList).
	  displayName  Shown on the HUD, in tooltips and in /effect's answers (default: the name with
	               spaces, "JumpBoost" -> "Jump Boost").
	  command      Its /effect id: Minecraft's (effect.minecraft.<id>: "jump_boost"), this game's
	               ("oil_coated") or Tough As Nails' ("thirst"). "minecraft:" in front is accepted.
	  color        { r, g, b } 0-255: Minecraft's MobEffect colour (a potion's liquid and icon).
	  category     "beneficial" | "harmful" | "neutral" (MobEffectCategory): the HUD's rows, the
	               tooltip's colour.
	  icon         The HUD glyph (client Ui/EffectIcons) drawn in the effect's colour.
	Attribute modifiers, per level (amplifier + 1):
	  speed        movement speed MULTIPLY_TOTAL (Speed +0.2, Slowness -0.15, Oil Coated -0.15):
	               the ground speed is multiplied by 1 + speed x level, each effect in turn.
	  mining       Haste's +0.2 (Player.getDestroySpeed: x (1 + 0.2 x level)).
	  fatigue      Mining Fatigue's table instead: x 0.3, 0.09, 0.0027, 0.00081 (level 4 and up).
	  jump         Jump Boost's +0.1 jump velocity (blocks a tick), and a block less of fall
	               damage per level (LivingEntity.calculateFallDamage).
	  melee        attack damage ADDITION (half hearts): Strength +3, Weakness -4.
	  resistance   share of incoming damage taken off (Resistance 0.2: getDamageAfterMagicAbsorb's
	               (25 - 5 x level) / 25; level 5 and up: nothing gets through).
	Ticking (MobEffect.applyEffectTick, on the ticks isDurationEffectTick picks):
	  interval     ticks between applications, shifted right by the amplifier (Regeneration 50,
	               Poison 25, Wither 40: interval >> amplifier, every tick once that is 0).
	  heal         half hearts healed each application, while not at full health (Regeneration 1).
	  damage       half hearts each application (Poison, Wither 1), magic: through armor.
	  lethal       its damage may kill (Wither); without it the damage only lands while the
	               health is above 1 half heart (Poison: `if (getHealth() > 1.0F)`).
	  instant      "heal" (Instant Health: 4 << amplifier half hearts) or "harm" (Instant Damage:
	               6 << amplifier, magic): applied once, on the tick after it is given, then gone
	               (HealOrHarmMobEffect; given with 1 tick, never shown).
	Fire (server Players/Burning):
	  fireImmune   no hurt from fire, lava, campfires or burning (Fire Resistance: LivingEntity.hurt
	               returns false for IS_FIRE damage; burning itself still counts down).
	  burnFactor   burning set while it lasts lasts this many times longer (Oil Coated 2, Fuel
	               Soaked 3: lava's 15 s become 30 / 45 s, a fire's 8 s 16 / 24 s).
	  burnBonus    half hearts added to every burning hurt (Oil Coated 1: 2 every second).
	  ignites      catches fire in a fire block at once (no 20 tick wait) and from any explosion
	               that hurts (Fuel Soaked: petrol on the skin).
	  washOff      water (a fluid that `extinguishes`) takes it off at once.
	The client:
	  view         "nightVision" | "blindness" | "nausea" (client Rendering/EffectView), "glowing"
	               (an outline everyone sees through walls: the server's Highlight).
	  noSprint     can't start sprinting while it lasts (Blindness: LocalPlayer.canStartSprinting).
	Elsewhere:
	  external     its state is kept by another module (Tough As Nails' Thirst, Internal Warmth,
	               Internal Chill and Climate Clemency: server Players/ToughAsNails) and only read
	               (and given or cleared by /effect) through an adapter (server Players/Effects
	               `addExternal`), so the HUD lists every effect in one place.
]]

export type EffectSpec = {
	name: string,
	displayName: string?,
	command: string,
	color: { number },
	category: string,
	icon: string,
	speed: number?,
	mining: number?,
	fatigue: boolean?,
	jump: number?,
	melee: number?,
	resistance: number?,
	interval: number?,
	heal: number?,
	damage: number?,
	lethal: boolean?,
	instant: string?,
	fireImmune: boolean?,
	burnFactor: number?,
	burnBonus: number?,
	ignites: boolean?,
	washOff: boolean?,
	view: string?,
	noSprint: boolean?,
	external: boolean?,
}

local list: { EffectSpec } = {
	-- 1..18: Minecraft 1.20.1's (MobEffects), with their colours.
	{
		name = "Speed",
		command = "speed",
		color = { 124, 175, 198 },
		category = "beneficial",
		icon = "speed",
		speed = 0.2,
	},
	{
		name = "Slowness",
		command = "slowness",
		color = { 90, 108, 129 },
		category = "harmful",
		icon = "slowness",
		speed = -0.15,
	},
	{
		name = "Haste",
		command = "haste",
		color = { 217, 192, 67 },
		category = "beneficial",
		icon = "pickaxe",
		mining = 0.2,
	},
	{
		name = "MiningFatigue",
		command = "mining_fatigue",
		color = { 74, 66, 23 },
		category = "harmful",
		icon = "pickaxe",
		fatigue = true,
	},
	{
		name = "Strength",
		command = "strength",
		color = { 147, 36, 35 },
		category = "beneficial",
		icon = "sword",
		melee = 3,
	},
	{
		name = "InstantHealth",
		command = "instant_health",
		color = { 248, 36, 35 },
		category = "beneficial",
		icon = "heart",
		instant = "heal",
	},
	{
		name = "InstantDamage",
		command = "instant_damage",
		color = { 67, 10, 9 },
		category = "harmful",
		icon = "broken",
		instant = "harm",
	},
	{
		name = "JumpBoost",
		command = "jump_boost",
		color = { 34, 255, 76 },
		category = "beneficial",
		icon = "jump",
		jump = 0.1,
	},
	{
		name = "Nausea",
		command = "nausea",
		color = { 85, 29, 74 },
		category = "harmful",
		icon = "spiral",
		view = "nausea",
	},
	{
		name = "Regeneration",
		command = "regeneration",
		color = { 205, 92, 171 },
		category = "beneficial",
		icon = "heart",
		interval = 50,
		heal = 1,
	},
	{
		name = "Resistance",
		command = "resistance",
		color = { 153, 69, 58 },
		category = "beneficial",
		icon = "shield",
		resistance = 0.2,
	},
	{
		name = "FireResistance",
		command = "fire_resistance",
		color = { 228, 154, 58 },
		category = "beneficial",
		icon = "flame",
		fireImmune = true,
	},
	{
		name = "Blindness",
		command = "blindness",
		color = { 31, 31, 35 },
		category = "harmful",
		icon = "eye",
		view = "blindness",
		noSprint = true,
	},
	{
		name = "NightVision",
		command = "night_vision",
		color = { 31, 31, 161 },
		category = "beneficial",
		icon = "eye",
		view = "nightVision",
	},
	{
		name = "Weakness",
		command = "weakness",
		color = { 72, 77, 72 },
		category = "harmful",
		icon = "sword",
		melee = -4,
	},
	{
		name = "Poison",
		command = "poison",
		color = { 78, 147, 49 },
		category = "harmful",
		icon = "drop",
		interval = 25,
		damage = 1,
	},
	{
		name = "Wither",
		command = "wither",
		color = { 53, 42, 39 },
		category = "harmful",
		icon = "skull",
		interval = 40,
		damage = 1,
		lethal = true,
	},
	{
		name = "Glowing",
		command = "glowing",
		color = { 148, 160, 97 },
		category = "neutral",
		icon = "star",
		view = "glowing",
	},
	-- 19, 20: this game's, from its fluids (FluidList `effects`). Crude oil coats the skin: slower
	-- and flammable; petrol soaks it: it catches at once and burns far longer. Water washes both off.
	{
		name = "OilCoated",
		command = "oil_coated",
		color = { 66, 58, 76 },
		category = "harmful",
		icon = "drop",
		speed = -0.15,
		burnFactor = 2,
		burnBonus = 1,
		washOff = true,
	},
	{
		name = "FuelSoaked",
		command = "fuel_soaked",
		color = { 232, 172, 44 },
		category = "harmful",
		icon = "drop",
		burnFactor = 3,
		ignites = true,
		washOff = true,
	},
	-- 21..24: Tough As Nails' (its MobEffects in TAN 1.20), kept by Shared/ToughAsNails' states.
	{
		name = "Thirst",
		command = "thirst",
		color = { 112, 160, 64 },
		category = "harmful",
		icon = "drop",
		external = true,
	},
	{
		name = "InternalWarmth",
		command = "internal_warmth",
		color = { 235, 120, 40 },
		category = "beneficial",
		icon = "flame",
		external = true,
	},
	{
		name = "InternalChill",
		command = "internal_chill",
		color = { 150, 210, 255 },
		category = "beneficial",
		icon = "snowflake",
		external = true,
	},
	{
		name = "ClimateClemency",
		command = "climate_clemency",
		color = { 236, 200, 92 },
		category = "beneficial",
		icon = "shield",
		external = true,
	},
}

-- Add new effects above this line, at the end (never reorder: the ids are sent).

return list
