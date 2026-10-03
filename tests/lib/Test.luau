--[[
	A very small test framework: `t.test(name, fn)`, `t.eq(a, b, msg)`, `t.ok(cond, msg)`.
]]

local Test = {}

export type Context = {
	test: (name: string, fn: () -> ()) -> (),
	eq: (actual: any, expected: any, message: string?) -> (),
	ok: (condition: any, message: string?) -> (),
	near: (actual: number, expected: number, tolerance: number, message: string?) -> (),
}

function Test.new(): (Context, () -> (number, number))
	local passed, failed = 0, 0

	local ctx: Context = {
		test = function(name, fn)
			local ok, err = pcall(fn)
			if ok then
				passed += 1
				print(`  [PASS] {name}`)
			else
				failed += 1
				print(`  [FAIL] {name}\n         {err}`)
			end
		end,
		eq = function(actual, expected, message)
			if actual ~= expected then
				error(`{message or "values differ"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
			end
		end,
		ok = function(condition, message)
			if not condition then
				error(message or "assertion failed", 2)
			end
		end,
		near = function(actual, expected, tolerance, message)
			if math.abs(actual - expected) > tolerance then
				error(`{message or "values differ"}: expected {expected} ± {tolerance}, got {actual}`, 2)
			end
		end,
	}

	return ctx, function()
		return passed, failed
	end
end

return Test
