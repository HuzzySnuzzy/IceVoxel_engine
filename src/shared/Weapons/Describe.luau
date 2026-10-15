--!strict
--[[
	Weapons in tooltips, pure (Shared/Items/Tooltip requires this; tests/spec/Tooltips checks it):
	what a firearm, a round, a magazine, an attachment or a melee weapon says, in Minecraft's
	tooltip colours by name (Tooltip's Colour: gray information, darkGreen a weapon's base numbers,
	blue a good modifier, red a warning).

	  state  the stack's own weapon data (Weapons/WeaponState, read through `sane`), shown where
	         Items.describe's data lines go, right under the name:
	           firearm   "Magazine: 9mm Pistol Magazine (Worn)" or "No magazine" (a detachable
	                     feed), "Rounds: 12 / 15 (9mm Rounds)" (the magazine's or the internal
	                     one's; none for the crossbow, which has only its chamber), "Chambered:
	                     9mm Rounds" or "Chamber empty", "Fire mode: Auto" (guns with more than
	                     one), "Optic: Red Dot Sight", "Muzzle: Suppressor (Badly damaged)",
	                     "Light: Weapon Flashlight (on)"; in red "Jammed: reload to clear it" and
	                     "Ruined: it will not fire"
	           magazine  "Rounds: 12 / 15 (9mm Rounds)"
	         (nothing for anything else, or for a firearm or magazine shown without a stack)
	  stats  the item's block after an empty line under a gray heading, as Tooltip's stat blocks:
	           firearm     "When fired:" the damage of each round of its calibre (" 7 Damage", a
	                       shotgun's " 8 x 2.5 Damage (12 Gauge Buckshot)" and " 16 Damage (12
	                       Gauge Slugs)": the round's times the gun's damage scale) and each fire
	                       mode's rate (" 700 Rounds a Minute (Auto)") in dark green, then its
	                       calibre, its feed ("Feeds from: 9mm Pistol Magazine", "Holds 5 rounds
	                       and 1 chambered", the crossbow's "Holds 1 bolt"), its mounts or
	                       built-in scope, and "Never jams" in gray
	           ammunition  "As ammunition:" its damage (" 2.5 Damage x 8 pellets"), its calibre,
	                       the range of full damage, a bolt's recovery chance, and the guns it
	                       fits
	           magazine    "As a magazine:" its calibre, capacity and the guns it fits
	           attachment  "When mounted:" an optic's zoom, a muzzle device's noise and spread
	                       (blue: less is better), "Suppressed", a light's reach, the guns it fits
	           melee       "Melee:" (only while the melee rework is on, Weapons/Melee) the heavy
	                       attack's damage in dark green, "Hold the attack button for a heavy
	                       blow", the guard's share and a knife's finisher in blue
	  lines  both texts in order (state, then the heading and the block), for logs and tests.

	The condition words are the survival look's (Ui/Theme.CONDITIONS, tests/spec/Tooltips checks
	they agree) at Weapons.level of a part's durability left. A part's condition is shown only for
	the parts that wear inside a gun (its magazine, its muzzle device): a gun's own is the
	tooltip's header (Ui/ItemTooltip). Item data keys get no Items.addDescriber here: the keys
	(`n`, `mode`, `light`...) are short and generic, so a describer would answer for other items'
	data too; `state` reads them for weapons alone.
]]

local Items = require(script.Parent.Parent.Items)
local Weapons = require(script.Parent)
local WeaponState = require(script.Parent.WeaponState)
local Melee = require(script.Parent.Melee)

type Stack = Items.Stack

-- Tooltip's colours by name (Shared/Items/Tooltip.Colour; it requires this module).
export type Colour = "white" | "gray" | "blue" | "red" | "darkGreen" | "lore"
export type Line = { text: string, colour: Colour }

local Describe = {}

-- The condition words by Weapons.level (Ui/Theme.CONDITIONS' names).
Describe.CONDITIONS = table.freeze({ "Pristine", "Worn", "Damaged", "Badly damaged", "Ruined" })

-- Calibres as players read them.
local CALIBRES: { [string]: string } = {
	["9mm"] = "9mm",
	["357"] = ".357",
	["12g"] = "12 gauge",
	["22"] = ".22",
	["556"] = "5.56",
	["762"] = "7.62",
	["308"] = ".308",
	bolt = "Crossbow bolt",
}

-- Attachment slots' names, and the order the tooltip names them in.
local SLOT_NAMES: { [string]: string } = { optic = "Optic", muzzle = "Muzzle", light = "Light" }
local SLOT_ORDER: { Weapons.AttachmentSlot } = { "optic", "muzzle", "light" }

-- A calibre's name ("9mm", ".357", "12 gauge"; unknown ones as they are).
function Describe.calibre(calibre: string): string
	return CALIBRES[calibre] or calibre
end

-- A number as Minecraft's tooltips write it (Tooltip.number: "#.##").
local function format(value: number): string
	local text = string.format("%.2f", value)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return if text == "-0" then "0" else text
end

-- A share as a percentage: 0.25 -> "25%".
local function percent(share: number): string
	return `{format(share * 100)}%`
end

-- The condition word of `item` worn by `damage`.
function Describe.condition(item: number, damage: number?): string
	return Describe.CONDITIONS[Weapons.level(WeaponState.fraction(item, damage))]
end

-- Items' display names joined: "9mm Pistol, SMG".
local function names(items: { number }): string
	local list = table.create(#items)
	for index, item in items do
		list[index] = Items.displayName(item)
	end
	return table.concat(list, ", ")
end

-- The firearms that take a calibre (item order).
local function gunsOf(calibre: string): { number }
	local list: { number } = {}
	for _, item in Weapons.FIREARMS do
		if (Weapons.firearm(item) :: Weapons.FirearmSpec).calibre == calibre then
			table.insert(list, item)
		end
	end
	return list
end

local function add(into: { Line }, text: string, colour: Colour?)
	table.insert(into, { text = text, colour = colour or "gray" })
end

-- "Rounds: 12 / 15 (9mm Rounds)".
local function roundsLine(into: { Line }, n: number, capacity: number, round: number?)
	local kind = if n > 0 and round then ` ({Items.displayName(round)})` else ""
	add(into, `Rounds: {n} / {capacity}{kind}`)
end

--[[ The stack's state ]]

-- A firearm's state lines (see the header).
local function firearmState(into: { Line }, spec: Weapons.FirearmSpec, stack: Stack)
	local clean = WeaponState.sane(stack)
	local n, round = WeaponState.rounds(clean)
	if spec.magazine ~= nil then
		local mag, wear = WeaponState.magazine(clean)
		if mag then
			add(into, `Magazine: {Items.displayName(mag)} ({Describe.condition(mag, wear)})`)
			roundsLine(into, n, WeaponState.capacity(mag), round)
		else
			add(into, "No magazine")
		end
	elseif spec.internal > 0 then
		roundsLine(into, n, spec.internal, round)
	end
	local chambered = WeaponState.chamber(clean)
	add(into, if chambered then `Chambered: {Items.displayName(chambered)}` else "Chamber empty")
	if #spec.modes > 1 then
		add(into, `Fire mode: {if WeaponState.mode(clean) == "auto" then "Auto" else "Semi"}`)
	end
	for _, slot in SLOT_ORDER do
		local part, wear = WeaponState.attachment(clean, slot :: Weapons.AttachmentSlot)
		if part then
			local extra = ""
			if slot == "muzzle" and (Items.get(part) :: Items.ItemDef).durability then
				extra = ` ({Describe.condition(part, wear)})`
			elseif slot == "light" then
				extra = if clean.data and clean.data.lit == true then " (on)" else " (off)"
			end
			add(into, `{SLOT_NAMES[slot]}: {Items.displayName(part)}{extra}`)
		end
	end
	if WeaponState.jammed(clean) then
		add(into, "Jammed: reload to clear it", "red")
	end
	if Weapons.level(WeaponState.fraction(clean.item, clean.damage)) >= Weapons.RUINED then
		add(into, "Ruined: it will not fire", "red")
	end
end

-- The weapon state lines of `stack` (see the header; {} for none).
function Describe.state(stack: Stack?): { Line }
	local into: { Line } = {}
	if stack == nil then
		return into
	end
	local gun = Weapons.firearm(stack.item)
	local magazine = Weapons.magazine(stack.item)
	if gun then
		firearmState(into, gun, stack)
	elseif magazine then
		local n, round = WeaponState.rounds(WeaponState.sane(stack))
		roundsLine(into, n, magazine.capacity, round)
	end
	return into
end

--[[ The item's stat block ]]

-- " 7 Damage", " 2.5 Damage x 8 pellets" (times `scale`), with the round's name when `named`.
local function damageLine(into: { Line }, ammo: Weapons.AmmoSpec, scale: number, named: boolean)
	local damage = format(ammo.damage * scale)
	local text = if ammo.pellets > 1 then ` {damage} Damage x {ammo.pellets} pellets` else ` {damage} Damage`
	if named then
		text ..= ` ({Items.displayName(ammo.item)})`
	end
	add(into, text, "darkGreen")
end

local function firearmStats(spec: Weapons.FirearmSpec): { Line }
	local body: { Line } = {}
	local rounds = Weapons.ammoFor(spec.calibre)
	for _, round in rounds do
		damageLine(body, Weapons.ammo(round) :: Weapons.AmmoSpec, spec.damageScale, #rounds > 1)
	end
	for _, mode in spec.modes do
		local kind = if #spec.modes > 1 then (if mode.kind == "auto" then " (Auto)" else " (Semi)") else ""
		add(body, ` {format(mode.rpm)} Rounds a Minute{kind}`, "darkGreen")
	end
	add(body, `Calibre: {Describe.calibre(spec.calibre)}`)
	if spec.magazine ~= nil then
		add(body, `Feeds from: {Items.displayName(spec.magazine)}`)
	elseif spec.internal > 0 then
		add(body, `Holds {spec.internal} rounds and 1 chambered`)
	else
		local round = rounds[1]
		add(body, `Holds 1 {if round then string.lower(Items.displayName(round)) else "round"}`)
	end
	local mounts: { string } = {}
	for _, slot in SLOT_ORDER do
		if spec.mounts[slot] then
			table.insert(mounts, SLOT_NAMES[slot])
		end
	end
	if #mounts > 0 then
		add(body, `Mounts: {table.concat(mounts, ", ")}`)
	end
	if spec.scope then
		add(body, `Built-in scope: {format(spec.scope)}x`)
	end
	if not spec.jams then
		add(body, "Never jams")
	end
	return body
end

local function ammoStats(spec: Weapons.AmmoSpec): { Line }
	local body: { Line } = {}
	damageLine(body, spec, 1, false)
	add(body, `Calibre: {Describe.calibre(spec.calibre)}`)
	add(body, `Full damage to {format(spec.range)} blocks`)
	if spec.recover > 0 then
		add(body, `Often found again after a shot ({percent(spec.recover)})`)
	end
	local guns = gunsOf(spec.calibre)
	if #guns > 0 then
		add(body, `Fits: {names(guns)}`)
	end
	return body
end

local function magazineStats(spec: Weapons.MagazineSpec): { Line }
	local body: { Line } = {}
	add(body, `Calibre: {Describe.calibre(spec.calibre)}`)
	add(body, `Holds {spec.capacity} rounds`)
	add(body, `Fits: {names(spec.fits)}`)
	return body
end

local function attachmentStats(spec: Weapons.AttachmentSpec): { Line }
	local body: { Line } = {}
	if spec.zoom then
		add(body, `{format(spec.zoom)}x Zoom`, "blue")
	end
	if spec.slot == "muzzle" then
		if spec.noise < 1 then
			add(body, `Noise: {percent(spec.noise)}`, "blue")
		end
		if spec.spread < 1 then
			add(body, `Spread: {percent(spec.spread)}`, "blue")
		end
		if spec.suppressed then
			add(body, "Suppressed")
		end
	end
	local beam = spec.beam
	if beam then
		add(body, `Lights {format(beam.range)} blocks ahead`, "blue")
	end
	add(body, `Fits: {names(spec.fits)}`)
	return body
end

local function meleeStats(item: number): { Line }
	local body: { Line } = {}
	local spec = Melee.spec(item)
	if spec == nil then
		return body
	end
	add(body, ` {format(spec.heavy)} Heavy Attack Damage`, "darkGreen")
	add(body, "Hold the attack button for a heavy blow")
	if spec.guard > 0 then
		add(body, `Guard: blocks {percent(spec.guard)} of a zombie's hit`, "blue")
	end
	if spec.finisher then
		add(body, "Kills an unaware zombie from behind", "blue")
	end
	return body
end

--[[
	The stat block of `item` (see the header): its heading and lines; nil and {} for anything that
	is no weapon (and a melee weapon while the rework is off).
]]
function Describe.stats(item: number): (string?, { Line })
	local gun = Weapons.firearm(item)
	if gun then
		return "When fired:", firearmStats(gun)
	end
	local ammo = Weapons.ammo(item)
	if ammo then
		return "As ammunition:", ammoStats(ammo)
	end
	local magazine = Weapons.magazine(item)
	if magazine then
		return "As a magazine:", magazineStats(magazine)
	end
	local attachment = Weapons.attachment(item)
	if attachment then
		return "When mounted:", attachmentStats(attachment)
	end
	local melee = meleeStats(item)
	if #melee > 0 then
		return "Melee:", melee
	end
	return nil, {}
end

-- The weapon lines of `stack` for its tooltip, in order ({} for none): its state, then its stat
-- block's heading and lines (see the header).
function Describe.lines(stack: Items.Stack?): { string }
	local texts: { string } = {}
	if stack == nil then
		return texts
	end
	for _, line in Describe.state(stack) do
		table.insert(texts, line.text)
	end
	local heading, body = Describe.stats(stack.item)
	if heading then
		table.insert(texts, heading)
		for _, line in body do
			table.insert(texts, line.text)
		end
	end
	return texts
end

return Describe
