--!strict
--[[
	The client's floating origin: where the render frame's 0 is in the world, and every conversion
	between the two frames. Pure Luau (no services, no instances), so specs, the streamer's fake
	`game` and every loader can require it; its state is per VM (workers never touch it: they make
	node-local cells).

	Three frames:
	  world blocks  blocks as Luau doubles: every piece of logic (the hull, the streamer, raycasts,
	                entities, mobs, weather, sounds, the protocol, the server). Exact.
	  world studs   blocks x Config.BlockSize, doubles: transitional values on the way to an
	                instance. Exact.
	  render studs  world studs - O, float32 inside Vector3 / CFrame: only Roblox instances
	                (CFrames, Positions, attachments, the camera, SetListener).
	O = (Origin.x, 0, Origin.z) studs. It never shifts Y (the world is 3072 studs tall: altitude-
	dependent engine behaviour, the Atmosphere's haze and lighting, stays as it is) and is a multiple
	of Config.Origin.Snap (768 = 2^8 x 3 studs, 16 chunks): blocks, chunks, the 4-stud lighting
	grid and power-of-two texture tiles up to 256 studs line up identically before and after a
	move, and block centres (x + 0.5) x 3 - O are exact in float32 for |x| <= 1e6 within one snap of
	O. The server has no origin.

	Rules for code that places or reads instances:
	  R1  never write a world Vector3 into an instance: convert from doubles (`blocksToRender`,
	      `renderX` / `renderZ`). A world Vector3 is float32: at 1e6 blocks that is 1/16 block.
	  R2  never compare a render position with a world one: convert one side (`renderToBlocks`,
	      `blocksToRender`). Differences of two render positions (reach, distance to the camera,
	      VectorToObjectSpace) need nothing.
	  R3  Y is never shifted.
	  R4  directions (LookVector, velocities, sizes) are frame-free.
	  R5  a module that caches render studs subscribes to `onRebase`; one that places instances once
	      registers a client Rendering/Rebase mover; per-frame writers only convert.

	Moving (`plan`, `planTo`, `set`): client Rendering/Rebase moves the origin when the camera is
	farther than Config.Origin.RebaseDistance (8192 studs: 1/1024 stud resolution there) from it
	along X or Z, or SoftDistance (3072) at a moment a hitch can't be seen; `set` then tells the
	listeners (caches) and Rebase moves the instances. With Config.Origin.Enabled false `plan` and
	`planTo` give nothing, the origin stays at 0 and every conversion is the identity.

	The Vector3 / CFrame functions use Roblox's Vector3 and CFrame, read when called (under Lune a
	spec provides them as globals: tests/spec/Origin); the scalar ones need nothing.
]]

local Config = require(script.Parent.Parent.Config)

local BLOCK = Config.BlockSize
local Settings = Config.Origin

export type Listener = (dx: number, dz: number, epoch: number) -> ()

local Origin = {}

-- World studs of the render origin (multiples of Config.Origin.Snap).
Origin.x = 0
Origin.z = 0
-- +1 at every move (containers remember the origin they were placed for).
Origin.epoch = 0

local listeners: { Listener } = {}

local function finite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

--[[ World -> render ]]

-- Block coordinates (doubles) -> render studs: (x * B - Ox, y * B, z * B - Oz), doubles until the
-- Vector3.
function Origin.blocksToRender(x: number, y: number, z: number): Vector3
	return Vector3.new(x * BLOCK - Origin.x, y * BLOCK, z * BLOCK - Origin.z)
end

-- The centre of block (x, y, z) in render studs.
function Origin.blockCentreToRender(x: number, y: number, z: number): Vector3
	return Vector3.new((x + 0.5) * BLOCK - Origin.x, (y + 0.5) * BLOCK, (z + 0.5) * BLOCK - Origin.z)
end

-- World studs (doubles) -> render studs.
function Origin.studsToRender(sx: number, sy: number, sz: number): Vector3
	return Vector3.new(sx - Origin.x, sy, sz - Origin.z)
end

-- One coordinate (world studs, a double) -> render studs: for hot paths that build their own
-- CFrames.
function Origin.renderX(worldStudsX: number): number
	return worldStudsX - Origin.x
end

function Origin.renderZ(worldStudsZ: number): number
	return worldStudsZ - Origin.z
end

-- A world-studs Vector3 -> render studs. The input is float32 already: only for values near the
-- origin (offsets, small worlds); far positions go through the double forms above.
function Origin.toRender(v: Vector3): Vector3
	if Origin.x == 0 and Origin.z == 0 then
		return v
	end
	return v - Vector3.new(Origin.x, 0, Origin.z)
end

-- A world-studs CFrame -> render studs (rotation kept).
function Origin.cframeToRender(cf: CFrame): CFrame
	if Origin.x == 0 and Origin.z == 0 then
		return cf
	end
	return cf - Vector3.new(Origin.x, 0, Origin.z)
end

--[[ Render -> world ]]

-- Render studs -> world blocks, as doubles: ((v.X + Ox) / B, v.Y / B, (v.Z + Oz) / B).
function Origin.renderToBlocks(v: Vector3): (number, number, number)
	return (v.X + Origin.x) / BLOCK, v.Y / BLOCK, (v.Z + Origin.z) / BLOCK
end

-- Render studs -> world studs, as doubles.
function Origin.renderToStuds(v: Vector3): (number, number, number)
	return v.X + Origin.x, v.Y, v.Z + Origin.z
end

-- Render studs -> a world-studs Vector3 (float32: for text and logs, not for logic far out).
function Origin.toWorld(v: Vector3): Vector3
	if Origin.x == 0 and Origin.z == 0 then
		return v
	end
	return v + Vector3.new(Origin.x, 0, Origin.z)
end

-- (Ox, 0, Oz).
function Origin.offset(): Vector3
	return Vector3.new(Origin.x, 0, Origin.z)
end

--[[ Planning (pure) ]]

-- The multiple of Config.Origin.Snap nearest to `worldStuds`.
function Origin.snap(worldStuds: number): number
	local snap = Settings.Snap
	return math.floor(worldStuds / snap + 0.5) * snap
end

--[[
	The new origin (world studs) for a camera at render (x, z): when it is farther than
	RebaseDistance from the origin along X or Z, or farther than SoftDistance and `hidden` (a
	moment a hitch can't be seen). nil otherwise, when the snapped origin would not move, or with
	Config.Origin.Enabled false.
]]
function Origin.plan(cameraRenderX: number, cameraRenderZ: number, hidden: boolean): (number?, number?)
	if not Settings.Enabled or not finite(cameraRenderX) or not finite(cameraRenderZ) then
		return nil, nil
	end
	local far = math.max(math.abs(cameraRenderX), math.abs(cameraRenderZ))
	if far <= Settings.RebaseDistance and not (hidden and far > Settings.SoftDistance) then
		return nil, nil
	end
	local x, z = Origin.snap(Origin.x + cameraRenderX), Origin.snap(Origin.z + cameraRenderZ)
	if x == Origin.x and z == Origin.z then
		return nil, nil
	end
	return x, z
end

--[[
	The new origin for a destination at world studs (x, z) (a teleport, a respawn): its snapped
	position when it lies farther than SoftDistance from the current origin along X or Z, else nil
	(also with Config.Origin.Enabled false).
]]
function Origin.planTo(worldStudsX: number, worldStudsZ: number): (number?, number?)
	if not Settings.Enabled or not finite(worldStudsX) or not finite(worldStudsZ) then
		return nil, nil
	end
	local far = math.max(math.abs(worldStudsX - Origin.x), math.abs(worldStudsZ - Origin.z))
	if far <= Settings.SoftDistance then
		return nil, nil
	end
	local x, z = Origin.snap(worldStudsX), Origin.snap(worldStudsZ)
	if x == Origin.x and z == Origin.z then
		return nil, nil
	end
	return x, z
end

--[[ Moving (no instances: client Rendering/Rebase moves those) ]]

--[[
	Puts the origin at world studs (x, z) (snapped: `plan` and `planTo` give such values) and
	returns (dx, dz) = new - old. A move adds 1 to `epoch` and calls the listeners in the order
	they subscribed, with (dx, dz, epoch); setting the origin where it is does nothing.
]]
function Origin.set(x: number, z: number): (number, number)
	assert(finite(x) and finite(z), "Origin.set: the origin must be finite")
	local dx, dz = x - Origin.x, z - Origin.z
	if dx == 0 and dz == 0 then
		return 0, 0
	end
	Origin.x, Origin.z = x, z
	Origin.epoch += 1
	local epoch = Origin.epoch
	-- (A copy: a listener may disconnect itself or others. Moves are rare.)
	for _, listener in table.clone(listeners) do
		listener(dx, dz, epoch)
	end
	return dx, dz
end

-- Calls `listener(dx, dz, epoch)` after every move; returns its disconnect.
function Origin.onRebase(listener: Listener): () -> ()
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

-- Back to the start (specs): the origin at 0, epoch 0, no listeners.
function Origin.reset()
	Origin.x, Origin.z, Origin.epoch = 0, 0, 0
	listeners = {}
end

return Origin
