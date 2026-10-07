--!strict
--[[
	Network protocol.

	All traffic goes through one RemoteEvent (see Net/Remotes) as `(messageType, payload: buffer)`.
	Using one remote keeps server -> client messages strictly ordered, which the client relies on:
	a chunk's edit list and later live edits for that chunk must arrive in the order they were sent.

	Terrain itself is never sent: everyone generates it from the seed. Only edits travel.

	Client -> server
	  RequestChunks  u16 count, count x (i32 cx, i32 cz)
	  Edit           u8 action, i32 x, u16 y, i32 z, u16 block, u32 seq (the inventory action
	                 number of a placement, see Inventory below; 0 for breaking)
	  Teleport       i32 x, i32 z
	  SaveWaypoints  waypoint list (below)
	  Fall           f32 fall distance (blocks) of a landing, for fall damage
	  Mine           u8 started (1 started mining the block, 0 stopped), i32 x, u16 y, i32 z
	  Inventory      u32 seq, u8 kind, then by kind (Inventory/Types Action):
	                   1 click     u8 window, i16 slot, u8 clickType, u8 button
	                   2 drag      u8 window, u8 mode, u8 count, count x u16 slot
	                   3 select    u8 slot (1..9)
	                   4 drop      u8 all (0 / 1)
	                   5 creative  u8 window, i16 slot (-1 = cursor), u16 item, u8 count,
	                               u16 damage, item data (below): the whole stack, as
	                               Minecraft's creative slot packet
	                   6 close     u8 window
	  Use            i32 x, u16 y, i32 z: right click on a usable block (opens a chest)
	  UseItem        i32 x, u16 y, i32 z, u8 side (0..5), u8 flags (bit 0: sneaking): a right click
	                 on block (x, y, z) with an item that is no block (the Configurator, buckets).
	                 Sides are Shared/Transmitters' (0 Down, 1 Up, 2 North, 3 South, 4 West,
	                 5 East). For the Configurator `side` is the transmitter's side picked from the
	                 hit point; for a bucket the clicked face (the fluid goes into (x, y, z) when it
	                 is replaceable, else into (x, y, z) + offset(side)). An empty bucket aimed at a
	                 fluid's source (Shared/Fluids.isSource) sends the source's cell.
	  StructureBlock i32 x, u16 y, i32 z, u8 op, then by op (Minecraft's
	                 ServerboundSetStructureBlockPacket and its update types):
	                   1 open     nothing: the player right clicked the block; the server answers
	                              with a StructureBlocks message with the open flag (or a Notice)
	                   2 update   structure settings (below): the screen's fields (UPDATE_DATA;
	                              the mode also swaps the block, Blocks.structureBlock)
	                   3 save     settings: save the region (SAVE_AREA)
	                   4 load     settings, u32 transfer: place the structure (LOAD_AREA) named in
	                              the settings (transfer 0) or the text this player uploaded as
	                              StructureData `transfer` (the screen's "Paste data" box)
	                   5 detect   settings: fit the region between the CORNER blocks of the same
	                              name (SCAN_AREA)
	  Jigsaw         i32 x, u16 y, i32 z, u8 op, then by op (Minecraft's
	                 ServerboundSetJigsawBlockPacket and ServerboundJigsawGeneratePacket):
	                   1 open      nothing (answered like StructureBlock's)
	                   2 update    jigsaw settings (below)
	                   3 generate  jigsaw settings, u8 levels (0..7), u8 keepJigsaws (0 / 1): apply
	                               the settings, then assemble from this jigsaw's pool here
	  StructureData  a piece of structure text (below): text pasted into a LOAD screen, uploaded
	                 before the load that names its transfer
	  SetGameMode    u8 mode (Minecraft's GameType id: 0 survival, 1 creative, 2 adventure,
	                 3 spectator): switch one's own game mode (the F3 + F4 switcher, F3 + N), with
	                 the /gamemode command's permission and answers
	  SpectatorTeleport f64 userId: a spectator teleports to that player (the spectator menu's
	                 "Teleport to Player"); a whole number, finite (Studio's test players are
	                 negative)
	  SaveSettings   player settings (below): the choices of the client's device profile, sent
	                 about Config.Settings.SaveDelay seconds after the last change and when the
	                 menu closes (the server keeps them and saves them on leave)
	  Exertion       u16 sprintCm, u16 waterCm, u8 jumps, u8 sprintJumps, u8 flags (bit 0:
	                 sprinting now): the movement that costs thirst since the last report
	                 (Shared/ToughAsNails/Exertion: centimetres sprinted on the ground and moved in
	                 water, jumps not sprinting and sprinting), about once a second; the server
	                 bounds it by the time since the last one
	  Drink          u8 action, then for 4 and 5: i32 x, u16 y, i32 z (a water source)
	                 (Shared/ToughAsNails/Drinks):
	                   1 start   began drinking the held bottle or canteen (holding use)
	                   2 finish  held it Drinks.USE_TICKS: drink it (the server checks the time
	                             since start, and that the same item is still in the same slot)
	                   3 cancel  let go early
	                   4 hand    a sip from the water source with an empty hand
	                   5 fill    fill the held Glass Bottle or canteen at the water source
	  Attack         u32 mob id: a left click on a mob (server Mobs/Mobs checks the reach from the
	                 eyes, the line of sight and the game mode, and hits with the held item)
	  Eat            u8 action: 1 start / 2 finish / 3 cancel holding a food (Shared/Items/Foods;
	                 the server checks the time held and the item, as for Drink)
	  UnlockSkill    u8 skill: unlock node `skill` of the skill tree (its place in
	                 Shared/Progression/Skills' list, 1-based); the server checks the Age, the
	                 prerequisites and the skill points (Progression.canUnlock) and answers with a
	                 Progress message, or a Notice saying why not
	  CreateWorld    the title screen's Create World screen (Shared/WorldSettings Request): u8 mode
	                 (GameType id: 0 survival, 1 creative, 2 adventure), u8 difficulty (0 peaceful
	                 .. 3 hard), u8 flags (bit 0 allow commands, bit 1 generate structures), then
	                 u16 length + text each: world name (at most MAX_WORLD_NAME bytes), world type
	                 id (MAX_WORLD_TYPE), options (WorldTypes.encodeOptions, MAX_WORLD_OPTIONS) and
	                 the seed as typed (MAX_WORLD_SEED). Other ids, flags, lengths or invalid UTF-8
	                 are malformed; the server checks the rest (operators only, once:
	                 Players/WorldMenu, WorldSettings.validate) and answers with CreateWorldResult
	  EnterWorld     nothing: the title screen's Join World (or a created world): the server loads
	                 the player's character once the world exists

	Server -> client
	  ChunkEdits     u16 chunkCount, per chunk: i32 cx, i32 cz, u32 count, count x (u32 localIndex, u16 block)
	  Edits          u32 count, count x (i32 x, u16 y, i32 z, u16 block)
	  Waypoints      waypoint list (below)
	  Inventory      the player's inventory after their action `ack`: u32 ack, u8 selected (1..9),
	                 4 armor + 36 inventory + 1 cursor stacks, u8 window, u8 containerKind (0 none,
	                 else its index in Types.KINDS), u16 containerBlock, u8 containerSize,
	                 u8 n + n x f64 container data (at most Types.MAX_CONTAINER_DATA, no NaN: a
	                 furnace's litTime, litDuration, cookingProgress, cookingTotalTime,
	                 cookingItem; machines' energy), containerSize stacks. A stack is u16 item,
	                 u8 count (0 = empty, and nothing more follows), u16 damage (a tool's wear),
	                 item data (below). A malformed snapshot (bad lengths, kinds, data) decodes to
	                 nil.
	  Entities       u16 count, count x entity update (u8 op, u32 id, then by op):
	                   1 spawn   u16 item, u8 count, f32 x, y, z, vx, vy, vz (blocks, per tick), u16 age (ticks)
	                   2 sync    f32 x, y, z, vx, vy, vz
	                   3 count   u8 count
	                   4 remove  f64 collector (UserId of the player who picked it up, 0 = none)
	                   5 take    u8 count, f64 collector: a partial pickup (the item stays, smaller)
	  Notice         u16 length, text: a message for the player (shown in the chat)
	  Sound          u16 count, count x (u16 sound, f32 x, y, z, u8 volume, u8 pitch): sound events
	                 to play at (x, y, z) (blocks), `sound` an event number of Shared/Sounds,
	                 volume and pitch in hundredths of the event's own (100 = as listed). The
	                 sounds near the player this frame (server Audio/Sounds).
	  Transmitters   u32 count, count x (i32 x, u16 y, i32 z, u16 modes, u8 colour, u8 fluid,
	                 u8 fluidId): the state of Mekanism transmitters (Shared/Transmitters): the six
	                 side modes packed 2 bits a side (side 0 lowest, so at most 4095), the colour
	                 (0 none, 1..16 dyes), how full a pipe's network is (`fluid`: 0 empty .. 255
	                 full, Transmitters.fillLevel) and what it holds (`fluidId`: a Shared/Fluids id,
	                 0 none, 1 water, 2 lava, 3 oil, 4 fuel); a message with modes, a colour or a
	                 fluid id beyond those is malformed. A record replaces whatever the client knew
	                 about that position; transmitters in the default state (all NORMAL, no
	                 colour, empty) need none, and the client forgets positions that stop being
	                 transmitters. Sent with a chunk's edit list and to the players near a change.
	  Tanks          u32 count, count x (i32 x, u16 y, i32 z, u8 fluid (a Shared/Fluids id: 0 none,
	                 1 water, 2 lava, 3 oil, 4 fuel; beyond them is malformed), u32 amount (mB)):
	                 fluid tanks, the same way.
	  StructureBlocks u8 flags (bit 0: open, the answer to this player's open request: show the
	                 screen of the record's block), u32 count, count x (i32 x, u16 y, i32 z,
	                 u8 present, then when present is 1 the structure settings): structure blocks'
	                 settings, for their screens, bounding boxes and WAILA. A record replaces what
	                 the client knew about that position; present 0 means there is no structure
	                 block there any more (forget it). Sent with a chunk's edit list and to the
	                 players near a change, as Transmitters.
	  Jigsaws        the same with jigsaw settings
	  StructureData  a piece of structure text (below): the text a SAVE made, for the player who
	                 saved (the screen shows it to copy)
	  Machines       u32 count, count x (i32 x, u16 y, i32 z, f64 energy, f64 capacity (J; math.huge
	                 is the creative cube's infinity), f32 input, f32 output (J the energy network
	                 put in / took out last tick), f32 rate (J/t the machine made, + or used, -),
	                 u8 flags (bit 0: active), u8 state (the kind's state code, Shared/Machines
	                 KindSpec `state`: why it is not working), u8 tanks (0 for a kind without
	                 any), tanks x (u8 fluid (a Shared/Fluids id, 0 empty; beyond them is
	                 malformed), u32 amount, u32 capacity (mB)): the machine's fluid tanks in its
	                 kind's order, Machines.tankContents): Mekanism machines (Shared/Machines) for
	                 WAILA and the world, the same way as Tanks (a record replaces what the client
	                 knew; a machine without one is empty and idle at its block's capacity, state
	                 0, its tanks empty). NaN is malformed. A viewer of the machine's window gets
	                 its whole data in Inventory snapshots instead.
	  Transport      u32 count, count x op (u8 op, u32 id, then by op): items in transporters.
	                   1 add     u16 item, u8 count, i32 x, u16 y, i32 z (the transporter it is in),
	                             u8 progress (0..100 through that block), u8 speed (progress per
	                             tick), f64 startTime (workspace:GetServerTimeNow() when it was at
	                             `progress` there), u8 n, n x u8 side (the sides it leaves each
	                             block through, the first leaving (x, y, z)). An add with an id the
	                             client knows replaces that item (it was re-routed).
	                   2 remove  u8 reason (0 arrived, 1 dropped, 2 gone)
	                 Clients move items along the path themselves at 20 ticks a second; nothing
	                 is sent per block.
	  Settings       player settings (below): the saved choices of one device profile, one message
	                 for each of the three profiles once the server loaded them on join (a profile
	                 with nothing saved has count 0)
	  Explosion      f32 x, y, z, f32 power, f32 kx, ky, kz: an explosion (server World/Explosions)
	                 within Config.Explosions.EffectDistance of the player, for its effect, and
	                 the knockback it gives this player (blocks per tick, added to the movement's
	                 velocity; 0 when it doesn't reach them): Minecraft's ClientboundExplodePacket
	                 without the block list (blocks come as edits). Non-finite numbers, a power
	                 outside 0..MAX_EXPLOSION_POWER or a push over MAX_KNOCKBACK are malformed.
	  Survival       u8 flags (bit 0 thirst on, 1 temperature on, 2 wet, 3 Internal Warmth,
	                 4 Internal Chill), u8 thirst (0..20), u8 hydration x 10, u8 exhaustion x 50
	                 (clamped to 255), u8 temperature + 10 and u8 target + 10 (the body
	                 temperature -10..10 and where it is going), u16 frozen and u16 heat
	                 (0..Temperature.EXTREME_TICKS), u16 Thirst effect ticks, u16 Climate
	                 Clemency seconds left (rounded up): 14 bytes, the player's own thirst and
	                 body temperature (Shared/ToughAsNails), sent to them alone when it changes
	                 (at most every few ticks, and at once on joining and respawning); unknown
	                 flags and out of range values are malformed
	  Mobs           u16 count, count x op (u8 op, u32 mob id, then by op): the mobs within
	                 Config.Mobs.TrackingDistance of the player (server Mobs/Mobs), positions in
	                 1/32 block (i32 each: the feet), yaw in 1/256 of a turn (u8: facing
	                 (sin, cos)), health in half hearts (u8), flags (u8: bit 0 hurt flash, 1
	                 burning, 2 dying, 3 a creeper's fuse lit) and the fuse's ticks (u8):
	                   1 spawn   u8 kind (Shared/Entities/MobList id), u8 variant, i32 x, y, z,
	                             u8 yaw, u8 health, u8 flags, u8 fuse
	                   2 state   i32 x, y, z, u8 yaw, u8 health, u8 flags, u8 fuse (sent when it
	                             changed, every Config.Mobs.SyncTicks)
	                   3 remove  nothing (gone, died, or out of range)
	                   4 arrow   i32 x, y, z, i32 tx, ty, tz: a skeleton's arrow flying from x to tx
	                   5 push    f32 kx, ky, kz: this player's knockback from the mob's hit (blocks
	                             per tick, at most MAX_KNOCKBACK)
	                 An unknown op or kind, a wrong length or a non-finite push is malformed.
	  Effects        u8 count, count x (u8 effect, u8 amplifier, i32 ticks, u8 flags): every status
	                 effect the player has (Shared/Effects: the running ones and Tough As Nails'
	                 external ones), sent to them alone when the list changes, an effect ends
	                 early or its time left drifts from the client's own countdown by more than a
	                 second (server Players/EffectRules.needsSync), and at once for a new character
	                 (empty). `ticks` left (-1: never ends, Effects.INFINITE), flags bit 0 ambient,
	                 bit 1 paused (its time stands still: not counted down by the client).
	                 Unknown effects, the same effect twice, ticks below -1, other flags or more
	                 entries than effects are malformed.
	  Progress       u32 points (total knowledge, at most Knowledge.MAX_POINTS), u8 age (an
	                 Ages index, 1..Ages.count), u8 n + n x u8 skill (unlocked nodes, Skills'
	                 places, 1..Skills.count), u8 categories (= #Knowledge.CATEGORIES) +
	                 categories x u16 count (discoveries by category, clamped to 65535), u8
	                 milestones (= #Ages.MILESTONES) + ceil(milestones / 8) bytes of bits (bit i % 8
	                 of byte i // 8: milestone i + 1 met): the player's own progression
	                 (Shared/Progression.status), sent to them alone on joining (once loaded) and
	                 after every change, at most one a frame; anything out of range is malformed
	  MenuState      u8 state (MenuState: 0 waiting for the operator, 1 creating, 2 ready, 3 failed),
	                 then u16 length + text each: the operator's name (the first operator here, ""
	                 for none) and the world's name ("" before it exists): the title screen's
	                 state, sent on joining and to everyone when it changes (Players/WorldMenu)
	  CreateWorldResult u8 ok (0 / 1), u16 length + text: the answer to this player's CreateWorld
	                 (why not, when it failed)

	Item data (Items.Data, Minecraft's item NBT, flat): u8 n (0 = no data, at most
	  Items.MAX_DATA_KEYS), then n entries sorted by key: u8 keyLength (1..32) + key ([%w_]),
	  u8 type, value: type 0 a number (f64, finite), 1 a string (u8 length (at most 64) + bytes),
	  2 a boolean (u8 0 / 1). Duplicate keys, other types and anything Items.validData refuses are
	  malformed. Item entities and items in transporters carry no data on the wire (clients only
	  draw them).

	Structure settings and jigsaw settings: Structures/Settings' wire format (mode, name, offset,
	  size, rotation, mirror, integrity, seed, flags, metadata; name, target, pool, final state,
	  joint). Unknown codes, NaN and strings over 128 bytes are malformed; numbers out of range are
	  clamped into Minecraft's ranges (as its block entities clamp what they load).

	StructureData pieces (both ways): u32 transfer, u16 index, u16 count, u16 length + text (UTF-8
	  bytes, at most STRUCTURE_PIECE): piece `index` (0-based) of `count` (1..MAX_STRUCTURE_PIECES)
	  of one text, numbered `transfer` by its sender (0 is no transfer). A text is
	  Config.Structures.DataPieceChars characters a piece, at most Config.Structures.MaxDataChars in
	  all (the 200,000 characters a StringValue holds); `splitStructureData` cuts one and
	  `joinStructureData` puts the pieces back together, refusing pieces that don't fit.

	Waypoint list: u32 revision, u8 count, count x (i32 x, i32 y, i32 z, u8 r, u8 g, u8 b, u8 nameLength, name)
	  The client numbers its changes (revision); the server echoes the revision it answers (0 = the
	  list loaded on join), so neither side ever applies an older list over a newer one.

	Player settings (Shared/PlayerSettings): u8 version (1), u8 profile (1 desktop, 2 touch,
	  3 console), u8 count, count x (u8 id, f32 value): only the settings the player chose, by
	  their append-only ids. Another version, profile or length is malformed; unknown ids and NaN
	  are dropped and values are clamped into their ranges (a touch profile's to the phone limits).
]]

local Config = require(script.Parent.Parent.Config)
local Effects = require(script.Parent.Parent.Effects)
local Fluids = require(script.Parent.Parent.Fluids)
local GameMode = require(script.Parent.Parent.GameMode)
local InventoryTypes = require(script.Parent.Parent.Inventory.Types)
local Items = require(script.Parent.Parent.Items)
local PlayerSettings = require(script.Parent.Parent.PlayerSettings)
local Progression = require(script.Parent.Parent.Progression)
local Settings = require(script.Parent.Parent.Structures.Settings)
local Exertion = require(script.Parent.Parent.ToughAsNails.Exertion)
local Temperature = require(script.Parent.Parent.ToughAsNails.Temperature)

local Protocol = {}

Protocol.ClientMessage = {
	RequestChunks = 1,
	Edit = 2,
	Teleport = 3,
	SaveWaypoints = 4,
	Fall = 5,
	Mine = 6,
	Inventory = 7,
	Use = 8,
	UseItem = 9,
	StructureBlock = 10,
	Jigsaw = 11,
	StructureData = 12,
	SetGameMode = 13,
	SpectatorTeleport = 14,
	SaveSettings = 15,
	Exertion = 16,
	Drink = 17,
	Attack = 18,
	Eat = 19,
	UnlockSkill = 20,
	CreateWorld = 21,
	EnterWorld = 22,
}

Protocol.ServerMessage = {
	ChunkEdits = 1,
	Edits = 2,
	Waypoints = 3,
	Inventory = 4,
	Entities = 5,
	Notice = 6,
	Sound = 7,
	Transmitters = 8,
	Tanks = 9,
	Transport = 10,
	Machines = 11,
	StructureBlocks = 12,
	Jigsaws = 13,
	StructureData = 14,
	Settings = 15,
	Explosion = 16,
	Survival = 17,
	Mobs = 18,
	Effects = 19,
	Progress = 20,
	MenuState = 21,
	CreateWorldResult = 22,
}

Protocol.EditAction = {
	Break = 1,
	Place = 2,
}

-- Limits enforced when decoding untrusted client data.
Protocol.MAX_CHUNKS_PER_REQUEST = 256
Protocol.EDIT_BYTES = 12
Protocol.MAX_WAYPOINTS = 64
Protocol.MAX_WAYPOINT_NAME = 32
-- Edits and teleports outside this many blocks from the origin are rejected.
Protocol.MAX_COORDINATE = 1000000

export type Waypoint = {
	name: string,
	x: number,
	y: number,
	z: number,
	color: { number },
}

export type ChunkCoord = { number }
export type ChunkEditList = { cx: number, cz: number, edits: { [number]: number } }

--[[ Client -> server ]]

function Protocol.encodeChunkRequest(coords: { ChunkCoord }): buffer
	local b = buffer.create(2 + #coords * 8)
	buffer.writeu16(b, 0, #coords)
	for i, coord in coords do
		local o = 2 + (i - 1) * 8
		buffer.writei32(b, o, coord[1])
		buffer.writei32(b, o + 4, coord[2])
	end
	return b
end

-- Returns nil when the payload is malformed.
function Protocol.decodeChunkRequest(b: buffer): { ChunkCoord }?
	local len = buffer.len(b)
	if len < 2 then
		return nil
	end
	local count = buffer.readu16(b, 0)
	if count > Protocol.MAX_CHUNKS_PER_REQUEST or len ~= 2 + count * 8 then
		return nil
	end
	local coords = table.create(count)
	for i = 1, count do
		local o = 2 + (i - 1) * 8
		coords[i] = { buffer.readi32(b, o), buffer.readi32(b, o + 4) }
	end
	return coords
end

function Protocol.encodeEdit(action: number, x: number, y: number, z: number, block: number, seq: number?): buffer
	local b = buffer.create(17)
	buffer.writeu8(b, 0, action)
	buffer.writei32(b, 1, x)
	buffer.writeu16(b, 5, y)
	buffer.writei32(b, 7, z)
	buffer.writeu16(b, 11, block)
	buffer.writeu32(b, 13, seq or 0)
	return b
end

-- action (nil when malformed), x, y, z, block, seq.
function Protocol.decodeEdit(b: buffer): (number?, number, number, number, number, number)
	if buffer.len(b) ~= 17 then
		return nil, 0, 0, 0, 0, 0
	end
	return buffer.readu8(b, 0),
		buffer.readi32(b, 1),
		buffer.readu16(b, 5),
		buffer.readi32(b, 7),
		buffer.readu16(b, 11),
		buffer.readu32(b, 13)
end

--[[ Mining and using blocks ]]

function Protocol.encodeMine(started: boolean, x: number, y: number, z: number): buffer
	local b = buffer.create(11)
	buffer.writeu8(b, 0, if started then 1 else 0)
	buffer.writei32(b, 1, x)
	buffer.writeu16(b, 5, y)
	buffer.writei32(b, 7, z)
	return b
end

-- started (nil when malformed), x, y, z.
function Protocol.decodeMine(b: buffer): (boolean?, number, number, number)
	if buffer.len(b) ~= 11 then
		return nil, 0, 0, 0
	end
	local flag = buffer.readu8(b, 0)
	if flag > 1 then
		return nil, 0, 0, 0
	end
	return flag == 1, buffer.readi32(b, 1), buffer.readu16(b, 5), buffer.readi32(b, 7)
end

function Protocol.encodeUse(x: number, y: number, z: number): buffer
	local b = buffer.create(10)
	buffer.writei32(b, 0, x)
	buffer.writeu16(b, 4, y)
	buffer.writei32(b, 6, z)
	return b
end

-- x (nil when malformed), y, z.
function Protocol.decodeUse(b: buffer): (number?, number, number)
	if buffer.len(b) ~= 10 then
		return nil, 0, 0
	end
	return buffer.readi32(b, 0), buffer.readu16(b, 4), buffer.readi32(b, 6)
end

--[[ Using items on blocks (the Configurator, buckets) ]]

Protocol.USE_ITEM_BYTES = 12

function Protocol.encodeUseItem(x: number, y: number, z: number, side: number, sneaking: boolean): buffer
	local b = buffer.create(Protocol.USE_ITEM_BYTES)
	buffer.writei32(b, 0, x)
	buffer.writeu16(b, 4, y)
	buffer.writei32(b, 6, z)
	buffer.writeu8(b, 10, side)
	buffer.writeu8(b, 11, if sneaking then 1 else 0)
	return b
end

-- x (nil when malformed: wrong length, a side beyond 5, unknown flags, too far out), y, z, side,
-- sneaking.
function Protocol.decodeUseItem(b: buffer): (number?, number, number, number, boolean)
	if buffer.len(b) ~= Protocol.USE_ITEM_BYTES then
		return nil, 0, 0, 0, false
	end
	local x, y, z = buffer.readi32(b, 0), buffer.readu16(b, 4), buffer.readi32(b, 6)
	local side, flags = buffer.readu8(b, 10), buffer.readu8(b, 11)
	if side > 5 or flags > 1 or math.abs(x) > Protocol.MAX_COORDINATE or math.abs(z) > Protocol.MAX_COORDINATE then
		return nil, 0, 0, 0, false
	end
	return x, y, z, side, flags == 1
end

--[[ Item data (Items.Data) ]]

local DATA_NUMBER, DATA_STRING, DATA_BOOLEAN = 0, 1, 2

-- The keys of `data` in the order they travel (sorted, so equal data always encodes alike).
local function sortedKeys(data: Items.Data): { string }
	local keys: { string } = {}
	for key in next, data do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- Bytes `data` takes on the wire (1 for none; data Items.validData refuses travels as none).
function Protocol.dataSize(data: Items.Data?): number
	if data == nil or not Items.validData(data) then
		return 1
	end
	local size = 1
	for key, value in next, data do
		size += 2 + #key
		if type(value) == "number" then
			size += 8
		elseif type(value) == "string" then
			size += 1 + #value
		else
			size += 1
		end
	end
	return size
end

-- Writes `data` at offset `o` (Protocol.dataSize bytes) and returns the offset after it.
function Protocol.writeData(b: buffer, o: number, data: Items.Data?): number
	if data == nil or not Items.validData(data) then
		buffer.writeu8(b, o, 0)
		return o + 1
	end
	local keys = sortedKeys(data)
	buffer.writeu8(b, o, #keys)
	o += 1
	for _, key in keys do
		buffer.writeu8(b, o, #key)
		buffer.writestring(b, o + 1, key)
		o += 1 + #key
		local value = data[key]
		if type(value) == "number" then
			buffer.writeu8(b, o, DATA_NUMBER)
			buffer.writef64(b, o + 1, value)
			o += 9
		elseif type(value) == "string" then
			buffer.writeu8(b, o, DATA_STRING)
			buffer.writeu8(b, o + 1, #value)
			buffer.writestring(b, o + 2, value)
			o += 2 + #value
		else
			buffer.writeu8(b, o, DATA_BOOLEAN)
			buffer.writeu8(b, o + 1, if value then 1 else 0)
			o += 2
		end
	end
	return o
end

--[[
	Reads item data at offset `o` of the first `len` bytes of `b`: the data (nil: none, or frozen
	valid data) and the offset after it, or ok = false when it is malformed.
]]
function Protocol.readData(b: buffer, o: number, len: number): (boolean, Items.Data?, number)
	if o + 1 > len then
		return false, nil, o
	end
	local n = buffer.readu8(b, o)
	o += 1
	if n == 0 then
		return true, nil, o
	elseif n > Items.MAX_DATA_KEYS then
		return false, nil, o
	end
	local data: Items.Data = {}
	for _ = 1, n do
		if o + 1 > len then
			return false, nil, o
		end
		local keyLength = buffer.readu8(b, o)
		-- (Room for the key and the type byte.)
		if keyLength < 1 or keyLength > Items.MAX_DATA_KEY or o + 2 + keyLength > len then
			return false, nil, o
		end
		local key = buffer.readstring(b, o + 1, keyLength)
		if not Items.validDataKey(key) or data[key] ~= nil then
			return false, nil, o
		end
		o += 1 + keyLength
		local kind = buffer.readu8(b, o)
		o += 1
		if kind == DATA_NUMBER then
			if o + 8 > len then
				return false, nil, o
			end
			data[key] = buffer.readf64(b, o)
			o += 8
		elseif kind == DATA_STRING then
			if o + 1 > len then
				return false, nil, o
			end
			local length = buffer.readu8(b, o)
			if length > Items.MAX_DATA_STRING or o + 1 + length > len then
				return false, nil, o
			end
			data[key] = buffer.readstring(b, o + 1, length)
			o += 1 + length
		elseif kind == DATA_BOOLEAN then
			if o + 1 > len then
				return false, nil, o
			end
			local flag = buffer.readu8(b, o)
			if flag > 1 then
				return false, nil, o
			end
			data[key] = flag == 1
			o += 1
		else
			return false, nil, o
		end
	end
	-- (NaN and infinities are caught here.)
	if not Items.validData(data) then
		return false, nil, o
	end
	return true, table.freeze(data), o
end

--[[ Inventory actions (client -> server) ]]

local ACTION_CLICK, ACTION_DRAG, ACTION_SELECT, ACTION_DROP, ACTION_CREATIVE, ACTION_CLOSE = 1, 2, 3, 4, 5, 6

-- Encodes inventory action number `seq`. `place` actions travel inside Edit messages instead.
function Protocol.encodeInventoryAction(seq: number, action: InventoryTypes.Action): buffer
	local b
	if action.kind == "click" then
		b = buffer.create(10)
		buffer.writeu8(b, 4, ACTION_CLICK)
		buffer.writeu8(b, 5, action.window)
		buffer.writei16(b, 6, action.slot)
		buffer.writeu8(b, 8, action.clickType)
		buffer.writeu8(b, 9, action.button)
	elseif action.kind == "drag" then
		local count = math.min(#action.slots, InventoryTypes.MAX_DRAG)
		b = buffer.create(8 + count * 2)
		buffer.writeu8(b, 4, ACTION_DRAG)
		buffer.writeu8(b, 5, action.window)
		buffer.writeu8(b, 6, action.mode)
		buffer.writeu8(b, 7, count)
		for i = 1, count do
			buffer.writeu16(b, 8 + (i - 1) * 2, action.slots[i])
		end
	elseif action.kind == "select" then
		b = buffer.create(6)
		buffer.writeu8(b, 4, ACTION_SELECT)
		buffer.writeu8(b, 5, action.slot)
	elseif action.kind == "drop" then
		b = buffer.create(6)
		buffer.writeu8(b, 4, ACTION_DROP)
		buffer.writeu8(b, 5, if action.all then 1 else 0)
	elseif action.kind == "creative" then
		b = buffer.create(13 + Protocol.dataSize(action.data))
		buffer.writeu8(b, 4, ACTION_CREATIVE)
		buffer.writeu8(b, 5, action.window)
		buffer.writei16(b, 6, action.slot)
		buffer.writeu16(b, 8, action.item)
		buffer.writeu8(b, 10, action.count)
		buffer.writeu16(b, 11, math.clamp(Items.cleanDamage(action.damage) or 0, 0, 65535))
		Protocol.writeData(b, 13, action.data)
	elseif action.kind == "close" then
		b = buffer.create(6)
		buffer.writeu8(b, 4, ACTION_CLOSE)
		buffer.writeu8(b, 5, action.window)
	else
		error(`Inventory action {action.kind} is not sent on its own`)
	end
	buffer.writeu32(b, 0, seq)
	return b
end

--[[
	seq and action, or nil when the payload is malformed. Only the shape is checked here; whether
	the action is allowed (slot numbers, items, game mode) is up to Inventory/Menu and the server.
]]
function Protocol.decodeInventoryAction(b: buffer): (number?, InventoryTypes.Action?)
	local len = buffer.len(b)
	if len < 6 then
		return nil, nil
	end
	local seq = buffer.readu32(b, 0)
	local kind = buffer.readu8(b, 4)
	if kind == ACTION_CLICK and len == 10 then
		return seq,
			{
				kind = "click",
				window = buffer.readu8(b, 5),
				slot = buffer.readi16(b, 6),
				clickType = buffer.readu8(b, 8),
				button = buffer.readu8(b, 9),
			}
	elseif kind == ACTION_DRAG and len >= 8 then
		local count = buffer.readu8(b, 7)
		if count > InventoryTypes.MAX_DRAG or len ~= 8 + count * 2 then
			return nil, nil
		end
		local slots = table.create(count)
		for i = 1, count do
			slots[i] = buffer.readu16(b, 8 + (i - 1) * 2)
		end
		return seq, { kind = "drag", window = buffer.readu8(b, 5), mode = buffer.readu8(b, 6), slots = slots }
	elseif kind == ACTION_SELECT and len == 6 then
		return seq, { kind = "select", slot = buffer.readu8(b, 5) }
	elseif kind == ACTION_DROP and len == 6 then
		return seq, { kind = "drop", all = buffer.readu8(b, 5) ~= 0 }
	elseif kind == ACTION_CREATIVE and len >= 14 then
		local ok, data, after = Protocol.readData(b, 13, len)
		if not ok or after ~= len then
			return nil, nil
		end
		local damage = buffer.readu16(b, 11)
		return seq,
			{
				kind = "creative",
				window = buffer.readu8(b, 5),
				slot = buffer.readi16(b, 6),
				item = buffer.readu16(b, 8),
				count = buffer.readu8(b, 10),
				damage = if damage > 0 then damage else nil,
				data = data,
			}
	elseif kind == ACTION_CLOSE and len == 6 then
		return seq, { kind = "close", window = buffer.readu8(b, 5) }
	end
	return nil, nil
end

--[[ Inventory snapshot (server -> client) ]]

-- A stack's fixed part: u16 item, u8 count, u16 damage (its data follows).
local STACK_BYTES = 5

local function stackSize(stack: InventoryTypes.Stack?): number
	if stack and stack.count > 0 then
		return STACK_BYTES + Protocol.dataSize(stack.data)
	end
	return 3
end

local function writeStack(b: buffer, o: number, stack: InventoryTypes.Stack?): number
	if stack and stack.count > 0 then
		buffer.writeu16(b, o, stack.item)
		buffer.writeu8(b, o + 2, math.min(stack.count, 255))
		buffer.writeu16(b, o + 3, math.clamp(Items.cleanDamage(stack.damage) or 0, 0, 65535))
		return Protocol.writeData(b, o + STACK_BYTES, stack.data)
	end
	-- An empty slot: item 0, count 0.
	buffer.writeu16(b, o, 0)
	buffer.writeu8(b, o + 2, 0)
	return o + 3
end

-- The stack at `o` (nil: an empty slot) and the offset after it; ok = false when malformed.
local function readStack(b: buffer, o: number, len: number): (boolean, InventoryTypes.Stack?, number)
	if o + 3 > len then
		return false, nil, o
	end
	local count = buffer.readu8(b, o + 2)
	if count == 0 then
		return true, nil, o + 3
	elseif o + STACK_BYTES > len then
		return false, nil, o
	end
	local ok, data, after = Protocol.readData(b, o + STACK_BYTES, len)
	if not ok then
		return false, nil, o
	end
	local damage = buffer.readu16(b, o + 3)
	return true,
		{ item = buffer.readu16(b, o), count = count, damage = if damage > 0 then damage else nil, data = data },
		after
end

local KIND_CODE: { [string]: number } = {}
for code, kind in InventoryTypes.KINDS do
	KIND_CODE[kind] = code
end

-- A container data value as sent: NaN (which the decoder refuses) becomes 0.
local function dataValue(value: number?): number
	if value == nil or value ~= value then
		return 0
	end
	return value
end

--[[
	An Inventory message for `snapshot`. A container of a kind Types.KINDS does not list travels as
	none (kind 0, no slots, no data), so the snapshot still decodes; container data beyond
	Types.MAX_CONTAINER_DATA values is cut and NaN is sent as 0.
]]
function Protocol.encodeInventory(snapshot: InventoryTypes.Snapshot): buffer
	local container = snapshot.container
	if container and KIND_CODE[container.kind] == nil then
		container = nil
	end
	local size = if container then math.min(container.size, InventoryTypes.MAX_CONTAINER) else 0
	local data = if container then container.data else nil
	local dataCount = if data then math.min(#data, InventoryTypes.MAX_CONTAINER_DATA) else 0
	local inventory = snapshot.inventory

	local bytes = 5 + 5 + 1 + dataCount * 8
	for slot = 1, InventoryTypes.ARMOR_SIZE do
		bytes += stackSize(inventory.armor[slot])
	end
	for slot = 1, InventoryTypes.INVENTORY_SIZE do
		bytes += stackSize(inventory.slots[slot])
	end
	bytes += stackSize(inventory.cursor)
	if container then
		for slot = 1, size do
			bytes += stackSize(container.slots[slot])
		end
	end

	local b = buffer.create(bytes)
	buffer.writeu32(b, 0, snapshot.ack)
	buffer.writeu8(b, 4, inventory.selected)
	local o = 5
	for slot = 1, InventoryTypes.ARMOR_SIZE do
		o = writeStack(b, o, inventory.armor[slot])
	end
	for slot = 1, InventoryTypes.INVENTORY_SIZE do
		o = writeStack(b, o, inventory.slots[slot])
	end
	o = writeStack(b, o, inventory.cursor)
	buffer.writeu8(b, o, snapshot.window)
	buffer.writeu8(b, o + 1, if container then KIND_CODE[container.kind] else 0)
	buffer.writeu16(b, o + 2, if container then container.block else 0)
	buffer.writeu8(b, o + 4, size)
	buffer.writeu8(b, o + 5, dataCount)
	o += 6
	for i = 1, dataCount do
		buffer.writef64(b, o, dataValue((data :: { number })[i]))
		o += 8
	end
	if container then
		for slot = 1, size do
			o = writeStack(b, o, container.slots[slot])
		end
	end
	return b
end

--[[
	The snapshot in an Inventory message, or nil when it is malformed: wrong lengths, a selected
	slot outside 1..9, an unknown container kind (or slots without one), more container slots or
	data than allowed, NaN data, or item data Items.validData refuses.
]]
function Protocol.decodeInventory(b: buffer): InventoryTypes.Snapshot?
	local len = buffer.len(b)
	if len < 5 then
		return nil
	end
	local inventory = InventoryTypes.newInventory()
	inventory.selected = buffer.readu8(b, 4)
	if inventory.selected < 1 or inventory.selected > InventoryTypes.HOTBAR_SIZE then
		return nil
	end
	local o = 5
	local ok: boolean, stack: InventoryTypes.Stack? = true, nil
	for slot = 1, InventoryTypes.ARMOR_SIZE do
		ok, stack, o = readStack(b, o, len)
		if not ok then
			return nil
		end
		inventory.armor[slot] = stack
	end
	for slot = 1, InventoryTypes.INVENTORY_SIZE do
		ok, stack, o = readStack(b, o, len)
		if not ok then
			return nil
		end
		inventory.slots[slot] = stack
	end
	ok, stack, o = readStack(b, o, len)
	if not ok then
		return nil
	end
	inventory.cursor = stack
	if o + 6 > len then
		return nil
	end
	local window = buffer.readu8(b, o)
	local code = buffer.readu8(b, o + 1)
	local kind = InventoryTypes.KINDS[code]
	local block = buffer.readu16(b, o + 2)
	local size = buffer.readu8(b, o + 4)
	local dataCount = buffer.readu8(b, o + 5)
	o += 6
	if
		(code ~= 0 and kind == nil)
		or (kind == nil and (size > 0 or dataCount > 0))
		or size > InventoryTypes.MAX_CONTAINER
		or dataCount > InventoryTypes.MAX_CONTAINER_DATA
		or o + dataCount * 8 > len
	then
		return nil
	end
	local data: { number }? = nil
	if dataCount > 0 then
		local values = table.create(dataCount)
		for i = 1, dataCount do
			local value = buffer.readf64(b, o)
			if value ~= value then
				return nil
			end
			values[i] = value
			o += 8
		end
		data = values
	end
	local container: InventoryTypes.Container? = nil
	if kind then
		local slots = {}
		for slot = 1, size do
			ok, stack, o = readStack(b, o, len)
			if not ok then
				return nil
			end
			slots[slot] = stack
		end
		container = { kind = kind, block = block, size = size, slots = slots, data = data }
	end
	if o ~= len then
		return nil
	end
	return { ack = buffer.readu32(b, 0), inventory = inventory, window = window, container = container }
end

--[[ Entities (server -> client) ]]

export type EntityOp =
	{
		op: "spawn",
		id: number,
		item: number,
		count: number,
		x: number,
		y: number,
		z: number,
		vx: number,
		vy: number,
		vz: number,
		age: number,
	}
	| { op: "sync", id: number, x: number, y: number, z: number, vx: number, vy: number, vz: number }
	| { op: "count", id: number, count: number }
	| { op: "remove", id: number, collector: number }
	| { op: "take", id: number, count: number, collector: number }

local OP_SPAWN, OP_SYNC, OP_COUNT, OP_REMOVE, OP_TAKE = 1, 2, 3, 4, 5
local OP_SIZE = {
	[OP_SPAWN] = 5 + 3 + 24 + 2,
	[OP_SYNC] = 5 + 24,
	[OP_COUNT] = 5 + 1,
	[OP_REMOVE] = 5 + 8,
	[OP_TAKE] = 5 + 1 + 8,
}
local OP_CODE = { spawn = OP_SPAWN, sync = OP_SYNC, count = OP_COUNT, remove = OP_REMOVE, take = OP_TAKE }

function Protocol.encodeEntities(ops: { EntityOp }): buffer
	local size = 2
	for _, op in ops do
		size += OP_SIZE[OP_CODE[op.op]]
	end
	local b = buffer.create(size)
	buffer.writeu16(b, 0, #ops)
	local o = 2
	for _, op in ops do
		buffer.writeu8(b, o, OP_CODE[op.op])
		buffer.writeu32(b, o + 1, op.id)
		o += 5
		if op.op == "spawn" then
			buffer.writeu16(b, o, op.item)
			buffer.writeu8(b, o + 2, op.count)
			o += 3
		end
		if op.op == "spawn" or op.op == "sync" then
			buffer.writef32(b, o, op.x)
			buffer.writef32(b, o + 4, op.y)
			buffer.writef32(b, o + 8, op.z)
			buffer.writef32(b, o + 12, op.vx)
			buffer.writef32(b, o + 16, op.vy)
			buffer.writef32(b, o + 20, op.vz)
			o += 24
		end
		if op.op == "spawn" then
			buffer.writeu16(b, o, math.clamp(op.age, 0, 65535))
			o += 2
		elseif op.op == "count" then
			buffer.writeu8(b, o, op.count)
			o += 1
		elseif op.op == "remove" then
			buffer.writef64(b, o, op.collector)
			o += 8
		elseif op.op == "take" then
			buffer.writeu8(b, o, op.count)
			buffer.writef64(b, o + 1, op.collector)
			o += 9
		end
	end
	return b
end

function Protocol.decodeEntities(b: buffer): { EntityOp }
	local ops: { EntityOp } = {}
	local count = buffer.readu16(b, 0)
	local o = 2
	for _ = 1, count do
		local code = buffer.readu8(b, o)
		local id = buffer.readu32(b, o + 1)
		o += 5
		if code == OP_SPAWN then
			table.insert(ops, {
				op = "spawn",
				id = id,
				item = buffer.readu16(b, o),
				count = buffer.readu8(b, o + 2),
				x = buffer.readf32(b, o + 3),
				y = buffer.readf32(b, o + 7),
				z = buffer.readf32(b, o + 11),
				vx = buffer.readf32(b, o + 15),
				vy = buffer.readf32(b, o + 19),
				vz = buffer.readf32(b, o + 23),
				age = buffer.readu16(b, o + 27),
			})
			o += 29
		elseif code == OP_SYNC then
			table.insert(ops, {
				op = "sync",
				id = id,
				x = buffer.readf32(b, o),
				y = buffer.readf32(b, o + 4),
				z = buffer.readf32(b, o + 8),
				vx = buffer.readf32(b, o + 12),
				vy = buffer.readf32(b, o + 16),
				vz = buffer.readf32(b, o + 20),
			})
			o += 24
		elseif code == OP_COUNT then
			table.insert(ops, { op = "count", id = id, count = buffer.readu8(b, o) })
			o += 1
		elseif code == OP_REMOVE then
			table.insert(ops, { op = "remove", id = id, collector = buffer.readf64(b, o) })
			o += 8
		elseif code == OP_TAKE then
			table.insert(
				ops,
				{ op = "take", id = id, count = buffer.readu8(b, o), collector = buffer.readf64(b, o + 1) }
			)
			o += 9
		else
			error(`Unknown entity op {code}`)
		end
	end
	return ops
end

--[[ Notices ]]

Protocol.MAX_NOTICE = 1000

function Protocol.encodeNotice(text: string): buffer
	local cut = string.sub(text, 1, Protocol.MAX_NOTICE)
	local b = buffer.create(2 + #cut)
	buffer.writeu16(b, 0, #cut)
	buffer.writestring(b, 2, cut)
	return b
end

function Protocol.decodeNotice(b: buffer): string
	return buffer.readstring(b, 2, buffer.readu16(b, 0))
end

--[[ Sounds (server -> client) ]]

-- A sound to play: event `sound` (Shared/Sounds) at (x, y, z) in blocks, its volume and pitch
-- multiplied by `volume` and `pitch` (0..2.55, in steps of 0.01).
export type SoundCue = { sound: number, x: number, y: number, z: number, volume: number, pitch: number }

Protocol.SOUND_BYTES = 16
Protocol.MAX_SOUNDS = 65535

-- A multiplier as a u8 of hundredths (nonsense becomes 1).
local function hundredths(value: number): number
	if value ~= value then
		return 100
	end
	return math.clamp(math.round(value * 100), 0, 255)
end

function Protocol.encodeSounds(cues: { SoundCue }): buffer
	local count = math.min(#cues, Protocol.MAX_SOUNDS)
	local b = buffer.create(2 + count * Protocol.SOUND_BYTES)
	buffer.writeu16(b, 0, count)
	local o = 2
	for i = 1, count do
		local cue = cues[i]
		buffer.writeu16(b, o, cue.sound)
		buffer.writef32(b, o + 2, cue.x)
		buffer.writef32(b, o + 6, cue.y)
		buffer.writef32(b, o + 10, cue.z)
		buffer.writeu8(b, o + 14, hundredths(cue.volume))
		buffer.writeu8(b, o + 15, hundredths(cue.pitch))
		o += Protocol.SOUND_BYTES
	end
	return b
end

-- The cues of a Sound message, or nil when it is malformed.
function Protocol.decodeSounds(b: buffer): { SoundCue }?
	local len = buffer.len(b)
	if len < 2 then
		return nil
	end
	local count = buffer.readu16(b, 0)
	if len ~= 2 + count * Protocol.SOUND_BYTES then
		return nil
	end
	local cues: { SoundCue } = table.create(count)
	local o = 2
	for i = 1, count do
		cues[i] = {
			sound = buffer.readu16(b, o),
			x = buffer.readf32(b, o + 2),
			y = buffer.readf32(b, o + 6),
			z = buffer.readf32(b, o + 10),
			volume = buffer.readu8(b, o + 14) / 100,
			pitch = buffer.readu8(b, o + 15) / 100,
		}
		o += Protocol.SOUND_BYTES
	end
	return cues
end

--[[ Mekanism transmitters, fluid tanks, machines and items in transit (server -> client) ]]

-- A transmitter's state: packed side modes (u16), colour (0..16), fill (`fluid`, 0..255) and the
-- fluid a pipe's network holds (`fluidId`, Shared/Fluids: 0 none; nil writes 0, decoded records
-- always have it).
export type TransmitterRecord = {
	x: number,
	y: number,
	z: number,
	modes: number,
	colour: number,
	fluid: number,
	fluidId: number?,
}
-- A fluid tank: fluid (Shared/Fluids id: 0 none, 1 water, 2 lava, 3 oil, 4 fuel) and amount in mB.
export type TankRecord = { x: number, y: number, z: number, fluid: number, amount: number }
-- One of a machine's fluid tanks: its fluid (Shared/Fluids id, 0 empty), amount and capacity in mB.
export type MachineTank = { fluid: number, amount: number, capacity: number }
-- A Mekanism machine: energy and capacity (J), the network's input / output and its own rate (J
-- per tick, the last tick's), whether it is working, its kind's state code (0..255) and its
-- tanks in order (Machines.tankContents; nil or empty for a kind without any, and decoded
-- records without tanks have nil).
export type MachineRecord = {
	x: number,
	y: number,
	z: number,
	energy: number,
	capacity: number,
	input: number,
	output: number,
	rate: number,
	active: boolean,
	state: number,
	tanks: { MachineTank }?,
}
-- An item entering a transporter or re-routed (`add`), or leaving the transporters (`remove`).
export type TransportOp = {
	op: "add",
	id: number,
	item: number,
	count: number,
	x: number,
	y: number,
	z: number,
	progress: number,
	speed: number,
	startTime: number,
	path: { number },
} | { op: "remove", id: number, reason: number }

Protocol.TRANSMITTER_BYTES = 15
Protocol.TANK_BYTES = 15
-- A Machines record's fixed part (up to its state), then its tank count byte and its tanks.
Protocol.MACHINE_BYTES = 40
Protocol.MACHINE_TANK_BYTES = 9
-- Most tanks a Machines record carries (a u8 count).
Protocol.MAX_MACHINE_TANKS = 255
-- Most sides an `add` carries; a longer route is sent again on the way.
Protocol.MAX_PATH = 255
-- Why an item left the transporters (`remove`).
Protocol.TransportRemoveReason = table.freeze({ Arrived = 0, Dropped = 1, Gone = 2 })

-- Largest packed side modes (six sides, 2 bits each) and colour (Minecraft's 16 dyes) a
-- Transmitters record may hold; anything above is malformed.
local MAX_MODES = 4095
local MAX_COLOUR = 16

local TRANSPORT_ADD, TRANSPORT_REMOVE = 1, 2
-- Bytes of an add before its path (op and id included), and of a remove.
local TRANSPORT_ADD_BYTES = 29
local TRANSPORT_REMOVE_BYTES = 6

-- A whole number clamped to a field's range (NaN becomes the low end).
local function clampInt(value: number, low: number, high: number): number
	if value ~= value then
		return low
	end
	return math.clamp(math.floor(value), low, high)
end

-- A fluid id as sent: a Shared/Fluids id, anything else (nil, unknown, NaN) none.
local function fluidIdOf(value: number?): number
	return if value and Fluids.isValid(value) then value else Fluids.NONE
end

function Protocol.encodeTransmitters(records: { TransmitterRecord }): buffer
	local b = buffer.create(4 + #records * Protocol.TRANSMITTER_BYTES)
	buffer.writeu32(b, 0, #records)
	local o = 4
	for _, record in records do
		buffer.writei32(b, o, record.x)
		buffer.writeu16(b, o + 4, record.y)
		buffer.writei32(b, o + 6, record.z)
		buffer.writeu16(b, o + 10, clampInt(record.modes, 0, MAX_MODES))
		buffer.writeu8(b, o + 12, clampInt(record.colour, 0, MAX_COLOUR))
		buffer.writeu8(b, o + 13, clampInt(record.fluid, 0, 255))
		buffer.writeu8(b, o + 14, fluidIdOf(record.fluidId))
		o += Protocol.TRANSMITTER_BYTES
	end
	return b
end

-- The records of a Transmitters message, or nil when it is malformed (modes beyond the six sides'
-- 12 bits, a colour beyond 16 or an unknown fluid id included).
function Protocol.decodeTransmitters(b: buffer): { TransmitterRecord }?
	local len = buffer.len(b)
	if len < 4 then
		return nil
	end
	local count = buffer.readu32(b, 0)
	if len ~= 4 + count * Protocol.TRANSMITTER_BYTES then
		return nil
	end
	local records: { TransmitterRecord } = table.create(count)
	local o = 4
	for i = 1, count do
		local modes, colour = buffer.readu16(b, o + 10), buffer.readu8(b, o + 12)
		local fluidId = buffer.readu8(b, o + 14)
		if modes > MAX_MODES or colour > MAX_COLOUR or fluidId > Fluids.COUNT then
			return nil
		end
		records[i] = {
			x = buffer.readi32(b, o),
			y = buffer.readu16(b, o + 4),
			z = buffer.readi32(b, o + 6),
			modes = modes,
			colour = colour,
			fluid = buffer.readu8(b, o + 13),
			fluidId = fluidId,
		}
		o += Protocol.TRANSMITTER_BYTES
	end
	return records
end

function Protocol.encodeTanks(records: { TankRecord }): buffer
	local b = buffer.create(4 + #records * Protocol.TANK_BYTES)
	buffer.writeu32(b, 0, #records)
	local o = 4
	for _, record in records do
		buffer.writei32(b, o, record.x)
		buffer.writeu16(b, o + 4, record.y)
		buffer.writei32(b, o + 6, record.z)
		buffer.writeu8(b, o + 10, fluidIdOf(record.fluid))
		buffer.writeu32(b, o + 11, clampInt(record.amount, 0, 4294967295))
		o += Protocol.TANK_BYTES
	end
	return b
end

-- The records of a Tanks message, or nil when it is malformed (an unknown fluid id included).
function Protocol.decodeTanks(b: buffer): { TankRecord }?
	local len = buffer.len(b)
	if len < 4 then
		return nil
	end
	local count = buffer.readu32(b, 0)
	if len ~= 4 + count * Protocol.TANK_BYTES then
		return nil
	end
	local records: { TankRecord } = table.create(count)
	local o = 4
	for i = 1, count do
		local fluid = buffer.readu8(b, o + 10)
		if fluid > Fluids.COUNT then
			return nil
		end
		records[i] = {
			x = buffer.readi32(b, o),
			y = buffer.readu16(b, o + 4),
			z = buffer.readi32(b, o + 6),
			fluid = fluid,
			amount = buffer.readu32(b, o + 11),
		}
		o += Protocol.TANK_BYTES
	end
	return records
end

-- A number as sent: NaN (which the decoder refuses) becomes 0.
local function finiteOrInfinite(value: number): number
	return if value ~= value then 0 else value
end

-- Tanks a record sends (at most MAX_MACHINE_TANKS: a longer list sends its first ones).
local function tankCount(record: MachineRecord): number
	local tanks = record.tanks
	return if tanks then math.min(#tanks, Protocol.MAX_MACHINE_TANKS) else 0
end

function Protocol.encodeMachines(records: { MachineRecord }): buffer
	local size = 4
	for _, record in records do
		size += Protocol.MACHINE_BYTES + 1 + tankCount(record) * Protocol.MACHINE_TANK_BYTES
	end
	local b = buffer.create(size)
	buffer.writeu32(b, 0, #records)
	local o = 4
	for _, record in records do
		buffer.writei32(b, o, record.x)
		buffer.writeu16(b, o + 4, record.y)
		buffer.writei32(b, o + 6, record.z)
		buffer.writef64(b, o + 10, finiteOrInfinite(record.energy))
		buffer.writef64(b, o + 18, finiteOrInfinite(record.capacity))
		buffer.writef32(b, o + 26, finiteOrInfinite(record.input))
		buffer.writef32(b, o + 30, finiteOrInfinite(record.output))
		buffer.writef32(b, o + 34, finiteOrInfinite(record.rate))
		buffer.writeu8(b, o + 38, if record.active then 1 else 0)
		-- (Anything but a whole number 0..255 goes as 0: no state.)
		local state = record.state or 0
		buffer.writeu8(b, o + 39, if state == math.floor(state) and state >= 0 and state <= 255 then state else 0)
		o += Protocol.MACHINE_BYTES
		local count = tankCount(record)
		buffer.writeu8(b, o, count)
		o += 1
		local tanks = record.tanks
		if tanks then
			for i = 1, count do
				local tank = tanks[i]
				buffer.writeu8(b, o, fluidIdOf(tank.fluid))
				buffer.writeu32(b, o + 1, clampInt(tank.amount, 0, 4294967295))
				buffer.writeu32(b, o + 5, clampInt(tank.capacity, 0, 4294967295))
				o += Protocol.MACHINE_TANK_BYTES
			end
		end
	end
	return b
end

--[[
	The records of a Machines message, or nil when it is malformed (NaN, flags beyond bit 0, an
	unknown fluid id, a length that is not what the counts say). Records without tanks have none
	(`tanks` nil).
]]
function Protocol.decodeMachines(b: buffer): { MachineRecord }?
	local len = buffer.len(b)
	if len < 4 then
		return nil
	end
	local count = buffer.readu32(b, 0)
	-- (Each record takes at least its fixed part and its tank count: a count that can't fit is
	-- refused before anything is made for it.)
	if 4 + count * (Protocol.MACHINE_BYTES + 1) > len then
		return nil
	end
	local records: { MachineRecord } = table.create(count)
	local o = 4
	for i = 1, count do
		if o + Protocol.MACHINE_BYTES + 1 > len then
			return nil
		end
		local energy, capacity = buffer.readf64(b, o + 10), buffer.readf64(b, o + 18)
		local input, output, rate = buffer.readf32(b, o + 26), buffer.readf32(b, o + 30), buffer.readf32(b, o + 34)
		local flags = buffer.readu8(b, o + 38)
		if
			energy ~= energy
			or capacity ~= capacity
			or input ~= input
			or output ~= output
			or rate ~= rate
			or flags > 1
		then
			return nil
		end
		local at = o + Protocol.MACHINE_BYTES
		local tankTotal = buffer.readu8(b, at)
		at += 1
		if at + tankTotal * Protocol.MACHINE_TANK_BYTES > len then
			return nil
		end
		local tanks: { MachineTank }? = nil
		if tankTotal > 0 then
			local list: { MachineTank } = table.create(tankTotal)
			for j = 1, tankTotal do
				local fluid = buffer.readu8(b, at)
				if fluid > Fluids.COUNT then
					return nil
				end
				list[j] = { fluid = fluid, amount = buffer.readu32(b, at + 1), capacity = buffer.readu32(b, at + 5) }
				at += Protocol.MACHINE_TANK_BYTES
			end
			tanks = list
		end
		records[i] = {
			x = buffer.readi32(b, o),
			y = buffer.readu16(b, o + 4),
			z = buffer.readi32(b, o + 6),
			energy = energy,
			capacity = capacity,
			input = input,
			output = output,
			rate = rate,
			active = flags == 1,
			state = buffer.readu8(b, o + 39),
			tanks = tanks,
		}
		o = at
	end
	if o ~= len then
		return nil
	end
	return records
end

-- (A path longer than MAX_PATH sends its first MAX_PATH sides.)
function Protocol.encodeTransport(ops: { TransportOp }): buffer
	local size = 4
	for _, op in ops do
		if op.op == "add" then
			size += TRANSPORT_ADD_BYTES + math.min(#op.path, Protocol.MAX_PATH)
		else
			size += TRANSPORT_REMOVE_BYTES
		end
	end
	local b = buffer.create(size)
	buffer.writeu32(b, 0, #ops)
	local o = 4
	for _, op in ops do
		if op.op == "add" then
			buffer.writeu8(b, o, TRANSPORT_ADD)
			buffer.writeu32(b, o + 1, op.id)
			buffer.writeu16(b, o + 5, op.item)
			buffer.writeu8(b, o + 7, clampInt(op.count, 0, 255))
			buffer.writei32(b, o + 8, op.x)
			buffer.writeu16(b, o + 12, op.y)
			buffer.writei32(b, o + 14, op.z)
			buffer.writeu8(b, o + 18, clampInt(op.progress, 0, 255))
			buffer.writeu8(b, o + 19, clampInt(op.speed, 0, 255))
			buffer.writef64(b, o + 20, op.startTime)
			local n = math.min(#op.path, Protocol.MAX_PATH)
			buffer.writeu8(b, o + 28, n)
			for i = 1, n do
				buffer.writeu8(b, o + 28 + i, op.path[i])
			end
			o += TRANSPORT_ADD_BYTES + n
		else
			buffer.writeu8(b, o, TRANSPORT_REMOVE)
			buffer.writeu32(b, o + 1, op.id)
			buffer.writeu8(b, o + 5, clampInt(op.reason, 0, 255))
			o += TRANSPORT_REMOVE_BYTES
		end
	end
	return b
end

-- The ops of a Transport message, or nil when it is malformed (a side beyond 5 included).
function Protocol.decodeTransport(b: buffer): { TransportOp }?
	local len = buffer.len(b)
	if len < 4 then
		return nil
	end
	local count = buffer.readu32(b, 0)
	local ops: { TransportOp } = {}
	local o = 4
	for _ = 1, count do
		if o + TRANSPORT_REMOVE_BYTES > len then
			return nil
		end
		local code = buffer.readu8(b, o)
		local id = buffer.readu32(b, o + 1)
		if code == TRANSPORT_ADD then
			if o + TRANSPORT_ADD_BYTES > len then
				return nil
			end
			local n = buffer.readu8(b, o + 28)
			if o + TRANSPORT_ADD_BYTES + n > len then
				return nil
			end
			local path = table.create(n)
			for i = 1, n do
				local side = buffer.readu8(b, o + 28 + i)
				if side > 5 then
					return nil
				end
				path[i] = side
			end
			table.insert(ops, {
				op = "add",
				id = id,
				item = buffer.readu16(b, o + 5),
				count = buffer.readu8(b, o + 7),
				x = buffer.readi32(b, o + 8),
				y = buffer.readu16(b, o + 12),
				z = buffer.readi32(b, o + 14),
				progress = buffer.readu8(b, o + 18),
				speed = buffer.readu8(b, o + 19),
				startTime = buffer.readf64(b, o + 20),
				path = path,
			})
			o += TRANSPORT_ADD_BYTES + n
		elseif code == TRANSPORT_REMOVE then
			table.insert(ops, { op = "remove", id = id, reason = buffer.readu8(b, o + 5) })
			o += TRANSPORT_REMOVE_BYTES
		else
			return nil
		end
	end
	if o ~= len then
		return nil
	end
	return ops
end

--[[ Server -> client ]]

function Protocol.encodeChunkEdits(lists: { ChunkEditList }): buffer
	local size = 2
	local counts = table.create(#lists, 0)
	for i, list in lists do
		local n = 0
		for _ in list.edits do
			n += 1
		end
		counts[i] = n
		size += 12 + n * 6
	end

	local b = buffer.create(size)
	buffer.writeu16(b, 0, #lists)
	local o = 2
	for i, list in lists do
		buffer.writei32(b, o, list.cx)
		buffer.writei32(b, o + 4, list.cz)
		buffer.writeu32(b, o + 8, counts[i])
		o += 12
		for index, block in list.edits do
			buffer.writeu32(b, o, index)
			buffer.writeu16(b, o + 4, block)
			o += 6
		end
	end
	return b
end

function Protocol.decodeChunkEdits(b: buffer): { ChunkEditList }
	local lists = {}
	local count = buffer.readu16(b, 0)
	local o = 2
	for _ = 1, count do
		local list: ChunkEditList = { cx = buffer.readi32(b, o), cz = buffer.readi32(b, o + 4), edits = {} }
		local n = buffer.readu32(b, o + 8)
		o += 12
		for _ = 1, n do
			list.edits[buffer.readu32(b, o)] = buffer.readu16(b, o + 4)
			o += 6
		end
		table.insert(lists, list)
	end
	return lists
end

-- `edits` is a flat array: x1, y1, z1, block1, x2, ...
function Protocol.encodeEdits(edits: { number }, first: number?, last: number?): buffer
	local from = first or 1
	local to = last or #edits
	local count = (to - from + 1) // 4
	local b = buffer.create(4 + count * Protocol.EDIT_BYTES)
	buffer.writeu32(b, 0, count)
	local o = 4
	for i = from, to, 4 do
		buffer.writei32(b, o, edits[i])
		buffer.writeu16(b, o + 4, edits[i + 1])
		buffer.writei32(b, o + 6, edits[i + 2])
		buffer.writeu16(b, o + 10, edits[i + 3])
		o += Protocol.EDIT_BYTES
	end
	return b
end

-- Calls `callback(x, y, z, block)` for every edit in the message.
function Protocol.forEachEdit(b: buffer, callback: (number, number, number, number) -> ())
	local count = buffer.readu32(b, 0)
	local o = 4
	for _ = 1, count do
		callback(buffer.readi32(b, o), buffer.readu16(b, o + 4), buffer.readi32(b, o + 6), buffer.readu16(b, o + 10))
		o += Protocol.EDIT_BYTES
	end
end

--[[ Teleport ]]

function Protocol.encodeTeleport(x: number, z: number): buffer
	local b = buffer.create(8)
	buffer.writei32(b, 0, x)
	buffer.writei32(b, 4, z)
	return b
end

function Protocol.decodeTeleport(b: buffer): (number?, number)
	if buffer.len(b) ~= 8 then
		return nil, 0
	end
	local x, z = buffer.readi32(b, 0), buffer.readi32(b, 4)
	if math.abs(x) > Protocol.MAX_COORDINATE or math.abs(z) > Protocol.MAX_COORDINATE then
		return nil, 0
	end
	return x, z
end

--[[ Game modes ]]

function Protocol.encodeSetGameMode(mode: string): buffer
	local b = buffer.create(1)
	buffer.writeu8(b, 0, GameMode.id(mode))
	return b
end

-- The game mode asked for, or nil when the payload is malformed.
function Protocol.decodeSetGameMode(b: buffer): string?
	if buffer.len(b) ~= 1 then
		return nil
	end
	return GameMode.fromId(buffer.readu8(b, 0))
end

-- Largest |user id| SpectatorTeleport carries (the integers a f64 holds exactly).
local MAX_USER_ID = 2 ^ 53

function Protocol.encodeSpectatorTeleport(userId: number): buffer
	local b = buffer.create(8)
	buffer.writef64(b, 0, userId)
	return b
end

-- The target's user id, or nil when the payload is malformed (not a whole number).
function Protocol.decodeSpectatorTeleport(b: buffer): number?
	if buffer.len(b) ~= 8 then
		return nil
	end
	local userId = buffer.readf64(b, 0)
	if userId ~= userId or math.abs(userId) > MAX_USER_ID or userId ~= math.floor(userId) then
		return nil
	end
	return userId
end

--[[ Fall damage ]]

-- Longest fall a landing can report (blocks).
Protocol.MAX_FALL = 2048

function Protocol.encodeFall(distance: number): buffer
	local b = buffer.create(4)
	buffer.writef32(b, 0, distance)
	return b
end

-- Fall distance, or nil when the payload is malformed.
function Protocol.decodeFall(b: buffer): number?
	if buffer.len(b) ~= 4 then
		return nil
	end
	local distance = buffer.readf32(b, 0)
	if distance ~= distance or distance < 0 or distance > Protocol.MAX_FALL then
		return nil
	end
	return distance
end

--[[ Waypoints ]]

-- Cuts a name to MAX_WAYPOINT_NAME bytes without splitting a UTF-8 character.
function Protocol.truncateName(name: string): string
	local cut = Protocol.MAX_WAYPOINT_NAME
	if #name <= cut then
		return name
	end
	-- Step back while the first byte after the cut is a continuation byte (10xxxxxx).
	while cut > 0 and bit32.band(string.byte(name, cut + 1), 0xC0) == 0x80 do
		cut -= 1
	end
	return string.sub(name, 1, cut)
end

function Protocol.encodeWaypoints(list: { Waypoint }, revision: number): buffer
	local count = math.min(#list, Protocol.MAX_WAYPOINTS)
	local size = 5
	local names = table.create(count)
	for i = 1, count do
		names[i] = Protocol.truncateName(list[i].name)
		size += 16 + #names[i]
	end
	local b = buffer.create(size)
	buffer.writeu32(b, 0, revision)
	buffer.writeu8(b, 4, count)
	local o = 5
	for i = 1, count do
		local w = list[i]
		buffer.writei32(b, o, w.x)
		buffer.writei32(b, o + 4, w.y)
		buffer.writei32(b, o + 8, w.z)
		buffer.writeu8(b, o + 12, w.color[1])
		buffer.writeu8(b, o + 13, w.color[2])
		buffer.writeu8(b, o + 14, w.color[3])
		buffer.writeu8(b, o + 15, #names[i])
		buffer.writestring(b, o + 16, names[i])
		o += 16 + #names[i]
	end
	return b
end

-- Returns the list and its revision, or nil when the payload is malformed.
function Protocol.decodeWaypoints(b: buffer): ({ Waypoint }?, number)
	local len = buffer.len(b)
	if len < 5 then
		return nil, 0
	end
	local revision = buffer.readu32(b, 0)
	local count = buffer.readu8(b, 4)
	if count > Protocol.MAX_WAYPOINTS then
		return nil, 0
	end
	local list: { Waypoint } = {}
	local o = 5
	for _ = 1, count do
		if o + 16 > len then
			return nil, 0
		end
		local nameLength = buffer.readu8(b, o + 15)
		if nameLength > Protocol.MAX_WAYPOINT_NAME or o + 16 + nameLength > len then
			return nil, 0
		end
		local x, y, z = buffer.readi32(b, o), buffer.readi32(b, o + 4), buffer.readi32(b, o + 8)
		if math.abs(x) > Protocol.MAX_COORDINATE or math.abs(z) > Protocol.MAX_COORDINATE or math.abs(y) > 4096 then
			return nil, 0
		end
		table.insert(list, {
			x = x,
			y = y,
			z = z,
			color = { buffer.readu8(b, o + 12), buffer.readu8(b, o + 13), buffer.readu8(b, o + 14) },
			name = buffer.readstring(b, o + 16, nameLength),
		})
		o += 16 + nameLength
	end
	if o ~= len then
		return nil, 0
	end
	return list, revision
end

--[[ Structure blocks and jigsaw blocks ]]

-- What a StructureBlock message asks (client -> server). `settings` for every op but "open",
-- `transfer` for "load" (0: by name).
export type StructureBlockRequest = {
	x: number,
	y: number,
	z: number,
	op: string, -- "open" | "update" | "save" | "load" | "detect"
	settings: Settings.StructureSettings?,
	transfer: number,
}
-- What a Jigsaw message asks (client -> server): `settings` for "update" and "generate", `levels`
-- (0..7) and `keepJigsaws` for "generate".
export type JigsawRequest = {
	x: number,
	y: number,
	z: number,
	op: string, -- "open" | "update" | "generate"
	settings: Settings.JigsawSettings?,
	levels: number,
	keepJigsaws: boolean,
}
-- A structure block's or jigsaw's state (server -> client); settings nil: it is gone.
export type StructureBlockRecord = { x: number, y: number, z: number, settings: Settings.StructureSettings? }
export type JigsawRecord = { x: number, y: number, z: number, settings: Settings.JigsawSettings? }

Protocol.StructureOp = table.freeze({ "open", "update", "save", "load", "detect" })
Protocol.JigsawOp = table.freeze({ "open", "update", "generate" })

local STRUCTURE_OP_CODE: { [string]: number } = {}
for code, op in Protocol.StructureOp do
	STRUCTURE_OP_CODE[op] = code
end
local JIGSAW_OP_CODE: { [string]: number } = {}
for code, op in Protocol.JigsawOp do
	JIGSAW_OP_CODE[op] = code
end

-- Bytes of a position (i32 x, u16 y, i32 z).
local POSITION_BYTES = 10

local function writePosition(b: buffer, o: number, x: number, y: number, z: number)
	buffer.writei32(b, o, x)
	buffer.writeu16(b, o + 4, y)
	buffer.writei32(b, o + 6, z)
end

-- A position read at `o`, nil when it is beyond MAX_COORDINATE.
local function readPosition(b: buffer, o: number): (number?, number, number)
	local x, y, z = buffer.readi32(b, o), buffer.readu16(b, o + 4), buffer.readi32(b, o + 6)
	if math.abs(x) > Protocol.MAX_COORDINATE or math.abs(z) > Protocol.MAX_COORDINATE then
		return nil, 0, 0
	end
	return x, y, z
end

function Protocol.encodeStructureBlock(request: StructureBlockRequest): buffer
	local code = STRUCTURE_OP_CODE[request.op]
	assert(code, `Unknown structure block op {request.op}`)
	local settings = request.settings
	local size = POSITION_BYTES + 1
	if code ~= 1 then
		size += Settings.structureBytes(settings or Settings.defaultStructure())
	end
	if request.op == "load" then
		size += 4
	end
	local b = buffer.create(size)
	writePosition(b, 0, request.x, request.y, request.z)
	buffer.writeu8(b, POSITION_BYTES, code)
	local o = POSITION_BYTES + 1
	if code ~= 1 then
		o = Settings.writeStructure(b, o, settings or Settings.defaultStructure())
	end
	if request.op == "load" then
		buffer.writeu32(b, o, clampInt(request.transfer, 0, 4294967295))
	end
	return b
end

-- The request in a StructureBlock message, or nil when it is malformed (wrong length, unknown op,
-- bad settings, a position beyond MAX_COORDINATE).
function Protocol.decodeStructureBlock(b: buffer): StructureBlockRequest?
	local len = buffer.len(b)
	if len < POSITION_BYTES + 1 then
		return nil
	end
	local x, y, z = readPosition(b, 0)
	local op = Protocol.StructureOp[buffer.readu8(b, POSITION_BYTES)]
	if x == nil or op == nil then
		return nil
	end
	local o = POSITION_BYTES + 1
	local settings: Settings.StructureSettings? = nil
	if op ~= "open" then
		local ok, read, after = Settings.readStructure(b, o, len)
		if not ok then
			return nil
		end
		settings, o = read, after
	end
	local transfer = 0
	if op == "load" then
		if o + 4 > len then
			return nil
		end
		transfer = buffer.readu32(b, o)
		o += 4
	end
	if o ~= len then
		return nil
	end
	return { x = x, y = y, z = z, op = op, settings = settings, transfer = transfer }
end

function Protocol.encodeJigsaw(request: JigsawRequest): buffer
	local code = JIGSAW_OP_CODE[request.op]
	assert(code, `Unknown jigsaw op {request.op}`)
	local settings = request.settings or Settings.defaultJigsaw()
	local size = POSITION_BYTES + 1
	if code ~= 1 then
		size += Settings.jigsawBytes(settings)
	end
	if request.op == "generate" then
		size += 2
	end
	local b = buffer.create(size)
	writePosition(b, 0, request.x, request.y, request.z)
	buffer.writeu8(b, POSITION_BYTES, code)
	local o = POSITION_BYTES + 1
	if code ~= 1 then
		o = Settings.writeJigsaw(b, o, settings)
	end
	if request.op == "generate" then
		buffer.writeu8(b, o, clampInt(request.levels, 0, Settings.MAX_LEVELS))
		buffer.writeu8(b, o + 1, if request.keepJigsaws then 1 else 0)
	end
	return b
end

-- The request in a Jigsaw message, or nil when it is malformed (wrong length, unknown op, bad
-- settings, levels beyond 7, a flag beyond 1, a position beyond MAX_COORDINATE).
function Protocol.decodeJigsaw(b: buffer): JigsawRequest?
	local len = buffer.len(b)
	if len < POSITION_BYTES + 1 then
		return nil
	end
	local x, y, z = readPosition(b, 0)
	local op = Protocol.JigsawOp[buffer.readu8(b, POSITION_BYTES)]
	if x == nil or op == nil then
		return nil
	end
	local o = POSITION_BYTES + 1
	local settings: Settings.JigsawSettings? = nil
	if op ~= "open" then
		local ok, read, after = Settings.readJigsaw(b, o, len)
		if not ok then
			return nil
		end
		settings, o = read, after
	end
	local levels, keep = 0, false
	if op == "generate" then
		if o + 2 > len then
			return nil
		end
		levels = buffer.readu8(b, o)
		local flag = buffer.readu8(b, o + 1)
		if levels > Settings.MAX_LEVELS or flag > 1 then
			return nil
		end
		keep = flag == 1
		o += 2
	end
	if o ~= len then
		return nil
	end
	return { x = x, y = y, z = z, op = op, settings = settings, levels = levels, keepJigsaws = keep }
end

-- Writes records (position, u8 present, settings) after a u8 flags and u32 count.
local function encodeRecords<T>(
	records: { { x: number, y: number, z: number, settings: T? } },
	open: boolean?,
	bytes: (T) -> number,
	write: (buffer, number, T) -> number
): buffer
	local size = 5
	for _, record in records do
		size += POSITION_BYTES + 1
		local settings = record.settings
		if settings ~= nil then
			size += bytes(settings)
		end
	end
	local b = buffer.create(size)
	buffer.writeu8(b, 0, if open then 1 else 0)
	buffer.writeu32(b, 1, #records)
	local o = 5
	for _, record in records do
		writePosition(b, o, record.x, record.y, record.z)
		local settings = record.settings
		buffer.writeu8(b, o + POSITION_BYTES, if settings ~= nil then 1 else 0)
		o += POSITION_BYTES + 1
		if settings ~= nil then
			o = write(b, o, settings)
		end
	end
	return b
end

-- Reads what `encodeRecords` wrote: the records (nil when malformed) and the open flag.
local function decodeRecords<T>(
	b: buffer,
	read: (buffer, number, number) -> (boolean, T?, number)
): ({ { x: number, y: number, z: number, settings: T? } }?, boolean)
	local len = buffer.len(b)
	if len < 5 then
		return nil, false
	end
	local flags = buffer.readu8(b, 0)
	local count = buffer.readu32(b, 1)
	-- (Every record takes at least a position and its present byte.)
	if flags > 1 or count > (len - 5) // (POSITION_BYTES + 1) then
		return nil, false
	end
	local records = table.create(count)
	local o = 5
	for i = 1, count do
		if o + POSITION_BYTES + 1 > len then
			return nil, false
		end
		local x, y, z = readPosition(b, o)
		local present = buffer.readu8(b, o + POSITION_BYTES)
		if x == nil or present > 1 then
			return nil, false
		end
		o += POSITION_BYTES + 1
		local settings: T? = nil
		if present == 1 then
			local ok, value, after = read(b, o, len)
			if not ok then
				return nil, false
			end
			settings, o = value, after
		end
		records[i] = { x = x, y = y, z = z, settings = settings }
	end
	if o ~= len then
		return nil, false
	end
	return records, flags == 1
end

-- A StructureBlocks message: `records` (settings nil: the block is gone); `open` answers the
-- player's open request (show the first record's screen).
function Protocol.encodeStructureBlocks(records: { StructureBlockRecord }, open: boolean?): buffer
	return encodeRecords(records, open, Settings.structureBytes, Settings.writeStructure)
end

-- The records of a StructureBlocks message (nil when malformed) and its open flag.
function Protocol.decodeStructureBlocks(b: buffer): ({ StructureBlockRecord }?, boolean)
	return decodeRecords(b, Settings.readStructure)
end

-- A Jigsaws message, the same way.
function Protocol.encodeJigsaws(records: { JigsawRecord }, open: boolean?): buffer
	return encodeRecords(records, open, Settings.jigsawBytes, Settings.writeJigsaw)
end

-- The records of a Jigsaws message (nil when malformed) and its open flag.
function Protocol.decodeJigsaws(b: buffer): ({ JigsawRecord }?, boolean)
	return decodeRecords(b, Settings.readJigsaw)
end

--[[ Structure text in pieces (both ways) ]]

export type StructureDataPiece = { transfer: number, index: number, count: number, text: string }
-- A text being received: its pieces so far (`joinStructureData`).
export type StructureDataAssembly = { count: number, received: number, bytes: number, pieces: { [number]: string } }

-- Bytes of text in one piece, the most pieces of one text, and the longest text (bytes).
Protocol.STRUCTURE_PIECE = math.clamp(math.floor(Config.Structures.DataPieceChars), 1, 60000)
Protocol.MAX_STRUCTURE_TEXT = math.max(1, math.floor(Config.Structures.MaxDataChars))
Protocol.MAX_STRUCTURE_PIECES = math.min(65535, math.ceil(Protocol.MAX_STRUCTURE_TEXT / Protocol.STRUCTURE_PIECE))
-- Texts one sender may have half received at once: a new one beyond this drops the others
-- (abandoned uploads), so a client can't keep the server holding many.
Protocol.MAX_OPEN_TRANSFERS = 2
local PIECE_HEADER = 10

function Protocol.encodeStructureData(piece: StructureDataPiece): buffer
	local text = string.sub(piece.text, 1, Protocol.STRUCTURE_PIECE)
	local b = buffer.create(PIECE_HEADER + #text)
	buffer.writeu32(b, 0, clampInt(piece.transfer, 0, 4294967295))
	buffer.writeu16(b, 4, clampInt(piece.index, 0, 65535))
	buffer.writeu16(b, 6, clampInt(piece.count, 0, 65535))
	buffer.writeu16(b, 8, #text)
	buffer.writestring(b, PIECE_HEADER, text)
	return b
end

-- The piece in a StructureData message, or nil when it is malformed (wrong length, transfer 0,
-- no pieces or more than MAX_STRUCTURE_PIECES, an index beyond the count, a piece longer than
-- STRUCTURE_PIECE).
function Protocol.decodeStructureData(b: buffer): StructureDataPiece?
	local len = buffer.len(b)
	if len < PIECE_HEADER then
		return nil
	end
	local transfer = buffer.readu32(b, 0)
	local index, count, length = buffer.readu16(b, 4), buffer.readu16(b, 6), buffer.readu16(b, 8)
	if
		transfer == 0
		or count < 1
		or count > Protocol.MAX_STRUCTURE_PIECES
		or index >= count
		or length > Protocol.STRUCTURE_PIECE
		or len ~= PIECE_HEADER + length
	then
		return nil
	end
	return { transfer = transfer, index = index, count = count, text = buffer.readstring(b, PIECE_HEADER, length) }
end

--[[
	`text` (cut to MAX_STRUCTURE_TEXT bytes) as the pieces of transfer `transfer`, STRUCTURE_PIECE
	bytes each (an empty text is one empty piece). Send each with encodeStructureData.
]]
function Protocol.splitStructureData(transfer: number, text: string): { StructureDataPiece }
	local all = string.sub(text, 1, Protocol.MAX_STRUCTURE_TEXT)
	local size = Protocol.STRUCTURE_PIECE
	local count = math.max(1, math.ceil(#all / size))
	local pieces: { StructureDataPiece } = table.create(count)
	for i = 1, count do
		pieces[i] = {
			transfer = transfer,
			index = i - 1,
			count = count,
			text = string.sub(all, (i - 1) * size + 1, i * size),
		}
	end
	return pieces
end

--[[
	Adds `piece` to the texts being received (`assemblies`, by transfer, kept by the caller per
	sender) and returns the whole text once its last piece arrived (and forgets the transfer).
	Returns nil and a message when the piece doesn't fit what came before (another count, an index
	received twice) or the text grows beyond MAX_STRUCTURE_TEXT; the transfer is dropped then.
	Pieces may arrive in any order. A sender starting a transfer again under a number already in
	progress should pick a new number: its old pieces would be mixed in. A new transfer while
	MAX_OPEN_TRANSFERS are half received drops those.
]]
function Protocol.joinStructureData(
	assemblies: { [number]: StructureDataAssembly },
	piece: StructureDataPiece
): (string?, string?)
	local assembly = assemblies[piece.transfer]
	if assembly == nil then
		local open = 0
		for _ in assemblies do
			open += 1
		end
		if open >= Protocol.MAX_OPEN_TRANSFERS then
			table.clear(assemblies)
		end
		assembly = { count = piece.count, received = 0, bytes = 0, pieces = {} }
		assemblies[piece.transfer] = assembly
	end
	if assembly.count ~= piece.count or assembly.pieces[piece.index] ~= nil or piece.index >= piece.count then
		assemblies[piece.transfer] = nil
		return nil, "The structure data arrived mixed up: paste it again"
	end
	assembly.bytes += #piece.text
	if assembly.bytes > Protocol.MAX_STRUCTURE_TEXT then
		assemblies[piece.transfer] = nil
		return nil, `The structure data is too long (at most {Protocol.MAX_STRUCTURE_TEXT} characters)`
	end
	assembly.pieces[piece.index] = piece.text
	assembly.received += 1
	if assembly.received < assembly.count then
		return nil, nil
	end
	assemblies[piece.transfer] = nil
	local parts = table.create(assembly.count)
	for i = 0, assembly.count - 1 do
		parts[i + 1] = assembly.pieces[i]
	end
	return table.concat(parts), nil
end

--[[ Player settings ]]

-- A device profile's chosen settings (SaveSettings and Settings; PlayerSettings.encode).
function Protocol.encodeSettings(profile: number, values: PlayerSettings.Values): buffer
	return PlayerSettings.encode(profile, values)
end

-- The profile and its settings, clamped; nil when malformed (PlayerSettings.decode).
function Protocol.decodeSettings(b: buffer): (number?, PlayerSettings.Values?)
	return PlayerSettings.decode(b)
end

--[[ Explosions (server -> client) ]]

-- An explosion at (x, y, z) (blocks) of `power`, and the knockback it gives the receiving player
-- (blocks per tick).
export type ExplosionEffect = { x: number, y: number, z: number, power: number, kx: number, ky: number, kz: number }

Protocol.EXPLOSION_BYTES = 28
-- Largest power and push an Explosion message may carry.
Protocol.MAX_EXPLOSION_POWER = 64
Protocol.MAX_KNOCKBACK = 10

function Protocol.encodeExplosion(effect: ExplosionEffect): buffer
	local b = buffer.create(Protocol.EXPLOSION_BYTES)
	buffer.writef32(b, 0, effect.x)
	buffer.writef32(b, 4, effect.y)
	buffer.writef32(b, 8, effect.z)
	buffer.writef32(b, 12, effect.power)
	buffer.writef32(b, 16, effect.kx)
	buffer.writef32(b, 20, effect.ky)
	buffer.writef32(b, 24, effect.kz)
	return b
end

-- The explosion of an Explosion message, or nil when it is malformed.
function Protocol.decodeExplosion(b: buffer): ExplosionEffect?
	if buffer.len(b) ~= Protocol.EXPLOSION_BYTES then
		return nil
	end
	local values = table.create(7)
	for i = 1, 7 do
		local value = buffer.readf32(b, (i - 1) * 4)
		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		values[i] = value
	end
	local power, kx, ky, kz = values[4], values[5], values[6], values[7]
	if
		power < 0
		or power > Protocol.MAX_EXPLOSION_POWER
		or math.sqrt(kx * kx + ky * ky + kz * kz) > Protocol.MAX_KNOCKBACK
	then
		return nil
	end
	return { x = values[1], y = values[2], z = values[3], power = power, kx = kx, ky = ky, kz = kz }
end

--[[ Thirst and temperature (Tough As Nails) ]]

Protocol.EXERTION_BYTES = 7

-- Movement that costs thirst (Shared/ToughAsNails/Exertion's report).
function Protocol.encodeExertion(report: Exertion.Report): buffer
	local b = buffer.create(Protocol.EXERTION_BYTES)
	buffer.writeu16(b, 0, math.clamp(report.sprintCm, 0, 65535))
	buffer.writeu16(b, 2, math.clamp(report.waterCm, 0, 65535))
	buffer.writeu8(b, 4, math.clamp(report.jumps, 0, 255))
	buffer.writeu8(b, 5, math.clamp(report.sprintJumps, 0, 255))
	buffer.writeu8(b, 6, if report.sprinting then 1 else 0)
	return b
end

-- The report, nil when malformed (wrong length, unknown flags).
function Protocol.decodeExertion(b: buffer): Exertion.Report?
	if buffer.len(b) ~= Protocol.EXERTION_BYTES then
		return nil
	end
	local flags = buffer.readu8(b, 6)
	if flags > 1 then
		return nil
	end
	return {
		sprintCm = buffer.readu16(b, 0),
		waterCm = buffer.readu16(b, 2),
		jumps = buffer.readu8(b, 4),
		sprintJumps = buffer.readu8(b, 5),
		sprinting = flags == 1,
	}
end

-- Drink actions (see the header).
Protocol.DrinkAction = table.freeze({
	Start = 1,
	Finish = 2,
	Cancel = 3,
	Hand = 4,
	Fill = 5,
})

-- A drink action; Hand and Fill carry the water source's cell.
function Protocol.encodeDrink(action: number, x: number?, y: number?, z: number?): buffer
	if action == Protocol.DrinkAction.Hand or action == Protocol.DrinkAction.Fill then
		local b = buffer.create(11)
		buffer.writeu8(b, 0, action)
		buffer.writei32(b, 1, x or 0)
		buffer.writeu16(b, 5, y or 0)
		buffer.writei32(b, 7, z or 0)
		return b
	end
	local b = buffer.create(1)
	buffer.writeu8(b, 0, action)
	return b
end

-- action (nil when malformed: unknown, wrong length, too far out), x, y, z (0 when none).
function Protocol.decodeDrink(b: buffer): (number?, number, number, number)
	local len = buffer.len(b)
	if len < 1 then
		return nil, 0, 0, 0
	end
	local action = buffer.readu8(b, 0)
	local actions = Protocol.DrinkAction
	if action == actions.Hand or action == actions.Fill then
		if len ~= 11 then
			return nil, 0, 0, 0
		end
		local x, y, z = buffer.readi32(b, 1), buffer.readu16(b, 5), buffer.readi32(b, 7)
		if math.abs(x) > Protocol.MAX_COORDINATE or math.abs(z) > Protocol.MAX_COORDINATE then
			return nil, 0, 0, 0
		end
		return action, x, y, z
	end
	if len ~= 1 or action < actions.Start or action > actions.Cancel then
		return nil, 0, 0, 0
	end
	return action, 0, 0, 0
end

-- A player's thirst and temperature as their HUD shows them (Survival).
export type SurvivalStatus = {
	thirstOn: boolean,
	temperatureOn: boolean,
	wet: boolean,
	-- TAN's Internal Warmth and Internal Chill are on.
	warmth: boolean,
	chill: boolean,
	thirst: number,
	hydration: number,
	exhaustion: number,
	-- The body temperature and its target (-10..10, Temperature's scale).
	temperature: number,
	target: number,
	-- Hypothermia and hyperthermia (0..Temperature.EXTREME_TICKS).
	frozen: number,
	heat: number,
	-- Ticks left of TAN's Thirst effect.
	effect: number,
	-- Seconds left of TAN's Climate Clemency.
	clemency: number,
}

Protocol.SURVIVAL_BYTES = 14

function Protocol.encodeSurvival(status: SurvivalStatus): buffer
	local b = buffer.create(Protocol.SURVIVAL_BYTES)
	local flags = (if status.thirstOn then 1 else 0)
		+ (if status.temperatureOn then 2 else 0)
		+ (if status.wet then 4 else 0)
		+ (if status.warmth then 8 else 0)
		+ (if status.chill then 16 else 0)
	local extreme = Temperature.EXTREME_TICKS
	buffer.writeu8(b, 0, flags)
	buffer.writeu8(b, 1, math.clamp(math.round(status.thirst), 0, 20))
	buffer.writeu8(b, 2, math.clamp(math.round(status.hydration * 10), 0, 200))
	buffer.writeu8(b, 3, math.clamp(math.round(status.exhaustion * 50), 0, 255))
	buffer.writeu8(b, 4, math.clamp(math.round(status.temperature), Temperature.MIN, Temperature.MAX) - Temperature.MIN)
	buffer.writeu8(b, 5, math.clamp(math.round(status.target), Temperature.MIN, Temperature.MAX) - Temperature.MIN)
	buffer.writeu16(b, 6, math.clamp(math.round(status.frozen), 0, extreme))
	buffer.writeu16(b, 8, math.clamp(math.round(status.heat), 0, extreme))
	buffer.writeu16(b, 10, math.clamp(math.round(status.effect), 0, 65535))
	buffer.writeu16(b, 12, math.clamp(math.ceil(status.clemency), 0, 65535))
	return b
end

-- The status, nil when malformed.
function Protocol.decodeSurvival(b: buffer): SurvivalStatus?
	if buffer.len(b) ~= Protocol.SURVIVAL_BYTES then
		return nil
	end
	local flags = buffer.readu8(b, 0)
	local thirst, hydration = buffer.readu8(b, 1), buffer.readu8(b, 2)
	local temperature, target = buffer.readu8(b, 4), buffer.readu8(b, 5)
	local frozen, heat = buffer.readu16(b, 6), buffer.readu16(b, 8)
	local span, extreme = Temperature.MAX - Temperature.MIN, Temperature.EXTREME_TICKS
	if
		flags > 31
		or thirst > 20
		or hydration > 200
		or temperature > span
		or target > span
		or frozen > extreme
		or heat > extreme
	then
		return nil
	end
	return {
		thirstOn = bit32.btest(flags, 1),
		temperatureOn = bit32.btest(flags, 2),
		wet = bit32.btest(flags, 4),
		warmth = bit32.btest(flags, 8),
		chill = bit32.btest(flags, 16),
		thirst = thirst,
		hydration = hydration / 10,
		exhaustion = buffer.readu8(b, 3) / 50,
		temperature = temperature + Temperature.MIN,
		target = target + Temperature.MIN,
		frozen = frozen,
		heat = heat,
		effect = buffer.readu16(b, 10),
		clemency = buffer.readu16(b, 12),
	}
end

--[[ Mobs ]]

-- Positions in Mobs messages are this many steps a block (i32: ±67 million blocks).
Protocol.MOB_POSITION_SCALE = 32
-- Mobs flags (see the header).
Protocol.MobFlag = table.freeze({ Hurt = 1, Burning = 2, Dying = 4, Fuse = 8 })

export type MobOp = {
	op: "spawn",
	id: number,
	kind: number,
	variant: number,
	x: number,
	y: number,
	z: number,
	yaw: number,
	health: number,
	flags: number,
	fuse: number,
} | {
	op: "state",
	id: number,
	x: number,
	y: number,
	z: number,
	yaw: number,
	health: number,
	flags: number,
	fuse: number,
} | { op: "remove", id: number } | {
	op: "arrow",
	id: number,
	x: number,
	y: number,
	z: number,
	tx: number,
	ty: number,
	tz: number,
} | { op: "push", id: number, kx: number, ky: number, kz: number }

local MOB_SPAWN, MOB_STATE, MOB_REMOVE, MOB_ARROW, MOB_PUSH = 1, 2, 3, 4, 5
local MOB_CODE = { spawn = MOB_SPAWN, state = MOB_STATE, remove = MOB_REMOVE, arrow = MOB_ARROW, push = MOB_PUSH }
-- Bytes after the op's u8 code and u32 id.
local MOB_SIZE = {
	[MOB_SPAWN] = 2 + 12 + 4,
	[MOB_STATE] = 12 + 4,
	[MOB_REMOVE] = 0,
	[MOB_ARROW] = 24,
	[MOB_PUSH] = 12,
}
local POSITION_LIMIT = 2 ^ 31 - 1

local function quantize(value: number): number
	local q = math.round(value * Protocol.MOB_POSITION_SCALE)
	if q ~= q then
		return 0
	end
	return math.clamp(q, -POSITION_LIMIT, POSITION_LIMIT)
end

-- A yaw (radians) as 1/256 turns.
function Protocol.mobYaw(yaw: number): number
	local turns = yaw / (2 * math.pi)
	if turns ~= turns or math.abs(turns) == math.huge then
		return 0
	end
	return math.round(turns * 256) % 256
end

local function u8(value: number): number
	if value ~= value then
		return 0
	end
	return math.clamp(math.round(value), 0, 255)
end

function Protocol.encodeMobs(ops: { MobOp }): buffer
	local size = 2
	for _, op in ops do
		size += 5 + MOB_SIZE[MOB_CODE[op.op]]
	end
	local b = buffer.create(size)
	buffer.writeu16(b, 0, #ops)
	local o = 2
	for _, op in ops do
		buffer.writeu8(b, o, MOB_CODE[op.op])
		buffer.writeu32(b, o + 1, op.id)
		o += 5
		if op.op == "spawn" then
			buffer.writeu8(b, o, op.kind)
			buffer.writeu8(b, o + 1, u8(op.variant))
			o += 2
		end
		if op.op == "spawn" or op.op == "state" then
			buffer.writei32(b, o, quantize(op.x))
			buffer.writei32(b, o + 4, quantize(op.y))
			buffer.writei32(b, o + 8, quantize(op.z))
			buffer.writeu8(b, o + 12, Protocol.mobYaw(op.yaw))
			buffer.writeu8(b, o + 13, u8(op.health))
			buffer.writeu8(b, o + 14, u8(op.flags))
			buffer.writeu8(b, o + 15, u8(op.fuse))
			o += 16
		elseif op.op == "arrow" then
			buffer.writei32(b, o, quantize(op.x))
			buffer.writei32(b, o + 4, quantize(op.y))
			buffer.writei32(b, o + 8, quantize(op.z))
			buffer.writei32(b, o + 12, quantize(op.tx))
			buffer.writei32(b, o + 16, quantize(op.ty))
			buffer.writei32(b, o + 20, quantize(op.tz))
			o += 24
		elseif op.op == "push" then
			buffer.writef32(b, o, op.kx)
			buffer.writef32(b, o + 4, op.ky)
			buffer.writef32(b, o + 8, op.kz)
			o += 12
		end
	end
	return b
end

-- The ops of a Mobs message, nil when malformed (see the header). `kinds`: how many mob kinds
-- there are (Shared/Entities/MobList.COUNT).
function Protocol.decodeMobs(b: buffer, kinds: number): { MobOp }?
	local len = buffer.len(b)
	if len < 2 then
		return nil
	end
	local count = buffer.readu16(b, 0)
	local ops: { MobOp } = table.create(count)
	local o = 2
	local scale = Protocol.MOB_POSITION_SCALE
	local turn = 2 * math.pi / 256
	for _ = 1, count do
		if o + 5 > len then
			return nil
		end
		local code = buffer.readu8(b, o)
		local id = buffer.readu32(b, o + 1)
		local size = MOB_SIZE[code]
		if size == nil or o + 5 + size > len then
			return nil
		end
		o += 5
		if code == MOB_SPAWN then
			local kind = buffer.readu8(b, o)
			if kind < 1 or kind > kinds then
				return nil
			end
			table.insert(ops, {
				op = "spawn",
				id = id,
				kind = kind,
				variant = buffer.readu8(b, o + 1),
				x = buffer.readi32(b, o + 2) / scale,
				y = buffer.readi32(b, o + 6) / scale,
				z = buffer.readi32(b, o + 10) / scale,
				yaw = buffer.readu8(b, o + 14) * turn,
				health = buffer.readu8(b, o + 15),
				flags = buffer.readu8(b, o + 16),
				fuse = buffer.readu8(b, o + 17),
			})
		elseif code == MOB_STATE then
			table.insert(ops, {
				op = "state",
				id = id,
				x = buffer.readi32(b, o) / scale,
				y = buffer.readi32(b, o + 4) / scale,
				z = buffer.readi32(b, o + 8) / scale,
				yaw = buffer.readu8(b, o + 12) * turn,
				health = buffer.readu8(b, o + 13),
				flags = buffer.readu8(b, o + 14),
				fuse = buffer.readu8(b, o + 15),
			})
		elseif code == MOB_REMOVE then
			table.insert(ops, { op = "remove", id = id })
		elseif code == MOB_ARROW then
			table.insert(ops, {
				op = "arrow",
				id = id,
				x = buffer.readi32(b, o) / scale,
				y = buffer.readi32(b, o + 4) / scale,
				z = buffer.readi32(b, o + 8) / scale,
				tx = buffer.readi32(b, o + 12) / scale,
				ty = buffer.readi32(b, o + 16) / scale,
				tz = buffer.readi32(b, o + 20) / scale,
			})
		else
			local kx, ky, kz = buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)
			if
				not (kx == kx and ky == ky and kz == kz)
				or math.sqrt(kx * kx + ky * ky + kz * kz) > Protocol.MAX_KNOCKBACK
			then
				return nil
			end
			table.insert(ops, { op = "push", id = id, kx = kx, ky = ky, kz = kz })
		end
		o += size
	end
	if o ~= len then
		return nil
	end
	return ops
end

function Protocol.encodeAttack(id: number): buffer
	local b = buffer.create(4)
	buffer.writeu32(b, 0, id)
	return b
end

-- The mob id of an Attack message, nil when malformed.
function Protocol.decodeAttack(b: buffer): number?
	if buffer.len(b) ~= 4 then
		return nil
	end
	return buffer.readu32(b, 0)
end

-- Eat actions (see the header).
Protocol.EatAction = table.freeze({ Start = 1, Finish = 2, Cancel = 3 })

function Protocol.encodeEat(action: number): buffer
	local b = buffer.create(1)
	buffer.writeu8(b, 0, action)
	return b
end

-- The action of an Eat message, nil when malformed.
function Protocol.decodeEat(b: buffer): number?
	if buffer.len(b) ~= 1 then
		return nil
	end
	local action = buffer.readu8(b, 0)
	if action < Protocol.EatAction.Start or action > Protocol.EatAction.Cancel then
		return nil
	end
	return action
end

--[[ Status effects (server -> client) ]]

Protocol.EFFECT_BYTES = 7

-- A player's status effects (Effects message).
function Protocol.encodeEffects(entries: { Effects.Entry }): buffer
	local count = math.min(#entries, Effects.COUNT)
	local b = buffer.create(1 + count * Protocol.EFFECT_BYTES)
	buffer.writeu8(b, 0, count)
	for i = 1, count do
		local entry = entries[i]
		local o = 1 + (i - 1) * Protocol.EFFECT_BYTES
		buffer.writeu8(b, o, entry.effect)
		buffer.writeu8(b, o + 1, math.clamp(entry.amplifier, 0, Effects.MAX_AMPLIFIER))
		buffer.writei32(b, o + 2, math.clamp(math.floor(entry.ticks), Effects.INFINITE, 2 ^ 31 - 1))
		buffer.writeu8(b, o + 6, (if entry.ambient then 1 else 0) + (if entry.paused then 2 else 0))
	end
	return b
end

-- The effects of an Effects message, nil when it is malformed.
function Protocol.decodeEffects(b: buffer): { Effects.Entry }?
	local len = buffer.len(b)
	if len < 1 then
		return nil
	end
	local count = buffer.readu8(b, 0)
	if count > Effects.COUNT or len ~= 1 + count * Protocol.EFFECT_BYTES then
		return nil
	end
	local entries: { Effects.Entry } = table.create(count)
	local seen: { [number]: boolean } = {}
	for i = 1, count do
		local o = 1 + (i - 1) * Protocol.EFFECT_BYTES
		local effect = buffer.readu8(b, o)
		local ticks = buffer.readi32(b, o + 2)
		local flags = buffer.readu8(b, o + 6)
		if not Effects.isValid(effect) or seen[effect] or ticks < Effects.INFINITE or flags > 3 then
			return nil
		end
		seen[effect] = true
		entries[i] = {
			effect = effect,
			amplifier = buffer.readu8(b, o + 1),
			ticks = ticks,
			ambient = bit32.btest(flags, 1),
			paused = bit32.btest(flags, 2),
		}
	end
	return entries
end

--[[ Progression (knowledge, Ages, skills) ]]

-- A node to unlock (UnlockSkill): its place in Skills' list.
function Protocol.encodeUnlockSkill(skill: number): buffer
	local b = buffer.create(1)
	buffer.writeu8(b, 0, math.clamp(skill, 0, 255))
	return b
end

-- The node's place, nil when malformed (wrong length, no such node).
function Protocol.decodeUnlockSkill(b: buffer): number?
	if buffer.len(b) ~= 1 then
		return nil
	end
	local skill = buffer.readu8(b, 0)
	if skill < 1 or skill > Progression.Skills.count then
		return nil
	end
	return skill
end

function Protocol.encodeProgress(status: Progression.Status): buffer
	local Skills, Knowledge, Ages = Progression.Skills, Progression.Knowledge, Progression.Ages
	local skills: { number } = {}
	for id in status.skills do
		local skill = Skills.byId(id)
		if skill then
			table.insert(skills, skill.index)
		end
	end
	table.sort(skills)
	local categories = #Knowledge.CATEGORIES
	local milestones = #Ages.MILESTONES
	local bytes = (milestones + 7) // 8
	local b = buffer.create(4 + 1 + 1 + #skills + 1 + categories * 2 + 1 + bytes)
	buffer.writeu32(b, 0, math.clamp(math.floor(status.points), 0, Knowledge.MAX_POINTS))
	buffer.writeu8(b, 4, math.clamp(status.age, 1, Ages.count))
	buffer.writeu8(b, 5, #skills)
	local offset = 6
	for _, index in skills do
		buffer.writeu8(b, offset, index)
		offset += 1
	end
	buffer.writeu8(b, offset, categories)
	offset += 1
	for _, category in Knowledge.CATEGORIES do
		buffer.writeu16(b, offset, math.clamp(status.counts[category] or 0, 0, 65535))
		offset += 2
	end
	buffer.writeu8(b, offset, milestones)
	offset += 1
	for i = 1, milestones do
		if status.milestones[i] then
			local at = offset + (i - 1) // 8
			buffer.writeu8(b, at, bit32.bor(buffer.readu8(b, at), bit32.lshift(1, (i - 1) % 8)))
		end
	end
	return b
end

-- The status, nil when malformed.
function Protocol.decodeProgress(b: buffer): Progression.Status?
	local Skills, Knowledge, Ages = Progression.Skills, Progression.Knowledge, Progression.Ages
	local len = buffer.len(b)
	if len < 6 then
		return nil
	end
	local points, age, n = buffer.readu32(b, 0), buffer.readu8(b, 4), buffer.readu8(b, 5)
	if points > Knowledge.MAX_POINTS or age < 1 or age > Ages.count or len < 6 + n + 1 then
		return nil
	end
	local skills: { [string]: boolean } = {}
	local offset = 6
	for _ = 1, n do
		local skill = Skills.get(buffer.readu8(b, offset))
		if skill == nil then
			return nil
		end
		skills[skill.id] = true
		offset += 1
	end
	local categories = buffer.readu8(b, offset)
	offset += 1
	if categories ~= #Knowledge.CATEGORIES or len < offset + categories * 2 + 1 then
		return nil
	end
	local counts: { [string]: number } = {}
	for _, category in Knowledge.CATEGORIES do
		counts[category] = buffer.readu16(b, offset)
		offset += 2
	end
	local milestones = buffer.readu8(b, offset)
	offset += 1
	if milestones ~= #Ages.MILESTONES or len ~= offset + (milestones + 7) // 8 then
		return nil
	end
	local met: { boolean } = {}
	for i = 1, milestones do
		met[i] = bit32.btest(buffer.readu8(b, offset + (i - 1) // 8), bit32.lshift(1, (i - 1) % 8))
	end
	return { points = points, age = age, skills = skills, counts = counts, milestones = met }
end

--[[ The title screen (Players/WorldMenu, client Ui/MainMenu) ]]

-- Longest texts (bytes) a CreateWorld carries: WorldSettings' 32 characters, 4 bytes each at most.
Protocol.MAX_WORLD_NAME = 128
Protocol.MAX_WORLD_TYPE = 64
Protocol.MAX_WORLD_OPTIONS = 1024
Protocol.MAX_WORLD_SEED = 128
Protocol.MAX_MENU_TEXT = 256

-- The title screen's states (MenuState).
Protocol.MenuState = table.freeze({
	Waiting = 0,
	Creating = 1,
	Ready = 2,
	Failed = 3,
})

-- A CreateWorld request (Shared/WorldSettings.Request with the options still encoded).
export type CreateWorld = {
	name: string,
	gameMode: string,
	difficulty: number,
	allowCommands: boolean,
	structures: boolean,
	worldType: string,
	-- WorldTypes.encodeOptions.
	options: string,
	seed: string,
}

-- Writes `texts` as u16 length + bytes each from `offset`; returns the offset after them.
local function writeTexts(b: buffer, offset: number, texts: { string }): number
	for _, text in texts do
		buffer.writeu16(b, offset, #text)
		buffer.writestring(b, offset + 2, text)
		offset += 2 + #text
	end
	return offset
end

-- Reads `limits` texts (u16 length + valid UTF-8 bytes, at most each limit) from `offset`: nil
-- when one is malformed or more bytes follow.
local function readTexts(b: buffer, offset: number, limits: { number }): { string }?
	local len = buffer.len(b)
	local texts = {}
	for _, limit in limits do
		if offset + 2 > len then
			return nil
		end
		local n = buffer.readu16(b, offset)
		if n > limit or offset + 2 + n > len then
			return nil
		end
		local text = buffer.readstring(b, offset + 2, n)
		if utf8.len(text) == nil then
			return nil
		end
		table.insert(texts, text)
		offset += 2 + n
	end
	if offset ~= len then
		return nil
	end
	return texts
end

-- `text` cut to at most `limit` bytes, at the start of a character (so it stays valid UTF-8).
local function cut(text: string, limit: number): string
	if #text <= limit then
		return text
	end
	local stop = limit
	-- (Back over continuation bytes, 0x80..0xBF, to the character the cut fell in.)
	while stop > 0 do
		local byte = string.byte(text, stop + 1)
		if byte < 0x80 or byte >= 0xC0 then
			break
		end
		stop -= 1
	end
	return string.sub(text, 1, stop)
end

function Protocol.encodeCreateWorld(request: CreateWorld): buffer
	local texts = {
		cut(request.name, Protocol.MAX_WORLD_NAME),
		cut(request.worldType, Protocol.MAX_WORLD_TYPE),
		cut(request.options, Protocol.MAX_WORLD_OPTIONS),
		cut(request.seed, Protocol.MAX_WORLD_SEED),
	}
	local size = 3
	for _, text in texts do
		size += 2 + #text
	end
	local b = buffer.create(size)
	buffer.writeu8(b, 0, GameMode.id(request.gameMode))
	buffer.writeu8(b, 1, request.difficulty)
	buffer.writeu8(b, 2, (if request.allowCommands then 1 else 0) + (if request.structures then 2 else 0))
	writeTexts(b, 3, texts)
	return b
end

-- The request, nil when the payload is malformed (Spectator too: the screen has no such choice).
function Protocol.decodeCreateWorld(b: buffer): CreateWorld?
	if buffer.len(b) < 3 then
		return nil
	end
	local mode = GameMode.fromId(buffer.readu8(b, 0))
	local difficulty = buffer.readu8(b, 1)
	local flags = buffer.readu8(b, 2)
	if mode == nil or mode == GameMode.SPECTATOR or difficulty > 3 or flags > 3 then
		return nil
	end
	local texts = readTexts(
		b,
		3,
		{ Protocol.MAX_WORLD_NAME, Protocol.MAX_WORLD_TYPE, Protocol.MAX_WORLD_OPTIONS, Protocol.MAX_WORLD_SEED }
	)
	if texts == nil then
		return nil
	end
	return {
		name = texts[1],
		gameMode = mode,
		difficulty = difficulty,
		allowCommands = bit32.btest(flags, 1),
		structures = bit32.btest(flags, 2),
		worldType = texts[2],
		options = texts[3],
		seed = texts[4],
	}
end

function Protocol.encodeMenuState(state: number, operator: string, world: string): buffer
	local texts = { cut(operator, Protocol.MAX_MENU_TEXT), cut(world, Protocol.MAX_MENU_TEXT) }
	local b = buffer.create(1 + 4 + #texts[1] + #texts[2])
	buffer.writeu8(b, 0, state)
	writeTexts(b, 1, texts)
	return b
end

-- state (nil when malformed), the operator's name, the world's name.
function Protocol.decodeMenuState(b: buffer): (number?, string, string)
	if buffer.len(b) < 1 then
		return nil, "", ""
	end
	local state = buffer.readu8(b, 0)
	local texts = readTexts(b, 1, { Protocol.MAX_MENU_TEXT, Protocol.MAX_MENU_TEXT })
	if state > Protocol.MenuState.Failed or texts == nil then
		return nil, "", ""
	end
	return state, texts[1], texts[2]
end

function Protocol.encodeCreateWorldResult(ok: boolean, message: string): buffer
	local text = cut(message, Protocol.MAX_MENU_TEXT)
	local b = buffer.create(3 + #text)
	buffer.writeu8(b, 0, if ok then 1 else 0)
	writeTexts(b, 1, { text })
	return b
end

-- ok (nil when malformed), the message.
function Protocol.decodeCreateWorldResult(b: buffer): (boolean?, string)
	if buffer.len(b) < 1 then
		return nil, ""
	end
	local flag = buffer.readu8(b, 0)
	local texts = readTexts(b, 1, { Protocol.MAX_MENU_TEXT })
	if flag > 1 or texts == nil then
		return nil, ""
	end
	return flag == 1, texts[1]
end

return Protocol
