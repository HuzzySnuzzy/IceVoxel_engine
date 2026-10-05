--!strict
--[[
	Structure blocks and jigsaw blocks on the server: Minecraft 1.20.1's
	ServerGamePacketListenerImpl.handleSetStructureBlock / handleSetJigsawBlock /
	handleJigsawGenerate, StructureBlockEntity and JigsawBlockEntity. Pure (no Roblox APIs): it
	works on a WorldServer, the settings store (StructureStore), the containers (Players/
	Containers) and what its `Env` does for it, so the tests drive it end to end.
	Structures/StructureBlocks connects it to the game (messages, permission, rate limits,
	ServerStorage, replication).

	Every request was decoded (Net/Protocol: malformed ones never get here) and comes with
	`allowed` (Structures/Permission: creative, and Config.Structures.Permission,
	Config.Gameplay.Admins, the owner or Studio).
	It must name a structure block (or a jigsaw) that is there, without generating terrain, within
	reach for "open" (Interaction.Reach + 2, as Use) and within OP_RANGE for the others (a screen
	stays open where its block was clicked; Minecraft checks nothing). Anything else is ignored.

	Structure block requests (op, settings, transfer):
	  open    the block's settings to the player, flagged open (their screen shows them); a player
	          who may not use it is told so
	  update  the screen's fields: the settings are stored (names checked: Settings.
	          checkStructure, a bad one is refused and the player told), and a new mode swaps the
	          block (Blocks.structureBlock), which keeps its settings (StructureStore)
	  save    update, then SAVE: the region (block + offset, size; terrain generated if need be,
	          as edits do) is captured (Template.capture: structure voids keep, DATA blocks become
	          data markers, jigsaws keep their settings, containers their items, cave air and
	          cave twins their surface forms), encoded ("IVS1:..."), kept for the session by name
	          (and handed to `Env.stored`, ServerStorage, until the session drops it:
	          `Env.forget`) and sent to the player (`Env.sendData`);
	          they read "Saved structure '<name>' (N blocks, M characters)"
	  load    update, then LOAD: the template named in the settings (this session's saves first,
	          then the library) or the text the player uploaded (transfer: StructureData pieces,
	          `data`). As Minecraft, a template of another size first only sets the size ("Structure
	          '<name>' position prepared": the bounding box shows where it goes) and the next LOAD
	          places it. Placing is a Placement plan (rotation, mirror, integrity, seed; 0 picks a
	          random seed) spread over frames (`place`)
	  detect  update, then DETECT (StructureBlockEntity.detectSize): the CORNER blocks with this
	          name within Config.Structures.DetectRange blocks (sideways, any height) span a box,
	          or one corner and this block do; the region becomes the inside of that box
	          (offset = min - block + 1, size = max - min - 1), if every side is at least 1 and it
	          fits the structure block's limits
	Jigsaw requests (op, settings, levels, keepJigsaws):
	  open      as above, with the jigsaw's settings
	  update    the settings are stored (Settings.checkJigsaw: names, a final state that is a block)
	  generate  update, then Generate: Jigsaw.generateFrom from this jigsaw (its pool, target,
	            front and top) with `levels`, a random seed, the session's saves and the library
	            (`lookups`: a pool may hold templates saved minutes ago), then the pieces placed
	            like LOAD, jigsaws turned into their final state unless "Keep jigsaws" (kept ones
	            keep their settings). Terrain matching pieces follow `surfaceHeight`
	Replies use Minecraft's wording (structure_block.* in en_us) where it has one.

	Plans wait in one queue: a LOAD or Generate that would take it beyond MAX_QUEUED cells is
	refused until it drains ("Still placing ..."), and a Generate whose pieces hold more than
	MAX_GENERATE cells is refused outright. A LOAD's plan (at most 48^3 cells) is built at once; a
	Generate's is streamed (Placement.piecesPlan: its cells, and the surface heights its terrain
	matching pieces need, are worked out as it is placed), so a request never costs more than its
	assembly however many cells it brings.

	Uploads (`data`): StructureData pieces put together per player (Protocol.joinStructureData);
	the last UPLOADS_KEPT finished texts are kept by transfer number, so LOAD can name one (twice:
	prepare, then load). Only players allowed to use structure blocks may upload.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Jigsaw = require(Shared.Structures.Jigsaw)
local Library = require(Shared.Structures.Library)
local Machines = require(Shared.Machines)
local Protocol = require(Shared.Net.Protocol)
local Settings = require(Shared.Structures.Settings)
local Template = require(Shared.Structures.Template)
local Types = require(Shared.Inventory.Types)

local Containers = require(script.Parent.Parent.Players.Containers)
local WorldServer = require(script.Parent.Parent.World.WorldServer)
local Permission = require(script.Parent.Permission)
local Placement = require(script.Parent.Placement)
local StructureStore = require(script.Parent.StructureStore)

type Template = Template.Template
type StructureSettings = Settings.StructureSettings
type JigsawSettings = Settings.JigsawSettings
type Stack = Types.Stack

-- What the server does for the core (Structures/StructureBlocks: the game; tests: fakes).
export type Env = {
	world: WorldServer.World,
	store: StructureStore.Store,
	containers: Containers.Store,
	-- The structure library (Library.load(); called when first needed).
	library: () -> Library.Library,
	-- A message for the player's chat (Notice).
	notify: (player: any, text: string) -> (),
	-- Records to one player; `open` answers their open request.
	sendStructureBlocks: (player: any, records: { Protocol.StructureBlockRecord }, open: boolean) -> (),
	sendJigsaws: (player: any, records: { Protocol.JigsawRecord }, open: boolean) -> (),
	-- A SAVE's text, to the player who saved (StructureData pieces).
	sendData: (player: any, text: string) -> (),
	-- A SAVE's text under its name, somewhere the user can copy it (ServerStorage), and that
	-- save dropped from the session (beyond MAX_SAVED or MAX_SAVED_BYTES): `stored` keeps a
	-- copy only while the session does, so its caps hold there too.
	stored: ((name: string, text: string) -> ())?,
	forget: ((name: string) -> ())?,
	-- The items of the container at (x, y, z) changed without its viewers (Inventories).
	containerChanged: ((x: number, y: number, z: number) -> ())?,
	-- A fresh random seed (structure seed 0, Generate).
	seed: () -> number,
	-- Is (x, y, z) within `range` blocks of the player?
	inRange: (player: any, x: number, y: number, z: number, range: number) -> boolean,
}

export type Saved = { template: Template, text: string }

type Uploads = {
	assemblies: { [number]: Protocol.StructureDataAssembly },
	-- Finished texts, newest last.
	done: { { transfer: number, text: string } },
}

export type Lookups = {
	template: (name: string) -> Template?,
	pool: (name: string) -> Jigsaw.Pool?,
}

export type Server = {
	env: Env,
	queue: Placement.Queue,
	-- This session's saves by name, their names oldest first, and their bytes in all.
	saved: { [string]: Saved },
	savedOrder: { string },
	savedBytes: number,
	uploads: { [any]: Uploads },
	-- The templates and pools over the saves and the library (made again after a save).
	cachedLookups: Lookups?,

	structureBlock: (self: Server, player: any, request: Protocol.StructureBlockRequest, allowed: boolean) -> (),
	jigsaw: (self: Server, player: any, request: Protocol.JigsawRequest, allowed: boolean) -> (),
	data: (self: Server, player: any, piece: Protocol.StructureDataPiece, allowed: boolean) -> (),
	use: (self: Server, player: any, x: number, y: number, z: number, allowed: boolean) -> (),
	leave: (self: Server, player: any) -> (),
	place: (self: Server, blocks: number, chunks: number, seconds: number?) -> number,
	template: (self: Server, name: string) -> Template?,
	lookups: (self: Server) -> Lookups,
}

local StructureServer = {}

local AIR = Blocks.AIR
local HEIGHT = Config.WorldHeight
local SIZE = Config.ChunkSize

-- Blocks from the player: an open (a right click) and the screen's other requests.
StructureServer.OPEN_RANGE = Config.Interaction.Reach + 2
StructureServer.OP_RANGE = 32
-- Saves kept in memory by name, and their bytes (text and cells) in all: beyond either the
-- oldest goes first (and its copy in ServerStorage: Env.forget).
StructureServer.MAX_SAVED = 256
StructureServer.MAX_SAVED_BYTES = 32000000
-- Finished uploads kept per player.
StructureServer.UPLOADS_KEPT = 2
-- Warnings told after one request (the rest are counted).
StructureServer.MAX_WARNINGS = 3
-- Cells waiting to be placed at most (LOADs and Generates queue behind each other), and the most
-- one Generate may place (its templates' cells in all): at 2,000 a frame, about 25 and 17 s.
StructureServer.MAX_QUEUED = 3000000
StructureServer.MAX_GENERATE = 2000000

--[[ Messages (Minecraft's structure_block.* where there is one) ]]

local Messages = {}
StructureServer.Messages = Messages

function Messages.saved(name: string, blocks: number, characters: number): string
	return `Saved structure '{name}' ({blocks} blocks, {characters} characters)`
end
function Messages.saveFailure(name: string): string
	return `Unable to save structure '{name}'`
end
function Messages.loadSuccess(name: string): string
	return `Structure loaded from '{name}'`
end
function Messages.loadPrepare(name: string): string
	return `Structure '{name}' position prepared`
end
function Messages.loadNotFound(name: string): string
	return `Structure '{name}' is not available`
end
function Messages.sizeSuccess(name: string): string
	return `Size successfully detected for '{name}'`
end
Messages.SIZE_FAILURE = "Unable to detect structure size. Add corners with matching structure names"
function Messages.invalidName(name: string): string
	return `Invalid structure name '{name}'`
end
Messages.UPLOAD_MISSING = "The pasted structure data did not arrive whole: paste it again"
function Messages.generated(pieces: number, pool: string): string
	return `Generated {pieces} {if pieces == 1 then "piece" else "pieces"} from pool '{pool}'`
end
function Messages.emptyPool(pool: string): string
	return `Nothing to generate: pool '{pool}' is empty`
end
function Messages.busy(pending: number): string
	return `Still placing {pending} blocks of other structures: try again when they are done`
end
function Messages.tooBig(cells: number): string
	return `Too big to generate: {cells} blocks (at most {StructureServer.MAX_GENERATE})`
end

--[[ Pure helpers ]]

-- Does `block` count as the ground for a terrain matching piece: a sturdy block or a fluid (not
-- leaves, plants, torches or glow lichen)?
local function ground(block: number): boolean
	return Blocks.isSturdy(block) or (Blocks.isValid(block) and Blocks.get(block).fluid ~= nil)
end

--[[
	The y of the first air above the ground of column (x, z), for a jigsaw's Generate (Minecraft's
	WORLD_SURFACE_WG): the live world where its chunk is loaded (above the highest sturdy block or
	fluid, so trees, plants and glow lichen don't lift a path), else the generator's terrain height
	(the sea's surface counts as ground), never generating terrain.
]]
function StructureServer.surfaceHeight(world: WorldServer.World, x: number, z: number): number
	local chunk = world:peekChunk(x // SIZE, z // SIZE)
	if chunk == nil then
		local height = world.generator.column(x, z)
		return math.max(height, Config.SeaLevel)
	end
	for y = chunk.height - 1, 0, -1 do
		local block = world:peekBlock(x, y, z)
		if block ~= nil and ground(block) then
			return y + 1
		end
	end
	return 0
end

--[[
	Container items (Template: 1-based slot, item name, count, damage) as a container's slots for
	a container of `size` slots: unknown items, slots beyond the size, repeated slots and counts
	below 1 are left out; counts are capped at the item's stack size. Item data is not kept.
]]
function StructureServer.slotsFromItems(items: { Template.ContainerItem }, size: number): { [number]: Stack }
	local slots: { [number]: Stack } = {}
	if type(items) ~= "table" then
		return slots
	end
	for _, entry in items do
		if type(entry) ~= "table" then
			continue
		end
		local slot, count, name = entry.slot, entry.count, entry.item
		local item = if type(name) == "string" then rawget(Items.id :: any, name) else nil
		if
			item ~= nil
			and type(slot) == "number"
			and slot == math.floor(slot)
			and slot >= 1
			and slot <= size
			and slots[slot] == nil
			and type(count) == "number"
			and count >= 1
		then
			local stack =
				Items.newStack(item, math.min(math.floor(count), Items.maxStack(item)), tonumber(entry.damage) or 0)
			if stack then
				slots[slot] = stack
			end
		end
	end
	return slots
end

-- A container's slots as Template container items (sorted by slot; item data left out).
function StructureServer.itemsFromSlots(container: Types.Container): { Template.ContainerItem }
	local items: { Template.ContainerItem } = {}
	for slot = 1, container.size do
		local stack = container.slots[slot]
		local def = if stack and stack.count >= 1 then Items.get(stack.item) else nil
		if stack and def then
			table.insert(items, { slot = slot, item = def.name, count = stack.count, damage = stack.damage or 0 })
		end
	end
	return items
end

--[[
	Minecraft's StructureBlockEntity.detectSize for a SAVE block at (x, y, z), given its CORNER
	blocks' positions: the box around them (one corner: around it and the block). Returns the
	region's relative position and size (the inside of the box), or nil when there is no corner
	or a side is under 1 (or over the limits: Settings.MAX_OFFSET / MAX_SIZE, where Minecraft has
	none) with the message why.
]]
function StructureServer.detect(
	x: number,
	y: number,
	z: number,
	corners: { { number } }
): ({ number }?, { number }?, string?)
	if #corners == 0 then
		return nil, nil, Messages.SIZE_FAILURE
	end
	local first = corners[1]
	local min = { first[1], first[2], first[3] }
	local max = { first[1], first[2], first[3] }
	local others: { { number } } = if #corners == 1 then { { x, y, z } } else corners
	for _, p in others do
		for k = 1, 3 do
			min[k] = math.min(min[k], p[k])
			max[k] = math.max(max[k], p[k])
		end
	end
	local pos = { x, y, z }
	local offset, size = {}, {}
	for k = 1, 3 do
		if max[k] - min[k] <= 1 then
			return nil, nil, Messages.SIZE_FAILURE
		end
		offset[k] = min[k] - pos[k] + 1
		size[k] = max[k] - min[k] - 1
		if size[k] > Settings.MAX_SIZE or math.abs(offset[k]) > Settings.MAX_OFFSET then
			return nil,
				nil,
				`Unable to detect structure size: the corners are too far apart (at most {Settings.MAX_SIZE} blocks inside on each side, within {Settings.MAX_OFFSET} of this block)`
		end
	end
	return offset, size, nil
end

-- Template lists of names starting with `prefix` (sorted).
local function withPrefix(names: { string }, prefix: string): { string }
	local list = {}
	local n = #prefix
	for _, name in names do
		if string.sub(name, 1, n) == prefix then
			table.insert(list, name)
		end
	end
	table.sort(list)
	return list
end

--[[
	The templates and pools a jigsaw's Generate and a LOAD by name see: this session's saves over
	the library's templates of the same name, and pools resolved as the library does (an explicit
	pool, else the template of exactly that name, else every template named "<pool>/...", weight
	1, rigid unless the library says terrain matching) over both. So a piece saved a minute ago
	joins its pool at once.
]]
function StructureServer.lookups(library: Library.Library, saved: { [string]: Saved }): Lookups
	local sessionNames: { string } = {}
	for name in saved do
		table.insert(sessionNames, name)
	end
	table.sort(sessionNames)
	local function template(name: string): Template?
		if type(name) ~= "string" then
			return nil
		end
		local own = saved[name]
		if own then
			return own.template
		end
		return library.template(name) :: any
	end
	local resolved: { [string]: Jigsaw.Pool | false } = {}
	local function pool(name: string): Jigsaw.Pool?
		if type(name) ~= "string" then
			return nil
		end
		local cached = resolved[name]
		if cached ~= nil then
			return if cached == false then nil else cached :: Jigsaw.Pool
		end
		local found: Jigsaw.Pool? = library.pools[name]
		if found == nil and saved[name] then
			found = { name = name, elements = { { template = name, weight = 1, projection = Jigsaw.RIGID } } }
		end
		if found == nil then
			local own = withPrefix(sessionNames, name .. "/")
			if #own == 0 then
				found = library.pool(name)
			elseif library.templates[name] then
				found = library.pool(name)
			else
				-- The library's implicit pool (its projections) plus the saves, sorted by name.
				local elements: { [string]: Jigsaw.Element } = {}
				local base = library.pool(name)
				if base then
					for _, e in base.elements do
						if e.template then
							elements[e.template] = e
						end
					end
				end
				for _, t in own do
					if elements[t] == nil then
						elements[t] = { template = t, weight = 1, projection = Jigsaw.RIGID }
					end
				end
				local names: { string } = {}
				for t in elements do
					table.insert(names, t)
				end
				table.sort(names)
				local list: { Jigsaw.Element } = {}
				for _, t in names do
					table.insert(list, elements[t])
				end
				found = { name = name, elements = list }
			end
		end
		resolved[name] = found or false
		return found
	end
	return { template = template, pool = pool }
end

--[[ The server ]]

local ServerMethods = {}
ServerMethods.__index = ServerMethods

local function sameSize(a: { number }, b: { number }): boolean
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- Tells the player up to MAX_WARNINGS of `warnings`, and how many more there were.
local function tellWarnings(env: Env, player: any, warnings: { string })
	local n = #warnings
	for i = 1, math.min(n, StructureServer.MAX_WARNINGS) do
		env.notify(player, warnings[i])
	end
	if n > StructureServer.MAX_WARNINGS then
		env.notify(player, `... and {n - StructureServer.MAX_WARNINGS} more`)
	end
end

-- The structure block at (x, y, z) if the request may act on it: it is there (loaded), in range.
-- One the store has no settings for gets the defaults (generation never makes these blocks, but a
-- library template's final state could).
local function structureBlockAt(self: Server, player: any, x: number, y: number, z: number, range: number): number?
	if y < 0 or y >= HEIGHT then
		return nil
	end
	local block = self.env.world:peekBlock(x, y, z)
	if block == nil or not Blocks.isStructureBlock(block) or not self.env.inRange(player, x, y, z, range) then
		return nil
	end
	if self.env.store:structure(x, y, z) == nil then
		-- (One that came without an edit the store saw, e.g. a final state: its defaults now.)
		self.env.store:blockChanged(x, y, z, AIR, block)
	end
	return block
end

local function jigsawAt(self: Server, player: any, x: number, y: number, z: number, range: number): number?
	if y < 0 or y >= HEIGHT then
		return nil
	end
	local block = self.env.world:peekBlock(x, y, z)
	if block == nil or not Blocks.isJigsaw(block) or not self.env.inRange(player, x, y, z, range) then
		return nil
	end
	if self.env.store:jigsaw(x, y, z) == nil then
		self.env.store:blockChanged(x, y, z, AIR, block)
	end
	return block
end

local function bytesOf(saved: Saved): number
	return #saved.text + buffer.len(saved.template.cells)
end

-- Remembers a save for the session by name (the oldest are dropped beyond MAX_SAVED or
-- MAX_SAVED_BYTES, and `Env.forget` told; the newest always stays).
local function remember(self: Server, name: string, template: Template, text: string)
	local old = self.saved[name]
	if old then
		self.savedBytes -= bytesOf(old)
		local i = table.find(self.savedOrder, name)
		if i then
			table.remove(self.savedOrder, i)
		end
	end
	local entry = { template = template, text = text }
	self.saved[name] = entry
	self.savedBytes += bytesOf(entry)
	table.insert(self.savedOrder, name)
	while
		#self.savedOrder > 1
		and (#self.savedOrder > StructureServer.MAX_SAVED or self.savedBytes > StructureServer.MAX_SAVED_BYTES)
	do
		local oldest = table.remove(self.savedOrder, 1) :: string
		local dropped = self.saved[oldest]
		if dropped then
			self.savedBytes -= bytesOf(dropped)
		end
		self.saved[oldest] = nil
		if self.env.forget then
			self.env.forget(oldest)
		end
	end
	-- (Pools over the saves are worked out again.)
	self.cachedLookups = nil
end

-- The template saved this session or in the library under `name`.
function ServerMethods.template(self: Server, name: string): Template?
	return self:lookups().template(name)
end

function ServerMethods.lookups(self: Server): Lookups
	local cached = self.cachedLookups
	if cached then
		return cached
	end
	local made = StructureServer.lookups(self.env.library(), self.saved)
	self.cachedLookups = made
	return made
end

--[[ SAVE ]]

local function save(self: Server, player: any, x: number, y: number, z: number, s: StructureSettings)
	local env = self.env
	local name = s.name
	if s.mode ~= "save" then
		env.notify(player, Messages.saveFailure(name))
		return
	end
	for k = 1, 3 do
		if s.size[k] < 1 then
			env.notify(player, `{Messages.saveFailure(name)}: the size must be at least 1 on every side`)
			return
		end
	end
	local world = env.world
	local containers = env.containers
	local store = env.store
	local template, warnings = Template.capture({
		name = name,
		x = x + s.offset[1],
		y = y + s.offset[2],
		z = z + s.offset[3],
		size = s.size,
		getBlock = function(bx: number, by: number, bz: number): number?
			if by < 0 or by >= HEIGHT then
				return AIR
			end
			-- (Terrain is generated where need be, as edits do.)
			return world:getBlock(bx, by, bz)
		end,
		jigsaw = function(bx: number, by: number, bz: number): JigsawSettings?
			return store:jigsaw(bx, by, bz)
		end,
		marker = function(bx: number, by: number, bz: number): string?
			local settings = store:structure(bx, by, bz)
			return if settings then settings.metadata else nil
		end,
		container = function(bx: number, by: number, bz: number): { Template.ContainerItem }?
			local container = containers:peek(bx, by, bz)
			if container == nil or container.block ~= world:peekBlock(bx, by, bz) then
				return nil
			end
			return StructureServer.itemsFromSlots(container)
		end,
	})
	local problem = Template.check(template)
	if problem then
		env.notify(player, `{Messages.saveFailure(name)}: {problem}`)
		return
	end
	local ok, text = pcall(Template.encode, template)
	if not ok or type(text) ~= "string" then
		env.notify(player, `{Messages.saveFailure(name)}: {tostring(text)}`)
		return
	end
	local limit = Protocol.MAX_STRUCTURE_TEXT
	if #text > limit then
		env.notify(
			player,
			`{Messages.saveFailure(name)}: it is {#text} characters, over the {limit} a StringValue holds; save it in smaller parts`
		)
		return
	end
	remember(self, name, template, text)
	if env.stored then
		env.stored(name, text)
	end
	env.sendData(player, text)
	env.notify(player, Messages.saved(name, Template.count(template), #text))
	tellWarnings(env, player, warnings)
end

--[[ LOAD ]]

-- What a container cell gets once its block is there; jigsaws and DATA blocks their settings.
local function applyExtra(self: Server, x: number, y: number, z: number, block: number, extra: Placement.Extra)
	local env = self.env
	if env.world:peekBlock(x, y, z) ~= block then
		return
	end
	if extra.jigsaw then
		env.store:setJigsaw(x, y, z, extra.jigsaw)
	end
	if extra.structure then
		local settings = table.clone(extra.structure)
		settings.mode = Blocks.structureMode(block) or settings.mode
		env.store:setStructure(x, y, z, settings)
	end
	local items = extra.items
	if items and Machines.containerSize(block) > 0 then
		local container = env.containers:get(x, y, z, block)
		local slots = StructureServer.slotsFromItems(items, container.size)
		-- (Replaced as the template says, as Minecraft clears a container it places over.)
		table.clear(container.slots)
		for slot, stack in slots do
			container.slots[slot] = stack
		end
		if env.containerChanged then
			env.containerChanged(x, y, z)
		end
	end
end

-- The upload `transfer` the player finished, nil if there is none.
local function uploaded(self: Server, player: any, transfer: number): string?
	local uploads = self.uploads[player]
	if uploads == nil then
		return nil
	end
	for _, done in uploads.done do
		if done.transfer == transfer then
			return done.text
		end
	end
	return nil
end

local function load(self: Server, player: any, x: number, y: number, z: number, s: StructureSettings, transfer: number)
	local env = self.env
	local template: Template? = nil
	local name = s.name
	if transfer ~= 0 then
		local text = uploaded(self, player, transfer)
		if text == nil then
			env.notify(player, Messages.UPLOAD_MISSING)
			return
		end
		local decoded, err, warnings = Template.decode(text)
		if decoded == nil then
			env.notify(player, `Unable to load the pasted structure: {err or "it is not structure data"}`)
			return
		end
		tellWarnings(env, player, warnings or {})
		template = decoded
		name = decoded.name
	elseif name == "" then
		env.notify(player, Messages.invalidName(name))
		return
	else
		template = self:template(name)
	end
	if template == nil or s.mode ~= "load" then
		env.notify(player, Messages.loadNotFound(name))
		return
	end
	if not sameSize(s.size, template.size) then
		-- Minecraft: a template of another size only sets the size first (the box shows where it
		-- goes); the next LOAD places it.
		local prepared = table.clone(s)
		prepared.size = table.clone(template.size)
		env.store:setStructure(x, y, z, prepared)
		env.notify(player, Messages.loadPrepare(name))
		return
	end
	local size = template.size
	local pending = self.queue:pending()
	if pending + size[1] * size[2] * size[3] > StructureServer.MAX_QUEUED then
		env.notify(player, Messages.busy(pending))
		return
	end
	local seed = if s.seed == 0 then env.seed() else s.seed
	local plan = Placement.loadPlan(template, {
		x = x + s.offset[1],
		y = y + s.offset[2],
		z = z + s.offset[3],
		rotation = s.rotation,
		mirror = s.mirror,
		integrity = s.integrity,
		seed = seed,
	})
	self.queue:add(plan)
	env.notify(player, Messages.loadSuccess(name))
end

--[[ DETECT ]]

local function detect(self: Server, player: any, x: number, y: number, z: number, s: StructureSettings)
	local env = self.env
	if s.mode ~= "save" then
		env.notify(player, Messages.SIZE_FAILURE)
		return
	end
	local range = Config.Structures.DetectRange
	local corners: { { number } } = {}
	for _, p in env.store:corners(x, z, range, s.name) do
		-- (A corner is one while its block is: the store follows the blocks.)
		if Blocks.structureMode(env.world:peekBlock(p[1], p[2], p[3]) or AIR) == "corner" then
			table.insert(corners, p)
		end
	end
	local offset, size, problem = StructureServer.detect(x, y, z, corners)
	if offset == nil or size == nil then
		env.notify(player, problem or Messages.SIZE_FAILURE)
		return
	end
	local detected = table.clone(s)
	detected.offset = offset
	detected.size = size
	env.store:setStructure(x, y, z, detected)
	env.notify(player, Messages.sizeSuccess(s.name))
end

--[[ Requests ]]

-- Stores a structure block's settings from its screen (Minecraft sets every field before any
-- action): a new mode swaps the block. false (and the player told) when the names are bad.
local function update(
	self: Server,
	player: any,
	x: number,
	y: number,
	z: number,
	block: number,
	s: StructureSettings
): boolean
	local env = self.env
	local problem = Settings.checkStructure(s)
	if problem then
		env.notify(player, problem)
		-- (Their screen goes back to what the block holds.)
		env.sendStructureBlocks(player, { env.store:structureRecord(x, y, z) }, false)
		return false
	end
	local target = Blocks.structureBlock(s.mode)
	if target and target ~= block then
		env.world:setBlock(x, y, z, target)
	end
	local settings = Settings.clampStructure(s)
	settings.mode = Blocks.structureMode(env.world:peekBlock(x, y, z) or block) or settings.mode
	env.store:setStructure(x, y, z, settings)
	return true
end

function ServerMethods.structureBlock(
	self: Server,
	player: any,
	request: Protocol.StructureBlockRequest,
	allowed: boolean
)
	local env = self.env
	local x, y, z = request.x, request.y, request.z
	local op: string = request.op
	local range = if op == "open" then StructureServer.OPEN_RANGE else StructureServer.OP_RANGE
	local block = structureBlockAt(self, player, x, y, z, range)
	if block == nil then
		return
	end
	if not allowed then
		if op == "open" then
			env.notify(player, Permission.DENIED)
		end
		return
	end
	if op == "open" then
		env.sendStructureBlocks(player, { env.store:structureRecord(x, y, z) }, true)
		return
	end
	local s = request.settings
	if s == nil or not update(self, player, x, y, z, block, s) then
		return
	end
	local stored = env.store:structure(x, y, z) :: StructureSettings
	if op == "update" then
		return
	end
	-- (Minecraft's hasStructureName: the actions need a name; a pasted LOAD brings its own.)
	local pasted = request.transfer ~= 0 and request.op == "load"
	if stored.name == "" and not pasted then
		env.notify(player, Messages.invalidName(stored.name))
		return
	end
	if op == "save" then
		save(self, player, x, y, z, stored)
	elseif op == "load" then
		load(self, player, x, y, z, stored, request.transfer)
	elseif op == "detect" then
		detect(self, player, x, y, z, stored)
	end
end

function ServerMethods.jigsaw(self: Server, player: any, request: Protocol.JigsawRequest, allowed: boolean)
	local env = self.env
	local x, y, z, op = request.x, request.y, request.z, request.op
	local range = if op == "open" then StructureServer.OPEN_RANGE else StructureServer.OP_RANGE
	local block = jigsawAt(self, player, x, y, z, range)
	if block == nil then
		return
	end
	if not allowed then
		if op == "open" then
			env.notify(player, Permission.DENIED)
		end
		return
	end
	if op == "open" then
		env.sendJigsaws(player, { env.store:jigsawRecord(x, y, z) }, true)
		return
	end
	local settings = request.settings
	if settings == nil then
		return
	end
	local front, top = Blocks.jigsawOrientation(block)
	local clamped = Settings.clampJigsaw(settings, front)
	local problem = Settings.checkJigsaw(clamped)
	if problem then
		env.notify(player, problem)
		env.sendJigsaws(player, { env.store:jigsawRecord(x, y, z) }, false)
		return
	end
	env.store:setJigsaw(x, y, z, clamped)
	if op ~= "generate" or front == nil or top == nil then
		return
	end

	-- Generate (JigsawBlockEntity.generate: the pool, from the jigsaw's own position).
	local pool = clamped.pool
	if Jigsaw.EMPTY_POOLS[pool] then
		env.notify(player, Messages.emptyPool(pool))
		return
	end
	local world = env.world
	local heights: { [number]: number } = {}
	local function firstFreeHeight(hx: number, hz: number): number
		local key = (hx + 1048576) * 2097152 + (hz + 1048576)
		local h = heights[key]
		if h == nil then
			h = StructureServer.surfaceHeight(world, hx, hz)
			heights[key] = h
		end
		return h
	end
	local warnings: { string } = {}
	local lookups = self:lookups()
	local pieces = Jigsaw.generateFrom({
		seed = env.seed(),
		source = {
			x = x,
			y = y,
			z = z,
			front = front,
			top = top,
			pool = pool,
			target = clamped.target,
			joint = clamped.joint,
		},
		levels = request.levels,
		firstFreeHeight = firstFreeHeight,
		pool = lookups.pool,
		template = lookups.template :: any,
		warn = function(message: string)
			table.insert(warnings, message)
		end,
	})
	if #pieces == 0 then
		env.notify(player, warnings[1] or Messages.emptyPool(pool))
		return
	end
	local volume = Placement.volume(pieces, lookups.template)
	local pending = self.queue:pending()
	if volume > StructureServer.MAX_GENERATE then
		env.notify(player, Messages.tooBig(volume))
		return
	elseif pending + volume > StructureServer.MAX_QUEUED then
		env.notify(player, Messages.busy(pending))
		return
	end
	local plan = Placement.piecesPlan(pieces, lookups.template, firstFreeHeight, request.keepJigsaws)
	self.queue:add(plan)
	env.notify(player, Messages.generated(#pieces, pool))
	tellWarnings(env, player, warnings)
end

-- A right click (Use message) on a structure block or jigsaw: the same as an open request.
function ServerMethods.use(self: Server, player: any, x: number, y: number, z: number, allowed: boolean)
	local block = if y >= 0 and y < HEIGHT then self.env.world:peekBlock(x, y, z) else nil
	if block == nil then
		return
	elseif Blocks.isStructureBlock(block) then
		self:structureBlock(player, { x = x, y = y, z = z, op = "open", transfer = 0 }, allowed)
	elseif Blocks.isJigsaw(block) then
		self:jigsaw(player, { x = x, y = y, z = z, op = "open", levels = 0, keepJigsaws = false }, allowed)
	end
end

function ServerMethods.data(self: Server, player: any, piece: Protocol.StructureDataPiece, allowed: boolean)
	if not allowed then
		return
	end
	local uploads = self.uploads[player]
	if uploads == nil then
		uploads = { assemblies = {}, done = {} }
		self.uploads[player] = uploads
	end
	local text, err = Protocol.joinStructureData(uploads.assemblies, piece)
	if err then
		self.env.notify(player, err)
	elseif text then
		for i, done in uploads.done do
			if done.transfer == piece.transfer then
				table.remove(uploads.done, i)
				break
			end
		end
		table.insert(uploads.done, { transfer = piece.transfer, text = text })
		while #uploads.done > StructureServer.UPLOADS_KEPT do
			table.remove(uploads.done, 1)
		end
	end
end

-- Forgets what the player was uploading.
function ServerMethods.leave(self: Server, player: any)
	self.uploads[player] = nil
end

--[[
	Places up to `blocks` cells of the queued LOADs and Generates (and generates up to `chunks`
	chunks on the way), within `seconds` when given. Returns the cells placed.
]]
function ServerMethods.place(self: Server, blocks: number, chunks: number, seconds: number?): number
	local world = self.env.world
	return self.queue:step(blocks, chunks, {
		clock = os.clock,
		setBlock = function(x: number, y: number, z: number, block: number)
			world:setBlock(x, y, z, block)
		end,
		loaded = function(x: number, z: number): boolean
			return world:peekChunk(x // SIZE, z // SIZE) ~= nil
		end,
		load = function(x: number, z: number)
			world:getChunk(x // SIZE, z // SIZE)
		end,
		extra = function(x: number, y: number, z: number, block: number, extra: Placement.Extra)
			applyExtra(self, x, y, z, block, extra)
		end,
	}, seconds)
end

-- A new server core on `env`.
function StructureServer.new(env: Env): Server
	local self = {
		env = env,
		queue = Placement.newQueue(),
		saved = {},
		savedOrder = {},
		savedBytes = 0,
		uploads = {},
	}
	return (setmetatable(self, ServerMethods) :: any) :: Server
end

return StructureServer
