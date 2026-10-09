--!strict
--[[
	Bringing a returning player's old data into characters (Config.Characters.Migrate), the rules
	without Roblox: server Players/CharacterStore and World/WorldSave apply them. Pure, so the
	specs run it.

	Before characters, a player's Knowledge, Ages and skills were theirs for every world
	(Players/ProgressStore, "IceVoxelProgress_v1") and each saved world kept their inventory and
	where they stood (Save/PlayerCodec, "<worldId>/p/<userId>"). Now a character carries the
	progress and the inventory, and a world keeps where each character stood
	(Save/WorldCharacterCodec).

	  Legacy     a user with an old progress record and no characters yet gets "Character 1" made
	             for them the first time their list is read (`legacy`): their name (Roblox's
	             display name, filtered, or "Character 1"), Mediumcore (today's rule: everything
	             drops on death), their own avatar with everything worn (`allWorn`), the progress
	             copied (ProgressStore itself is never written again: it stays as a backup), an
	             empty inventory, marked `legacy`. The index then marks the migration done; a
	             progress read that failed decides nothing (tried again next session), and a user
	             with nothing old is marked done at their next index write.
	  Per world  the first of a user's characters to enter a saved world whose record lists an old
	             player record of theirs not yet taken in (`shouldImport`: the meta's `players`
	             has them, `legacyImported` does not, the character's `imported` does not name the
	             world) takes it in (`import`): its place, facing, game mode and previous one
	             become the character's entry in that world when it has none there yet
	             (`entry`); its 36 slots, armor, equipment (a version 2 record's accessories,
	             vanity armor and vanity accessories: Save/PlayerCodec) and the cursor's stack go
	             into the character's inventory: each into the same slot when that is empty (an
	             armor piece into its armor slot, an accessory into its accessory slot unless
	             another of its accessory slots wears that item already: Terraria wears none
	             twice), else merged and into empty slots (Inventory/Menu.add), and what does not
	             fit is listed to drop at the character's feet when it spawns. Its Mana Crystals
	             (a version 2 record's) add to the character's, up to Config.Mana.MaxCrystals 9;
	             those past it come back as Mana Crystal items (in the bag, or listed to drop).
	             Its mana, health, Tough As Nails and effects are left (the character's own
	             count). The character records the world's id in `imported` at once
	             (`markCharacter`: it never takes the same record in twice); the meta records
	             `legacyImported[userId] = charId` (`markWorld`, saved with the world) only once
	             that character was saved with what it took in (Players/CharacterStore confirms
	             it: World/WorldSave.confirmImport), and only a character that is saved at all
	             takes anything in (not one that lasts for the session, nor one this version
	             can't write). The old record is kept as a backup, never deleted.
	  Crash      a crash between the character's save and the world's save can take the same old
	             record in twice: a duplicate of those items, never a loss. Accepted.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Appearance = require(Shared.Characters.Appearance)
local Characters = require(Shared.Characters)
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Menu = require(Shared.Inventory.Menu)
local Types = require(Shared.Inventory.Types)

local CharacterCodec = require(script.Parent.CharacterCodec)
local PlayerCodec = require(script.Parent.PlayerCodec)
local WorldCharacterCodec = require(script.Parent.WorldCharacterCodec)
local WorldMeta = require(script.Parent.WorldMeta)

type Record = CharacterCodec.Record
type Stack = Items.Stack

local CharacterMigration = {}

-- The legacy character's name when the user's own can't be used.
CharacterMigration.DEFAULT_NAME = "Character 1"

--[[ The legacy character ]]

-- `appearance` with every asset worn (one of each single kind: the first), a copy.
function CharacterMigration.allWorn(appearance: Appearance.Appearance): Appearance.Appearance
	local result = Appearance.copy(appearance)
	local taken: { [number]: boolean } = {}
	for _, asset in result.assets do
		if Appearance.isAccessory(asset.kind) then
			asset.worn = true
		else
			asset.worn = not taken[asset.kind]
			taken[asset.kind] = true
		end
	end
	return result
end

-- `name` as a character's name, else DEFAULT_NAME.
function CharacterMigration.name(name: string?): string
	return Characters.cleanName(name) or CharacterMigration.DEFAULT_NAME
end

--[[
	The character made from a returning user's old progress (see the header): id `id`, `name`
	(cleaned), Mediumcore, `appearance` all worn, made at `now`. The progress goes beside it in
	the value (the caller's).
]]
function CharacterMigration.legacy(id: number, name: string?, appearance: Appearance.Appearance, now: number): Record
	local record = CharacterCodec.new(
		id,
		CharacterMigration.name(name),
		Characters.Difficulty.Mediumcore,
		CharacterMigration.allWorn(appearance),
		now
	)
	record.legacy = true
	return record
end

--[[ Old per-world records ]]

-- Should `record` (character `charId` of user `userId`) take in that user's old record in the
-- world of `meta` (see the header)?
function CharacterMigration.shouldImport(meta: WorldMeta.Meta, userId: number, record: Record): boolean
	local user = string.format("%.0f", userId)
	return meta.players[user] ~= nil
		and meta.legacyImported[user] == nil
		and table.find(record.imported, meta.id) == nil
end

-- Records in `record` that it took in an old record of the world of `meta` (at once: see the header).
function CharacterMigration.markCharacter(meta: WorldMeta.Meta, record: Record)
	if table.find(record.imported, meta.id) == nil then
		table.insert(record.imported, meta.id)
	end
	while #record.imported > CharacterCodec.MAX_IMPORTED do
		table.remove(record.imported, 1)
	end
end

-- Records in the world's `meta` that character `charId` took in user `userId`'s old record there
-- (once that character was saved with it: see the header).
function CharacterMigration.markWorld(meta: WorldMeta.Meta, userId: number, charId: number)
	meta.legacyImported[string.format("%.0f", userId)] = charId
end

-- Both marks at once (`markCharacter`, `markWorld`).
function CharacterMigration.markImported(meta: WorldMeta.Meta, userId: number, record: Record)
	CharacterMigration.markWorld(meta, userId, record.id)
	CharacterMigration.markCharacter(meta, record)
end

-- The character's entry in the world: `existing` when it has one, else the old record's place.
function CharacterMigration.entry(
	existing: WorldCharacterCodec.Entry?,
	old: PlayerCodec.Record
): WorldCharacterCodec.Entry
	return existing or WorldCharacterCodec.fromLegacy(old)
end

--[[
	Puts the old record's slots, armor, equipment and cursor into `record`'s inventory (see the
	header) and returns what did not fit (copies, to drop at the character's feet).
]]
function CharacterMigration.import(record: Record, old: PlayerCodec.Record): { Stack }
	local leftovers: { Stack } = {}
	local inventory = Types.newInventory()
	inventory.slots = record.slots
	inventory.selected = record.selected
	local pending: { Stack } = {}
	for slot = 1, Types.INVENTORY_SIZE do
		local stack = Items.copyStack(old.slots[slot])
		if stack and stack.count >= 1 then
			local current = record.slots[slot]
			if current == nil or current.count < 1 then
				record.slots[slot] = stack
			else
				table.insert(pending, stack)
			end
		end
	end
	for slot = 1, Types.ARMOR_SIZE do
		local stack = Items.copyStack(old.armor[slot])
		if stack and stack.count >= 1 then
			local current = record.armor[slot]
			if current == nil or current.count < 1 then
				record.armor[slot] = stack
			else
				table.insert(pending, stack)
			end
		end
	end
	-- (A version 2 record's equipment: the same place when the character's is empty and, for an
	-- accessory slot, no other one wears that item. A version 1 record has none: empty tables.)
	local function wornElsewhere(into: { [number]: Stack? }, size: number, slot: number, item: number): boolean
		for other = 1, size do
			local worn = into[other]
			if other ~= slot and worn and worn.count >= 1 and worn.item == item then
				return true
			end
		end
		return false
	end
	local function equipment(from: { [number]: Stack? }?, into: { [number]: Stack? }, size: number, once: boolean)
		if from == nil then
			return
		end
		for slot = 1, size do
			local stack = Items.copyStack(from[slot])
			if stack and stack.count >= 1 then
				local current = into[slot]
				local free = current == nil or current.count < 1
				if free and once and wornElsewhere(into, size, slot, stack.item) then
					free = false
				end
				if free then
					into[slot] = stack
				else
					table.insert(pending, stack)
				end
			end
		end
	end
	equipment(old.accessories, record.accessories, Types.ACCESSORY_SIZE, true)
	equipment(old.vanityArmor, record.vanityArmor, Types.VANITY_ARMOR_SIZE, false)
	equipment(old.vanityAccessories, record.vanityAccessories, Types.VANITY_ACCESSORY_SIZE, false)
	-- (A version 2 record's Mana Crystals add to the character's; those past the most, as items.)
	local crystals = math.max(0, math.floor(old.crystals or 0))
	if crystals > 0 then
		local total = record.crystals + crystals
		local most = Config.Mana.MaxCrystals
		record.crystals = math.min(total, most)
		local extra = if total > most then Items.newStack(Items.id.ManaCrystal, total - most) else nil
		if extra then
			table.insert(pending, extra)
		end
	end
	local cursor = Items.copyStack(old.cursor)
	if cursor and cursor.count >= 1 then
		table.insert(pending, cursor)
	end
	for _, stack in pending do
		local left = Menu.add(inventory, stack)
		if left and left.count >= 1 then
			table.insert(leftovers, left)
		end
	end
	return leftovers
end

return CharacterMigration
