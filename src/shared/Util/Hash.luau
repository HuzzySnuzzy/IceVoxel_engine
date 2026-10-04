--!strict
--!native
--[[
	Deterministic integer hashing and a tiny seeded RNG.

	Everything procedural must give identical results on the server, on every client and inside every
	worker actor, so we cannot use `Random` with shared state or `math.random`. These functions are
	pure, work on 32-bit unsigned integers and never lose precision (products stay below 2^53).
]]

local bxor = bit32.bxor
local rshift = bit32.rshift
local lshift = bit32.lshift

local U32 = 4294967296

local Hash = {}

-- (a * b) mod 2^32 without overflowing the 53-bit double mantissa.
local function mul32(a: number, b: number): number
	local lo = (a % 65536) * b
	local hi = ((a // 65536) * b) % 65536 * 65536
	return (lo + hi) % U32
end
Hash.mul32 = mul32

local function fmix(h: number): number
	h = bxor(h, rshift(h, 16))
	h = mul32(h, 0x85EBCA6B)
	h = bxor(h, rshift(h, 13))
	h = mul32(h, 0xC2B2AE35)
	return bxor(h, rshift(h, 16))
end

-- Hash of a seed and up to three integers (negative values are fine). Returns a u32.
function Hash.hash3(seed: number, x: number, y: number, z: number): number
	local h = fmix(seed % U32)
	h = fmix(bxor(h, mul32(x % U32, 0x27D4EB2F)))
	h = fmix(bxor(h, mul32(y % U32, 0x165667B1)))
	return fmix(bxor(h, mul32(z % U32, 0x9E3779B1)))
end

function Hash.hash2(seed: number, x: number, z: number): number
	return Hash.hash3(seed, x, 0x5BD1E995, z)
end

-- Same as hash3 but mapped to [0, 1).
function Hash.float3(seed: number, x: number, y: number, z: number): number
	return Hash.hash3(seed, x, y, z) / U32
end

-- Turns a string into a u32 (FNV-1a). Used to derive independent sub-seeds ("salts") by name.
function Hash.string(s: string): number
	local h = 0x811C9DC5
	for i = 1, #s do
		h = mul32(bxor(h, string.byte(s, i)), 0x01000193)
	end
	return h
end

--[[
	Xorshift32 random generator. Only uses shifts and xors, so it is exact in Luau and fast.
]]
export type Rng = {
	state: number,
	next: (self: Rng) -> number,
	float: (self: Rng) -> number,
	int: (self: Rng, min: number, max: number) -> number,
	chance: (self: Rng, p: number) -> boolean,
}

local Rng = {}
Rng.__index = Rng

function Rng.next(self: Rng): number
	local x = self.state
	x = bxor(x, lshift(x, 13))
	x = bxor(x, rshift(x, 17))
	x = bxor(x, lshift(x, 5))
	self.state = x
	return x
end

-- Uniform float in [0, 1).
function Rng.float(self: Rng): number
	return Rng.next(self) / U32
end

-- Uniform integer in [min, max] (inclusive).
function Rng.int(self: Rng, min: number, max: number): number
	return min + (Rng.next(self) % (max - min + 1))
end

function Rng.chance(self: Rng, p: number): boolean
	return Rng.float(self) < p
end

function Hash.rng(seed: number): Rng
	local state = fmix(seed % U32)
	if state == 0 then
		state = 0x9E3779B9
	end
	return (setmetatable({ state = state }, Rng) :: any) :: Rng
end

return Hash
