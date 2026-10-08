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
	               when that is safe (a chest /locate poi found); else, for a y written as a
	               number or "~n", the nearest safe spot in the column within NEAR (16) blocks of
	               it (so "/tp ~ ~10 ~" in a cave stays in the cave, and in the open lands on the
	               ground below); else on the column's safe top (SafeSpot.column: where a plain
	               "~" y, "any height" as in /locate's links, goes first); else the nearest column
	               with one within LANDING_RADIUS (24) blocks (SafeSpot.find, as the map's
	               teleport: a lake's, a lava lake's, a geyser's, a ravine's or a cave entrance's
	               middle has no safe top); else afloat on open water (SafeSpot.waterSurface: an
	               ocean's middle, not its bed); else exactly as asked. Creative and spectator
	               players go exactly where asked, as to a player.
	  Answers      Minecraft's: "Teleported Steve to 100.500000, 64.000000, 200.500000" (its %f;
	               one player: where they landed, a deviation when that isn't where asked),
	               "Teleported 3 entities to ..." (where asked), "Teleported Steve to Alex"; "No
	               player was found".
	  Who may      the operators' permission (Minecraft's level 2: Players/Operators).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local GameMode = require(Shared.GameMode)
local PlayerSync = require(Shared.Net.PlayerSync)
local Protocol = require(Shared.Net.Protocol)

local GameModeCommand = require(script.Parent.GameModeCommand)
local SafeSpot = require(script.Parent.SafeSpot)
local WorldServer = require(script.Parent.Parent.World.WorldServer)

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
	-- The nearest safe spot within LANDING_RADIUS of column (x, z) (nil x: none), and the feet's
	-- block afloat on open water there (nil: no water on top). nil: not looked for.
	near: ((x: number, z: number) -> (number?, number, number))?,
	waterSurface: ((x: number, z: number) -> number?)?,
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
-- Blocks from a written y searched in its column, and around the column searched for a safe one.
TeleportCommand.NEAR = 16
TeleportCommand.LANDING_RADIUS = 24

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

--[[
	Where a player of `mode` asking for feet (x, y, z) lands (see the header). `anyHeight`: the y
	was a plain "~" (any height: the column's safe top before a spot near it).
]]
function TeleportCommand.landing(
	mode: string,
	x: number,
	y: number,
	z: number,
	context: Context,
	anyHeight: boolean?
): (number, number, number)
	if mode == GameMode.CREATIVE or mode == GameMode.SPECTATOR then
		return x, y, z
	end
	local isSafe = context.isSafe
	local bx, by, bz = math.floor(x), math.floor(y), math.floor(z)
	if isSafe(bx, by, bz) then
		return x, y, z
	elseif isSafe(bx, by + 1, bz) then
		return x, by + 1, z
	end
	if not anyHeight then
		-- (Nearest first: d below, then d + 1 above, by + 1 was looked at.)
		for d = 1, TeleportCommand.NEAR do
			if isSafe(bx, by - d, bz) then
				return x, by - d, z
			elseif isSafe(bx, by + d + 1, bz) then
				return x, by + d + 1, z
			end
		end
	end
	local top = context.column(bx, bz)
	if top then
		return x, top, z
	end
	local near = context.near
	if near then
		local nx, ny, nz = near(bx, bz)
		if nx then
			return nx + 0.5, ny, nz + 0.5
		end
	end
	local waterSurface = context.waterSurface
	local afloat = if waterSurface then waterSurface(bx, bz) else nil
	if afloat then
		return x, afloat, z
	end
	return x, y, z
end

--[[
	A Context on `world`'s blocks (Players/SafeSpot; a chunk may be generated to look): what
	Players/TeleportCommands runs /tp with.
]]
function TeleportCommand.worldContext(
	world: WorldServer.World,
	mayUse: boolean,
	source: Candidate,
	players: { Candidate }
): Context
	return {
		mayUse = mayUse,
		source = source,
		players = players,
		isSafe = function(x: number, y: number, z: number): boolean
			return SafeSpot.isSafe(world, x, y, z)
		end,
		column = function(x: number, z: number): number?
			return SafeSpot.column(world, x, z)
		end,
		near = function(x: number, z: number): (number?, number, number)
			return SafeSpot.find(world, x, z, TeleportCommand.LANDING_RADIUS)
		end,
		waterSurface = function(x: number, z: number): number?
			return SafeSpot.waterSurface(world, x, z)
		end,
	}
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
	-- (Where each game mode lands, worked out once: it may look at many columns.)
	local anyHeight = args[#args - 1] == "~"
	local landed: { [string]: { number } } = {}
	for _, target in targets do
		local spot = landed[target.mode]
		if spot == nil then
			local fx, fy, fz = TeleportCommand.landing(target.mode, x, y, z, context, anyHeight)
			spot = { fx, fy, fz }
			landed[target.mode] = spot
		end
		table.insert(result.moves, { key = target.key, x = spot[1], y = spot[2], z = spot[3] })
	end
	local function position(px: number, py: number, pz: number): string
		local format = TeleportCommand.formatNumber
		return `{format(px)}, {format(py)}, {format(pz)}`
	end
	if #targets == 1 then
		local move = result.moves[1]
		return say(`Teleported {targets[1].name} to {position(move.x, move.y, move.z)}`)
	end
	return say(`Teleported {#targets} entities to {position(x, y, z)}`)
end

return TeleportCommand
