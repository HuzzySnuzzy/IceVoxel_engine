--!strict
--!native
--[[
	Cave carving for full detail (LOD 0) chunks.

	Two kinds of caves:
	  * "spaghetti" tunnels where two independent 3D noise fields are both close to zero,
	  * "cheese" caverns where a third, lower-frequency field is high.

	3D noise is the most expensive part of generation, so the fields are sampled on a coarse grid
	(every GRID blocks, aligned to world coordinates so neighbouring chunks agree) and trilinearly
	interpolated per block.

	Caves are carved as CaveAir and stay at least Config.Caves.SurfaceMargin blocks below the
	surface. That keeps them invisible from above ground, so the client only has to mesh cave walls
	close to the camera (see Blocks.cullLutHiddenCaves).
]]

local Config = require(script.Parent.Parent.Config)
local Blocks = require(script.Parent.Parent.Blocks)
local ChunkLayout = require(script.Parent.Parent.World.ChunkLayout)
local Noise = require(script.Parent.Noise)

local GRID = 4
local SIZE = ChunkLayout.SIZE
local P = ChunkLayout.PADDED

local TUNNEL_RADIUS = 0.067 -- how close to zero both tunnel fields must be
local TUNNEL_RADIUS_SQ = TUNNEL_RADIUS * TUNNEL_RADIUS
local CAVERN_THRESHOLD = 0.62 -- cavern field value above which rock is removed
local CAVERN_MAX_Y = 48 -- caverns only below this height

local floor = math.floor
local writeu16 = buffer.writeu16

export type Carver = (data: buffer, originX: number, originZ: number, heights: { number }) -> ()

local Caves = {}

function Caves.new(seed: number): Carver
	local tunnelA = Noise.noise3(seed, "caves.tunnelA", 1 / 56, 1.5)
	local tunnelB = Noise.noise3(seed, "caves.tunnelB", 1 / 56, 1.5)
	local cavern = Noise.noise3(seed, "caves.cavern", 1 / 80, 1.8)

	local margin = Config.Caves.SurfaceMargin
	local minY = Config.Caves.MinY
	local caveAir = Blocks.CAVE_AIR

	local gridA: { number }, gridB: { number }, gridC: { number } = {}, {}, {}
	local colA: { number }, colB: { number }, colC: { number } = {}, {}, {}

	-- `heights[pz * P + px + 1]` is the terrain height of every padded column.
	return function(data: buffer, originX: number, originZ: number, heights: { number })
		local maxTop = 0
		for i = 1, P * P do
			local top = heights[i] - margin
			if top > maxTop then
				maxTop = top
			end
		end
		if maxTop <= minY then
			return
		end

		-- Grid covering the padded chunk.
		local gx0 = (originX - 1) // GRID
		local gz0 = (originZ - 1) // GRID
		local gy0 = minY // GRID
		local nxg = (originX + SIZE) // GRID + 2 - gx0
		local nzg = (originZ + SIZE) // GRID + 2 - gz0
		local nyg = (maxTop - 1) // GRID + 2 - gy0
		local layer = nxg * nzg

		local i = 1
		for gy = gy0, gy0 + nyg - 1 do
			local y = gy * GRID
			local caverns = y < CAVERN_MAX_Y
			for gz = gz0, gz0 + nzg - 1 do
				local z = gz * GRID
				for gx = gx0, gx0 + nxg - 1 do
					local x = gx * GRID
					gridA[i] = tunnelA(x, y, z)
					gridB[i] = tunnelB(x, y, z)
					gridC[i] = if caverns then cavern(x, y, z) else -1
					i += 1
				end
			end
		end

		for pz = 0, P - 1 do
			local wz = originZ + pz - 1
			local fz = wz / GRID - gz0
			local iz = floor(fz)
			local tz = fz - iz
			for px = 0, P - 1 do
				local top = heights[pz * P + px + 1] - margin
				if top > minY then
					local wx = originX + px - 1
					local fx = wx / GRID - gx0
					local ix = floor(fx)
					local tx = fx - ix

					-- Bilinear interpolation on every grid level this column crosses.
					local levels = (top - 1) // GRID + 2 - gy0
					for l = 1, levels do
						local i00 = (l - 1) * layer + iz * nxg + ix + 1
						local i10 = i00 + 1
						local i01 = i00 + nxg
						local i11 = i01 + 1

						local a0 = gridA[i00] + (gridA[i10] - gridA[i00]) * tx
						local a1 = gridA[i01] + (gridA[i11] - gridA[i01]) * tx
						colA[l] = a0 + (a1 - a0) * tz

						local b0 = gridB[i00] + (gridB[i10] - gridB[i00]) * tx
						local b1 = gridB[i01] + (gridB[i11] - gridB[i01]) * tx
						colB[l] = b0 + (b1 - b0) * tz

						local c0 = gridC[i00] + (gridC[i10] - gridC[i00]) * tx
						local c1 = gridC[i01] + (gridC[i11] - gridC[i01]) * tx
						colC[l] = c0 + (c1 - c0) * tz
					end

					-- Linear interpolation between levels for each block. Values are linear inside a
					-- segment, so a segment where a tunnel field stays away from zero (or the cavern
					-- field stays low) on both ends can be skipped entirely.
					local base = (pz * P + px) * 2
					local stride = P * P * 2
					for l = 1, levels - 1 do
						local a0, a1 = colA[l], colA[l + 1]
						local b0, b1 = colB[l], colB[l + 1]
						local c0, c1 = colC[l], colC[l + 1]
						local tunnel = not (
							(a0 > TUNNEL_RADIUS and a1 > TUNNEL_RADIUS)
							or (a0 < -TUNNEL_RADIUS and a1 < -TUNNEL_RADIUS)
							or (b0 > TUNNEL_RADIUS and b1 > TUNNEL_RADIUS)
							or (b0 < -TUNNEL_RADIUS and b1 < -TUNNEL_RADIUS)
						)
						if tunnel or c0 > CAVERN_THRESHOLD or c1 > CAVERN_THRESHOLD then
							local segment = (gy0 + l - 1) * GRID
							local yStart = if segment < minY then minY else segment
							local yEnd = segment + GRID - 1
							if yEnd > top - 1 then
								yEnd = top - 1
							end
							local da, db, dc = a1 - a0, b1 - b0, c1 - c0
							for y = yStart, yEnd do
								local t = (y - segment) / GRID
								local a = a0 + da * t
								local b = b0 + db * t
								if a * a + b * b < TUNNEL_RADIUS_SQ or c0 + dc * t > CAVERN_THRESHOLD then
									writeu16(data, base + y * stride, caveAir)
								end
							end
						end
					end
				end
			end
		end
	end
end

return Caves
