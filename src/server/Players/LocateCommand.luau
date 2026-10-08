--!strict
--[[
	The /locate chat command, without the Roblox parts (those are in Players/LocateCommands), so
	the tests can run it. Minecraft 1.20.1's LocateCommand:

	    /locate structure <structure | #tag>   "The nearest outpost is at [1142, ~, 582] (1281 blocks away)"
	    /locate biome <biome | #tag>           "The nearest jungle is at [-672, 93, 640] (928 blocks away)"
	    /locate poi <type | #tag>              "The nearest chest is at [-46, 25, -13] (48 blocks away)"

	Ids and tags are Generation/Locate's registries (structures: the built-in kinds and the
	library's; biomes; points of interest: Shared/Poi), matched loosely ("minecraft:birch_forest",
	"BirchForest"); a tag's answer names the member found: "#mineshaft (mineshaft_overgrown)".

	  Answers   Minecraft's texts exactly (en_us): success, "Could not find a structure of type
	            "x" nearby", "Could not find a biome of type "x" within reasonable distance",
	            "... point of interest ...", "There is no structure with type "x"", "Can't find
	            element 'x' of type 'minecraft:worldgen/biome'" (and "Can't find tag ..."). The
	            coordinates are Minecraft's green "[x, y, z]": a link (`Link`: its bytes in the
	            text, and the command it suggests: "/tp @s x y z", chat.coordinates' click event)
	            the chat (client Ui/Chat) puts in the box when clicked, hovering "Click to
	            teleport". Coordinates are true world coordinates (what F3 shows), with or
	            without the floating origin.
	  Y         "~" for structures on the surface (Minecraft's), the y for underground ones
	            (mineshafts, an entrance's collar, an oil deposit: "~" would be useless there),
	            the surface's height for biomes, the block's y for points of interest (Minecraft
	            shows "~" for those too: a deviation, as a chest is often underground).
	  Distance  floored and horizontal (Minecraft's for structures and points of interest, found
	            in 3D within PoiRadius; biomes are 2D here, where Minecraft's is 3D).
	  Who may   the operators' permission (Minecraft's level 2: Players/Operators).

	Searches run one at a time, a slice of each frame (`Queue`): `submit` puts a player's search
	in line (replacing their earlier one), `step` resumes them for at most `budget` seconds of the
	frame, the searches' `yield` (the queue's) suspends them when that is spent, and one running
	longer than `timeout` gives up. Pure (the clock is given), so the tests check it never takes
	more than the budget plus one probe a frame.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Locate = require(Shared.Generation.Locate)
local Poi = require(Shared.Poi)
local TerrainGenerator = require(Shared.Generation.TerrainGenerator)

local PoiSearch = require(script.Parent.Parent.World.PoiSearch)
local WorldServer = require(script.Parent.Parent.World.WorldServer)

export type Type = "structure" | "biome" | "poi"

export type Registries = {
	structure: Locate.Registry,
	biome: Locate.Registry,
	poi: Locate.Registry,
}

export type Context = {
	mayUse: boolean,
	registries: Registries,
}

-- A search to run: what, and what the answer calls it.
export type Request = {
	type: Type,
	resolved: Locate.Resolved,
}

export type Result = {
	request: Request?,
	-- Messages for the player who typed the command.
	feedback: { string },
}

-- The clickable part of an answer: bytes first..last of the text, and the command it suggests.
export type Link = { first: number, last: number, suggest: string }

local LocateCommand = {}

LocateCommand.ALIASES = { "/locate" }
LocateCommand.USAGE = "Usage: /locate structure <structure|#tag>, /locate biome <biome|#tag>, /locate poi <poi|#tag>"
LocateCommand.DENIED = "You can't use /locate here"
LocateCommand.BUSY = "Too many locates are running; try again in a moment"
LocateCommand.FAILED = "An unexpected error occurred trying to execute that command"
-- chat.coordinates.tooltip: what hovering the coordinates says.
LocateCommand.TOOLTIP = "Click to teleport"

-- Minecraft's registry names (argument.resource.not_found's type).
LocateCommand.REGISTRY = table.freeze({
	structure = "minecraft:worldgen/structure",
	biome = "minecraft:worldgen/biome",
	poi = "minecraft:point_of_interest_type",
} :: { [string]: string })

-- The registries: structures (the built-in kinds and `libraryNames`), biomes, points of interest.
function LocateCommand.registries(libraryNames: { string }): Registries
	return {
		structure = Locate.structureRegistry(libraryNames),
		biome = Locate.biomeRegistry(),
		poi = Locate.registry("point_of_interest_type", Poi.ids, Poi.tags()),
	}
end

local function words(text: string): { string }
	local list = {}
	for word in string.gmatch(text, "%S+") do
		table.insert(list, word)
	end
	return list
end

-- Is `text` a /locate command (the alias, then nothing or a space)?
function LocateCommand.matches(text: string): boolean
	local first = string.match(text, "^%s*(%S+)")
	return first ~= nil and table.find(LocateCommand.ALIASES, string.lower(first)) ~= nil
end

--[[
	Runs a chat message as /locate: nil when it is something else; otherwise the search to start
	or what to say instead (usage, permission, an unknown id or tag).
]]
function LocateCommand.run(text: string, context: Context): Result?
	if not LocateCommand.matches(text) then
		return nil
	end
	local result: Result = { feedback = {} }
	local function say(message: string): Result
		table.insert(result.feedback, message)
		return result
	end
	if not context.mayUse then
		return say(LocateCommand.DENIED)
	end
	local args = words(text)
	local kind = if args[2] then string.lower(args[2]) else nil
	if (kind ~= "structure" and kind ~= "biome" and kind ~= "poi") or #args ~= 3 then
		return say(LocateCommand.USAGE)
	end
	local type: Type = kind :: Type
	local typed = args[3]
	local resolved, problem = Locate.resolve(context.registries[type], typed)
	if resolved == nil then
		if type == "structure" then
			return say(`There is no structure with type "{typed}"`)
		elseif problem == "tag" then
			return say(`Can't find tag '{string.sub(typed, 2)}' of type '{LocateCommand.REGISTRY[type]}'`)
		end
		return say(`Can't find element '{typed}' of type '{LocateCommand.REGISTRY[type]}'`)
	end
	result.request = { type = type, resolved = resolved }
	return result
end

--[[ Searching ]]

-- The kinds of `generator` whose ids are in `members`.
function LocateCommand.kinds(generator: TerrainGenerator.Generator, members: { string }): { Locate.Kind }
	local list: { Locate.Kind } = {}
	local get = generator.locateKinds
	if get == nil then
		return list
	end
	local set = Locate.set(members)
	for _, kind in get() do
		if set[kind.id] then
			table.insert(list, kind)
		end
	end
	return list
end

--[[
	Runs `request` for a player whose feet are at (px, py, pz) (blocks; the search starts at
	their block, as Minecraft's): the generator's kinds, layout or biomes (on `generator`, which
	the search may suspend in the middle of: never the world's own while chunks are being
	generated) and, for points of interest, `world`'s edits too. nil: nothing found.
]]
function LocateCommand.search(
	request: Request,
	generator: TerrainGenerator.Generator,
	world: WorldServer.World?,
	px: number,
	py: number,
	pz: number,
	yield: (() -> ())?,
	stats: Locate.Stats?
): Locate.Found?
	local bx, by, bz = math.floor(px), math.floor(py), math.floor(pz)
	local members = request.resolved.members
	local cfg = Config.Locate
	if request.type == "structure" then
		local list = generator.locateList
		if list then
			return Locate.nearestListed(list(), Locate.set(members), bx, bz)
		end
		return Locate.nearest(LocateCommand.kinds(generator, members), bx, bz, yield, stats)
	elseif request.type == "biome" then
		-- (Large Biomes: twice as far in steps twice as long, the same samples; Debug: All
		-- Biomes' narrow strips: a quarter.)
		local scale = math.clamp(generator.climateScale or 1, 0.25, 2)
		return Locate.biome(
			generator.column,
			Locate.biomeSet(members),
			generator.biomes,
			bx,
			bz,
			cfg.BiomeRadius * scale,
			cfg.BiomeStep * scale,
			yield,
			stats
		)
	end
	if world == nil then
		return nil
	end
	local found = PoiSearch.nearest(world, generator, PoiSearch.wanted(members), bx, by, bz, cfg.PoiRadius, {
		yield = yield,
		generatedNear = cfg.PoiGeneratedNear,
		stats = stats,
	})
	if found == nil then
		return nil
	end
	-- (The nearest is the nearest in 3D, as Minecraft's search; the distance shown is horizontal,
	-- as its answer: showLocateResult's absoluteY false.)
	local dx, dz = found.x - bx, found.z - bz
	return {
		id = found.id,
		x = found.x,
		y = found.y,
		z = found.z,
		showY = true,
		distance = math.sqrt(dx * dx + dz * dz),
	}
end

--[[ Answers ]]

-- "[x, y, z]" (chat.coordinates in square brackets), y "~" when not shown.
function LocateCommand.coordinates(found: Locate.Found): string
	local y = if found.showY then tostring(math.floor(found.y)) else "~"
	return `[{math.floor(found.x)}, {y}, {math.floor(found.z)}]`
end

-- The command the coordinates suggest (chat.coordinates' click: "/tp @s x y z").
function LocateCommand.suggestion(found: Locate.Found): string
	local y = if found.showY then tostring(math.floor(found.y)) else "~"
	return `/tp @s {math.floor(found.x)} {y} {math.floor(found.z)}`
end

-- The answer to a search that found `found`: its text and the coordinates' link.
function LocateCommand.success(request: Request, found: Locate.Found): (string, Link)
	local name = Locate.label(request.resolved, found.id)
	local head = `The nearest {name} is at `
	local coordinates = LocateCommand.coordinates(found)
	local text = `{head}{coordinates} ({math.floor(found.distance)} blocks away)`
	return text, { first = #head + 1, last = #head + #coordinates, suggest = LocateCommand.suggestion(found) }
end

-- The answer to a search that found nothing (or ran out of time).
function LocateCommand.notFound(request: Request): string
	local label = request.resolved.label
	if request.type == "structure" then
		return `Could not find a structure of type "{label}" nearby`
	elseif request.type == "biome" then
		return `Could not find a biome of type "{label}" within reasonable distance`
	end
	return `Could not find a point of interest of type "{label}" within reasonable distance`
end

-- The server log's line (Minecraft's "Locating element X took N ms").
function LocateCommand.logLine(request: Request, ms: number, stats: Locate.Stats): string
	return `[IceVoxel] locating {request.type} {request.resolved.label} took {math.floor(ms + 0.5)} ms `
		.. `({stats.probes} probes, {stats.verified} checked)`
end

--[[
	The argument completion the chat offers (WorldSettings.COMMAND_ARGUMENTS_ATTRIBUTE): one line
	per position, "<previous words, space joined>|<candidates, comma joined>": the three kinds,
	then each kind's ids and tags ("#...").
]]
function LocateCommand.arguments(registries: Registries): string
	local lines = { "|structure,biome,poi" }
	for _, type in { "structure", "biome", "poi" } do
		local registry: Locate.Registry = (registries :: any)[type]
		local candidates = table.clone(registry.ids)
		for _, tag in registry.tagNames do
			table.insert(candidates, "#" .. tag)
		end
		table.insert(lines, `{type}|{table.concat(candidates, ",")}`)
	end
	return table.concat(lines, "\n")
end

--[[ The queue ]]

export type Job = {
	key: any,
	-- The search: calls the queue's yield often, and answers the player itself.
	run: (yield: () -> ()) -> (),
	-- Called instead when it runs past the timeout, and when it errors (with the message).
	timedOut: () -> (),
	failed: (message: string) -> (),
	thread: thread?,
	-- The clock when it first ran.
	started: number?,
}

export type Queue = {
	jobs: { Job },
	running: Job?,
	budget: number,
	timeout: number,
	capacity: number,
	clock: () -> number,
	-- When this frame's slice started (`step`).
	sliceStart: number,
	yield: () -> (),
}

-- A queue: `budget` and `timeout` in seconds, at most `capacity` jobs waiting or running.
function LocateCommand.newQueue(budget: number, timeout: number, capacity: number, clock: () -> number): Queue
	local queue: Queue
	queue = {
		jobs = {},
		running = nil,
		budget = budget,
		timeout = timeout,
		capacity = capacity,
		clock = clock,
		sliceStart = 0,
		-- (The searches' yield: suspends the running job once the slice is spent.)
		yield = function()
			if queue.clock() - queue.sliceStart >= queue.budget and coroutine.isyieldable() then
				coroutine.yield()
			end
		end,
	}
	return queue
end

-- Jobs waiting or running.
function LocateCommand.pending(queue: Queue): number
	return #queue.jobs + (if queue.running then 1 else 0)
end

-- Drops `key`'s job, waiting or running (a running one is never resumed again).
function LocateCommand.cancel(queue: Queue, key: any)
	for i = #queue.jobs, 1, -1 do
		if queue.jobs[i].key == key then
			table.remove(queue.jobs, i)
		end
	end
	local running = queue.running
	if running and running.key == key then
		queue.running = nil
	end
end

-- Puts a job in line, replacing `job.key`'s earlier one. false: the queue is full.
function LocateCommand.submit(queue: Queue, job: Job): boolean
	LocateCommand.cancel(queue, job.key)
	if LocateCommand.pending(queue) >= queue.capacity then
		return false
	end
	table.insert(queue.jobs, job)
	return true
end

--[[
	Runs the jobs for at most the budget (one job after another while time is left). Returns the
	seconds spent.
]]
function LocateCommand.step(queue: Queue): number
	local clock = queue.clock
	local start = clock()
	queue.sliceStart = start
	while clock() - start < queue.budget do
		local job = queue.running
		if job == nil then
			job = table.remove(queue.jobs, 1)
			if job == nil then
				break
			end
			queue.running = job
		end
		assert(job)
		local now = clock()
		if job.started == nil then
			job.started = now
		elseif now - (job.started :: number) > queue.timeout then
			queue.running = nil
			job.timedOut()
			continue
		end
		local thread = job.thread
		if thread == nil then
			local run = job.run
			local yield = queue.yield
			thread = coroutine.create(function()
				run(yield)
			end)
			job.thread = thread
		end
		assert(thread)
		local ok, problem = coroutine.resume(thread)
		if not ok then
			queue.running = nil
			job.failed(tostring(problem))
		elseif coroutine.status(thread) == "dead" then
			if queue.running == job then
				queue.running = nil
			end
		end
	end
	return clock() - start
end

return LocateCommand
