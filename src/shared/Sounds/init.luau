--!strict
--[[
	The sound catalogue: Minecraft's sound events and what each one plays (Sounds/SoundList), as
	numbered events the server and every client agree on, and the lookups the game needs.

	  * `Sounds.id["block.stone.break"]` -> event number (errors on unknown names, so typos fail
	    loudly), `find(name)` (nil instead), `get(number or name)` -> Event, `events` (by number).
	  * `block(block, action)`: the event of a block's sound type (Blocks `sound`) for "break",
	    "place", "hit", "step" or "fall", or the block's own (SoundList.BLOCK_SOUNDS: punching fire
	    out hisses).
	  * `container(block, opened)`: a chest's lid; `equip(old, new)` / `armorEquip(item)`: armor
	    put on; `fall(halfHearts)`: Minecraft's small or big fall.
	  * `lookupNames(sound)`: the names a developer's Sound may have to replace an event, most
	    specific first (block.stone.break, then its category block.break).
	  * `contentIds()`: every sound file the catalogue uses (fallbacks too), to preload;
	    `pitch(event, roll)`: a pitch with the event's random variance.
	  * `MOODS`: the names of the cave mood events (Sounds/MusicList.Moods), one picked at random
	    each time the mood fills (Audio/Ambience); empty: the stand-in ambient.cave plays.

	Event numbers are positions in the catalogue: the block events (SOUND_TYPES x ACTIONS, in
	order), then SoundList.EVENTS. Every machine builds them in that fixed order, so Protocol
	`Sound` can carry them; they change when the list does, so nothing saves them.

	An event's `volume`, `pitch` and fallback are final: a block event's already have Minecraft's
	scaling for its action (SoundList).
]]

local Blocks = require(script.Parent.Blocks)
local Items = require(script.Parent.Items)
local SoundList = require(script.SoundList)

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
	-- Who plays it: "server", "predicted" or "client" (see SoundList).
	side: string,
}

local Sounds = {}

-- Minecraft's default hearing distance (blocks).
Sounds.DEFAULT_DISTANCE = 16
Sounds.DEFAULT_VOLUME = 0.5
Sounds.ACTIONS = table.freeze({ "break", "place", "hit", "step", "fall" })
Sounds.SOURCES = table.freeze({ "blocks", "players", "ambient", "ui" })
Sounds.SIDES = table.freeze({ "server", "predicted", "client" })
-- The cave mood events, in MusicList.Moods' order.
Sounds.MOODS = SoundList.MOODS

local events: { Event } = {}
local ids: { [string]: number } = {}

local function add(event: Event)
	assert(ids[event.name] == nil, `Duplicate sound event {event.name}`)
	assert(table.find(Sounds.SOURCES, event.source), `Sound {event.name} has unknown source {event.source}`)
	assert(table.find(Sounds.SIDES, event.side), `Sound {event.name} has unknown side {event.side}`)
	assert(string.find(event.id, "^rbxasset") ~= nil, `Sound {event.name} has no rbxasset id`)
	assert(event.volume >= 0 and event.pitch > 0, `Sound {event.name} has a bad volume or pitch`)
	table.insert(events, event)
	event.index = #events
	ids[event.name] = event.index
end

local function fallbackOf(
	fallback: SoundList.Fallback?,
	volume: number,
	pitch: number,
	duration: number?,
	volumeScale: number,
	pitchScale: number
): Fallback?
	if fallback == nil then
		return nil
	end
	return {
		id = fallback.id,
		volume = (fallback.volume or volume) * volumeScale,
		pitch = (fallback.pitch or pitch) * pitchScale,
		duration = fallback.duration or duration,
	}
end

--[[ Block events: block.<type>.<action> ]]

for _, action in SoundList.ACTIONS do
	assert(table.find(Sounds.ACTIONS, action.name), `Unknown block sound action {action.name}`)
end
assert(#SoundList.ACTIONS == #Sounds.ACTIONS, "SoundList.ACTIONS must list every block action once")
-- byAction[action][sound type index] = event number.
local byAction: { [string]: { [number]: number } } = {}
for _, action in Sounds.ACTIONS do
	byAction[action] = {}
end

for typeIndex, typeName in Blocks.SOUND_TYPES do
	local blockType: SoundList.BlockType? = nil
	for _, candidate in SoundList.BLOCK_TYPES do
		if candidate.name == typeName then
			blockType = candidate
		end
	end
	assert(blockType, `SoundList has no block sound type {typeName}`)
	for _, action in SoundList.ACTIONS do
		local own = blockType.actions and blockType.actions[action.name]
		local clip: SoundList.Clip = own or (if action.clip == "dig" then blockType.dig else blockType.step)
		local volumeScale = blockType.volume * action.volumeScale + action.volumeAdd
		local pitchScale = blockType.pitch * action.pitch
		local volume = clip.volume or Sounds.DEFAULT_VOLUME
		local pitch = clip.pitch or 1
		add({
			index = 0,
			name = `block.{typeName}.{action.name}`,
			category = `block.{action.name}`,
			id = clip.id,
			volume = volume * volumeScale,
			pitch = pitch * pitchScale,
			-- (The variance scales with the pitch, as it is part of it.)
			pitchVariance = (clip.pitchVariance or 0) * pitchScale,
			duration = clip.duration,
			fallback = fallbackOf(clip.fallback, volume, pitch, clip.duration, volumeScale, pitchScale),
			maxDistance = Sounds.DEFAULT_DISTANCE,
			source = "blocks",
			ui = false,
			side = action.side,
		})
		byAction[action.name][typeIndex] = #events
	end
end
for _, blockType in SoundList.BLOCK_TYPES do
	assert(table.find(Blocks.SOUND_TYPES, blockType.name), `SoundList has unknown block sound type {blockType.name}`)
end

--[[ Every other event ]]

for _, spec in SoundList.EVENTS do
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
		fallback = fallbackOf(spec.fallback, volume, pitch, spec.duration, 1, 1),
		maxDistance = spec.maxDistance or Sounds.DEFAULT_DISTANCE,
		source = spec.source,
		ui = spec.ui == true,
		side = spec.side,
	})
end

Sounds.events = events
Sounds.count = #events
-- Event numbers travel as u16 (Protocol `Sound`).
assert(Sounds.count < 65536, "At most 65535 sound events")

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

--[[ Lookups ]]

-- Blocks' own action sounds (SoundList.BLOCK_SOUNDS), by block id and action.
local ownSounds: { [number]: { [string]: number } } = {}
for name, actions in SoundList.BLOCK_SOUNDS do
	local block = Blocks.find(name)
	assert(block ~= nil, `SoundList.BLOCK_SOUNDS names unknown block {name}`)
	local map: { [string]: number } = {}
	for action, event in actions do
		assert(byAction[action] ~= nil, `SoundList.BLOCK_SOUNDS has unknown action {action} for {name}`)
		map[action] = Sounds.id[event]
	end
	ownSounds[block] = map
end

--[[
	The event a block makes for `action` ("break", "place", "hit", "step" or "fall"): its own
	(SoundList.BLOCK_SOUNDS: fire's extinguish hiss), else its sound type's (Blocks `sound`). nil
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

-- The lid sound of a block with a menu, opened (first viewer) or closed (last viewer gone); nil
-- for blocks without one (furnaces, crafting tables, anything else).
function Sounds.container(block: number, opened: boolean): number?
	local def = if Blocks.isValid(block) then Blocks.get(block) else nil
	local menu = def and def.menu
	local sounds = if menu then SoundList.MENUS[menu] else nil
	if sounds == nil then
		return nil
	end
	return Sounds.find(if opened then sounds.open else sounds.close)
end

-- The equip sound of an armor item (by its material), nil for items that are not armor.
function Sounds.armorEquip(item: number): number?
	local def = Items.get(item)
	if def == nil or def.armor == nil then
		return nil
	end
	for _, entry in SoundList.ARMOR do
		if string.sub(def.name, 1, #entry.prefix) == entry.prefix then
			return Sounds.find(entry.sound)
		end
	end
	return Sounds.find(SoundList.ARMOR_DEFAULT)
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

-- The sound of a landing that hurt `halfHearts` (Minecraft's small_fall up to 4, else big_fall).
function Sounds.fall(halfHearts: number): number
	return Sounds.id[if halfHearts > SoundList.SMALL_FALL_MAX
		then "entity.player.big_fall"
		else "entity.player.small_fall"]
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
