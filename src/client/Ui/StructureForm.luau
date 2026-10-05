--!strict
--[[
	What the structure block screen and the jigsaw screen hold, without any GUI: Minecraft 1.20.1's
	StructureBlockEditScreen and JigsawBlockEditScreen as data. Pure (no Roblox APIs), so the tests
	drive it; Ui/StructureScreen draws it.

	Structure block form
	  Text fields as typed (name, relative position x y z, size x y z, integrity, seed, the DATA
	  marker), plus the mode, rotation, mirror and the two toggles. `structureSettings` reads them
	  the way Minecraft does: a number that does not parse is 0 (a position or a size), 1 (the
	  integrity) or 0 (the seed), and Structures/Settings clamps the rest (positions to +-48, sizes
	  to 0..48, integrity to 0..1). Typing is filtered as Minecraft's fields filter it: names keep
	  the characters resource locations allow (Settings.validName), numbers digits (and a leading
	  minus where it makes sense, a dot in the integrity), the marker printable text; each field has
	  Minecraft's length cap.

	  Layout (`layout(mode)`): Minecraft's widgets per mode at Minecraft's GUI positions, x from the
	  screen's centre. Each mode shows what Minecraft's updateMode shows (SAVE: name, position,
	  size, "Show Invisible Blocks", DETECT, SAVE; LOAD: name, position, integrity and seed,
	  "Show Bounding Box", rotation, mirror, LOAD; CORNER: name; DATA: the marker) with two rows of
	  ours (y 150..196) where Minecraft has "Include Entities" (there are no entities to save):
	  SAVE shows the data the last SAVE made, LOAD a box for pasted data. The mode line, the mode
	  and action buttons and Done / Cancel move down by 30 to make room.

	  Merging (`merge`): the server sends the block's settings when they change (the player's own
	  update, a mode change, LOAD's "position prepared" size, another player). A field takes the
	  new value only when it changed on the server and differs from what this screen last sent, so
	  what the player typed since is kept, while a size the server prepared still shows.

	  Waiting (`await`, `waiting`): every action sends all the fields, and DETECT and LOAD
	  ("position prepared") change the region on the server. An action sent before that answer
	  came back would put the old region back (SAVE right after DETECT would save the old box).
	  Minecraft closes the screen after them; this one stays open, so its actions wait for the
	  block's next record (`merge`), at most AWAIT_SECONDS.

	Jigsaw form: pool, name, target, final state (fields), joint, levels (0..7) and "Keep
	Jigsaws". The joint button only shows for vertical fronts (Minecraft's). `jigsawProblem` is why
	Done and Generate are off (Minecraft greys them out for names that are no resource location).

	Data: SAVE's text is shown in parts of DATA_PART characters (`dataParts`; a TextBox with a
	whole 48^3 structure in it is not known to render or copy reliably), and pasted text is checked
	before it is uploaded (`pasteSummary`, Structures/Template.decode: the name, size and block
	count, or what is wrong with it).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Settings = require(Shared.Structures.Settings)
local Template = require(Shared.Structures.Template)

type StructureSettings = Settings.StructureSettings
type JigsawSettings = Settings.JigsawSettings

local StructureForm = {}

-- Characters of one shown part of a saved structure's text.
StructureForm.DATA_PART = 16000
-- Minecraft's caps: names and the marker 128, the number fields 15 characters.
StructureForm.MAX_NUMBER = 15

StructureForm.MODE_NAMES = table.freeze({ save = "Save", load = "Load", corner = "Corner", data = "Data" })
-- Minecraft's structure_block.mode_info.* (this game saves to text instead of a file).
StructureForm.MODE_INFO = table.freeze({
	save = "Save Mode - Write to Text",
	load = "Load Mode - Load from Name or Text",
	corner = "Corner Mode - Placement and Size Marker",
	data = "Data Mode - Game Logic Marker",
})
-- Minecraft's mirror symbols (mirror.none, mirror.left_right, mirror.front_back) in the pixel font.
StructureForm.MIRROR_SYMBOLS = table.freeze({ none = "|", leftRight = "< >", frontBack = "^ v" })
StructureForm.ROTATION_LABELS = table.freeze({ "0", "90", "180", "270" })
StructureForm.JOINT_NAMES = table.freeze({ rollable = "Rollable", aligned = "Aligned" })

local HORIZONTAL: { [string]: boolean } = { North = true, South = true, West = true, East = true }

export type StructureFields = {
	name: string,
	posX: string,
	posY: string,
	posZ: string,
	sizeX: string,
	sizeY: string,
	sizeZ: string,
	integrity: string,
	seed: string,
	metadata: string,
}

export type StructureFormState = {
	x: number,
	y: number,
	z: number,
	fields: StructureFields,
	mode: string,
	rotation: number,
	mirror: string,
	showBoundingBox: boolean,
	showInvisible: boolean,
	-- What the server says the block holds, and what this screen sent last (nil: nothing yet).
	base: StructureSettings,
	sent: StructureSettings?,
	-- When DETECT or LOAD went, until the block's next record (`await`); nil: not waiting.
	awaiting: number?,
}

export type JigsawFields = { pool: string, name: string, target: string, finalState: string }

export type JigsawFormState = {
	x: number,
	y: number,
	z: number,
	front: string,
	top: string,
	fields: JigsawFields,
	joint: string,
	levels: number,
	keepJigsaws: boolean,
	base: JigsawSettings,
	sent: JigsawSettings?,
}

--[[ Text ]]

-- A whole number as Minecraft prints it into a field ("-3"; huge seeds without an exponent).
local function integerText(value: number): string
	return string.format("%d", value)
end

-- The integrity as Minecraft's Float.toString: "1.0", "0.5".
local function floatText(value: number): string
	if value == math.floor(value) then
		return string.format("%d.0", value)
	end
	local text = string.format("%.6g", value)
	return text
end

-- `text` with only the characters a name allows (Settings.validName), at most MAX_NAME bytes.
function StructureForm.filterName(text: string): string
	return Settings.cut((string.gsub(text, "[^%w_%./:%-]", "")), Settings.MAX_NAME)
end

-- `text` as a whole number field: digits, and one leading minus when `negative`.
function StructureForm.filterInteger(text: string, negative: boolean): string
	local minus = negative and string.sub(text, 1, 1) == "-"
	local digits = string.gsub(text, "[^%d]", "")
	return string.sub((if minus then "-" else "") .. digits, 1, StructureForm.MAX_NUMBER)
end

-- `text` as a decimal field (the integrity): digits and one dot.
function StructureForm.filterDecimal(text: string): string
	local kept = string.gsub(text, "[^%d%.]", "")
	local dot = string.find(kept, ".", 1, true)
	if dot then
		kept = string.sub(kept, 1, dot) .. string.gsub(string.sub(kept, dot + 1), "%.", "")
	end
	return string.sub(kept, 1, StructureForm.MAX_NUMBER)
end

-- `text` as the DATA marker: printable text (no control characters), at most MAX_METADATA bytes.
function StructureForm.filterMetadata(text: string): string
	local clean = string.gsub(text, "%c", "")
	if utf8.len(clean) == nil then
		-- (Invalid UTF-8 is dropped byte by byte from the end until it reads.)
		while #clean > 0 and utf8.len(clean) == nil do
			clean = string.sub(clean, 1, -2)
		end
	end
	return Settings.cut(clean, Settings.MAX_METADATA)
end

-- Minecraft's parseCoordinate / parseSeed: the whole number in `text`, `default` when it is none.
local function parseInteger(text: string, default: number): number
	if string.find(text, "^%-?%d+$") == nil then
		return default
	end
	local value = tonumber(text)
	return if value then value else default
end

-- Minecraft's parseIntegrity: the number in `text`, 1 when it is none.
local function parseDecimal(text: string): number
	if string.find(text, "^%d*%.?%d*$") == nil or string.find(text, "%d") == nil then
		return 1
	end
	return tonumber(text) or 1
end

--[[ Structure block ]]

local function fieldsOf(s: StructureSettings): StructureFields
	return {
		name = s.name,
		posX = integerText(s.offset[1]),
		posY = integerText(s.offset[2]),
		posZ = integerText(s.offset[3]),
		sizeX = integerText(s.size[1]),
		sizeY = integerText(s.size[2]),
		sizeZ = integerText(s.size[3]),
		integrity = floatText(s.integrity),
		seed = integerText(s.seed),
		metadata = s.metadata,
	}
end

-- The form of the structure block at (x, y, z) holding `settings` (as the server sent them).
function StructureForm.newStructure(x: number, y: number, z: number, settings: StructureSettings): StructureFormState
	local s = Settings.clampStructure(settings)
	return {
		x = x,
		y = y,
		z = z,
		fields = fieldsOf(s),
		mode = s.mode,
		rotation = s.rotation,
		mirror = s.mirror,
		showBoundingBox = s.showBoundingBox,
		showInvisible = s.showInvisible,
		base = s,
		sent = nil,
		awaiting = nil,
	}
end

-- The settings the form's fields say (Minecraft's parsing, then Settings' ranges).
function StructureForm.structureSettings(form: StructureFormState): StructureSettings
	local f = form.fields
	return Settings.clampStructure({
		mode = form.mode,
		name = f.name,
		offset = { parseInteger(f.posX, 0), parseInteger(f.posY, 0), parseInteger(f.posZ, 0) },
		size = { parseInteger(f.sizeX, 0), parseInteger(f.sizeY, 0), parseInteger(f.sizeZ, 0) },
		rotation = form.rotation,
		mirror = form.mirror,
		integrity = parseDecimal(f.integrity),
		seed = parseInteger(f.seed, 0),
		showBoundingBox = form.showBoundingBox,
		showInvisible = form.showInvisible,
		metadata = f.metadata,
	})
end

-- What is wrong with the form's settings for the server (Settings.checkStructure), nil: nothing.
function StructureForm.structureProblem(form: StructureFormState): string?
	return Settings.checkStructure(StructureForm.structureSettings(form))
end

-- Remembers what this screen just sent (the settings of `structureSettings`).
function StructureForm.markSent(form: StructureFormState, settings: StructureSettings)
	form.sent = settings
end

-- Seconds the actions wait at most for the block's record after DETECT or LOAD.
StructureForm.AWAIT_SECONDS = 1

-- DETECT or LOAD went at `now`: the actions wait for the server's answer (see the header).
function StructureForm.await(form: StructureFormState, now: number)
	form.awaiting = now
end

-- Do the actions (DETECT, SAVE, LOAD, Done) wait for the server's answer at `now`?
function StructureForm.waiting(form: StructureFormState, now: number): boolean
	local since = form.awaiting
	return since ~= nil and now - since < StructureForm.AWAIT_SECONDS
end

-- Minecraft's mode button: Save -> Load -> Corner -> Data -> Save.
function StructureForm.nextMode(mode: string): string
	local index = table.find(Settings.MODES, mode) or 0
	return Settings.MODES[index % #Settings.MODES + 1]
end

-- The mirror button: none -> left-right -> front-back -> none.
function StructureForm.nextMirror(mirror: string): string
	local index = table.find(Settings.MIRRORS, mirror) or 0
	return Settings.MIRRORS[index % #Settings.MIRRORS + 1]
end

--[[
	Takes `incoming` (the block's settings from the server) into the form: each value that changed
	since the last server state and is not what this screen sent last replaces what the form shows
	(see the header), and the actions stop waiting. Returns whether anything shown changed.
]]
function StructureForm.merge(form: StructureFormState, incoming: StructureSettings): boolean
	form.awaiting = nil
	local new = Settings.clampStructure(incoming)
	local base, sent = form.base, form.sent
	local newFields, baseFields = fieldsOf(new), fieldsOf(base)
	local sentFields = if sent then fieldsOf(sent) else nil
	local changed = false
	for key, value in newFields :: any do
		local was = (baseFields :: any)[key]
		local mine = if sentFields then (sentFields :: any)[key] else nil
		if value ~= was and value ~= mine and (form.fields :: any)[key] ~= value then
			(form.fields :: any)[key] = value
			changed = true
		end
	end
	for _, key in { "mode", "rotation", "mirror", "showBoundingBox", "showInvisible" } do
		local value = (new :: any)[key]
		local was = (base :: any)[key]
		local mine = if sent then (sent :: any)[key] else nil
		if value ~= was and value ~= mine and (form :: any)[key] ~= value then
			(form :: any)[key] = value
			changed = true
		end
	end
	form.base = new
	return changed
end

--[[ Layout ]]

-- A widget of a screen: `id`, its kind and Minecraft's bounds (x from the screen's centre).
export type Widget = { id: string, kind: string, x: number, y: number, w: number, h: number, text: string? }

-- The screen's width and height in GUI pixels (Minecraft's widgets span the centre -154..154).
StructureForm.WIDTH = 320
StructureForm.STRUCTURE_HEIGHT = 274
StructureForm.JIGSAW_HEIGHT = 244

-- How far Minecraft's lower rows move down for our data / paste rows.
local SHIFT = 30

local function widget(id: string, kind: string, x: number, y: number, w: number, h: number, text: string?): Widget
	return { id = id, kind = kind, x = x, y = y, w = w, h = h, text = text }
end

--[[
	The structure block screen's widgets in `mode` (Minecraft's StructureBlockEditScreen.init and
	render, plus our data rows). Kinds: "title" (centred text), "label" (left), "rightLabel" (ends
	at x + w), "field", "button", "toggle", "data" (the read-only data box), "paste", "status".
]]
function StructureForm.layout(mode: string): { Widget }
	local list: { Widget } = {
		widget("title", "title", -154, 10, 308, 8, "Structure Block"),
	}
	local function add(w: Widget)
		table.insert(list, w)
	end
	if mode ~= "data" then
		add(widget("nameLabel", "label", -153, 30, 300, 8, "Structure Name"))
		add(widget("name", "field", -152, 40, 300, 20))
	end
	if mode == "save" or mode == "load" then
		add(widget("positionLabel", "label", -153, 70, 150, 8, "Relative Position"))
		add(widget("posX", "field", -152, 80, 80, 20))
		add(widget("posY", "field", -72, 80, 80, 20))
		add(widget("posZ", "field", 8, 80, 80, 20))
	end
	if mode == "save" then
		add(widget("invisibleLabel", "rightLabel", -2, 70, 156, 8, "Show Invisible Blocks:"))
		add(widget("showInvisible", "toggle", 104, 80, 50, 20))
		add(widget("sizeLabel", "label", -153, 110, 150, 8, "Structure Size"))
		add(widget("sizeX", "field", -152, 120, 80, 20))
		add(widget("sizeY", "field", -72, 120, 80, 20))
		add(widget("sizeZ", "field", 8, 120, 80, 20))
		add(widget("detectLabel", "rightLabel", 0, 110, 154, 8, "Detect structure size and position:"))
		add(widget("detect", "button", 104, 120, 50, 20, "DETECT"))
		add(widget("dataLabel", "label", -153, 150, 150, 8, "Structure Data"))
		add(widget("dataInfo", "rightLabel", -2, 150, 156, 8, ""))
		add(widget("data", "data", -152, 160, 300, 20))
		add(widget("dataHint", "label", -153, 186, 250, 8, ""))
		add(widget("previousPart", "button", 104, 183, 24, 14, "<"))
		add(widget("nextPart", "button", 130, 183, 24, 14, ">"))
		add(widget("save", "button", 104, 185 + SHIFT, 50, 20, "SAVE"))
	elseif mode == "load" then
		add(widget("boundingLabel", "rightLabel", -2, 70, 156, 8, "Show Bounding Box:"))
		add(widget("showBoundingBox", "toggle", 104, 80, 50, 20))
		add(widget("integrityLabel", "label", -153, 110, 300, 8, "Structure Integrity and Seed"))
		add(widget("integrity", "field", -152, 120, 80, 20))
		add(widget("seed", "field", -72, 120, 80, 20))
		add(widget("pasteLabel", "label", -153, 150, 150, 8, "Paste Data"))
		add(widget("pasteInfo", "rightLabel", -2, 150, 156, 8, ""))
		add(widget("paste", "paste", -152, 160, 300, 20))
		add(widget("pasteHint", "label", -153, 186, 306, 8, "Pasted data is loaded instead of the name"))
		add(widget("rotation0", "button", -102, 185 + SHIFT, 40, 20, "0"))
		add(widget("rotation1", "button", -61, 185 + SHIFT, 40, 20, "90"))
		add(widget("mirror", "button", -20, 185 + SHIFT, 40, 20))
		add(widget("rotation2", "button", 21, 185 + SHIFT, 40, 20, "180"))
		add(widget("rotation3", "button", 62, 185 + SHIFT, 40, 20, "270"))
		add(widget("load", "button", 104, 185 + SHIFT, 50, 20, "LOAD"))
	elseif mode == "data" then
		add(widget("metadataLabel", "label", -153, 110, 240, 8, "Custom Data Tag Name"))
		add(widget("metadata", "field", -152, 120, 240, 20))
	end
	add(widget("modeInfo", "label", -153, 174 + SHIFT, 250, 8, StructureForm.MODE_INFO[mode] or ""))
	add(widget("mode", "button", -154, 185 + SHIFT, 50, 20))
	add(widget("done", "button", -154, 210 + SHIFT, 150, 20, "Done"))
	add(widget("cancel", "button", 4, 210 + SHIFT, 150, 20, "Cancel"))
	add(widget("status", "label", -154, 234 + SHIFT, 308, 8, ""))
	return list
end

--[[
	The jigsaw screen's widgets (Minecraft's JigsawBlockEditScreen): pool, name, target and final
	state fields with their labels, the joint for vertical fronts, levels, "Keep Jigsaws",
	Generate, Done and Cancel, and our status line under them.
]]
function StructureForm.jigsawLayout(front: string): { Widget }
	local list: { Widget } = {
		widget("poolLabel", "label", -153, 10, 300, 8, "Target Pool:"),
		widget("pool", "field", -152, 20, 300, 20),
		widget("nameLabel", "label", -153, 45, 300, 8, "Name:"),
		widget("name", "field", -152, 55, 300, 20),
		widget("targetLabel", "label", -153, 80, 300, 8, "Target Name:"),
		widget("target", "field", -152, 90, 300, 20),
		widget("finalStateLabel", "label", -153, 115, 300, 8, "Turns into:"),
		widget("finalState", "field", -152, 125, 300, 20),
	}
	if not HORIZONTAL[front] then
		table.insert(list, widget("jointLabel", "label", -153, 156, 70, 8, "Joint Type:"))
		table.insert(list, widget("joint", "button", -72, 150, 220, 20))
	end
	table.insert(list, widget("levels", "slider", -154, 180, 100, 20))
	table.insert(list, widget("keepJigsaws", "button", -50, 180, 100, 20))
	table.insert(list, widget("generate", "button", 54, 180, 100, 20, "Generate"))
	table.insert(list, widget("done", "button", -154, 210, 150, 20, "Done"))
	table.insert(list, widget("cancel", "button", 4, 210, 150, 20, "Cancel"))
	table.insert(list, widget("status", "label", -154, 234, 308, 8, ""))
	return list
end

--[[ Jigsaw ]]

local function jigsawFieldsOf(j: JigsawSettings): JigsawFields
	return { pool = j.pool, name = j.name, target = j.target, finalState = j.finalState }
end

-- The form of the jigsaw at (x, y, z) facing `front` with `top` up, holding `settings`.
function StructureForm.newJigsaw(
	x: number,
	y: number,
	z: number,
	front: string,
	top: string,
	settings: JigsawSettings
): JigsawFormState
	local j = Settings.clampJigsaw(settings, front)
	return {
		x = x,
		y = y,
		z = z,
		front = front,
		top = top,
		fields = jigsawFieldsOf(j),
		joint = j.joint,
		levels = 0,
		-- (Minecraft's JigsawBlockEditScreen starts with Keep Jigsaws on.)
		keepJigsaws = true,
		base = j,
		sent = nil,
	}
end

function StructureForm.jigsawSettings(form: JigsawFormState): JigsawSettings
	local f = form.fields
	return Settings.clampJigsaw({
		name = f.name,
		target = f.target,
		pool = f.pool,
		finalState = f.finalState,
		joint = form.joint,
	}, form.front)
end

-- Why Done and Generate are off (Settings.checkJigsaw), nil when the settings are fine.
function StructureForm.jigsawProblem(form: JigsawFormState): string?
	return Settings.checkJigsaw(StructureForm.jigsawSettings(form))
end

function StructureForm.markJigsawSent(form: JigsawFormState, settings: JigsawSettings)
	form.sent = settings
end

-- Minecraft's joint button: rollable <-> aligned.
function StructureForm.nextJoint(joint: string): string
	return if joint == "rollable" then "aligned" else "rollable"
end

-- The jigsaw form's merge, as `merge`.
function StructureForm.mergeJigsaw(form: JigsawFormState, incoming: JigsawSettings): boolean
	local new = Settings.clampJigsaw(incoming, form.front)
	local base, sent = form.base, form.sent
	local changed = false
	for _, key in { "pool", "name", "target", "finalState" } do
		local value = (new :: any)[key]
		local mine = if sent then (sent :: any)[key] else nil
		if value ~= (base :: any)[key] and value ~= mine and (form.fields :: any)[key] ~= value then
			(form.fields :: any)[key] = value
			changed = true
		end
	end
	if new.joint ~= base.joint and (sent == nil or new.joint ~= sent.joint) and form.joint ~= new.joint then
		form.joint = new.joint
		changed = true
	end
	form.base = new
	return changed
end

--[[ Data ]]

-- `text` cut into parts of DATA_PART characters (one part when it is short; none when empty).
function StructureForm.dataParts(text: string): { string }
	local parts = {}
	local size = StructureForm.DATA_PART
	for i = 1, #text, size do
		table.insert(parts, string.sub(text, i, i + size - 1))
	end
	return parts
end

-- "1,149" for 1149.
function StructureForm.thousands(value: number): string
	local text = string.format("%d", math.floor(value))
	local grouped = string.reverse((string.gsub(string.reverse(text), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return grouped
end

--[[
	What the data box under SAVE says about the saved `text` split into `parts` with part `index`
	shown: the info at the right of its label ("1,149 characters", "part 2 of 9") and the hint
	under it.
]]
function StructureForm.dataLines(text: string?, parts: number, index: number): (string, string)
	if text == nil or text == "" then
		return "", "SAVE puts the structure's data here"
	end
	local info = `{StructureForm.thousands(#text)} characters`
	if parts > 1 then
		return `{info}, part {index} of {parts}`, "Click it, Ctrl+C to copy; copy every part in order"
	end
	return info, "Click it, then Ctrl+C (Cmd+C) to copy it"
end

export type PasteSummary = {
	ok: boolean,
	-- The structure's name, size and block count, or what is wrong with the text.
	text: string,
	name: string?,
}

--[[
	What pasted `text` is, for the paste box: nothing (empty: LOAD uses the name), a structure
	("hut 7x5x7, 120 blocks"; Template.decode's warnings counted) or why it is not one (Template's
	message, or too long). Never errors.
]]
function StructureForm.pasteSummary(text: string, maxChars: number): PasteSummary?
	if string.find(text, "%S") == nil then
		return nil
	end
	if #text > maxChars then
		return { ok = false, text = `Too long: at most {StructureForm.thousands(maxChars)} characters` }
	end
	local ok, template, err, warnings = pcall(Template.decode, text)
	if not ok or template == nil then
		local message = if ok then err else nil
		return { ok = false, text = tostring(message or "Not structure data") }
	end
	local t = template :: Template.Template
	local size = t.size
	local summary = `{t.name} {size[1]}x{size[2]}x{size[3]}, {Template.count(t)} blocks`
	local count = if type(warnings) == "table" then #(warnings :: { any }) else 0
	if count > 0 then
		summary ..= `, {count} warning{if count == 1 then "" else "s"}`
	end
	return { ok = true, text = summary, name = t.name }
end

return StructureForm
