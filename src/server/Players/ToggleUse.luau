--!strict
--[[
	Using blocks that toggle (BlockList `toggle`, `menu` "Toggle": the zombie apocalypse's bunker
	hatch, shut on the floor or open against the wall): a Use on one (sent by the client's right
	click; Players/Inventories checked the player is alive and within reach) swaps it for the
	block it names (Shared/Blocks/Toggles, pure) and plays that block's sound, as Players/DoorUse
	does for doors: everyone but spectators may (GameMode.canInteract), at most USES_PER_SECOND a
	second (bursts of twice that), and a refused use sends the player the block as it is.

	Nothing on the client predicts a toggle (Interaction/BlockInteraction predicts doors only), so
	the sound goes to everyone near, the user too (no `except`).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local Protocol = require(Shared.Net.Protocol)
local Toggles = require(Shared.Blocks.Toggles)

local WorldServer = require(script.Parent.Parent.World.WorldServer)
local ServerNet = require(script.Parent.Parent.Network.ServerNet)
local Sounds = require(script.Parent.Parent.Audio.Sounds)
local Inventories = require(script.Parent.Inventories)

local USES_PER_SECOND = 10

local ToggleUse = {}

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

function ToggleUse.start(net: ServerNet.ServerNet, world: WorldServer.World)
	assert(not started, "ToggleUse.start was already called")
	started = true
	-- The block at (x, y, z) as it is, to the player whose use was refused.
	local function resend(player: Player, x: number, y: number, z: number)
		local block = world:peekBlock(x, y, z)
		if block ~= nil then
			net.send(player, Protocol.ServerMessage.Edits, Protocol.encodeEdits({ x, y, z, block }))
		end
	end
	Inventories.onMenu("Toggle", function(player: Player, x: number, y: number, z: number, block: number)
		if not GameMode.canInteract(GameMode.of(player)) or not mayUse(player) then
			resend(player, x, y, z)
			return
		end
		local new, sound = Toggles.use(block)
		if new == nil then
			resend(player, x, y, z)
			return
		end
		world:setBlock(x, y, z, new)
		if sound and Sounds.allow(player) then
			Sounds.play(sound, x + 0.5, y + 0.5, z + 0.5)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		budgets[player] = nil
	end)
end

return ToggleUse
