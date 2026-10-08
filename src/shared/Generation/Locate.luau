--!strict
--[[
	Finding the nearest generated thing without generating chunks: Minecraft 1.20.1's /locate
	(LocateCommand, ChunkGenerator.findNearestMapStructure, ServerLevel.findClosestBiome3d) on
	this engine's generators. Pure (no services), so the server runs it in a budgeted coroutine
	(Players/LocateCommands), the specs run it under Lune, and an Actor could run it on a
	generator of its own.

	  Ids        what a player types: an id ("outpost", "minecraft:birch_forest", "BirchForest",
	             "birch forest") or a tag ("#mineshaft"). Matching is loose (`key`: any case, a
	             "minecraft:" or "icevoxel:" namespace dropped, no underscores, spaces or dashes);
	             ids are shown without a namespace in snake case (`snake`: BirchForest is
	             "birch_forest"), as Minecraft shows its registry ids. A Registry holds one kind of
	             thing's ids and tags (`registry`): structures (STRUCTURES, the built-in kinds, plus
	             the library's structures), biomes (BiomeList's, with Minecraft-like tags: BIOME_TAGS
	             and one per altitude band) and points of interest (Shared/Poi). A tag's members are
	             searched together and the answer names the member found, as Minecraft's
	             "#minecraft:village (minecraft:village_plains)". A biome tag also answers without
	             its "is_" ("#forest" is "#is_forest").
	  Kinds      a locatable structure on a grid of cells (the generator's `locateKinds`,
	             TerrainGenerator): each cell has at most one candidate, found by a cheap probe that
	             never touches the generator's caches (a hash and a few terrain columns: 1-21 µs),
	             and an exact verify for the few that might be nearest (a plan or an assembly,
	             0.5-5 ms, cached as the chunks would cache it, and it may yield).
	  Rings      `nearest` walks square rings of cells around the player's (Chebyshev distance k,
	             k = 0..rings), probes every cell of a ring, sorts its candidates by distance and
	             verifies them in that order while one could still beat the best so far. A kind
	             stops at the first ring that can't hold anything nearer: every point of ring k's
	             cells is at least (k - 1) x grid from the player along one axis, and a verified
	             position lies within `slack` of its cell, so once (k - 1) x grid - slack exceeds the
	             best distance it is done. That is the true nearest (Minecraft's returns the first
	             hit of the first ring that has one, which is not always the nearest). A tag's kinds
	             share the best distance, so the later ones stop early. Fixed layouts (the debug
	             structures world) list their things instead (`locateList`, `nearestListed`).
	  Biomes     `biome` walks square rings of samples `step` blocks apart (Minecraft's 32) out to
	             `radius` (its 6400), and keeps the nearest sample whose column's biome is in the
	             set; it stops at the first ring farther than that (exact at the sample spacing,
	             about sqrt(2) times the first hit's ring at most). A set the generator can't produce
	             (its `biomes`: Single Biome, flat worlds) fails at once, with no sample, as
	             Minecraft's possibleBiomes check does.
	  Costs      every probe, verify and sample is counted (`Stats`) and followed by `yield` (the
	             caller's budget check: it returns at once, or suspends the search until the next
	             frame), so no slice runs longer than its budget plus one probe or verify.
	             Measured in Lune: a full miss over 100 rings of outposts is some 40,000 probes
	             (0.9 s), over 6400 blocks of biomes 160,801 samples (0.8 s); a typical hit takes
	             1-3 rings, under 50 ms.
]]

local Biomes = require(script.Parent.Parent.Biomes)
local Blocks = require(script.Parent.Parent.Blocks)

--[[
	A locatable kind on a cell grid (the generator's `locateKinds`). Cell g covers blocks
	g x grid + origin .. (g + 1) x grid + origin - 1 on each axis (origin default 0).
	  slack   how far (blocks, per axis) a verified position may lie outside its cell
	  spread  how far (blocks) a verified position may lie from its probe's (default 0: the
	          probe's position is the answer when it verifies)
	  rings   the search's limit, in cells
	  showY   the answer shows its y (underground things) instead of "~" (Minecraft's structures)
	  probe   (gx, gz) -> x, z, y of the cell's candidate (x nil: none); never touches caches
	  verify  (gx, gz, px, pz, yield) -> x, y, z of the thing (x nil: there is none after all);
	          `px`, `pz`: the player (a long thing answers its part nearest them). nil: every probe
	          is exact.
]]
export type Kind = {
	id: string,
	grid: number,
	origin: number?,
	slack: number,
	spread: number?,
	rings: number,
	showY: boolean,
	probe: (gx: number, gz: number) -> (number?, number, number),
	verify: ((gx: number, gz: number, px: number, pz: number, yield: () -> ()) -> (number?, number, number))?,
}

-- A thing of a fixed layout (the generator's `locateList`).
export type Listed = { id: string, x: number, y: number, z: number, showY: boolean }

-- What a search found: the member id, its position, whether y is shown, and the distance.
export type Found = {
	id: string,
	x: number,
	y: number,
	z: number,
	showY: boolean,
	distance: number,
}

-- Work done: probes (cells probed, biome samples) and verifies.
export type Stats = { probes: number, verified: number }

export type Registry = {
	-- "structure", "biome" or "point_of_interest_type" (the messages name it).
	type: string,
	-- Display ids, sorted.
	ids: { string },
	-- Tag (display, without "#") -> member ids; and the tag names, sorted.
	tags: { [string]: { string } },
	tagNames: { string },
	-- Loose key -> display id / tag.
	byKey: { [string]: string },
	tagByKey: { [string]: string },
}

-- What a typed id or tag stands for: what to call it, and the ids to search.
export type Resolved = { label: string, members: { string }, tag: boolean }

local Locate = {}

-- The built-in structure kinds (TerrainGenerator's `locateKinds`), whatever this world has.
Locate.STRUCTURES = table.freeze({
	"mineshaft",
	"mineshaft_overgrown",
	"mineshaft_entrance",
	"oil_geyser",
	"oil_deposit",
	"lava_lake",
	"lake",
	"cave_entrance",
	"ravine",
})

-- Structure tags (Minecraft's #mineshaft and kin); "library" gets every library structure.
Locate.STRUCTURE_TAGS = table.freeze({
	mineshaft = { "mineshaft", "mineshaft_overgrown" },
	oil_well = { "oil_geyser", "oil_deposit" },
	lake = { "lava_lake", "lake" },
	cave = { "cave_entrance", "ravine", "mineshaft_entrance" },
} :: { [string]: { string } })
Locate.LIBRARY_TAG = "library"

-- Minecraft-like biome tags over BiomeList's biomes (snake case ids); "is_snowy" and the bands'
-- tags ("band_lowland" ...) are worked out from the list.
Locate.BIOME_TAGS = table.freeze({
	is_forest = { "forest", "birch_forest", "old_growth_taiga", "grove" },
	is_taiga = { "taiga", "old_growth_taiga" },
	is_mountain = { "meadow", "grove", "snowy_slopes", "jagged_peaks", "frozen_peaks", "stony_peaks" },
	is_hill = { "windswept_hills" },
	is_savanna = { "savanna", "windswept_savanna" },
	is_jungle = { "jungle" },
} :: { [string]: { string } })

--[[ Ids ]]

-- The loose form of an id or tag: lower case, without a "minecraft:" or "icevoxel:" namespace,
-- underscores, spaces or dashes.
function Locate.key(text: string): string
	local key = string.lower(text)
	local namespace = string.match(key, "^([%w]+):")
	if namespace == "minecraft" or namespace == "icevoxel" then
		key = string.sub(key, #namespace + 2)
	end
	return (string.gsub(key, "[_%s%-]", ""))
end

-- A name as an id: snake case ("BirchForest" -> "birch_forest", "Old Growth" -> "old_growth").
function Locate.snake(name: string): string
	local s = string.gsub(name, "(%l)(%u)", "%1_%2")
	s = string.gsub(s, "(%d)(%u)", "%1_%2")
	s = string.gsub(s, "[%s%-]+", "_")
	return string.lower(s)
end

local function sorted(list: { string }): { string }
	local out = table.clone(list)
	table.sort(out)
	return out
end

--[[
	A registry of `ids` (display ids) and `tags` (tag -> member ids; members that are no id are
	dropped, empty tags too). A later id with the same key as an earlier one is left out (the
	built-in kinds win over library structures of the same name).
]]
function Locate.registry(type: string, ids: { string }, tags: { [string]: { string } }): Registry
	local byKey: { [string]: string } = {}
	local list: { string } = {}
	for _, id in ids do
		local key = Locate.key(id)
		if byKey[key] == nil then
			byKey[key] = id
			table.insert(list, id)
		end
	end
	local kept: { [string]: { string } } = {}
	local tagByKey: { [string]: string } = {}
	local names: { string } = {}
	for tag, members in tags do
		local valid: { string } = {}
		for _, member in members do
			if byKey[Locate.key(member)] == member and not table.find(valid, member) then
				table.insert(valid, member)
			end
		end
		if #valid > 0 then
			kept[tag] = valid
			tagByKey[Locate.key(tag)] = tag
			table.insert(names, tag)
		end
	end
	return {
		type = type,
		ids = sorted(list),
		tags = kept,
		tagNames = sorted(names),
		byKey = byKey,
		tagByKey = tagByKey,
	}
end

-- The structures' registry: the built-in kinds and the library's structures (`libraryNames`).
function Locate.structureRegistry(libraryNames: { string }): Registry
	local ids = table.clone(Locate.STRUCTURES) :: { string }
	local library: { string } = {}
	for _, name in libraryNames do
		local id = Locate.snake(name)
		table.insert(ids, id)
		table.insert(library, id)
	end
	local tags: { [string]: { string } } = {}
	for tag, members in Locate.STRUCTURE_TAGS do
		tags[tag] = members
	end
	tags[Locate.LIBRARY_TAG] = library
	return Locate.registry("structure", ids, tags)
end

-- Biome index of each biome id ("birch_forest" -> its BiomeList index).
Locate.biomeIndex = {} :: { [string]: number }
for index, biome in Biomes.list do
	Locate.biomeIndex[Locate.snake(biome.name)] = index
end

-- The biomes' registry (see the header).
function Locate.biomeRegistry(): Registry
	local ids: { string } = {}
	local tags: { [string]: { string } } = {}
	for tag, members in Locate.BIOME_TAGS do
		tags[tag] = members
	end
	local snowy: { string } = {}
	local bands: { { string } } = {}
	for i in Biomes.bands do
		bands[i] = {}
	end
	local snow = Blocks.id.Snow
	for _, biome in Biomes.list do
		local id = Locate.snake(biome.name)
		table.insert(ids, id)
		if biome.frozen or biome.top == snow then
			table.insert(snowy, id)
		end
		for _, band in biome.bands do
			table.insert(bands[band], id)
		end
	end
	tags.is_snowy = snowy
	for i, band in Biomes.bands do
		tags[`band_{Locate.snake(band.name)}`] = bands[i]
	end
	return Locate.registry("biome", ids, tags)
end

--[[
	What `text` names in `registry`: an id, or a tag ("#..."). nil and "id" or "tag" when it names
	nothing (Minecraft's "There is no structure with type" / "Can't find element" / "Can't find
	tag").
]]
function Locate.resolve(registry: Registry, text: string): (Resolved?, ("id" | "tag")?)
	if string.sub(text, 1, 1) == "#" then
		local key = Locate.key(string.sub(text, 2))
		local tag = registry.tagByKey[key] or registry.tagByKey["is" .. key]
		if tag == nil then
			return nil, "tag"
		end
		return { label = `#{tag}`, members = registry.tags[tag], tag = true }, nil
	end
	local id = registry.byKey[Locate.key(text)]
	if id == nil then
		return nil, "id"
	end
	return { label = id, members = { id }, tag = false }, nil
end

-- What the answer calls the thing found: the id, or Minecraft's "#tag (member)".
function Locate.label(resolved: Resolved, found: string): string
	if resolved.tag then
		return `{resolved.label} ({found})`
	end
	return resolved.label
end

-- Members as a set.
function Locate.set(members: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, id in members do
		set[id] = true
	end
	return set
end

--[[ Structures ]]

local function noYield() end

type Hit = { d: number, gx: number, gz: number, x: number, y: number, z: number }

--[[
	The nearest thing of `kinds` to block (px, pz), by horizontal distance (see the header); nil
	when none lies within their rings. `yield` follows every probe and verify; `stats` counts them.
]]
function Locate.nearest(kinds: { Kind }, px: number, pz: number, yield: (() -> ())?, stats: Stats?): Found?
	local pause = yield or noYield
	local count: Stats = stats or { probes = 0, verified = 0 }
	local best = math.huge
	local found: Found? = nil
	local hits: { Hit } = {}
	for _, kind in kinds do
		local grid, origin = kind.grid, kind.origin or 0
		local spread = kind.spread or 0
		local cx, cz = (px - origin) // grid, (pz - origin) // grid
		local probe, verify = kind.probe, kind.verify
		for k = 0, kind.rings do
			-- Every cell of ring k is (k - 1) x grid away along one axis at least.
			if (k - 1) * grid - kind.slack > best then
				break
			end
			table.clear(hits)
			for gz = cz - k, cz + k do
				local edge = gz == cz - k or gz == cz + k
				local gx = cx - k
				while gx <= cx + k do
					local x, z, y = probe(gx, gz)
					count.probes += 1
					if x then
						local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
						if d - spread < best then
							table.insert(hits, { d = d, gx = gx, gz = gz, x = x, y = y, z = z })
						end
					end
					pause()
					-- (Inside rows only the two end cells belong to the ring.)
					gx += if edge or k == 0 then 1 else 2 * k
				end
			end
			if #hits > 1 then
				table.sort(hits, function(a: Hit, b: Hit): boolean
					return a.d < b.d
				end)
			end
			for _, hit in hits do
				if hit.d - spread >= best then
					break
				end
				if verify then
					local x, y, z = verify(hit.gx, hit.gz, px, pz, pause)
					count.verified += 1
					pause()
					if x then
						local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
						if d < best then
							best = d
							found = { id = kind.id, x = x, y = y, z = z, showY = kind.showY, distance = d }
						end
					end
				else
					best = hit.d
					found = { id = kind.id, x = hit.x, y = hit.y, z = hit.z, showY = kind.showY, distance = hit.d }
					break
				end
			end
		end
	end
	return found
end

-- The nearest listed thing whose id is in `members` (a fixed layout), or nil.
function Locate.nearestListed(list: { Listed }, members: { [string]: boolean }, px: number, pz: number): Found?
	local found: Found? = nil
	for _, thing in list do
		if members[thing.id] then
			local d = math.sqrt((thing.x - px) ^ 2 + (thing.z - pz) ^ 2)
			if found == nil or d < found.distance then
				found = { id = thing.id, x = thing.x, y = thing.y, z = thing.z, showY = thing.showY, distance = d }
			end
		end
	end
	return found
end

--[[ Biomes ]]

-- The biome indices of biome ids (unknown ones left out).
function Locate.biomeSet(members: { string }): { [number]: boolean }
	local set: { [number]: boolean } = {}
	for _, id in members do
		local index = Locate.biomeIndex[id]
		if index then
			set[index] = true
		end
	end
	return set
end

-- May a generator producing `biomes` (nil: every biome) have a biome of `set`?
function Locate.possible(set: { [number]: boolean }, biomes: { number }?): boolean
	if biomes == nil then
		return next(set) ~= nil
	end
	for _, index in biomes do
		if set[index] then
			return true
		end
	end
	return false
end

--[[
	The nearest column to block (px, pz) whose biome is in `set`, among samples `step` blocks
	apart in square rings out to `radius` (see the header): x, z of the sample, y its surface
	height (`column`'s first air), the horizontal distance. nil when none (or `biomes`, the
	generator's possible ones, has none of the set: no sample at all).
]]
function Locate.biome(
	column: (x: number, z: number) -> (number, number, number, number),
	set: { [number]: boolean },
	biomes: { number }?,
	px: number,
	pz: number,
	radius: number,
	step: number,
	yield: (() -> ())?,
	stats: Stats?
): Found?
	if not Locate.possible(set, biomes) then
		return nil
	end
	local pause = yield or noYield
	local count: Stats = stats or { probes = 0, verified = 0 }
	local bx, bz = math.floor(px), math.floor(pz)
	local best = math.huge
	local found: Found? = nil
	local foundBiome = 0
	for r = 0, radius // step do
		-- Every sample of ring r is r x step away at least.
		if r * step >= best then
			break
		end
		for j = -r, r do
			local edge = j == -r or j == r
			local i = -r
			while i <= r do
				local x, z = bx + i * step, bz + j * step
				local height, biome = column(x, z)
				count.probes += 1
				if set[biome] then
					local d = step * math.sqrt(i * i + j * j)
					if d < best then
						best, foundBiome = d, biome
						found = { id = "", x = x, y = height, z = z, showY = true, distance = d }
					end
				end
				pause()
				i += if edge or r == 0 then 1 else 2 * r
			end
		end
	end
	local result = found
	if result then
		result.id = Locate.snake(Biomes.list[foundBiome].name)
	end
	return result
end

return Locate
