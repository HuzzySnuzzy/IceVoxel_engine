--!strict
--[[
	The Roblox side of the mobs' parts, the thin glue between Entities/MobRigPool (which works
	out every part's size, colour and frame as numbers) and the scene. Entities/MobRenderer draws
	the game's mobs with it, and the Studio probe (tools/probes/ZombieRigProbe) the probe's, so
	the probe times the game's own code; tests/spec/ZombieRigProbe runs both on Lune's Roblox
	instances.

	  factory   MobRigPool's part factory: anchored Parts that collide with, touch and are queried
	            by nothing (SmoothPlastic, smooth surfaces, Locked), shadows only where the pool
	            asks (a rig's head and torso, the boxes); shown in `folder`, parked out of the
	            scene (Parent nil) while pooled. A part destroyed takes nothing with it: flames
	            are taken off a rig before it is let go (MobRigPool), and a Fire left on a part
	            would go with it and lock its Parent for good, so `destroy` takes any off first.
	  flames    a burning mob's Fire (BurningView's colours, Size by the mob's height), hung by
	            the pool on the part its tier burns on (MobRig.FIRE_SLOT).
	  move      the pool's frame: `parts[1..count]` to their frames (`matrices`, 12 numbers a part,
	            CFrame.new's order) in one BulkMoveTo, after the camera.
]]

local MobRigPool = require(script.Parent.MobRigPool)
local ZombieLooks = require(script.Parent.ZombieLooks)

local MobParts = {}

-- Flames (BurningView's colours): Fire.Size per block of the mob's height.
MobParts.FLAME_COLOUR = Color3.fromRGB(255, 140, 30)
MobParts.FLAME_GLOW = Color3.fromRGB(255, 220, 90)
MobParts.FLAME_SIZE = 3

local function colourOf(colour: number): Color3
	local r, g, b = ZombieLooks.unpack(colour)
	return Color3.fromRGB(r, g, b)
end

-- A part factory for MobRigPool showing its parts in `folder` (see the header).
function MobParts.factory(folder: Instance): MobRigPool.Factory<BasePart>
	return {
		create = function(sx: number, sy: number, sz: number, colour: number, shadow: boolean): BasePart
			local part = Instance.new("Part")
			part.Name = "Mob"
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = shadow
			part.Locked = true
			part.Material = Enum.Material.SmoothPlastic
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Size = Vector3.new(sx, sy, sz)
			part.Color = colourOf(colour)
			return part
		end,
		resize = function(part: BasePart, sx: number, sy: number, sz: number)
			part.Size = Vector3.new(sx, sy, sz)
		end,
		paint = function(part: BasePart, colour: number)
			part.Color = colourOf(colour)
		end,
		park = function(part: BasePart)
			part.Parent = nil
		end,
		show = function(part: BasePart)
			part.Parent = folder
		end,
		destroy = function(part: BasePart)
			local flames = part:FindFirstChildOfClass("Fire")
			if flames then
				flames.Parent = nil
			end
			part:Destroy()
		end,
		attach = function(flames: Fire, part: BasePart?)
			flames.Parent = part
		end,
	}
end

-- Flames for a burning mob `height` blocks tall (out of the scene until the pool hangs them).
function MobParts.flames(height: number): Fire
	local flames = Instance.new("Fire")
	flames.Color = MobParts.FLAME_COLOUR
	flames.SecondaryColor = MobParts.FLAME_GLOW
	flames.Heat = 9
	flames.Size = math.max(2, height * MobParts.FLAME_SIZE)
	return flames
end

-- Moves the pool's frame in one BulkMoveTo; `cframes` is the caller's list, reused every frame.
function MobParts.move(pool: MobRigPool.Pool<BasePart>, cframes: { CFrame })
	local n, m = pool.count, pool.matrices
	for i = 1, n do
		local o = (i - 1) * 12
		cframes[i] = CFrame.new(
			m[o + 1],
			m[o + 2],
			m[o + 3],
			m[o + 4],
			m[o + 5],
			m[o + 6],
			m[o + 7],
			m[o + 8],
			m[o + 9],
			m[o + 10],
			m[o + 11],
			m[o + 12]
		)
	end
	for i = n + 1, #cframes do
		cframes[i] = nil
	end
	if n > 0 then
		workspace:BulkMoveTo(pool.parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

return MobParts
