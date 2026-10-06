--!strict
--[[
	Remeshes of full detail chunks: which sections are dirty and why, which job goes next, in which
	lane and commit group. Pure (nodes are opaque keys; the renderer's commit groups come in through
	`Groups`), tested in tests/spec/Streaming.

	Reasons, most urgent first: EDIT (the player's and the server's edits), REVEAL (the cave view),
	SEAM (a coarser neighbour appeared or changed) and PLANTS (plants switched on or off). A
	section keeps its most urgent reason until a job takes it.

	Jobs (`dispatch`):
	  * edit jobs take a node's EDIT sections only, first come first served. They go to the
	    workers' and the renderer's edit lanes, never wait for anything else, and a node may have
	    several in flight;
	  * "near" jobs take all of a node's other dirty sections, by reason, then distance, one per
	    node at a time, at most `cap` in flight (so generation keeps some workers); except that
	    once one member of a batch was sent, the others go first and past the cap (the batch
	    goes live only when all of them are built, and a group waiting too long gives up:
	    ChunkRenderer).
	Every job has a token; a section remembers the token of the last job that took it, and a
	result only counts for the sections whose token is still that job's (`current`): a mesh never
	gets overwritten by an older job that came back later. A failed job (`done`) marks its
	sections again (those no newer job took) and the node waits FAIL_DELAY seconds, doubling up to
	FAIL_MAX, before its next job.

	Commit groups (batches): every node one batch of edits dirtied (the edited chunk, and the
	neighbours whose padding changed) goes live in the same frame. A batch opens a renderer group
	holding it once itself; each of its jobs, once sent, holds it too, and that hold is closed
	(`done`) once the job's builds were queued, or when it failed. When no member is left waiting
	for its job, the batch closes its own hold. New edits join the open batch. A cave reveal pass
	(`beginPass` / `endPass`) is a batch too when it changed at most `limit` sections, so a
	section whose cave cap opens and the neighbour it opens onto go live together; a bigger pass
	(entering a cave changes hundreds of sections) is cut into batches of at most `limit`
	sections, nearest nodes first, so what is near goes live first. The pass's `whole` nodes
	(sections being hidden, and the caps closing towards them) are one batch of their own
	whatever its size: nothing in it is urgent, and a tunnel must never stay open towards a
	section already meshed hidden. A member that is not ready leaves its batch and is remeshed
	alone later. `groupOf` tells which group a dirty section's job will carry.
]]

local RemeshQueue = {}

RemeshQueue.EDIT = 1
RemeshQueue.REVEAL = 2
RemeshQueue.SEAM = 3
RemeshQueue.PLANTS = 4

local EDIT = RemeshQueue.EDIT
local REVEAL = RemeshQueue.REVEAL
-- Batch lanes.
local EDIT_LANE = 1
local NEAR_LANE = 2

-- Seconds a node waits after a failed job, doubling per failure up to FAIL_MAX.
local FAIL_DELAY = 0.5
local FAIL_MAX = 8
RemeshQueue.FAIL_DELAY = FAIL_DELAY

export type Groups = {
	open: () -> any,
	hold: (group: any) -> (),
	close: (group: any) -> (),
}

type Batch = {
	group: any,
	members: { [any]: boolean },
	count: number,
	-- A member's job was sent: the others go next, past the near cap.
	sent: boolean,
}

type State = {
	-- Dirty sections and their reasons; how many, and how many for edits.
	dirty: { [number]: number },
	count: number,
	edits: number,
	-- Token of the last job that took each section.
	tokens: { [number]: number },
	-- Near jobs in flight.
	near: number,
	-- The batch the node waits in, per lane.
	batches: { [number]: Batch },
	failures: number,
	retryAt: number,
}

export type Job = {
	node: any,
	sections: { number },
	reasons: { number },
	edit: boolean,
	group: any?,
	token: number,
}

export type RemeshQueue = {
	groups: Groups,
	states: { [any]: State },
	-- Nodes with edit sections, first come first served.
	editOrder: { any },
	-- Nodes with other dirty sections, most urgent first (rebuilt when `orderDirty`).
	nearOrder: { any },
	orderDirty: boolean,
	editBatch: Batch?,
	batches: { Batch },
	pass: { nodes: { [any]: boolean }, sections: number, counts: { [any]: number } }?,
	token: number,
	nearInFlight: number,

	mark: (self: RemeshQueue, node: any, section: number, reason: number) -> (),
	isDirty: (self: RemeshQueue, node: any, section: number) -> boolean,
	groupOf: (self: RemeshQueue, node: any, section: number) -> any?,
	inPass: (self: RemeshQueue, node: any) -> boolean,
	passSize: (self: RemeshQueue) -> number,
	beginPass: (self: RemeshQueue) -> (),
	endPass: (
		self: RemeshQueue,
		limit: number,
		whole: { [any]: boolean }?,
		distance: ((node: any) -> number)?
	) -> number,
	invalidate: (self: RemeshQueue) -> (),
	dispatch: (
		self: RemeshQueue,
		submit: (job: Job) -> boolean,
		ready: (node: any) -> boolean,
		distance: (node: any) -> number,
		cap: number,
		now: number
	) -> number,
	current: (self: RemeshQueue, node: any, section: number, token: number) -> boolean,
	done: (self: RemeshQueue, job: Job, failed: boolean, now: number?) -> (),
	forget: (self: RemeshQueue, node: any) -> (),
	pending: (self: RemeshQueue) -> number,
}

local Queue = {}
Queue.__index = Queue

function RemeshQueue.new(groups: Groups): RemeshQueue
	local self = {
		groups = groups,
		states = {},
		editOrder = {},
		nearOrder = {},
		orderDirty = false,
		editBatch = nil,
		batches = {},
		pass = nil,
		token = 0,
		nearInFlight = 0,
	}
	return (setmetatable(self, Queue) :: any) :: RemeshQueue
end

local function stateOf(self: RemeshQueue, node: any): State
	local state = self.states[node]
	if state == nil then
		state = {
			dirty = {},
			count = 0,
			edits = 0,
			tokens = {},
			near = 0,
			batches = {},
			failures = 0,
			retryAt = -math.huge,
		}
		self.states[node] = state
	end
	return state :: State
end

local function newBatch(self: RemeshQueue): Batch
	local batch: Batch = { group = self.groups.open(), members = {}, count = 0, sent = false }
	table.insert(self.batches, batch)
	return batch
end

local function join(state: State, node: any, lane: number, batch: Batch)
	if state.batches[lane] == nil then
		state.batches[lane] = batch
		batch.members[node] = true
		batch.count += 1
	end
end

local function leave(state: State, node: any, lane: number): Batch?
	local batch = state.batches[lane]
	if batch then
		state.batches[lane] = nil
		batch.members[node] = nil
		batch.count -= 1
	end
	return batch
end

-- Section `section` of `node` needs a new mesh for `reason` (EDIT, REVEAL, SEAM, PLANTS).
function Queue.mark(self: RemeshQueue, node: any, section: number, reason: number)
	local state = stateOf(self, node)
	local old = state.dirty[section]
	if old == nil then
		state.count += 1
	end
	if old == nil or reason < old then
		state.dirty[section] = reason
		if reason == EDIT then
			state.edits += 1
			if state.edits == 1 then
				table.insert(self.editOrder, node)
			end
			local batch = self.editBatch
			if batch == nil then
				batch = newBatch(self)
				self.editBatch = batch
			end
			join(state, node, EDIT_LANE, batch :: Batch)
		else
			self.orderDirty = true
		end
	end
	local pass = self.pass
	if pass and reason == REVEAL then
		pass.nodes[node] = true
		pass.sections += 1
		pass.counts[node] = (pass.counts[node] or 0) + 1
	end
end

function Queue.isDirty(self: RemeshQueue, node: any, section: number): boolean
	local state = self.states[node]
	return state ~= nil and state.dirty[section] ~= nil
end

-- The commit group the job that will take dirty section `section` of `node` carries (its node
-- waits in a batch of that lane), or nil.
function Queue.groupOf(self: RemeshQueue, node: any, section: number): any?
	local state = self.states[node]
	local reason = if state then state.dirty[section] else nil
	if state == nil or reason == nil then
		return nil
	end
	local batch = state.batches[if reason == EDIT then EDIT_LANE else NEAR_LANE]
	return if batch then batch.group else nil
end

-- Did the pass being collected mark `node`?
function Queue.inPass(self: RemeshQueue, node: any): boolean
	local pass = self.pass
	return pass ~= nil and pass.nodes[node] == true
end

-- Sections the pass being collected marked so far.
function Queue.passSize(self: RemeshQueue): number
	local pass = self.pass
	return if pass then pass.sections else 0
end

-- Starts collecting a cave reveal pass's marks.
function Queue.beginPass(self: RemeshQueue)
	self.pass = { nodes = {}, sections = 0, counts = {} }
end

--[[
	Ends the pass: the nodes of `whole` it marked are one batch, whatever their number; the others
	are one when they changed 1..limit sections, or else (with `distance`) batches of at most
	`limit` sections, nearest nodes first. Returns how many sections it changed.
]]
function Queue.endPass(
	self: RemeshQueue,
	limit: number,
	whole: { [any]: boolean }?,
	distance: ((node: any) -> number)?
): number
	local pass = self.pass
	self.pass = nil
	if pass == nil or pass.sections == 0 then
		return 0
	end
	local wholeBatch: Batch? = nil
	local rest: { any } = {}
	local restSections = 0
	for node in pass.nodes do
		local state = self.states[node]
		if state and state.batches[NEAR_LANE] == nil and state.count > state.edits then
			if whole and whole[node] then
				if wholeBatch == nil then
					wholeBatch = newBatch(self)
				end
				join(state, node, NEAR_LANE, wholeBatch :: Batch)
			else
				table.insert(rest, node)
				restSections += pass.counts[node] or 0
			end
		end
	end
	if restSections > limit then
		if distance == nil then
			return pass.sections
		end
		local keys: { [any]: number } = {}
		for _, node in rest do
			keys[node] = distance(node)
		end
		table.sort(rest, function(a, b)
			return keys[a] < keys[b]
		end)
	end
	local batch: Batch? = nil
	local size = 0
	for _, node in rest do
		local n = pass.counts[node] or 0
		if batch == nil or size + n > limit then
			batch = newBatch(self)
			size = 0
		end
		join(self.states[node], node, NEAR_LANE, batch :: Batch)
		size += n
	end
	return pass.sections
end

-- Distances changed (the viewer moved): sort near jobs again.
function Queue.invalidate(self: RemeshQueue)
	self.orderDirty = true
end

local function newJob(self: RemeshQueue, node: any, state: State, edit: boolean, group: any?): Job
	self.token += 1
	local token = self.token
	local sections, reasons = {}, {}
	for section, reason in state.dirty do
		if (reason == EDIT) == edit then
			table.insert(sections, section)
			table.insert(reasons, reason)
		end
	end
	return { node = node, sections = sections, reasons = reasons, edit = edit, group = group, token = token }
end

-- The job was submitted: its sections are no longer dirty and belong to it.
local function take(self: RemeshQueue, state: State, job: Job)
	for _, section in job.sections do
		state.dirty[section] = nil
		state.tokens[section] = job.token
	end
	state.count -= #job.sections
	if job.edit then
		state.edits -= #job.sections
	else
		state.near += 1
		self.nearInFlight += 1
	end
end

-- Tries to submit `node`'s job for a lane; false when the pool is full. (`submit` must not call
-- the job's callback before it returns: worker results always come later.)
local function try(self: RemeshQueue, node: any, state: State, lane: number, submit: (job: Job) -> boolean): boolean
	local batch = state.batches[lane]
	local group = if batch then batch.group else nil
	local job = newJob(self, node, state, lane == EDIT_LANE, group)
	if #job.sections == 0 then
		leave(state, node, lane)
		return true
	end
	if not submit(job) then
		return false
	end
	-- (Only once sent: a group may start with its first job. Its callback comes later.)
	if group ~= nil then
		self.groups.hold(group)
	end
	if batch and not batch.sent then
		-- (Its other members move to the front: `buildNearOrder`.)
		batch.sent = true
		self.orderDirty = true
	end
	leave(state, node, lane)
	take(self, state, job)
	return true
end

-- Closes the own hold of every batch no member waits in any more.
local function closeBatches(self: RemeshQueue)
	local batches = self.batches
	local i = 1
	while i <= #batches do
		local batch = batches[i]
		if batch.count <= 0 then
			table.remove(batches, i)
			if self.editBatch == batch then
				self.editBatch = nil
			end
			self.groups.close(batch.group)
		else
			i += 1
		end
	end
end

local function buildNearOrder(self: RemeshQueue, distance: (node: any) -> number)
	local order = {}
	local keys: { [any]: number } = {}
	for node, state in self.states do
		if state.count > state.edits then
			local best = math.huge
			for _, reason in state.dirty do
				if reason ~= EDIT and reason < best then
					best = reason
				end
			end
			-- Members of a batch already being sent first.
			local batch = state.batches[NEAR_LANE]
			local rank = if batch and batch.sent then 0 else best
			keys[node] = rank * 1e7 + math.min(distance(node), 1e7 - 1)
			table.insert(order, node)
		end
	end
	table.sort(order, function(a, b)
		return keys[a] < keys[b]
	end)
	self.nearOrder = order
	self.orderDirty = false
end

--[[
	Submits jobs while `submit` accepts them: edit jobs first, then near jobs while fewer than
	`cap` are in flight. `ready(node)`: the node can be remeshed (built, data loaded). Returns how
	many jobs were submitted.
]]
function Queue.dispatch(
	self: RemeshQueue,
	submit: (job: Job) -> boolean,
	ready: (node: any) -> boolean,
	distance: (node: any) -> number,
	cap: number,
	now: number
): number
	local submitted = 0
	-- Edits.
	local order = self.editOrder
	if #order > 0 then
		local keep = {}
		local full = false
		for _, node in order do
			local state = self.states[node]
			if state == nil or state.edits == 0 then
				continue
			end
			if full then
				table.insert(keep, node)
			elseif not ready(node) or now < state.retryAt then
				-- (Its batch does not wait for it.)
				leave(state, node, EDIT_LANE)
				table.insert(keep, node)
			elseif try(self, node, state, EDIT_LANE, submit) then
				submitted += 1
			else
				full = true
				table.insert(keep, node)
			end
		end
		self.editOrder = keep
	end
	-- Near jobs (members of batches being sent first, past the cap).
	local urgent = false
	for _, batch in self.batches do
		if batch.sent and batch.count > 0 then
			urgent = true
			break
		end
	end
	if self.nearInFlight < cap or urgent then
		if self.orderDirty then
			buildNearOrder(self, distance)
		end
		local near = self.nearOrder
		local i = 1
		while i <= #near do
			local node = near[i]
			local state = self.states[node]
			if state == nil or state.count <= state.edits then
				table.remove(near, i)
				continue
			end
			if self.nearInFlight >= cap then
				local batch = state.batches[NEAR_LANE]
				if batch == nil or not batch.sent then
					break
				end
			end
			if state.near > 0 then
				i += 1
				continue
			end
			if not ready(node) or now < state.retryAt then
				-- (Its batch does not wait for it.)
				leave(state, node, NEAR_LANE)
				i += 1
				continue
			end
			if not try(self, node, state, NEAR_LANE, submit) then
				break
			end
			submitted += 1
			table.remove(near, i)
		end
	end
	-- Members with nothing left to dispatch leave their batch.
	for _, batch in self.batches do
		for node in table.clone(batch.members) do
			local state = self.states[node]
			if state == nil then
				batch.members[node] = nil
				batch.count -= 1
			elseif state.batches[NEAR_LANE] == batch and state.count <= state.edits then
				leave(state, node, NEAR_LANE)
			elseif state.batches[EDIT_LANE] == batch and state.edits == 0 then
				leave(state, node, EDIT_LANE)
			end
		end
	end
	closeBatches(self)
	return submitted
end

-- Is `token` still the job of section `section` of `node`?
function Queue.current(self: RemeshQueue, node: any, section: number, token: number): boolean
	local state = self.states[node]
	return state ~= nil and state.tokens[section] == token
end

--[[
	A job finished, after its builds were queued (or it failed / was cancelled: `failed`). A
	failed job marks its sections again (those no newer job took) and delays the node. Closes the
	job's hold on its commit group.
]]
function Queue.done(self: RemeshQueue, job: Job, failed: boolean, now: number?)
	if not job.edit then
		self.nearInFlight -= 1
	end
	local state = self.states[job.node]
	if state then
		if not job.edit then
			state.near -= 1
		end
		if failed then
			state.failures += 1
			state.retryAt = (now or 0) + math.min(FAIL_MAX, FAIL_DELAY * 2 ^ (state.failures - 1))
			for i, section in job.sections do
				if state.tokens[section] == job.token then
					state.tokens[section] = nil
					self:mark(job.node, section, job.reasons[i])
				end
			end
		else
			state.failures = 0
		end
	end
	if job.group ~= nil then
		self.groups.close(job.group)
	end
end

-- The node is gone: its dirty sections and batch places are dropped (its jobs still call `done`).
function Queue.forget(self: RemeshQueue, node: any)
	local state = self.states[node]
	if state == nil then
		return
	end
	leave(state, node, EDIT_LANE)
	leave(state, node, NEAR_LANE)
	self.states[node] = nil
	self.orderDirty = true
	closeBatches(self)
end

-- Dirty sections waiting for a job.
function Queue.pending(self: RemeshQueue): number
	local n = 0
	for _, state in self.states do
		n += state.count
	end
	return n
end

return RemeshQueue
