--!strict
--[[
	Opening and closing doors (Minecraft's DoorBlock.use): a Use on a door half (BlockList `menu`
	"Door", sent by the client's right click; Players/Inventories checked the player is alive and
	within reach) opens or closes both halves, and the door's double door partner with them
	(Shared/Blocks/Doors.use, pure). Everyone but spectators may (GameMode.canInteract: adventure
	players open doors, as in Minecraft), at most USES_PER_SECOND a second (bursts of twice that).

	The using client predicts the same change (Interaction/BlockInteraction), so it hears the door
	at once; everyone else near hears block.wooden_door.open or .close from here, once for a
	double door. A refused use sends the player the blocks around the door as they are, which
	undoes the prediction.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Doors = require(Shared.Blocks.Doors)
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Inventories = require(script.Parent.Inventories)

local USES_PER_SECOND = 10

local DoorUse = {}

local budgets: { [Player]: { tokens: number, last: number } } = {}
local started = false

local function mayUse(player: Player): boolean
	local now = os.clock()
	local budget = budgets[player]
	if budget == nil then
		budget = { tokens = USES_PER_SECOND * 2, last = now }
		budgets[player] = budget
	end
	budget.tokens = math.min(USES_PER_SECOND * 2, budget.tokens + (now - budget.last) * USES_PER_SECOND)
	budget.last = now
	if budget.tokens < 1 then
		return false
	end
	budget.tokens -= 1
	return true
end

function DoorUse.start(net: ServerNet.ServerNet, world: WorldServer.World)
	assert(not started, "DoorUse.start was already called")
	started = true
	local function peek(x: number, y: number, z: number): number?
		return world:peekBlock(x, y, z)
	end
	-- The cells a client may have predicted for a use at (x, y, z), as they are: the door's
	-- column and its neighbours' (a partner's), a block above and below.
	local function resend(player: Player, x: number, y: number, z: number)
		local edits: { number } = {}
		for _, d in { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			for dy = -1, 1 do
				local block = peek(x + d[1], y + dy, z + d[2])
				if block ~= nil then
					table.insert(edits, x + d[1])
					table.insert(edits, y + dy)
					table.insert(edits, z + d[2])
					table.insert(edits, block)
				end
			end
		end
		if #edits > 0 then
			net.send(player, Protocol.ServerMessage.Edits, Protocol.encodeEdits(edits))
		end
	end
	Inventories.onMenu("Door", function(player: Player, x: number, y: number, z: number, block: number)
		if not GameMode.canInteract(GameMode.of(player)) or not mayUse(player) then
			resend(player, x, y, z)
			return
		end
		local changes = Doors.use(block, peek, x, y, z)
		if #changes == 0 then
			resend(player, x, y, z)
			return
		end
		for _, change in changes do
			world:setBlock(change.x, change.y, change.z, change.block)
		end
		if Sounds.allow(player) then
			local first = changes[1]
			local sound = if Doors.opens(changes) then "block.wooden_door.open" else "block.wooden_door.close"
			Sounds.play(sound, first.x + 0.5, first.y + 1, first.z + 0.5, player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		budgets[player] = nil
	end)
end

return DoorUse
