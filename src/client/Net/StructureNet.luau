--!strict
--[[
	Structure blocks and jigsaw blocks over the network, on the client.

	  in   StructureBlocks and Jigsaws messages (Net/Protocol) update the records
	       (World/StructureRecords) the screens, WAILA and the outlines read; one flagged `open`
	       answers this player's right click (BlockInteraction sends a Use, as for chests) and
	       opens the block's screen (Ui/StructureScreen). StructureData pieces bring back the
	       text a SAVE made (StructureRecords.downloads, which matches it to the SAVE by its name
	       and size), which the SAVE screen then shows.
	  out  the screens' buttons: StructureBlock and Jigsaw requests. Text pasted into the LOAD
	       screen goes first, as StructureData pieces of a new transfer number, at most
	       Config.Structures.DataPiecesPerSecond (StructureRecords.outbox, which also keeps the
	       request after its pieces), then the LOAD that names the transfer. The server keeps
	       a player's last two finished uploads, so LOADing the same text again (Minecraft's
	       second LOAD after "position prepared") names the same transfer without sending it
	       again.

	Records of blocks that are gone (broken while the player was far) are pruned every few
	seconds against the loaded blocks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Protocol = require(Shared.Net.Protocol)
local Settings = require(Shared.Structures.Settings)

local ClientNet = require(script.Parent.ClientNet)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local StructureRecords = require(script.Parent.Parent.World.StructureRecords)
local StructureScreen = require(script.Parent.Parent.Ui.StructureScreen)

type StructureSettings = Settings.StructureSettings
type JigsawSettings = Settings.JigsawSettings

-- Uploads the server keeps per player (server Structures/StructureServer.UPLOADS_KEPT).
local UPLOADS_KEPT = 2
-- Seconds between prunes of stale records.
local PRUNE_INTERVAL = 3

local StructureNet = {}

local records = StructureRecords.new()
local downloads = StructureRecords.downloads()
local outbox = StructureRecords.outbox(Config.Structures.DataPiecesPerSecond)
-- The last transfer number used, the recent uploads (oldest first) and the one going out.
local transfer = 0
local uploads: { { text: string, transfer: number } } = {}
local upload: { total: number }? = nil
local started = false

-- The structure blocks and jigsaws the client knows about.
function StructureNet.records(): StructureRecords.Records
	return records
end

local function send(kind: number, payload: buffer)
	-- (Behind an upload in progress, so a request never overtakes the LOAD after its pieces.)
	if outbox:pending() > 0 then
		outbox:push({ { kind = kind, payload = payload } })
	else
		ClientNet.send(kind, payload)
	end
end

-- The transfer of `text`: one the server still keeps, or a new one, queued in pieces.
local function uploadTransfer(text: string): number
	for _, done in uploads do
		if done.text == text then
			return done.transfer
		end
	end
	transfer = transfer % 4294967295 + 1
	local messages: { StructureRecords.Message } = {}
	for _, piece in Protocol.splitStructureData(transfer, text) do
		table.insert(
			messages,
			{ kind = Protocol.ClientMessage.StructureData, payload = Protocol.encodeStructureData(piece) }
		)
	end
	outbox:push(messages)
	upload = { total = outbox:pending() }
	table.insert(uploads, { text = text, transfer = transfer })
	while #uploads > UPLOADS_KEPT do
		table.remove(uploads, 1)
	end
	return transfer
end

local actions: StructureScreen.Actions = {
	structure = function(op: string, x: number, y: number, z: number, settings: StructureSettings, pasted: string?)
		if op == "save" then
			downloads:expect(x, y, z, settings.name, settings.size, os.clock())
		end
		local number = 0
		if op == "load" and pasted then
			number = uploadTransfer(pasted)
		end
		send(
			Protocol.ClientMessage.StructureBlock,
			Protocol.encodeStructureBlock({ x = x, y = y, z = z, op = op, settings = settings, transfer = number })
		)
	end,
	jigsaw = function(
		op: string,
		x: number,
		y: number,
		z: number,
		settings: JigsawSettings,
		levels: number,
		keepJigsaws: boolean
	)
		send(
			Protocol.ClientMessage.Jigsaw,
			Protocol.encodeJigsaw({
				x = x,
				y = y,
				z = z,
				op = op,
				settings = settings,
				levels = levels,
				keepJigsaws = keepJigsaws,
			})
		)
	end,
	savedText = function(x: number, y: number, z: number): string?
		return downloads:text(x, y, z)
	end,
	uploadStatus = function(): string?
		local current = upload
		if current == nil then
			return nil
		end
		local left = math.min(outbox:pending(), current.total)
		return `Uploading the pasted data: {current.total - left} of {current.total} pieces`
	end,
}

function StructureNet.start(world: ClientWorld.ClientWorld)
	if started then
		return
	end
	started = true
	StructureScreen.start(actions)

	ClientNet.on(Protocol.ServerMessage.StructureBlocks, function(payload: buffer)
		local list, open = Protocol.decodeStructureBlocks(payload)
		if list == nil then
			return
		end
		StructureRecords.applyStructures(records, list)
		for _, record in list do
			StructureScreen.structureRecord(record.x, record.y, record.z, record.settings)
		end
		local first = list[1]
		if open and first then
			local block = world:getBlock(first.x, first.y, first.z)
			local mode = if block then Blocks.structureMode(block) else nil
			if mode then
				local settings = first.settings or Settings.defaultStructure(mode)
				StructureScreen.openStructure(first.x, first.y, first.z, settings)
			end
		end
	end)

	ClientNet.on(Protocol.ServerMessage.Jigsaws, function(payload: buffer)
		local list, open = Protocol.decodeJigsaws(payload)
		if list == nil then
			return
		end
		StructureRecords.applyJigsaws(records, list)
		for _, record in list do
			StructureScreen.jigsawRecord(record.x, record.y, record.z, record.settings)
		end
		local first = list[1]
		if open and first then
			local block = world:getBlock(first.x, first.y, first.z)
			if block and Blocks.isJigsaw(block) then
				local front = Blocks.jigsawOrientation(block)
				local settings = first.settings or Settings.defaultJigsaw(front)
				StructureScreen.openJigsaw(first.x, first.y, first.z, block, settings)
			end
		end
	end)

	ClientNet.on(Protocol.ServerMessage.StructureData, function(payload: buffer)
		local piece = Protocol.decodeStructureData(payload)
		if piece == nil then
			return
		end
		local key, text = downloads:add(piece, os.clock())
		if key and text then
			StructureScreen.refresh()
		end
	end)

	local sincePrune = 0
	RunService.Heartbeat:Connect(function(dt: number)
		if outbox:pending() > 0 then
			for _, message in outbox:step(dt) do
				ClientNet.send(message.kind, message.payload)
			end
			if outbox:pending() == 0 then
				upload = nil
			end
			StructureScreen.refresh()
		else
			-- (Tokens build up while idle, up to a second's worth.)
			outbox:step(dt)
		end
		sincePrune += dt
		if sincePrune >= PRUNE_INTERVAL then
			sincePrune = 0
			StructureRecords.prune(records, function(x: number, y: number, z: number): number?
				return world:getBlock(x, y, z)
			end)
		end
	end)
end

return StructureNet
