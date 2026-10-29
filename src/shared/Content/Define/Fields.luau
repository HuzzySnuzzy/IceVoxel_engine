--!strict
--[[
	How Content/Define's generators take what a pack gives them (Content/Define lists them). A
	generator copies every field of Content/Schema's kind that the author gives onto the entries it
	makes, with its defaults only where a field is left out (`defaults`), so an iron door, a set of
	armor with its `shielding` or a flower on sand is written like any other entry. So that no
	field is ever lost, `check` refuses, before anything is made, a field the generator would not
	know (with Schema's "did you mean"), one of the wrong type, one it needs left out, and one it
	makes itself (a door's `shape`, a fence's `fence`), naming the generator and the entry:
	"Content/Define: armorSet Lead: shieldng is no field it may have (did you mean shielding?)".
	A generator's own fields (a door's `wood`, an armor set's `points`) are checked with it.
]]

local Schema = require(script.Parent.Parent.Schema)

type Check = Schema.Check

-- What a generator takes besides its kind's fields (`check`): its own fields (name -> Check), the
-- ones it needs, and the ones it makes itself (name -> what makes it).
export type Rules = {
	kind: string?,
	own: { [string]: Check }?,
	needs: { string }?,
	made: { [string]: string }?,
}

local Fields = {}

-- Each kind's fields (Content/Schema).
local KINDS: { [string]: { [string]: Check } } = {
	blocks = Schema.BLOCK_FIELDS,
	items = Schema.ITEM_FIELDS,
}

local function fail(what: string, text: string): never
	error(`Content/Define: {what}: {text}`, 0)
end

-- A Check of a function (a door's `upper`).
function Fields.FUNCTION(value: any): string?
	return if type(value) == "function" then nil else ` must be a function, not a {type(value)}`
end

--[[
	Errors unless `value` (the generator's argument, `what` naming it in messages: "door Iron") is
	a table whose every field is one of `rules.own` or of `rules.kind`'s (Schema: "blocks",
	"items") and passes its check, none is one `rules.made` names, and every field of
	`rules.needs` is there.
]]
function Fields.check(what: string, value: any, rules: Rules)
	if type(value) ~= "table" then
		fail(what, `must be a table of fields, not a {type(value)}`)
	end
	local own: { [string]: Check } = rules.own or {}
	local fields: { [string]: Check } = if rules.kind then KINDS[rules.kind] else {}
	local made: { [string]: string } = rules.made or {}
	local needs: { string } = rules.needs or {}
	for key, element in value do
		if type(key) ~= "string" then
			fail(what, `has a key that is no name, {tostring(key)}`)
		end
		local maker = made[key]
		if maker then
			fail(what, `{key} is the generator's to make ({maker})`)
		end
		local check = own[key] or fields[key]
		if check == nil then
			-- (The hint: the fields it may have, the ones it makes left out.)
			local known: { [string]: boolean } = {}
			for name in fields do
				if made[name] == nil then
					known[name] = true
				end
			end
			for name in own do
				known[name] = true
			end
			local near = Schema.suggest(key, known)
			fail(what, `{key} is no field it may have{if near then ` (did you mean {near}?)` else ""}`)
		end
		local problem = check(element)
		if problem then
			fail(what, `{key}{problem}`)
		end
	end
	for _, key in needs do
		if value[key] == nil then
			fail(what, `{key} is missing`)
		end
	end
end

-- `entry` with `defaults`' fields wherever it has none of its own (it, changed).
function Fields.defaults<T>(entry: T, defaults: { [string]: any }): T
	for field, value in defaults do
		if (entry :: any)[field] == nil then
			(entry :: any)[field] = value
		end
	end
	return entry
end

return Fields
