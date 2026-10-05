--!strict
--[[
	Mekanism's pipes on the client: what the terrain cannot draw by itself.

	The terrain draws every transmitter's core and every fluid tank's frame (their BlockList
	`shape`). This module draws, within RADIUS blocks of the camera, what depends on neighbours and
	on the server's state (the boxes come from Rendering/TransmitterModel, pure and tested):

	  arms     towards each side a transmitter connects (Transmitters.connections: the neighbours'
	           blocks, both sides' modes, transporters' colours), collars between transmitters,
	           connector plates on acceptors, PUSH / PULL bands, a coloured transporter's tint;
	           Universal Cables' thinner arms reach the energy blocks around them;
	  water    in Mechanical Pipes (their network's fill) and in Fluid Tanks (amount / capacity);
	  items    moving through Logistical Transporters, small models of the item along their path.

	State, as the server sends it (Shared/Net/Protocol):
	  Transmitters  per position: packed side modes, colour, pipe fill. A record replaces what was
	                known; positions without one are in the default state (all NORMAL, no colour,
	                empty). Records come with a chunk's edit list and when something changes (to
	                every player near), so they are kept for chunks whose edit list is known or
	                asked for, or whose data is loaded, and forgotten when neither is (they come
	                again with the edit list). Any change of a position's block resets its state,
	                as the server starts a new transmitter in the default state; when this
	                player's own (predicted) break took it, it is kept UNDO_WINDOW seconds, and
	                comes back if the server refuses the break (it answers with an edit back to
	                the same block and sends no record).
	  Tanks         per position: fluid and amount (mB), the same way.
	  Machines      per position: a Mekanism machine's energy, capacity, the network's input and
	                output, its rate and whether it works (Protocol MachineRecord), the same way;
	                no record: empty and idle (WAILA reads them: `machine`).
	  Transport     items entering or re-routed in the transporters (an id, the item, where it is,
	                its progress, speed, the server time of that and its path) and leaving them.
	                Items are moved here every frame from workspace:GetServerTimeNow(), 20 ticks a
	                second (TransmitterModel.position); nothing is sent per block. An item that
	                arrived goes after ARRIVAL_GRACE seconds if no Remove came; one removed as
	                arrived first finishes its way (at most ARRIVED_WAIT seconds); dropped or gone
	                ones go at once. The way an item came into its first block is not sent: it is
                taken from its previous route (a re-route, a new speed) or, for an item just
                pulled, from the transporter's one PULL side on an inventory
                (TransmitterModel.entryOf, pullEntry); else it comes in straight. Items are not
                drawn over chunks that are not loaded. The server
	                only tells players near them, so items that stayed out of range for
	                FORGET_AFTER seconds are forgotten (moving ones end with their way anyway).

	Which positions hold transmitters and tanks: they only come from edits (never from generation),
	so a chunk's are found in its edit list when its data is loaded (World/ClientWorld
	onChunkLoaded, knownEdits) and followed through its block changes (onBlockChanged). Positions
	are only decorated while their chunk is shown (`isShown`, from the streamer), so arms never
	float over the coarse terrain that stands in for a chunk still being built.

	Performance: parts come from pools (one template per look: kind and colour), so nothing is
	created per frame. A transmitter's parts are rebuilt only when it, a neighbour or its state
	changed (or it comes into range), at most REBUILDS_PER_FRAME a frame, and only when what they
	show changed; a rebuild keeps the cell's parts of the same look (resized and moved, never
	re-parented: a pipe's water level changes several times a second). At most MAX_PARTS parts
	are used (beyond that, transmitters further in the queue
	keep their bare core until parts free up) and MAX_ITEMS item models (more items in range move
	on unseen). Item models are moved together with one BulkMoveTo per frame, after the camera.

	Read-only queries for WAILA (Ui/Waila) and aiming (Interaction/BlockInteraction): `state`,
	`tank`, `machine`, `connections`, `itemsIn`, `network` (the pipes, transporters or cables
	connected to a position, as the client sees them) and `stats`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local ChunkLayout = require(Shared.World.ChunkLayout)
local Coords = require(Shared.World.Coords)
local Machines = require(Shared.Machines)
local Protocol = require(Shared.Net.Protocol)
local Transmitters = require(Shared.Transmitters)

local ClientNet = require(script.Parent.Parent.Net.ClientNet)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local ItemModels = require(script.Parent.ItemModels)
local TransmitterModel = require(script.Parent.TransmitterModel)

local BLOCK = Config.BlockSize
local PIXEL = BLOCK / 16
local SIZE = Config.ChunkSize
local HEIGHT = Config.WorldHeight
local TICK_RATE = Transmitters.TICK_RATE

--[[ Tunables ]]

-- Blocks from the camera within which arms, water and items are drawn.
local RADIUS = 64
-- Seconds between checks of what came into or went out of range.
local REFRESH_INTERVAL = 0.25
-- Most parts the arms, bands and water use at once, and spare parts kept for reuse.
local MAX_PARTS = 4000
local MAX_SPARE_PARTS = 1000
-- Transmitters and tanks redrawn per frame at most.
local REBUILDS_PER_FRAME = 64
-- Item models drawn at once, their size (blocks) and how fast they turn (radians per tick, a
-- dropped item's: Minecraft's age / 20; on the client's clock, so a new route sent for an item
-- does not turn it back).
local MAX_ITEMS = 256
local ITEM_SIZE = 0.35
local ITEM_SPIN = 1 / 20
-- Seconds an item stays on the last face once its way is done, without a Remove; the longest an
-- item removed as arrived may take to finish its way; and how long one out of range is kept.
local ARRIVAL_GRACE = 0.5
local ARRIVED_WAIT = 1
local FORGET_AFTER = 60
-- Most transmitters a `network` query walks.
local MAX_NETWORK = 4096
-- Seconds the state of a transmitter or tank this player broke is kept, in case the server
-- refuses the break (it answers within a round trip, or a second for a delayed break).
local UNDO_WINDOW = 5
-- After the camera, so items follow this frame's view.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

-- How each kind of box (TransmitterModel.BoxKind) looks: material and transparency (the colour is
-- the box's).
local LOOKS: { [string]: { material: Enum.Material, transparency: number } } = {
	glass = { material = Enum.Material.Glass, transparency = 0.5 },
	frame = { material = Enum.Material.Metal, transparency = 0 },
	band = { material = Enum.Material.Neon, transparency = 0 },
	tint = { material = Enum.Material.SmoothPlastic, transparency = 0.45 },
	water = { material = Enum.Material.Glass, transparency = 0.3 },
	cable = { material = Enum.Material.SmoothPlastic, transparency = 0 },
}

-- A transmitter or tank position in a loaded chunk.
type Cell = {
	x: number,
	y: number,
	z: number,
	block: number,
	chunk: number,
	-- In range and shown: decorated.
	active: boolean,
	parts: { Part },
	-- What the parts show (nil: nothing drawn yet).
	signature: string?,
}

type TransmitterState = { modes: number, colour: number, fluid: number }
type TankState = { fluid: number, amount: number }
type MachineState = Protocol.MachineRecord

-- The state a predicted break took away (see UNDO_WINDOW).
type Undone = {
	block: number,
	at: number,
	transmitter: TransmitterState?,
	tank: TankState?,
	machine: MachineState?,
}

-- An item model and its parts, with each part's offset from the model's pivot.
type ItemModel = { item: number, model: Model, parts: { BasePart }, offsets: { CFrame } }

-- An item in transit.
type Transit = {
	id: number,
	item: number,
	count: number,
	route: TransmitterModel.Route,
	startTime: number,
	-- os.clock() when it was last in range, at the end of its way, and the deadline of a Remove
	-- as arrived.
	seenAt: number,
	arrivedAt: number?,
	removeBy: number?,
	spin: number,
	view: ItemModel?,
}

local TransmitterRenderer = {}

local world: ClientWorld.ClientWorld? = nil
local isShown: (cx: number, cz: number) -> boolean = function(_cx: number, _cz: number): boolean
	return true
end

-- Positions (Coords.posKey) of transmitters and tanks in loaded chunks, and per chunk key.
local cells: { [number]: Cell } = {}
local cellsByChunk: { [number]: { [number]: boolean } } = {}
-- Replicated state per position, and the positions per chunk key.
local transmitterStates: { [number]: TransmitterState } = {}
local tankStates: { [number]: TankState } = {}
local machineStates: { [number]: MachineState } = {}
local statesByChunk: { [number]: { [number]: boolean } } = {}
-- States taken by this player's own breaks, per position.
local undone: { [number]: Undone } = {}
-- Positions to redraw.
local dirty: { [number]: boolean } = {}
-- Positions that found no parts left (redrawn when parts free up).
local starved: { [number]: boolean } = {}
local partCount = 0
-- Part templates and spare parts per look ("kind r,g,b").
local templates: { [string]: Part } = {}
local spareParts: { [string]: { Part } } = {}
local spareCount = 0
local lookOf: { [Part]: string } = {}
-- Items in transit by id; item models drawn and spare ones per item; items per position (this
-- frame).
local transit: { [number]: Transit } = {}
local transitCount = 0
local drawnItems = 0
local spareModels: { [number]: { ItemModel } } = {}
local itemsAt: { [number]: number } = {}
local stacksAt: { [number]: number } = {}
-- `network` answers, cleared on every change.
local networks: { [number]: { size: number, capacity: number, complete: boolean } } = {}
local folder: Folder? = nil

local posKey = Coords.posKey

local function getBlock(x: number, y: number, z: number): number?
	local w = world
	return if w then w:getBlock(x, y, z) else nil
end

local function getState(x: number, y: number, z: number): (number, number)
	local state = transmitterStates[posKey(x, y, z)]
	if state then
		return state.modes, state.colour
	end
	return 0, 0
end

local function isSpecial(block: number): boolean
	return Transmitters.isTransmitter(block) or Transmitters.isTank(block)
end

--[[ Parts ]]

local function colourKey(c: { number }): string
	return `{c[1]},{c[2]},{c[3]}`
end

local function lookKey(kind: string, colour: { number }): string
	return `{kind} {colourKey(colour)}`
end

local function acquirePart(kind: string, colour: { number }): Part
	local key = lookKey(kind, colour)
	local spare = spareParts[key]
	local reused = if spare then table.remove(spare) else nil
	local part: Part
	if reused then
		part = reused
		spareCount -= 1
	else
		local template: Part? = templates[key]
		if template == nil then
			local look = LOOKS[kind] or LOOKS.frame
			local made = Instance.new("Part")
			made.Name = `Transmitter{kind}`
			made.Anchored = true
			made.CanCollide = false
			made.CanQuery = false
			made.CanTouch = false
			made.CastShadow = false
			made.Locked = true
			made.EnableFluidForces = false
			made.TopSurface = Enum.SurfaceType.Smooth
			made.BottomSurface = Enum.SurfaceType.Smooth
			made.Material = look.material
			made.Transparency = look.transparency
			made.Color = Color3.fromRGB(colour[1], colour[2], colour[3])
			templates[key] = made
			template = made
		end
		part = (template :: Part):Clone()
		lookOf[part] = key
	end
	partCount += 1
	return part
end

local function releasePart(part: Part)
	partCount -= 1
	part.Parent = nil
	local key = lookOf[part]
	if key == nil or spareCount >= MAX_SPARE_PARTS then
		lookOf[part] = nil
		part:Destroy()
		return
	end
	local spare = spareParts[key]
	if spare == nil then
		spare = {}
		spareParts[key] = spare
	end
	table.insert(spare, part)
	spareCount += 1
end

-- Parts were freed: positions that went without may have them now.
local function wakeStarved()
	for key in starved do
		dirty[key] = true
	end
	table.clear(starved)
end

-- Takes a cell's decoration down (it is drawn again when it becomes dirty and active).
local function undecorate(cell: Cell)
	for _, part in cell.parts do
		releasePart(part)
	end
	if #cell.parts > 0 then
		table.clear(cell.parts)
		wakeStarved()
	end
	cell.signature = nil
end

--[[ Positions ]]

local function markDirty(key: number)
	if cells[key] then
		dirty[key] = true
	end
end

-- Marks (x, y, z) and its six neighbours for redrawing.
local function markAround(x: number, y: number, z: number)
	markDirty(posKey(x, y, z))
	for side = 0, 5 do
		local dx, dy, dz = Transmitters.offset(side)
		local ny = y + dy
		if ny >= 0 and ny < HEIGHT then
			markDirty(posKey(x + dx, ny, z + dz))
		end
	end
end

-- The camera's position in blocks.
local function cameraBlocks(): Vector3
	local camera = workspace.CurrentCamera
	return if camera then camera.CFrame.Position / BLOCK else Vector3.zero
end

-- Is the cell in range of the camera (`eye`, blocks) and its chunk shown?
local function inRange(cell: Cell, eye: Vector3): boolean
	local dx, dy, dz = cell.x + 0.5 - eye.X, cell.y + 0.5 - eye.Y, cell.z + 0.5 - eye.Z
	return dx * dx + dy * dy + dz * dz <= RADIUS * RADIUS and isShown(cell.x // SIZE, cell.z // SIZE)
end

local function addCell(x: number, y: number, z: number, block: number)
	local key = posKey(x, y, z)
	local cell = cells[key]
	if cell then
		if cell.block ~= block then
			cell.block = block
			undecorate(cell)
		end
	else
		local chunk = Coords.chunkKey(x // SIZE, z // SIZE)
		local created: Cell = {
			x = x,
			y = y,
			z = z,
			block = block,
			chunk = chunk,
			active = false,
			parts = {},
			signature = nil,
		}
		-- (Drawn at once when it is in range, rather than at the next refresh.)
		created.active = inRange(created, cameraBlocks())
		cells[key] = created
		local list = cellsByChunk[chunk]
		if list == nil then
			list = {}
			cellsByChunk[chunk] = list
		end
		list[key] = true
	end
	markAround(x, y, z)
end

local function removeCell(key: number)
	local cell = cells[key]
	if cell == nil then
		return
	end
	undecorate(cell)
	cells[key] = nil
	dirty[key] = nil
	starved[key] = nil
	local list = cellsByChunk[cell.chunk]
	if list then
		list[key] = nil
		if next(list) == nil then
			cellsByChunk[cell.chunk] = nil
		end
	end
	markAround(cell.x, cell.y, cell.z)
end

local function dropStates(key: number)
	transmitterStates[key] = nil
	tankStates[key] = nil
	machineStates[key] = nil
end

-- Forgets the states of chunk `chunk` (a chunk key): its positions look default until records
-- come again (with its edit list).
local function dropChunkStates(chunk: number)
	local list = statesByChunk[chunk]
	if list then
		for key in list do
			dropStates(key)
			undone[key] = nil
			markDirty(key)
		end
		statesByChunk[chunk] = nil
	end
	table.clear(networks)
end

-- Indexes a state's position by chunk (to forget it with the chunk's edit list).
local function indexState(key: number, chunk: number)
	local list = statesByChunk[chunk]
	if list == nil then
		list = {}
		statesByChunk[chunk] = list
	end
	list[key] = true
end

-- Every known transmitter and tank of the chunk and of its four neighbours is redrawn.
local function markChunkAndNeighbours(cx: number, cz: number)
	for _, offset in { { 0, 0 }, { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } } do
		local list = cellsByChunk[Coords.chunkKey(cx + offset[1], cz + offset[2])]
		if list then
			for key in list do
				dirty[key] = true
			end
		end
	end
end

--[[ World events ]]

local function onBlockChanged(x: number, y: number, z: number, block: number, previous: number, predicted: boolean)
	local key = posKey(x, y, z)
	local now = os.clock()
	local stash = undone[key]
	undone[key] = nil
	-- A new block is a new transmitter or tank on the server, in the default state (no record
	-- comes for it). This player's own break may still be refused: keep what it took a while.
	local oldTransmitter, oldTank, oldMachine = transmitterStates[key], tankStates[key], machineStates[key]
	if
		predicted
		and (isSpecial(previous) or Machines.isMachine(previous))
		and (oldTransmitter or oldTank or oldMachine)
	then
		undone[key] = { block = previous, at = now, transmitter = oldTransmitter, tank = oldTank, machine = oldMachine }
	end
	dropStates(key)
	if not predicted and stash and stash.block == block and now - stash.at <= UNDO_WINDOW then
		-- The server put back what this player's break took: so is its state.
		if stash.transmitter then
			transmitterStates[key] = stash.transmitter
		end
		if stash.tank then
			tankStates[key] = stash.tank
		end
		if stash.machine then
			machineStates[key] = stash.machine
		end
		indexState(key, Coords.chunkKey(x // SIZE, z // SIZE))
		markAround(x, y, z)
	end
	if isSpecial(block) then
		addCell(x, y, z, block)
	elseif cells[key] then
		removeCell(key)
	else
		-- A chest, furnace or energy block placed or broken next to a transmitter changes its arms.
		markAround(x, y, z)
	end
	if Transmitters.isTransmitter(block) or Transmitters.isTransmitter(previous) then
		table.clear(networks)
	end
end

local function onChunkLoaded(cx: number, cz: number, loaded: boolean)
	local chunk = Coords.chunkKey(cx, cz)
	local w = world
	local found: { [number]: boolean } = {}
	if loaded and w then
		local list = w:knownEdits(cx, cz)
		if list then
			for index, block in list do
				if isSpecial(block) then
					local lx, y, lz = ChunkLayout.fromLocalIndex(index)
					local x, z = cx * SIZE + lx, cz * SIZE + lz
					-- (The chunk's data has every edit; check anyway.)
					if w:getBlock(x, y, z) == block then
						addCell(x, y, z, block)
						found[posKey(x, y, z)] = true
					end
				end
			end
		end
	end
	local list = cellsByChunk[chunk]
	if list then
		for key in table.clone(list) do
			if not found[key] then
				removeCell(key)
			end
		end
	end
	if loaded and w then
		-- (States of positions that are no transmitter, tank or machine in the chunk's data are
		-- stale.)
		local states = statesByChunk[chunk]
		if states then
			for key in states do
				local x, y, z = Coords.decodePosKey(key)
				local block = w:getBlock(x, y, z)
				if block == nil or not Transmitters.isTransmitter(block) then
					transmitterStates[key] = nil
				end
				if block == nil or not Transmitters.isTank(block) then
					tankStates[key] = nil
				end
				if block == nil or not Machines.isMachine(block) then
					machineStates[key] = nil
				end
			end
		end
	elseif w and w.edits[chunk] == nil then
		-- Neither its data nor its edit list: its records are no longer kept up to date.
		dropChunkStates(chunk)
	end
	-- Arms across the chunk's border appear or go.
	markChunkAndNeighbours(cx, cz)
	table.clear(networks)
end

local function onEditList(cx: number, cz: number, known: boolean)
	local chunk = Coords.chunkKey(cx, cz)
	local w = world
	-- (While its data is loaded, the server's change records keep the states right: the streamer
	-- forgets the edit lists of chunks it is about to drop, and may keep them after all.)
	if not known and w and w.chunks[chunk] == nil then
		-- Records come again with the edit list; until then the chunk's positions look default.
		dropChunkStates(chunk)
	end
end

-- Is the state of a position in this chunk wanted (its edit list is known or asked for, or its
-- data is loaded)?
local function wanted(x: number, z: number): boolean
	local w = world
	if w == nil then
		return false
	end
	local chunk = Coords.chunkKey(x // SIZE, z // SIZE)
	return w.edits[chunk] ~= nil or w.chunks[chunk] ~= nil
end

local function onTransmitters(records: { Protocol.TransmitterRecord })
	for _, record in records do
		local x, y, z = record.x, record.y, record.z
		if wanted(x, z) then
			local key = posKey(x, y, z)
			local old = transmitterStates[key]
			-- Only modes and colours change what is connected (a pipe's fill changes often).
			local linksChanged = (if old then old.modes else 0) ~= record.modes
				or (if old then old.colour else 0) ~= record.colour
			if record.modes == 0 and record.colour == 0 and record.fluid == 0 then
				transmitterStates[key] = nil
			else
				transmitterStates[key] = { modes = record.modes, colour = record.colour, fluid = record.fluid }
				indexState(key, Coords.chunkKey(x // SIZE, z // SIZE))
			end
			if linksChanged then
				-- (The neighbours' arms depend on this one's modes and colour.)
				markAround(x, y, z)
				table.clear(networks)
			else
				markDirty(key)
			end
		end
	end
end

local function onTanks(records: { Protocol.TankRecord })
	for _, record in records do
		local x, y, z = record.x, record.y, record.z
		if wanted(x, z) then
			local key = posKey(x, y, z)
			if record.fluid == 0 and record.amount == 0 then
				tankStates[key] = nil
			else
				tankStates[key] = { fluid = record.fluid, amount = record.amount }
				indexState(key, Coords.chunkKey(x // SIZE, z // SIZE))
			end
			markDirty(key)
		end
	end
end

local function onMachines(records: { Protocol.MachineRecord })
	for _, record in records do
		local x, y, z = record.x, record.y, record.z
		if wanted(x, z) then
			local key = posKey(x, y, z)
			machineStates[key] = record
			indexState(key, Coords.chunkKey(x // SIZE, z // SIZE))
		end
	end
end

--[[ Drawing transmitters and tanks ]]

-- The boxes of a cell and a signature of what they show.
local function design(cell: Cell): ({ TransmitterModel.Box }, string)
	local key = posKey(cell.x, cell.y, cell.z)
	local block = cell.block
	if Transmitters.isTank(block) then
		local state = tankStates[key]
		local fluid, amount = if state then state.fluid else 0, if state then state.amount else 0
		return TransmitterModel.tankBoxes(block, fluid, amount), `t{block} {fluid} {amount}`
	end
	local state = transmitterStates[key]
	local modes = if state then state.modes else 0
	local colour = if state then state.colour else 0
	local fluid = if state then state.fluid else 0
	local transmitters, acceptors =
		Transmitters.connections(block, modes, colour, cell.x, cell.y, cell.z, getBlock, getState)
	local boxes = TransmitterModel.transmitterBoxes(block, modes, colour, fluid, transmitters, acceptors)
	return boxes, `p{block} {modes} {colour} {fluid} {transmitters} {acceptors}`
end

local function redraw(key: number)
	local cell = cells[key]
	if cell == nil or not cell.active then
		return
	end
	local boxes, signature = design(cell)
	if signature == cell.signature then
		return
	end
	local old = cell.parts
	if partCount - #old + #boxes > MAX_PARTS then
		undecorate(cell)
		starved[key] = true
		return
	end
	-- The cell's parts of the same look are reused (resized and moved; no re-parenting).
	local reusable: { [string]: { Part } } = {}
	for _, part in old do
		local look = lookOf[part]
		if look then
			local list = reusable[look]
			if list == nil then
				list = {}
				reusable[look] = list
			end
			table.insert(list, part)
		else
			releasePart(part)
		end
	end
	local container = folder
	local cx, cy, cz = (cell.x + 0.5) * BLOCK, (cell.y + 0.5) * BLOCK, (cell.z + 0.5) * BLOCK
	local parts: { Part } = {}
	for _, box in boxes do
		local list = reusable[lookKey(box.kind, box.colour)]
		local part = (if list then table.remove(list) else nil) or acquirePart(box.kind, box.colour)
		part.Size = Vector3.new(box.size[1], box.size[2], box.size[3]) * PIXEL
		part.CFrame = CFrame.new(cx + box.offset[1] * PIXEL, cy + box.offset[2] * PIXEL, cz + box.offset[3] * PIXEL)
		if part.Parent ~= container then
			part.Parent = container
		end
		table.insert(parts, part)
	end
	local freed = false
	for _, list in reusable do
		for _, part in list do
			releasePart(part)
			freed = true
		end
	end
	cell.parts = parts
	cell.signature = signature
	if freed then
		wakeStarved()
	end
end

-- Decorates what came into range (and is shown), takes down what left it.
local function refresh()
	local eye = cameraBlocks()
	local limit = RADIUS * RADIUS
	local shownChunks: { [number]: boolean } = {}
	for key, cell in cells do
		local dx, dy, dz = cell.x + 0.5 - eye.X, cell.y + 0.5 - eye.Y, cell.z + 0.5 - eye.Z
		local near = dx * dx + dy * dy + dz * dz <= limit
		if near then
			local shown = shownChunks[cell.chunk]
			if shown == nil then
				shown = isShown(cell.x // SIZE, cell.z // SIZE)
				shownChunks[cell.chunk] = shown
			end
			near = shown
		end
		if near and not cell.active then
			cell.active = true
			dirty[key] = true
		elseif not near and cell.active then
			cell.active = false
			undecorate(cell)
			starved[key] = nil
		end
	end
end

local batch: { number } = {}
local function redrawSome()
	-- (Taken out first: redrawing may mark more positions, which must not happen mid-traversal.)
	table.clear(batch)
	for key in dirty do
		table.insert(batch, key)
		if #batch >= REBUILDS_PER_FRAME then
			break
		end
	end
	for _, key in batch do
		dirty[key] = nil
		redraw(key)
	end
end

--[[ Items in transit ]]

local function takeModel(item: number): ItemModel
	local spare = spareModels[item]
	local view = if spare then table.remove(spare) else nil
	if view then
		return view
	end
	local model = ItemModels.build(item, ITEM_SIZE * BLOCK)
	model.Name = `Transit{item}`
	local parts, offsets = {}, {}
	-- Built around CFrame.identity, so each part's CFrame is its offset from the pivot.
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			table.insert(parts, part)
			table.insert(offsets, part.CFrame)
		end
	end
	return { item = item, model = model, parts = parts, offsets = offsets }
end

local function giveBackModel(view: ItemModel)
	view.model.Parent = nil
	local spare = spareModels[view.item]
	if spare == nil then
		spare = {}
		spareModels[view.item] = spare
	end
	if #spare < 8 then
		table.insert(spare, view)
	else
		view.model:Destroy()
	end
end

local function hide(entry: Transit)
	local view = entry.view
	if view then
		entry.view = nil
		drawnItems -= 1
		giveBackModel(view)
	end
end

local function removeTransit(id: number)
	local entry = transit[id]
	if entry then
		hide(entry)
		transit[id] = nil
		transitCount -= 1
	end
end

local function speedAt(x: number, y: number, z: number): number?
	local block = getBlock(x, y, z)
	return if block then Transmitters.speed(block) else nil
end

-- The sides of the transmitter at (x, y, z) connected to transmitters and to acceptors.
local function connectionsAt(x: number, y: number, z: number): (number, number)
	local block = getBlock(x, y, z)
	if block == nil or not Transmitters.isTransmitter(block) then
		return 0, 0
	end
	local modes, colour = getState(x, y, z)
	return Transmitters.connections(block, modes, colour, x, y, z, getBlock, getState)
end

local function onTransport(ops: { Protocol.TransportOp })
	local clock = os.clock()
	for _, op in ops do
		if op.op == "add" then
			local entry = transit[op.id]
			-- The way it came into its block: from the way it was going (a re-route, a new
			-- speed), else (just pulled) out of the inventory on the transporter's PULL side.
			local way: number? = nil
			if entry then
				way = TransmitterModel.entryOf(entry.route, op.x, op.y, op.z)
			elseif op.progress < 50 then
				local modes = getState(op.x, op.y, op.z)
				local _, acceptors = connectionsAt(op.x, op.y, op.z)
				way = TransmitterModel.pullEntry(modes, acceptors)
			end
			local route = TransmitterModel.route(op.x, op.y, op.z, op.progress, op.speed, op.path, speedAt, way)
			if entry then
				-- Re-routed: the new way replaces the old; the model stays if it is the same item.
				if entry.item ~= op.item then
					hide(entry)
				end
				entry.item, entry.count = op.item, op.count
				entry.route, entry.startTime = route, op.startTime
				entry.seenAt, entry.arrivedAt, entry.removeBy = clock, nil, nil
			else
				transit[op.id] = {
					id = op.id,
					item = op.item,
					count = op.count,
					route = route,
					startTime = op.startTime,
					seenAt = clock,
					arrivedAt = nil,
					removeBy = nil,
					spin = (op.id % 64) / 64 * math.pi * 2,
					view = nil,
				}
				transitCount += 1
			end
		else
			local entry = transit[op.id]
			if entry then
				if op.reason == Protocol.TransportRemoveReason.Arrived and entry.arrivedAt == nil then
					-- (Let it reach the end of its way: the server may be a moment ahead.)
					entry.removeBy = clock + ARRIVED_WAIT
				else
					removeTransit(op.id)
				end
			end
		end
	end
end

local moveParts: { BasePart } = {}
local moveFrames: { CFrame } = {}

local function moveItems()
	table.clear(itemsAt)
	table.clear(stacksAt)
	table.clear(moveParts)
	table.clear(moveFrames)
	if transitCount == 0 then
		return
	end
	local w = world
	local now = workspace:GetServerTimeNow()
	local clock = os.clock()
	local eye = cameraBlocks()
	local limit = RADIUS * RADIUS
	for id, entry in transit do
		local ticks = (now - entry.startTime) * TICK_RATE
		local px, py, pz, k, arrived = TransmitterModel.position(entry.route, ticks)
		if arrived and entry.arrivedAt == nil then
			entry.arrivedAt = clock
		end
		local x, y, z = TransmitterModel.cell(entry.route, k)
		local arrivedAt, removeBy = entry.arrivedAt, entry.removeBy
		if
			(arrivedAt and clock - arrivedAt >= (if removeBy then 0 else ARRIVAL_GRACE))
			or (removeBy and clock >= removeBy)
			or clock - entry.seenAt > FORGET_AFTER
		then
			removeTransit(id)
			continue
		end
		local key = posKey(x, y, z)
		itemsAt[key] = (itemsAt[key] or 0) + entry.count
		stacksAt[key] = (stacksAt[key] or 0) + 1
		local dx, dy, dz = px - eye.X, py - eye.Y, pz - eye.Z
		local near = dx * dx + dy * dy + dz * dz <= limit
		if near then
			entry.seenAt = clock
			-- (Not over a chunk that is not loaded: it may still be coarse terrain there.)
			near = w ~= nil and w:isLoaded(x, z)
		end
		local view = entry.view
		if near and view == nil and drawnItems < MAX_ITEMS then
			local taken = takeModel(entry.item)
			view = taken
			entry.view = taken
			drawnItems += 1
			taken.model.Parent = folder
		elseif not near and view then
			hide(entry)
			view = nil
		end
		if view then
			local pivot = CFrame.new(px * BLOCK, py * BLOCK, pz * BLOCK)
				* CFrame.Angles(0, entry.spin + clock * TICK_RATE * ITEM_SPIN, 0)
			for i, part in view.parts do
				table.insert(moveParts, part)
				table.insert(moveFrames, pivot * view.offsets[i])
			end
		end
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

--[[ Queries ]]

-- The replicated state of a transmitter: packed side modes, colour (0..16) and fill (0..255).
function TransmitterRenderer.state(x: number, y: number, z: number): (number, number, number)
	local state = transmitterStates[posKey(x, y, z)]
	if state then
		return state.modes, state.colour, state.fluid
	end
	return 0, 0, 0
end

--[[
	The replicated state of a Mekanism machine (its last Machines record), nil when none came: an
	empty, idle machine at its block's capacity.
]]
function TransmitterRenderer.machine(x: number, y: number, z: number): Protocol.MachineRecord?
	return machineStates[posKey(x, y, z)]
end

-- The replicated contents of a fluid tank: fluid (0 none, 1 water) and amount (mB).
function TransmitterRenderer.tank(x: number, y: number, z: number): (number, number)
	local state = tankStates[posKey(x, y, z)]
	if state then
		return state.fluid, state.amount
	end
	return 0, 0
end

--[[
	The sides of the transmitter at (x, y, z) connected to transmitters and to acceptors (bit
	masks, Transmitters.connections), from the client's blocks and states; 0, 0 for anything else.
]]
function TransmitterRenderer.connections(x: number, y: number, z: number): (number, number)
	return connectionsAt(x, y, z)
end

-- Items (and stacks) in transit inside the transporter at (x, y, z) this frame.
function TransmitterRenderer.itemsIn(x: number, y: number, z: number): (number, number)
	local key = posKey(x, y, z)
	return itemsAt[key] or 0, stacksAt[key] or 0
end

--[[
	The transmitters connected to the one at (x, y, z) (itself included), as the client sees them:
	how many, what they add up to (Mechanical Pipes: a network's buffer, mB; Universal Cables: their
	throughput, J per tick; Transmitters.capacity) and whether the walk saw them all (it stops at
	MAX_NETWORK). 0, 0, true for anything else. The walk follows transmitter links only: the
	server's energy network also joins cables through the machines between them (EnergyNet), so
	its throughput can be more than this.
]]
function TransmitterRenderer.network(x: number, y: number, z: number): (number, number, boolean)
	local start = posKey(x, y, z)
	local cached = networks[start]
	if cached then
		return cached.size, cached.capacity, cached.complete
	end
	local block = getBlock(x, y, z)
	if block == nil or not Transmitters.isTransmitter(block) then
		return 0, 0, true
	end
	local seen: { [number]: boolean } = { [start] = true }
	local queue = { x, y, z }
	local head, size, capacity, complete = 1, 0, 0, true
	while head <= #queue do
		local cx, cy, cz = queue[head], queue[head + 1], queue[head + 2]
		head += 3
		local here = getBlock(cx, cy, cz)
		if here then
			size += 1
			capacity += Transmitters.capacity(here)
			if size >= MAX_NETWORK then
				complete = false
				break
			end
			local modes, colour = getState(cx, cy, cz)
			local linked = Transmitters.connections(here, modes, colour, cx, cy, cz, getBlock, getState)
			for side = 0, 5 do
				if bit32.band(linked, bit32.lshift(1, side)) ~= 0 then
					local dx, dy, dz = Transmitters.offset(side)
					local key = posKey(cx + dx, cy + dy, cz + dz)
					if not seen[key] then
						seen[key] = true
						table.insert(queue, cx + dx)
						table.insert(queue, cy + dy)
						table.insert(queue, cz + dz)
					end
				end
			end
		end
	end
	-- (Every member of a finished walk has the same answer.)
	local answer = { size = size, capacity = capacity, complete = complete }
	if complete then
		for key in seen do
			networks[key] = answer
		end
	else
		networks[start] = answer
	end
	return size, capacity, complete
end

export type Stats = { cells: number, decorated: number, parts: number, items: number, drawnItems: number }

-- Counters for the debug overlay.
function TransmitterRenderer.stats(): Stats
	local count, decorated = 0, 0
	for _, cell in cells do
		count += 1
		if #cell.parts > 0 then
			decorated += 1
		end
	end
	return { cells = count, decorated = decorated, parts = partCount, items = transitCount, drawnItems = drawnItems }
end

--[[ Start ]]

local started = false

--[[
	Starts drawing. `world` gives the blocks; `shown(cx, cz)` (optional) tells whether the full
	detail chunk (cx, cz) is on screen (ChunkStreamer: its node is shown).
]]
function TransmitterRenderer.start(clientWorld: ClientWorld.ClientWorld, shown: ((cx: number, cz: number) -> boolean)?)
	assert(not started, "TransmitterRenderer.start was already called")
	started = true
	world = clientWorld
	if shown then
		isShown = shown
	end

	local container = Instance.new("Folder")
	container.Name = "IceVoxelTransmitters"
	container.Parent = workspace
	folder = container

	clientWorld:onBlockChanged(onBlockChanged)
	clientWorld:onChunkLoaded(onChunkLoaded)
	clientWorld:onEditList(onEditList)
	-- Chunks loaded before this started.
	for key in clientWorld.chunks do
		local cx, cz = Coords.decodeChunkKey(key)
		onChunkLoaded(cx, cz, true)
	end

	ClientNet.on(Protocol.ServerMessage.Transmitters, function(payload)
		local records = Protocol.decodeTransmitters(payload)
		if records then
			onTransmitters(records)
		end
	end)
	ClientNet.on(Protocol.ServerMessage.Tanks, function(payload)
		local records = Protocol.decodeTanks(payload)
		if records then
			onTanks(records)
		end
	end)
	ClientNet.on(Protocol.ServerMessage.Machines, function(payload)
		local records = Protocol.decodeMachines(payload)
		if records then
			onMachines(records)
		end
	end)
	ClientNet.on(Protocol.ServerMessage.Transport, function(payload)
		local ops = Protocol.decodeTransport(payload)
		if ops then
			onTransport(ops)
		end
	end)

	local sinceRefresh = math.huge
	RunService:BindToRenderStep("IceVoxelTransmitters", RENDER_PRIORITY, function(dt: number)
		sinceRefresh += dt
		if sinceRefresh >= REFRESH_INTERVAL then
			sinceRefresh = 0
			refresh()
		end
		if next(dirty) ~= nil then
			redrawSome()
		end
		moveItems()
	end)
end

return TransmitterRenderer
