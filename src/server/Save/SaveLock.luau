--!strict
--[[
	Who has a saved world open: a session lock per world (Minecraft's session.lock), so two
	servers never write one world. Pure rules for World/WorldSave, which applies them inside
	DataStore UpdateAsync transforms on the key "<id>/lock" (the transform sees the stored value
	and returns the new one, or nil to leave it: so taking a lock is one atomic step).

	  Value     { job = the server's JobId (in Studio, a GUID of the session), at = os.time() of
	            its last heartbeat, released = true once it closed the world }.
	  Live      a lock is live while it is not released and its heartbeat is less than
	            Config.Save.LockTimeout (180 s) old: the server holding it renews it every third
	            of that, so a live lock means a running server; a crashed one's goes stale.
	  acquire   takes the lock when it is free (none, released, stale) or already this job's;
	            a live lock of another job refuses ("in use by another server"). Loading and
	            deleting a world first take its lock.
	  renew     the heartbeat: keeps this job's lock fresh. A lock taken by another job in the
	            meantime (this server stalled past the timeout and another took over) is lost:
	            the server stops saving that world (`lost`).
	  release   on closing (BindToClose) or giving up a load: this job's lock becomes released,
	            another's is left alone.
]]

export type Lock = { job: string, at: number, released: boolean? }

local SaveLock = {}

local function read(value: unknown): Lock?
	if type(value) ~= "table" then
		return nil
	end
	local stored = value :: { [string]: any }
	if type(stored.job) ~= "string" or type(stored.at) ~= "number" or stored.at ~= stored.at then
		return nil
	end
	return { job = stored.job, at = stored.at, released = stored.released == true }
end
SaveLock.read = read

-- Is the stored lock `value` held by a running server (not released, heartbeat within `timeout`)?
function SaveLock.isLive(value: unknown, now: number, timeout: number): boolean
	local lock = read(value)
	return lock ~= nil and not lock.released and now - lock.at < timeout
end

-- Is the stored lock live and another job's?
function SaveLock.heldByOther(value: unknown, job: string, now: number, timeout: number): boolean
	local lock = read(value)
	return lock ~= nil and lock.job ~= job and SaveLock.isLive(lock, now, timeout)
end

--[[
	The value that takes the lock for `job` at `now`, or nil and why not (a live lock of another
	job). An UpdateAsync transform returns it as it is.
]]
function SaveLock.acquire(value: unknown, job: string, now: number, timeout: number): (Lock?, string?)
	if SaveLock.heldByOther(value, job, now, timeout) then
		return nil, "in use by another server"
	end
	return { job = job, at = now }, nil
end

--[[
	The heartbeat: the renewed value, or nil and `lost` true when another job holds the lock now
	(or it was released: someone deleted or closed the world).
]]
function SaveLock.renew(value: unknown, job: string, now: number): (Lock?, boolean)
	local lock = read(value)
	if lock and lock.job == job and not lock.released then
		return { job = job, at = now }, false
	end
	return nil, true
end

-- The released value of `job`'s lock (nil: it is not this job's, leave it).
function SaveLock.release(value: unknown, job: string, now: number): Lock?
	local lock = read(value)
	if lock and lock.job == job then
		return { job = job, at = now, released = true }
	end
	return nil
end

return SaveLock
