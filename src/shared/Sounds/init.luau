--!strict
--[[
	The sound catalogue: Minecraft's sound events and what each one plays, as numbered events the
	server and every client agree on, and the lookups the game needs. The events are the content
	packs' `sounds` (Shared/Content; Content/Schema's SOUND_FIELDS say what each field does), merged
	by name, and one for each cave mood the packs' music gives (Sounds/MusicList).

	  * `Sounds.id["block.stone.break"]` -> event number (errors on unknown names, so typos fail
	    loudly), `find(name)` (nil instead), `get(number or name)` -> Event, `events` (by number).
	  * `block(block, action)`: the event of a block's sound type (Blocks `sound`) for "break",
	    "place", "hit", "step" or "fall", or the block's own (its content pack entry's `sounds`:
	    punching fire out hisses); `workSound(block)`: the event a machine plays looped while it
	    works (its entry's `workSound`).
	  * `container(block, opened)`: a chest's lid (MENUS); `equip(old, new)` / `armorEquip(item)`:
	    armor put on (its entry's `equipSound`, else ARMOR_DEFAULT; `equipment(old, new)`: an
	    equipment slot's, the generic sound for accessories and vanity clothes); `fall(halfHearts)`:
	    Minecraft's small or big fall.
	  * `lookupNames(sound)`: the names a developer's Sound may have to replace an event, most
	    specific first (block.stone.break, then its category block.break).
	  * `contentIds()`: every sound file the catalogue uses (fallbacks too), to preload;
	    `pitch(event, roll)`: a pitch with the event's random variance.
	  * `MOODS`: the names of the cave mood events (the packs' music of the set "mood": each the
	    event ambient.cave.<name>), one picked at random each time the mood fills (Audio/Ambience);
	    empty: the stand-in ambient.cave plays.
	  * `LIMITS`: kind -> the most voices of it at once (an event's category, else its name: the
	    events' `limit`, which every event of a kind that gives one gives alike; client
	    Audio/SoundRules.CAPS).

	Event numbers are places: the packs' sounds in load order (Shared/Content: each pack's in its
	order, a kind folder's files in their names' order), then the cave moods in theirs. Every
	machine loads the same packs, so it builds the same numbers, and Protocol `Sound` carries them
	as a u16 (asserted here); they move when content does, so nothing saves them and code names
	events by name.

	A cave mood's event (Minecraft's SimpleSoundInstance.forAmbientMood) plays its track at volume
	0.5 (MOOD_VOLUME) in the category ambient.cave, so a developer's Sound named "ambient.cave"
	replaces them all, and like the stand-in ambient.cave in every other way (its source, side,
	distance and limit: one at a time), the stand-in's own clip its fallback should the track fail
	to load.

	An event's `volume`, `pitch` and fallback are final: a block event's already have Minecraft's
	scaling for its action (Content/Define's `blockSounds`); a fallback's missing fields are the
	event's own.

	Checked as this loads, naming the pack's entry (Content checks the names entries give): every
	event's numbers (a volume of 0 or more, a pitch above 0, a variance, distance and limit that
	make sense) and its kind's limit; every block sound type's five events (Blocks.SOUND_TYPES);
	a block's own `sounds` by action and its `workSound` on a machine; and the events the game's
	code plays by name (PLAYED, MENUS, ARMOR_DEFAULT, the falls), which some pack must give.
]]

local Blocks = require(script.Parent.Blocks)
local Content = require(script.Parent.Content)
local Items = require(script.Parent.Items)
local MusicList = require(script.MusicList)
local Schema = require(script.Parent.Content.Schema)
local SoundsDefine = require(script.Parent.Content.Define.Sounds)

export type Fallback = { id: string, volume: number, pitch: number, duration: number? }

export type Event = {
	-- Its number (position in `events`) and Minecraft name.
	index: number,
	name: string,
	-- The name with the variant left out (block.break, item.armor.equip), nil when it has none.
	category: string?,
	-- The sound file and how it is played (Sound.Volume, PlaybackSpeed); the pitch varies by up to
	-- `pitchVariance` either way.
	id: string,
	volume: number,
	pitch: number,
	pitchVariance: number,
	-- Seconds of the file played (nil: all of it).
	duration: number?,
	-- Played instead when `id` fails to load.
	fallback: Fallback?,
	-- Blocks it is heard from (fading out linearly).
	maxDistance: number,
	-- The volume setting it follows: "blocks", "players", "ambient" or "ui".
	source: string,
	-- Played flat (2D) for the local player, not at a position.
	ui: boolean,
	-- Who plays it: "server", "predicted" or "client" (Content/Schema's SOUND_FIELDS).
	side: string,
	-- The most of its kind (its category, else its name) playing at once on a client (nil: the
	-- client's default, Audio/SoundRules.DEFAULT_CAP).
	limit: number?,
}

local Sounds = {}

-- Minecraft's default hearing distance (blocks).
Sounds.DEFAULT_DISTANCE = 16
Sounds.DEFAULT_VOLUME = SoundsDefine.DEFAULT_VOLUME
Sounds.ACTIONS = Blocks.SOUND_ACTIONS
Sounds.SOURCES = Schema.SOUND_SOURCES
Sounds.SIDES = Schema.SOUND_SIDES
-- Minecraft's volume of a cave mood (SimpleSoundInstance.forAmbientMood).
Sounds.MOOD_VOLUME = 0.5
-- A hurting landing of more half hearts than this sounds big.
Sounds.SMALL_FALL_MAX = 4

-- The lid sounds of blocks with a menu (Blocks `menu`). Furnaces and crafting tables have none.
Sounds.MENUS = table.freeze({
	Chest = table.freeze({ open = "block.chest.open", close = "block.chest.close" }),
}) :: { [string]: { open: string, close: string } }

-- The equip sound of armor whose entry names no `equipSound` of its own (`armorEquip`), and of
-- accessories and vanity clothes.
Sounds.ARMOR_DEFAULT = "item.armor.equip_generic"

--[[
	The events the game's code plays by name (client, server and shared modules; the module after
	each group), which some pack must give: checked as this loads, with this module's own (MENUS,
	ARMOR_DEFAULT, the falls). The events content names are checked where they are named
	(Content: blocks' and items' sound fields; MobList: mobs' voices; Weapons: the firearm classes'
	shots; Fluids: the buckets'), and those that look a name up and do without (a calibre's own
	shot: Rendering/ShotRules) need none. tests/spec/Sounds checks this list against the code.
]]
Sounds.PLAYED = table.freeze({
	-- Players and items (server Players/Characters, Entities/Entities, Players/Inventories,
	-- Audio/Sounds).
	"entity.player.hurt",
	"entity.player.death",
	"entity.item.pickup",
	"entity.item.break",
	"entity.generic.burn",
	"entity.generic.extinguish_fire",
	-- Swimming and splashes (client Audio/MovementSounds).
	"entity.generic.splash",
	"entity.generic.swim",
	-- Blocks the code breaks or opens (server Mobs/Mobs, Weapons, Players/DoorUse; client
	-- Interaction/BlockInteraction).
	"block.glass.break",
	"block.glass.hit",
	"block.wooden_door.open",
	"block.wooden_door.close",
	-- Eating and drinking (Items/Foods, client Audio/UseSoundRules, Interaction/Drinking, server
	-- Players/ToughAsNails).
	"entity.generic.eat",
	"entity.generic.eating",
	"entity.player.burp",
	"entity.generic.drink",
	"entity.generic.drinking",
	"item.bottle.fill",
	"block.campfire.boil",
	-- Ambience (client Audio/Ambience, Audio/SoundRules, Audio/Geiger).
	"ambient.cave",
	"block.furnace.fire_crackle",
	"block.fire.ambient",
	"block.lava.pop",
	"block.lava.ambient",
	"ambient.radiation.click",
	-- Fluids, fire and explosions (server Behaviours/Fluid, Behaviours/Tnt, World/Explosions,
	-- World/Nuke, Players/ItemUse, Transmitters/UseRules).
	"block.lava.extinguish",
	"item.flintandsteel.use",
	"item.configurator.click",
	"item.bucket.fill",
	"item.bucket.empty",
	"entity.generic.explode",
	"entity.tnt.primed",
	"entity.nuke.alarm",
	"entity.nuke.explode",
	-- The interface and progression (client Audio/SoundPlayer, Ui/MenuLayout,
	-- Player/ProgressionState).
	"ui.button.click",
	"ui.thermostat.click",
	"entity.experience_orb.pickup",
	"entity.player.levelup",
	"ui.toast.challenge_complete",
	-- Weather (client Weather/Precipitation, PrecipitationView, LightningView, StormView).
	"weather.rain",
	"weather.rain.above",
	"weather.rain.far",
	"weather.wind",
	"entity.lightning_bolt.thunder",
	"entity.lightning_bolt.thunder.far",
	"entity.lightning_bolt.impact",
	-- The seasons' stingers (client Ui/SeasonLine).
	"ambient.season.autumn",
	"ambient.season.winter",
	"ambient.season.spring",
	"ambient.season.summer",
	"ambient.season.heat_wave",
	-- Terraria's things (client Player/EquipmentLooks, Player/ManaState, Interaction/Casting;
	-- server Players/Magic, Players/FallenStars).
	"entity.player.double_jump",
	"entity.player.mana_full",
	"item.magic.cast",
	"entity.magic.hit",
	"item.mana_crystal.use",
	"entity.fallen_star.fall",
	-- The zombie apocalypse (server Mobs/Mobs, Mobs/MobAI; client Entities/MobRenderer,
	-- Ui/SurvivorHud).
	"entity.player.attack.strong",
	"entity.player.attack.weak",
	"entity.zombie.ambient",
	"entity.zombie.attack_wooden_door",
	"entity.zombie.break_wooden_door",
	"entity.zombie_screamer.scream",
	"ambient.blood_moon.rise",
	-- Weapons (client Rendering/ShotRules, Ui/Screens, Ui/InventoryScreen, Interaction/MeleeInput;
	-- server Weapons/WeaponActions, Mobs/Mobs).
	"item.firearm.suppressed",
	"item.firearm.far",
	"item.firearm.dry",
	"item.firearm.jam",
	"item.firearm.reload",
	"item.firearm.load_round",
	"item.firearm.chamber",
	"item.firearm.unload",
	"item.firearm.attach",
	"entity.bullet.impact",
	"entity.bullet.flesh",
	"item.melee.swing",
	"item.melee.heavy",
	"item.melee.block",
	-- Turrets (client Rendering/TurretView).
	"block.turret.servo",
})

local content = Content.default
local events: { Event } = {}
local ids: { [string]: number } = {}
-- Each kind's limit (an event's category, else its name), and the event that gave it first.
local limits: { [string]: number } = {}
local limitFrom: { [string]: string } = {}

-- A fallback with its missing fields the event's own.
local function fallbackOf(fallback: Schema.FallbackSpec?, volume: number, pitch: number, duration: number?): Fallback?
	if fallback == nil then
		return nil
	end
	return {
		id = fallback.id,
		volume = fallback.volume or volume,
		pitch = fallback.pitch or pitch,
		duration = fallback.duration or duration,
	}
end

-- Adds `event` (`where`: its entry, for messages), checking its numbers.
local function add(event: Event, where: string)
	assert(ids[event.name] == nil, `Sounds: {where}: another event has the name {event.name}`)
	assert(event.volume >= 0 and event.pitch > 0, `Sounds: {where} has a bad volume or pitch`)
	assert(event.pitchVariance >= 0, `Sounds: {where} has a negative pitch variance`)
	assert(event.maxDistance > 0, `Sounds: {where} has a bad maxDistance`)
	local limit = event.limit
	if limit then
		assert(limit >= 1 and limit == math.floor(limit), `Sounds: {where}'s limit must be a whole 1 or more`)
		local key = event.category or event.name
		local before = limits[key]
		assert(
			before == nil or before == limit,
			`Sounds: {where}'s limit {limit} is not {before}, the limit {limitFrom[key]} gives its kind {key} (its category, else its name)`
		)
		limits[key] = limit
		limitFrom[key] = limitFrom[key] or where
	end
	table.insert(events, event)
	event.index = #events
	ids[event.name] = event.index
end

--[[ The packs' events ]]

for _, spec in content.sounds do
	local volume = spec.volume or Sounds.DEFAULT_VOLUME
	local pitch = spec.pitch or 1
	add({
		index = 0,
		name = spec.name,
		category = spec.category,
		id = spec.id,
		volume = volume,
		pitch = pitch,
		pitchVariance = spec.pitchVariance or 0,
		duration = spec.duration,
		fallback = fallbackOf(spec.fallback, volume, pitch, spec.duration),
		maxDistance = spec.maxDistance or Sounds.DEFAULT_DISTANCE,
		source = spec.source,
		ui = spec.ui == true,
		side = spec.side,
		limit = spec.limit,
	}, content.where("sound", spec.name))
end

--[[ The cave moods: one event each, like the stand-in ambient.cave (the header) ]]

local moods: { string } = {}
local cave = events[ids["ambient.cave"] or 0]
assert(
	cave ~= nil or #MusicList.MOOD_NAMES == 0,
	"Sounds: the cave moods play like ambient.cave, which no pack's sounds give"
)
for index, track in MusicList.MOOD_NAMES do
	local stand = cave :: Event
	local name = `ambient.cave.{track}`
	table.insert(moods, name)
	add({
		index = 0,
		name = name,
		category = "ambient.cave",
		id = MusicList.Moods[index],
		volume = Sounds.MOOD_VOLUME,
		pitch = 1,
		pitchVariance = 0,
		duration = nil,
		fallback = { id = stand.id, volume = stand.volume, pitch = stand.pitch, duration = stand.duration },
		maxDistance = stand.maxDistance,
		source = stand.source,
		ui = stand.ui,
		side = stand.side,
		limit = nil,
	}, content.where("track", track))
end
-- The cave mood events, in the packs' music order.
Sounds.MOODS = table.freeze(moods)

Sounds.events = events
Sounds.count = #events
-- Event numbers travel as u16 (Protocol `Sound`).
assert(Sounds.count < 65536, `Sounds: {Sounds.count} events, at most 65535 (a u16 each)`)

--[[ Limits: one per kind, every event of a kind taking it ]]

for _, event in events do
	event.limit = limits[event.category or event.name]
end
Sounds.LIMITS = table.freeze(limits)

-- `Sounds.id["block.stone.break"]` -> its number. Unknown names error instead of returning nil.
Sounds.id = (
	setmetatable(ids, {
		__index = function(_, name)
			error(`Unknown sound event '{name}'`, 2)
		end,
	}) :: any
) :: { [string]: number }

-- The number of event `name`, nil when there is none.
function Sounds.find(name: string): number?
	return rawget(ids :: any, name)
end

-- The event with this number or name, nil when there is none.
function Sounds.get(sound: number | string): Event?
	if type(sound) == "string" then
		local index = rawget(ids :: any, sound)
		return if index then events[index] else nil
	end
	return events[sound]
end

--[[ Block events: block.<type>.<action> ]]

-- byAction[action][sound type index] = event number.
local byAction: { [string]: { [number]: number } } = {}
for _, action in Sounds.ACTIONS do
	byAction[action] = {}
	for typeIndex, typeName in Blocks.SOUND_TYPES do
		local id = Sounds.find(`block.{typeName}.{action}`)
		assert(id ~= nil, `Sounds: block sound type {typeName} has no event block.{typeName}.{action}`)
		byAction[action][typeIndex] = id
	end
end

--[[ What the game's code plays by name ]]

local function need(name: string, why: string)
	assert(Sounds.find(name) ~= nil, `Sounds: {why} plays {name}, which no pack's sounds give`)
end
for _, name in Sounds.PLAYED do
	need(name, "the game (Sounds.PLAYED)")
end
for menu, lid in Sounds.MENUS do
	need(lid.open, `a {menu} menu's lid (Sounds.MENUS)`)
	need(lid.close, `a {menu} menu's lid (Sounds.MENUS)`)
end
need(Sounds.ARMOR_DEFAULT, "armor without its own equip sound (Sounds.ARMOR_DEFAULT)")
need("entity.player.small_fall", "a small hurting landing (Sounds.fall)")
need("entity.player.big_fall", "a big hurting landing (Sounds.fall)")

--[[ Lookups ]]

--[[
	Blocks' own action sounds and machines' work sounds, by block id: each content pack block
	entry's `sounds` ({ [action] = event }) and `workSound` (Shared/Content checked the events).
	Armor's equip sounds: each item entry's `equipSound`, else ARMOR_DEFAULT. Every action is
	checked here, and that a work sound is a machine's, naming the entry.
]]
local ownSounds: { [number]: { [string]: number } } = {}
local workSounds: { [number]: string } = {}
for _, spec in content.blocks do
	if spec.sounds then
		local where = content.where("block", spec.name)
		local map: { [string]: number } = {}
		for action, event in spec.sounds do
			assert(byAction[action] ~= nil, `Sounds: {where} has unknown action {action}`)
			local id = rawget(ids :: any, event)
			assert(id ~= nil, `Sounds: {where}'s {action} plays unknown event {event}`)
			map[action] = id
		end
		ownSounds[Blocks.id[spec.name]] = map
	end
	if spec.workSound then
		local where = content.where("block", spec.name)
		assert(spec.machine ~= nil, `Sounds: {where} has a workSound but is no machine (it plays while one works)`)
		workSounds[Blocks.id[spec.name]] = spec.workSound
	end
end

-- Items' own equip sounds, by item id.
local equipSounds: { [number]: number } = {}
for _, spec in content.items do
	local event = spec.equipSound
	if event then
		local where = content.where("item", spec.name)
		local id = rawget(ids :: any, event)
		assert(id ~= nil, `Sounds: {where}'s equipSound is unknown event {event}`)
		equipSounds[Items.id[spec.name]] = id
	end
end

--[[
	The event a block makes for `action` ("break", "place", "hit", "step" or "fall"): its own
	(its entry's `sounds`: fire's extinguish hiss), else its sound type's (Blocks `sound`). nil
	for silent blocks (air), unknown ids and unknown actions.
]]
function Sounds.block(block: number, action: string): number?
	local map = byAction[action]
	if map == nil or not Blocks.isValid(block) then
		return nil
	end
	local own = ownSounds[block]
	if own and own[action] then
		return own[action]
	end
	local typeIndex = buffer.readu8(Blocks.soundLut, block)
	return if typeIndex > 0 then map[typeIndex] else nil
end

-- The event (by name) the machine `block` plays looped while it works (its entry's `workSound`:
-- client Audio/Ambience), nil for blocks without one.
function Sounds.workSound(block: number): string?
	return workSounds[block]
end

-- The lid sound of a block with a menu, opened (first viewer) or closed (last viewer gone); nil
-- for blocks without one (furnaces, crafting tables, anything else).
function Sounds.container(block: number, opened: boolean): number?
	local def = if Blocks.isValid(block) then Blocks.get(block) else nil
	local menu = def and def.menu
	local sounds = if menu then Sounds.MENUS[menu] else nil
	if sounds == nil then
		return nil
	end
	return Sounds.find(if opened then sounds.open else sounds.close)
end

-- The equip sound of an armor item (its entry's `equipSound`, else the generic one), nil for
-- items that are not armor.
function Sounds.armorEquip(item: number): number?
	local def = Items.get(item)
	if def == nil or def.armor == nil then
		return nil
	end
	return equipSounds[item] or Sounds.find(Sounds.ARMOR_DEFAULT)
end

--[[
	An armor slot went from `old` to `new`: the equip sound when armor was put on (Minecraft's
	onEquipItem: a different stack, not taking it off), else nil.
]]
function Sounds.equip(old: Items.Stack?, new: Items.Stack?): number?
	if new == nil or new.count < 1 then
		return nil
	end
	if old and old.count >= 1 and old.item == new.item and (old.damage or 0) == (new.damage or 0) then
		return nil
	end
	return Sounds.armorEquip(new.item)
end

--[[
	An equipment slot (an accessory, vanity armor or vanity accessory slot) went from `old` to
	`new`: as `equip`, and the generic equip sound for what is not armor (accessories and vanity
	clothes), nil when nothing was put on.
]]
function Sounds.equipment(old: Items.Stack?, new: Items.Stack?): number?
	if new == nil or new.count < 1 then
		return nil
	end
	if old and old.count >= 1 and old.item == new.item and (old.damage or 0) == (new.damage or 0) then
		return nil
	end
	return Sounds.armorEquip(new.item) or Sounds.find(Sounds.ARMOR_DEFAULT)
end

-- The sound of a landing that hurt `halfHearts` (Minecraft's small_fall up to 4, else big_fall).
function Sounds.fall(halfHearts: number): number
	return Sounds.id[if halfHearts > Sounds.SMALL_FALL_MAX then "entity.player.big_fall" else "entity.player.small_fall"]
end

--[[
	The names a developer's Sound may have to replace event `sound`, most specific first: its own
	name, then its category (block.stone.break, block.break). Empty for unknown events.
]]
function Sounds.lookupNames(sound: number | string): { string }
	local event = Sounds.get(sound)
	if event == nil then
		return {}
	end
	return if event.category then { event.name, event.category } else { event.name }
end

-- Every sound file the catalogue plays, fallbacks included, each once (to preload).
function Sounds.contentIds(): { string }
	local list: { string } = {}
	local seen: { [string]: boolean } = {}
	local function addId(id: string)
		if not seen[id] then
			seen[id] = true
			table.insert(list, id)
		end
	end
	for _, event in events do
		addId(event.id)
		if event.fallback then
			addId(event.fallback.id)
		end
	end
	return list
end

-- The pitch to play `event` at for a random `roll` in [0, 1): its pitch, varied by up to its
-- variance either way (never below 0.05).
function Sounds.pitch(event: Event, roll: number): number
	return math.max(0.05, event.pitch + (roll * 2 - 1) * event.pitchVariance)
end

return Sounds
