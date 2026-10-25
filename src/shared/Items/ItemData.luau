--!strict
--[[
	The item data keys whose numbers are content ids (Items `data`: Minecraft's item NBT, flat),
	listed once. Ids are given out as content loads and may differ in the next version, so saves
	keep these by name (server Save/SaveCodec's palette): a stack's data is written with each such
	number turned into its name's place in the record's palette, and read back as today's id of
	that name (a name this version doesn't know drops the key, and the stack counts as `lost`).

	  ID_KEYS   the fixed keys and what their number is (frozen):
	              ch, ammo, mag, optic, muzzle, light   an item: a weapon's chambered round, its
	                                                    rounds, its magazine and attachments
	                                                    (Shared/Weapons/WeaponState)
	              fluid                                 a fluid: a Fluid Tank's (server
	                                                    Transmitters/TransmitterWorld.tankData)
	  addIdKey  a key more, by whoever defines it: Shared/Machines adds "<tank>Fluid" of every tank
	            taking more than one fluid, and each kept field (KindSpec `keep`) holding an id
	            (KindSpec `types`), which a broken machine's item keeps (Machines.save)
	  idKind    what a key's number is ("block", "item" or "fluid"), nil for keys holding none

	A new key holding an id goes in ID_KEYS (or through addIdKey), or saves would keep its number
	as it is, which the next version's content may give to something else.
]]

export type IdKind = "block" | "item" | "fluid"

local ItemData = {}

ItemData.ID_KEYS = table.freeze({
	ch = "item",
	ammo = "item",
	mag = "item",
	optic = "item",
	muzzle = "item",
	light = "item",
	fluid = "fluid",
} :: { [string]: IdKind })

local added: { [string]: IdKind } = {}

local KINDS: { [string]: boolean } = { block = true, item = true, fluid = true }

-- Lists `key` as holding an id of `kind` ("block", "item" or "fluid"). A key listed twice must
-- hold the same kind both times.
function ItemData.addIdKey(key: string, kind: IdKind)
	assert(type(key) == "string" and key ~= "", "an id key needs a name")
	assert(KINDS[kind], `ItemData: {key} holds no kind of id {kind}`)
	local listed = ItemData.ID_KEYS[key] or added[key]
	assert(listed == nil or listed == kind, `ItemData: {key} holds a {listed} id, not a {kind}`)
	added[key] = kind
end

-- What the number under `key` is an id of, nil for keys holding none.
function ItemData.idKind(key: string): IdKind?
	return ItemData.ID_KEYS[key] or added[key]
end

return ItemData
