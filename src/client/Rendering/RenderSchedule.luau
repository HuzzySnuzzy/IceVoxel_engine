--!strict
--[[
	Which section build ChunkRenderer works on next, and when finished builds go live. Pure Luau
	(tasks carry the renderer's data opaquely), tested in tests/spec/RenderPipeline.

	Lanes, most urgent first:
	  EDIT        player and server edits, first in first out, with their own frame budget
	              (Render.EditBudgetMs), so an edit never waits behind anything else;
	  NEAR        cave reveal, plants and seams, by priority;
	  NORMAL      generation, by node priority, a node's sections in arrival order;
	  BACKGROUND  restyles (a texture setting changed), like NORMAL, after everything else.
	A task's priority is its own `priority` or else its node's `priority` field (the streamer's
	score: lower is sooner), read again by `reprioritise` after the streamer updates its nodes; ties
	go by arrival. Sorted lanes keep the most urgent task last, so taking it is O(1); new tasks are
	inserted by binary search.

	One uncommitted task per section. A task for a section whose previous task has not gone live
	yet waits ("parked") and joins its lane when that one commits, so every build diffs against
	what is on screen. A newer mesh makes an older one that has not started out of date, so with
	no commit group on either side the newer task replaces it (takes over its callbacks: the
	renderer is told through `add`'s result): a parked one, or the uncommitted one while it is
	still queued and not started (`new`'s `started` says which tasks the renderer began), in the
	more urgent of the two lanes. A new task in the same commit group as one of its section's
	tasks (uncommitted or parked) drops that one first: waiting behind it would deadlock the
	group, which cannot let the older one go live before the newer one is staged. When the dropped
	one was the uncommitted task, the next parked one takes its place, so meshes still go live
	oldest first.

	Restyle tasks (`restyle`: rebuild what the section shows with a new look) never replace a task
	and are replaced by any newer one (queued, started or parked): every build that starts later
	uses the new look anyway. The renderer adds one only where no task waits to start
	(`startsLater`), so a restyle never holds a later edit back in the background lane.

	Commit groups: the streamer opens a group for one batch of edits (or cave caps that change
	together), holds it while jobs that will add tasks to it are running, and closes each hold when
	the job's tasks were added (or the job failed). Its tasks are built, then held ("staged") until
	every task is staged and no hold is left; then `stage` / `close` return all of them, to go live
	in the same frame. A group open longer than the timeout gives up waiting (`expire`): its staged
	tasks go live at once and later ones as they are staged, so a lost job or a cycle between groups
	can never freeze a section on screen.
]]

local RenderSchedule = {}

RenderSchedule.EDIT = 1
RenderSchedule.NEAR = 2
RenderSchedule.NORMAL = 3
RenderSchedule.BACKGROUND = 4
local LANES = 4

-- Task states.
local QUEUED = 1
local PARKED = 2
local STAGED = 3
local DONE = 4
local DROPPED = 5
RenderSchedule.QUEUED = QUEUED
RenderSchedule.PARKED = PARKED
RenderSchedule.STAGED = STAGED
RenderSchedule.DONE = DONE
RenderSchedule.DROPPED = DROPPED

export type Group = {
	-- Jobs still expected to add tasks, tasks added but not staged yet, and staged tasks.
	holds: number,
	pending: number,
	staged: { Task },
	opened: number,
	-- Timed out: tasks go live as soon as they are staged.
	forced: boolean,
	-- Everything went live (or was dropped); later tasks go live alone.
	done: boolean,
}

export type Task = {
	node: any,
	section: number,
	lane: number,
	priority: number?,
	group: Group?,
	-- A restyle (see the header).
	restyle: boolean?,
	state: number,
	seq: number,
	-- The renderer's build state.
	data: any,
}

type Slot = { current: Task?, parked: { Task } }

export type Schedule = {
	lanes: { { Task } },
	-- First unread index of the EDIT lane (first in, first out).
	head: number,
	-- Queued tasks per lane.
	queued: { number },
	parkedCount: number,
	stagedCount: number,
	slots: { [any]: { [number]: Slot } },
	groups: { [Group]: boolean },
	seq: number,
	-- Has the renderer started building this queued task?
	started: (task: Task) -> boolean,

	add: (self: Schedule, task: Task) -> { Task }?,
	startsLater: (self: Schedule, node: any, section: number) -> boolean,
	peek: (self: Schedule, lane: number) -> Task?,
	pop: (self: Schedule, lane: number) -> (),
	stage: (self: Schedule, task: Task) -> { Task }?,
	committed: (self: Schedule, task: Task) -> (),
	openGroup: (self: Schedule, now: number) -> Group,
	hold: (self: Schedule, group: Group) -> (),
	close: (self: Schedule, group: Group) -> { Task }?,
	drop: (self: Schedule, node: any) -> ({ Task }, { Task }),
	expire: (self: Schedule, now: number, timeout: number) -> { Task },
	reprioritise: (self: Schedule) -> (),
	count: (self: Schedule) -> number,
	laneCount: (self: Schedule, lane: number) -> number,
	tasksOf: (self: Schedule, node: any) -> { Task },
}

local Schedule = {}
Schedule.__index = Schedule

--[[
	`started`: has the renderer started building a queued task? (Default: every queued task counts
	as started, so only parked tasks are replaced.)
]]
function RenderSchedule.new(started: ((task: Task) -> boolean)?): Schedule
	local lanes = {}
	local queued = {}
	for lane = 1, LANES do
		lanes[lane] = {}
		queued[lane] = 0
	end
	local self = {
		lanes = lanes,
		head = 1,
		queued = queued,
		parkedCount = 0,
		stagedCount = 0,
		slots = {},
		groups = {},
		seq = 0,
		started = started or function(_task: Task): boolean
			return true
		end,
	}
	return (setmetatable(self, Schedule) :: any) :: Schedule
end

local function priorityOf(task: Task): number
	local p = task.priority
	if p ~= nil then
		return p
	end
	local np = task.node.priority
	return if type(np) == "number" then np else 0
end

-- Is `a` less urgent than `b` (sorted lanes keep the most urgent last)?
local function after(a: Task, b: Task): boolean
	local pa, pb = priorityOf(a), priorityOf(b)
	if pa ~= pb then
		return pa > pb
	end
	return a.seq > b.seq
end

local function enqueue(self: Schedule, task: Task)
	task.state = QUEUED
	local lane = task.lane
	local list = self.lanes[lane]
	self.queued[lane] += 1
	if lane == RenderSchedule.EDIT then
		table.insert(list, task)
		return
	end
	-- Binary search for the first entry that is not less urgent than `task`.
	local lo, hi = 1, #list + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if after(list[mid], task) then
			lo = mid + 1
		else
			hi = mid
		end
	end
	table.insert(list, lo, task)
end

local function slotOf(self: Schedule, node: any, section: number): Slot
	local sections = self.slots[node]
	if sections == nil then
		sections = {}
		self.slots[node] = sections
	end
	local slot = sections[section]
	if slot == nil then
		slot = { current = nil, parked = {} }
		sections[section] = slot
	end
	return slot
end

local function complete(group: Group): boolean
	return group.holds <= 0 and group.pending <= 0
end

-- The group's staged tasks, in arrival order, to go live now; the group is done.
local function flush(self: Schedule, group: Group): { Task }
	local staged = group.staged
	group.staged = {}
	group.done = true
	self.groups[group] = nil
	table.sort(staged, function(a, b)
		return a.seq < b.seq
	end)
	return staged
end

-- Leaves a dropped task's group consistent; returns tasks that can go live because of it.
local function leaveGroup(self: Schedule, task: Task, wasStaged: boolean): { Task }?
	local group = task.group
	if group == nil or group.done then
		return nil
	end
	if wasStaged then
		local i = table.find(group.staged, task)
		if i then
			table.remove(group.staged, i)
		end
	else
		group.pending -= 1
	end
	if complete(group) or group.forced then
		return flush(self, group)
	end
	return nil
end

local function forget(self: Schedule, task: Task)
	local state = task.state
	if state == QUEUED then
		self.queued[task.lane] -= 1
	elseif state == PARKED then
		self.parkedCount -= 1
	elseif state == STAGED then
		self.stagedCount -= 1
	end
	task.state = DROPPED
end

local function park(self: Schedule, slot: Slot, task: Task)
	table.insert(slot.parked, task)
	task.state = PARKED
	self.parkedCount += 1
end

-- May `task` replace `old`, an older task of its section that has not gone live (see the header)?
local function supersedes(task: Task, old: Task): boolean
	return old.restyle == true or (not task.restyle and old.group == nil and task.group == nil)
end

--[[
	Adds a task (fields node, section, lane, priority, group, restyle, data). Returns the tasks it
	replaced, if any (dropped: the caller releases what they built and the new task keeps their
	callbacks). Tasks that become live through a replaced task's group are not
	possible here: a replaced task either has no group or the new task joins the same group.
]]
function Schedule.add(self: Schedule, task: Task): { Task }?
	self.seq += 1
	task.seq = self.seq
	local group = task.group
	if group then
		group.pending += 1
	end
	local slot = slotOf(self, task.node, task.section)
	local replaced: { Task }? = nil
	if group ~= nil and not group.done then
		-- An older task of the same group (uncommitted or parked) is out of date, and waiting
		-- behind it would deadlock the group.
		local current = slot.current
		local old: Task? = nil
		if current and current.group == group then
			old = current
			local wasStaged = current.state == STAGED
			forget(self, current)
			if wasStaged then
				local i = table.find(group.staged, current)
				if i then
					table.remove(group.staged, i)
				end
			else
				group.pending -= 1
			end
			-- The next waiting task (older than this one) takes its place.
			local nextTask = table.remove(slot.parked, 1)
			slot.current = nextTask
			if nextTask then
				self.parkedCount -= 1
				enqueue(self, nextTask)
			end
		else
			for i, t in slot.parked do
				if t.group == group then
					old = t
					forget(self, t)
					table.remove(slot.parked, i)
					group.pending -= 1
					break
				end
			end
		end
		if old then
			replaced = { old }
		end
	end
	local current = slot.current
	if current == nil then
		slot.current = task
		enqueue(self, task)
	elseif current.state == QUEUED and supersedes(task, current) and (current.restyle or not self.started(current)) then
		-- Not started (or a restyle): the newer mesh takes its place, at least as urgently.
		forget(self, current)
		task.lane = math.min(task.lane, current.lane)
		slot.current = task
		enqueue(self, task)
		replaced = replaced or {}
		table.insert(replaced :: { Task }, current)
	else
		local parked = slot.parked
		local last = parked[#parked]
		if last ~= nil and supersedes(task, last) then
			-- A newer mesh for the section: the parked one is out of date.
			forget(self, last)
			task.lane = math.min(task.lane, last.lane)
			parked[#parked] = task
			task.state = PARKED
			self.parkedCount += 1
			replaced = replaced or {}
			table.insert(replaced :: { Task }, last)
		else
			park(self, slot, task)
		end
	end
	return replaced
end

--[[
	Will a task start building this section later (one is parked, or the uncommitted one is queued
	and not started)? Such a build uses whatever look is current when it starts.
]]
function Schedule.startsLater(self: Schedule, node: any, section: number): boolean
	local sections = self.slots[node]
	local slot = sections and sections[section]
	if slot == nil then
		return false
	end
	if #slot.parked > 0 then
		return true
	end
	local current = slot.current
	return current ~= nil and current.state == QUEUED and not self.started(current)
end

-- The next task to build in `lane` (stays in the lane until `pop`).
function Schedule.peek(self: Schedule, lane: number): Task?
	local list = self.lanes[lane]
	if lane == RenderSchedule.EDIT then
		local head = self.head
		while true do
			local task = list[head]
			if task == nil then
				-- Empty: start over at the front.
				table.clear(list)
				self.head = 1
				return nil
			end
			if task.state == QUEUED then
				self.head = head
				return task
			end
			head += 1
		end
	end
	while true do
		local n = #list
		local task = list[n]
		if task == nil then
			return nil
		end
		if task.state == QUEUED then
			return task
		end
		list[n] = nil
	end
end

-- Takes the task `peek` returned out of its lane (it is built).
function Schedule.pop(self: Schedule, lane: number)
	local list = self.lanes[lane]
	if lane == RenderSchedule.EDIT then
		local head = self.head + 1
		if head > #list then
			table.clear(list)
			head = 1
		elseif head > 64 and head > #list // 2 then
			-- Compact now and then instead of table.remove(list, 1) per task.
			table.move(list, head, #list, 1)
			local keep = #list - head + 1
			for i = #list, keep + 1, -1 do
				list[i] = nil
			end
			head = 1
		end
		self.head = head
	else
		list[#list] = nil
	end
	self.queued[lane] -= 1
end

--[[
	A task is built (and popped). Returns the tasks to put live now, in order: just this one, or
	its whole group once complete; nil while the group waits.
]]
function Schedule.stage(self: Schedule, task: Task): { Task }?
	task.state = STAGED
	self.stagedCount += 1
	local group = task.group
	if group == nil or group.done then
		return { task }
	end
	group.pending -= 1
	table.insert(group.staged, task)
	if group.forced or complete(group) then
		return flush(self, group)
	end
	return nil
end

-- A staged task went live: the section's next task may start.
function Schedule.committed(self: Schedule, task: Task)
	if task.state == STAGED then
		self.stagedCount -= 1
	end
	task.state = DONE
	local sections = self.slots[task.node]
	local slot = sections and sections[task.section]
	if slot == nil or slot.current ~= task then
		return
	end
	local nextTask = table.remove(slot.parked, 1)
	if nextTask then
		self.parkedCount -= 1
		slot.current = nextTask
		enqueue(self, nextTask)
	else
		slot.current = nil
		sections[task.section] = nil
		if next(sections) == nil then
			self.slots[task.node] = nil
		end
	end
end

-- A new commit group held once (by its opener).
function Schedule.openGroup(self: Schedule, now: number): Group
	local group: Group = { holds = 1, pending = 0, staged = {}, opened = now, forced = false, done = false }
	self.groups[group] = true
	return group
end

function Schedule.hold(_self: Schedule, group: Group)
	group.holds += 1
end

-- Releases one hold; returns the tasks to put live now if that completed the group.
function Schedule.close(self: Schedule, group: Group): { Task }?
	group.holds -= 1
	if group.done or not complete(group) then
		return nil
	end
	return flush(self, group)
end

--[[
	Drops every task of a node (it was removed). Returns the dropped tasks (the caller releases what
	they built) and tasks of other nodes that can go live now because their group was waiting only
	for these.
]]
function Schedule.drop(self: Schedule, node: any): ({ Task }, { Task })
	local dropped: { Task } = {}
	local live: { Task } = {}
	local sections = self.slots[node]
	if sections == nil then
		return dropped, live
	end
	self.slots[node] = nil
	for _, slot in sections do
		local tasks = table.clone(slot.parked)
		if slot.current then
			table.insert(tasks, 1, slot.current)
		end
		for _, task in tasks do
			local wasStaged = task.state == STAGED
			forget(self, task)
			table.insert(dropped, task)
			local ready = leaveGroup(self, task, wasStaged)
			if ready then
				for _, t in ready do
					if t.node ~= node then
						table.insert(live, t)
					end
				end
			end
		end
	end
	return dropped, live
end

-- Groups open longer than `timeout` seconds stop waiting; returns their staged tasks.
function Schedule.expire(self: Schedule, now: number, timeout: number): { Task }
	local live: { Task } = {}
	for group in self.groups do
		if not group.forced and now - group.opened > timeout then
			group.forced = true
			for _, task in flush(self, group) do
				table.insert(live, task)
			end
			-- Tasks staged later go live alone (group.done).
		end
	end
	table.sort(live, function(a, b)
		return a.seq < b.seq
	end)
	return live
end

-- Re-sorts the prioritised lanes (call after the streamer updated its nodes' priorities).
function Schedule.reprioritise(self: Schedule)
	for lane = RenderSchedule.NEAR, LANES do
		local list = self.lanes[lane]
		local kept: { Task } = table.create(self.queued[lane])
		for _, task in list do
			if task.state == QUEUED then
				table.insert(kept, task)
			end
		end
		-- Sort keys once (comparisons read node fields otherwise).
		local keys: { [Task]: number } = {}
		for _, task in kept do
			keys[task] = priorityOf(task)
		end
		table.sort(kept, function(a, b)
			local pa, pb = keys[a], keys[b]
			if pa ~= pb then
				return pa > pb
			end
			return a.seq > b.seq
		end)
		self.lanes[lane] = kept
	end
end

-- Tasks not live yet: queued, parked or staged.
function Schedule.count(self: Schedule): number
	local n = self.parkedCount + self.stagedCount
	for lane = 1, LANES do
		n += self.queued[lane]
	end
	return n
end

function Schedule.laneCount(self: Schedule, lane: number): number
	return self.queued[lane]
end

-- A node's tasks that are not live yet (uncommitted first, then parked), by section.
function Schedule.tasksOf(self: Schedule, node: any): { Task }
	local out: { Task } = {}
	local sections = self.slots[node]
	if sections then
		for _, slot in sections do
			if slot.current then
				table.insert(out, slot.current)
			end
			for _, task in slot.parked do
				table.insert(out, task)
			end
		end
	end
	return out
end

return RenderSchedule
