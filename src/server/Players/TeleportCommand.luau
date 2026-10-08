--!strict
--[[
	The /tp chat command (alias /teleport), without the Roblox parts (Players/TeleportCommands), so
	the tests can run it. Minecraft 1.20.1's TeleportCommand, its common forms:

	    /tp <x> <y> <z>                    yourself to a position
	    /tp <targets> <x> <y> <z>          players to a position
	    /tp <destination>                  yourself to a player
	    /tp <targets> <destination>        players to a player

	  Coordinates  blocks, true world coordinates (what F3 and /locate show, with or without the
	               floating origin): a number, "~" (the player's own) or "~n" (n more), as
	               Minecraft's Vec3Argument: a whole number for x or z means the block's centre
	               (100 is 100.5), y is taken as written. Beyond Protocol.MAX_COORDINATE (x, z) or
	               PlayerSync's MIN_Y..MAX_Y (y): "Invalid position for teleport".
	  Targets      @s (yourself), @a (everyone), a name or display name or the start of one
	               (Players/GameModeCommand.findPlayers); a destination must be one player.
	  Landing      Minecraft puts you exactly there, in rock or mid-air. Here (a deviation) a
	               survival or adventure player who would land unsafe (Players/SafeSpot.isSafe:
	               the feet's block, standing room, no lava around) stands on the block instead
	               when that is safe (a chest /locate poi found), else on the column's safe top
	               (SafeSpot.column; a /locate link's "~" y lands there), else exactly as asked.
	               Creative and spectator players go exactly where asked, as to a player.
	  Answers      Minecraft's: "Teleported Steve to 100.500000, 64.000000, 200.500000" (its %f),
	               "Teleported 3 entities to ...", "Teleported Steve to Alex"; "No player was
	               found".
	  Who may      the operators' permission (Minecraft's level 2: Players/Operators).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local PlayerSync = require(Shared.Net.PlayerSync)
local Protocol = require(Shared.Net.Protocol)

local GameModeCommand = require(script.Parent.GameModeCommand)

-- A player the command can name, with where they stand (feet, blocks; x nil: nowhere).
export type Candidate = {
	key: any,
	name: string,
	displayName: string,
	mode: string,
	x: number?,
	y: number,
	z: number,
}

export type Context = {
	mayUse: boolean,
	source: Candidate,
	players: { Candidate },
	-- Can a player stand with their feet in block (x, y, z)? And the column's safe top (nil: none).
	isSafe: (x: number, y: number, z: number) -> boolean,
	column: (x: number, z: number) -> number?,
}

-- A move to make: the player, and the feet (blocks, doubles).
export type Move = { key: any, x: number, y: number, z: number }

export type Result = {
	moves: { Move },
	feedback: { string },
}

local TeleportCommand = {}

TeleportCommand.ALIASES = { "/tp", "/teleport" }
TeleportCommand.USAGE = "Usage: /tp <x> <y> <z>, /tp <targets> <x> <y> <z>, /tp <player>, /tp <targets> <player>"
TeleportCommand.DENIED = "You can't use /tp here"
TeleportCommand.INVALID = "Invalid position for teleport"
TeleportCommand.NO_PLAYER = "No player was found"
TeleportCommand.NOT_SINGLE = "Only one player is allowed, but the provided selector allows more than one"

local function words(text: string): { string }
	local list = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(list, word)
	end
	return list
end

-- Is `text` a /tp command?
function TeleportCommand.matches(text: string): boolean
	local first = string.match(text, "^%s*(%S+)")
	return first ~= nil and table.find(TeleportCommand.ALIASES, string.lower(first)) ~= nil
end

--[[
	A coordinate: a number, "~" or "~n" relative to `base` (nil: neither). A whole number without
	"~" is the block's centre when `centre` (x and z: Minecraft's Vec3Argument).
]]
function TeleportCommand.coordinate(text: string, base: number, centre: boolean): number?
	if string.sub(text, 1, 1) == "~" then
		local rest = string.sub(text, 2)
		if rest == "" then
			return base
		end
		local offset = tonumber(rest)
		return if offset and offset == offset and math.abs(offset) < math.huge then base + offset else nil
	end
	local value = tonumber(text)
	if value == nil or value ~= value or math.abs(value) == math.huge then
		return nil
	end
	if centre and not string.find(text, ".", 1, true) and value % 1 == 0 then
		return value + 0.5
	end
	return value
end

-- Minecraft's %f: six decimals.
function TeleportCommand.formatNumber(value: number): string
	return string.format("%f", value)
end

-- Where a player of `mode` asking for feet (x, y, z) lands (see the header).
function TeleportCommand.landing(
	mode: string,
	x: number,
	y: number,
	z: number,
	context: Context
): (number, number, number)
	if mode == GameMode.CREATIVE or mode == GameMode.SPECTATOR then
		return x, y, z
	end
	local bx, by, bz = math.floor(x), math.floor(y), math.floor(z)
	if context.isSafe(bx, by, bz) then
		return x, y, z
	elseif context.isSafe(bx, by + 1, bz) then
		return x, by + 1, z
	end
	local top = context.column(bx, bz)
	if top then
		return x, top, z
	end
	return x, y, z
end

-- The players `query` names (GameModeCommand.findPlayers' rules), or nil and why not.
local function findPlayers(query: string, context: Context): ({ Candidate }?, string?)
	local named: { GameModeCommand.Candidate } = {}
	local source: GameModeCommand.Candidate? = nil
	for _, candidate in context.players do
		local entry = { key = candidate, name = candidate.name, displayName = candidate.displayName }
		table.insert(named, entry)
		if candidate == context.source then
			source = entry
		end
	end
	local self = source
		or { key = context.source, name = context.source.name, displayName = context.source.displayName }
	local found, problem = GameModeCommand.findPlayers(query, self, named)
	if found == nil then
		return nil, problem
	end
	local list: { Candidate } = {}
	for _, entry in found do
		table.insert(list, entry.key :: Candidate)
	end
	return list, nil
end

local function valid(x: number, y: number, z: number): boolean
	local limit = Protocol.MAX_COORDINATE
	return math.abs(x) <= limit and math.abs(z) <= limit and y >= PlayerSync.MIN_Y and y <= PlayerSync.MAX_Y
end

--[[
	Runs a chat message as /tp: nil when it is something else; otherwise the moves to make and
	what to say.
]]
function TeleportCommand.run(text: string, context: Context): Result?
	if not TeleportCommand.matches(text) then
		return nil
	end
	local result: Result = { moves = {}, feedback = {} }
	local function say(message: string): Result
		table.insert(result.feedback, message)
		return result
	end
	if not context.mayUse then
		return say(TeleportCommand.DENIED)
	end
	local args = words(text)
	local count = #args - 1
	if count ~= 1 and count ~= 2 and count ~= 3 and count ~= 4 then
		return say(TeleportCommand.USAGE)
	end

	-- Who moves: yourself (1 or 3 arguments) or the targets named first.
	local targets: { Candidate }
	if count == 1 or count == 3 then
		targets = { context.source }
	else
		local found, problem = findPlayers(args[2], context)
		if found == nil then
			return say(problem or TeleportCommand.NO_PLAYER)
		end
		targets = found
	end

	-- To a player.
	if count <= 2 then
		local found, problem = findPlayers(args[#args], context)
		if found == nil then
			return say(problem or TeleportCommand.NO_PLAYER)
		elseif #found > 1 then
			return say(TeleportCommand.NOT_SINGLE)
		end
		local destination = found[1]
		local dx = destination.x
		if dx == nil then
			return say(TeleportCommand.NO_PLAYER)
		end
		for _, target in targets do
			table.insert(result.moves, { key = target.key, x = dx, y = destination.y, z = destination.z })
		end
		if #targets == 1 then
			return say(`Teleported {targets[1].name} to {destination.name}`)
		end
		return say(`Teleported {#targets} entities to {destination.name}`)
	end

	-- To a position: "~" is relative to the one who typed it (Minecraft's source position).
	local source = context.source
	local sx = source.x
	if
		sx == nil
		and (
			string.find(args[#args - 2], "~", 1, true)
			or string.find(args[#args - 1], "~", 1, true)
			or string.find(args[#args], "~", 1, true)
		)
	then
		return say(TeleportCommand.INVALID)
	end
	local baseX, baseY, baseZ = sx or 0, source.y, source.z
	local x = TeleportCommand.coordinate(args[#args - 2], baseX, true)
	local y = TeleportCommand.coordinate(args[#args - 1], baseY, false)
	local z = TeleportCommand.coordinate(args[#args], baseZ, true)
	if x == nil or y == nil or z == nil then
		return say(TeleportCommand.USAGE)
	elseif not valid(x, y, z) then
		return say(TeleportCommand.INVALID)
	end
	for _, target in targets do
		local fx, fy, fz = TeleportCommand.landing(target.mode, x, y, z, context)
		table.insert(result.moves, { key = target.key, x = fx, y = fy, z = fz })
	end
	local position =
		`{TeleportCommand.formatNumber(x)}, {TeleportCommand.formatNumber(y)}, {TeleportCommand.formatNumber(z)}`
	if #targets == 1 then
		return say(`Teleported {targets[1].name} to {position}`)
	end
	return say(`Teleported {#targets} entities to {position}`)
end

return TeleportCommand
