--!strict
--[[
	The structure block screen and the jigsaw screen (Minecraft 1.20.1's StructureBlockEditScreen
	and JigsawBlockEditScreen), drawn in this game's style over the darkened world and shown
	through Ui/Screens as panels (the mouse is free, E / Escape / gamepad B close them, as
	Minecraft's Escape cancels). Ui/StructureForm holds what they show (fields, layout per mode,
	merging the server's updates); Net/StructureNet opens them when the server answers a right
	click, and sends what their buttons ask (`Actions`).

	Structure block
	  The mode button cycles Save -> Load -> Corner -> Data and shows that mode's widgets. Buttons
	  act at once, as Minecraft's: DETECT, SAVE and LOAD send every field with the action, Done
	  sends the fields (UPDATE_DATA) and closes, Cancel (or Escape) closes and keeps what the
	  block had. Unlike Minecraft the screen stays open after an action: the server's answer is
	  repeated on the status line, DETECT's region and LOAD's prepared size show in the fields,
	  and after SAVE the structure's data appears in a read only box: click it (everything gets
	  selected) and press Ctrl+C (Cmd+C) to copy it. Roblox scripts can't write the clipboard, so
	  that is the way out; long data comes in parts (StructureForm.DATA_PART characters) to copy
	  in order. In LOAD mode a "Paste Data" box takes such text: LOAD then places it instead of
	  the name (checked here first: StructureForm.pasteSummary; uploaded in pieces by
	  Net/StructureNet); like Minecraft's fields, it starts empty each time a screen opens. After
	  DETECT and LOAD the actions wait for the block's new region (StructureForm.await), so one
	  pressed right after can't send the old one. While the screen is open, the region's outline
	  follows the fields (`preview`, Rendering/StructureBoxes).
	Jigsaw
	  Target pool, name, target name and "Turns into" fields, the joint (vertical fronts only),
	  levels 0..7, "Keep Jigsaws" and Generate (which, as Minecraft's, applies the fields, starts
	  the assembly and closes). Done and Generate are off while a field is no valid name or the
	  final state no block; the status line says which.

	Only creative players open these (the server checks the rest: Config.Structures.Permission,
	Config.Gameplay.Admins, the owner, Studio); the screen closes when the player leaves creative
	or the block goes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Blocks = require(Shared.Blocks)
local Config = require(Shared.Config)
local Settings = require(Shared.Structures.Settings)

local ClientInventory = require(script.Parent.Parent.Inventory.ClientInventory)
local Notices = require(script.Parent.Parent.Net.Notices)
local FormWidgets = require(script.Parent.FormWidgets)
local Screens = require(script.Parent.Screens)
local StructureForm = require(script.Parent.StructureForm)
local Style = require(script.Parent.Style)

type StructureSettings = Settings.StructureSettings
type JigsawSettings = Settings.JigsawSettings

-- Minecraft's label gray (10526880) and white.
local LABEL = Color3.fromRGB(160, 160, 160)
local WHITE = Color3.fromRGB(255, 255, 255)
local RED = Style.Colour.Red
-- Seconds a server answer stays on the status line.
local NOTICE_SECONDS = 8

local WIDTH = StructureForm.WIDTH

export type Actions = {
	-- A structure block request ("update", "save", "load", "detect"); `pasted`: LOAD's pasted text.
	structure: (op: string, x: number, y: number, z: number, settings: StructureSettings, pasted: string?) -> (),
	-- A jigsaw request ("update", "generate").
	jigsaw: (
		op: string,
		x: number,
		y: number,
		z: number,
		settings: JigsawSettings,
		levels: number,
		keepJigsaws: boolean
	) -> (),
	-- The text the last SAVE of the block at (x, y, z) gave, if it came.
	savedText: (x: number, y: number, z: number) -> string?,
	-- What the paste upload is doing ("Uploading 3 / 9 pieces"), nil when nothing.
	uploadStatus: () -> string?,
}

local StructureScreen = {}

local started = false
local actions: Actions? = nil

local structureForm: StructureForm.StructureFormState? = nil
local jigsawForm: StructureForm.JigsawFormState? = nil
-- The last server answer and when it came.
local notice: string? = nil
local noticeAt = -math.huge

-- Set by start.
local refreshStructure: () -> () = function() end
local resetStructure: () -> () = function() end
local refreshJigsaw: () -> () = function() end
local structurePanel: Screens.Panel? = nil
local jigsawPanel: Screens.Panel? = nil

-- Is a structure block screen (or a jigsaw screen) open?
function StructureScreen.isOpen(): boolean
	return structureForm ~= nil or jigsawForm ~= nil
end

--[[
	The open structure block screen's block and its settings as the fields say now (the outline
	follows them while the player types), nil when none is open.
]]
function StructureScreen.preview(): (number?, number?, number?, StructureSettings?)
	local form = structureForm
	if form == nil then
		return nil, nil, nil, nil
	end
	return form.x, form.y, form.z, StructureForm.structureSettings(form)
end

local function position(w: StructureForm.Widget): (number, number)
	return WIDTH / 2 + w.x, w.y
end

local function newRoot(name: string, height: number): Frame
	local root = Instance.new("Frame")
	root.Name = name
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(WIDTH, height)
	root.Visible = false
	root.ZIndex = 2
	return root
end

-- The status line: a problem first (red), then what an upload does, then the server's answer.
local function statusText(problem: string?): (string, Color3)
	if problem then
		return problem, RED
	end
	local a = actions
	local upload = if a then a.uploadStatus() else nil
	if upload then
		return upload, LABEL
	end
	if notice and os.clock() - noticeAt < NOTICE_SECONDS then
		return notice :: string, WHITE
	end
	return "", LABEL
end

--[[ Structure block screen ]]

local function buildStructure(): Screens.Panel
	local root = newRoot("StructureBlock", StructureForm.STRUCTURE_HEIGHT)
	local fields: { [string]: FormWidgets.EditBox } = {}
	local buttons: { [string]: FormWidgets.Button } = {}
	local labels: { [string]: FormWidgets.Label } = {}
	local filters: { [string]: (string) -> string } = {
		name = StructureForm.filterName,
		posX = function(text)
			return StructureForm.filterInteger(text, true)
		end,
		sizeX = function(text)
			return StructureForm.filterInteger(text, false)
		end,
		integrity = StructureForm.filterDecimal,
		seed = function(text)
			return StructureForm.filterInteger(text, true)
		end,
		metadata = StructureForm.filterMetadata,
	}
	filters.posY, filters.posZ = filters.posX, filters.posX
	filters.sizeY, filters.sizeZ = filters.sizeX, filters.sizeX

	-- Every widget any mode shows, made once (a widget has the same place in every mode).
	local made: { [string]: boolean } = {}
	for _, mode in Settings.MODES do
		for _, w in StructureForm.layout(mode) do
			if made[w.id] then
				continue
			end
			made[w.id] = true
			local x, y = position(w)
			if w.kind == "title" then
				labels[w.id] = FormWidgets.label(root, w.text or "", x, y, w.w, WHITE, "centre")
			elseif w.kind == "label" then
				labels[w.id] = FormWidgets.label(root, w.text or "", x, y, w.w, LABEL)
			elseif w.kind == "rightLabel" then
				labels[w.id] = FormWidgets.label(root, w.text or "", x, y, w.w, LABEL, "right")
			elseif w.kind == "field" then
				fields[w.id] = FormWidgets.editBox(root, x, y, w.w, w.h, 4, filters[w.id])
			elseif w.kind == "data" then
				fields[w.id] = FormWidgets.editBox(root, x, y, w.w, w.h, 4, nil, true)
			elseif w.kind == "paste" then
				local paste = FormWidgets.editBox(root, x, y, w.w, w.h, 4)
				paste.box.PlaceholderText = "IVS1:..."
				fields[w.id] = paste
			else
				buttons[w.id] = FormWidgets.button(root, w.text or "", x, y, w.w, w.h)
			end
		end
	end

	local dataPart = 1
	-- The pasted text's check (StructureForm.pasteSummary), made again when the box is left.
	local pasted: StructureForm.PasteSummary? = nil
	local pastedFor = ""

	local function checkPaste()
		local text = fields.paste:text()
		if text ~= pastedFor then
			pastedFor = text
			pasted = StructureForm.pasteSummary(text, Config.Structures.MaxDataChars)
		end
	end

	refreshStructure = function()
		local form = structureForm
		if form == nil then
			return
		end
		local shown: { [string]: boolean } = {}
		for _, w in StructureForm.layout(form.mode) do
			shown[w.id] = true
		end
		for id, field in fields do
			field:setVisible(shown[id] == true)
			local value = (form.fields :: any)[id]
			if value ~= nil and not field.box:IsFocused() then
				field:setText(value)
			end
		end
		for id, button in buttons do
			button:setVisible(shown[id] == true)
		end
		for id, label in labels do
			label:setVisible(shown[id] == true)
		end
		buttons.mode:setText(StructureForm.MODE_NAMES[form.mode] or form.mode)
		labels.modeInfo:setText(StructureForm.MODE_INFO[form.mode] or "")
		buttons.showInvisible:setText(if form.showInvisible then "ON" else "OFF")
		buttons.showBoundingBox:setText(if form.showBoundingBox then "ON" else "OFF")
		for r = 0, 3 do
			-- (Minecraft's: the current rotation's button is the inactive one.)
			buttons[`rotation{r}`]:setEnabled(form.rotation ~= r)
		end
		buttons.mirror:setText(StructureForm.MIRROR_SYMBOLS[form.mirror] or "|")
		local waiting = StructureForm.waiting(form, os.clock())
		for _, id in { "detect", "save", "load", "done" } do
			buttons[id]:setEnabled(not waiting)
		end

		-- SAVE's data.
		local a = actions
		local text = if a then a.savedText(form.x, form.y, form.z) else nil
		local parts = if text then StructureForm.dataParts(text) else {}
		dataPart = math.clamp(dataPart, 1, math.max(1, #parts))
		local info, hint = StructureForm.dataLines(text, #parts, dataPart)
		labels.dataInfo:setText(info)
		labels.dataHint:setText(hint)
		fields.data:setText(parts[dataPart] or "")
		fields.data.box.PlaceholderText = "No data yet"
		buttons.previousPart:setVisible(shown.previousPart == true and #parts > 1)
		buttons.nextPart:setVisible(shown.nextPart == true and #parts > 1)
		buttons.previousPart:setEnabled(dataPart > 1)
		buttons.nextPart:setEnabled(dataPart < #parts)

		-- LOAD's pasted data.
		checkPaste()
		local summary = pasted
		if summary then
			labels.pasteInfo:setText(summary.text, if summary.ok then LABEL else RED)
		else
			labels.pasteInfo:setText("", LABEL)
		end

		local problem = StructureForm.structureProblem(form)
		local status, colour = statusText(problem)
		labels.status:setText(status, colour)
	end

	-- A screen opening: no pasted text, the data's first part (Minecraft's screen is new each time).
	resetStructure = function()
		fields.paste:setText("")
		pasted = nil
		pastedFor = ""
		dataPart = 1
	end

	local panel: Screens.Panel
	local function finish()
		structureForm = nil
		Screens.closePanel(panel)
	end

	-- Sends `op` with the fields (nothing when they are wrong: the status line says why).
	local function send(op: string): boolean
		local form = structureForm
		local a = actions
		if form == nil or a == nil or StructureForm.waiting(form, os.clock()) then
			return false
		end
		local settings = StructureForm.structureSettings(form)
		if Settings.checkStructure(settings) then
			refreshStructure()
			return false
		end
		local text: string? = nil
		if op == "load" then
			checkPaste()
			local summary = pasted
			if summary and not summary.ok then
				refreshStructure()
				return false
			elseif summary then
				text = fields.paste:text()
			end
		end
		StructureForm.markSent(form, settings)
		notice = nil
		a.structure(op, form.x, form.y, form.z, settings, text)
		if op == "detect" or op == "load" then
			-- (They change the region on the server: the actions wait for it, see the header.)
			StructureForm.await(form, os.clock())
			task.delay(StructureForm.AWAIT_SECONDS, function()
				refreshStructure()
			end)
		end
		refreshStructure()
		return true
	end

	for id, field in fields do
		if id ~= "data" and id ~= "paste" then
			field.changed = function(text: string)
				local form = structureForm
				if form then
					(form.fields :: any)[id] = text
					refreshStructure()
				end
			end
		end
	end
	fields.paste.left = refreshStructure
	buttons.mode.clicked = function()
		local form = structureForm
		if form then
			form.mode = StructureForm.nextMode(form.mode)
			dataPart = 1
			refreshStructure()
		end
	end
	buttons.showInvisible.clicked = function()
		local form = structureForm
		if form then
			form.showInvisible = not form.showInvisible
			refreshStructure()
		end
	end
	buttons.showBoundingBox.clicked = function()
		local form = structureForm
		if form then
			form.showBoundingBox = not form.showBoundingBox
			refreshStructure()
		end
	end
	for r = 0, 3 do
		buttons[`rotation{r}`].clicked = function()
			local form = structureForm
			if form then
				form.rotation = r
				refreshStructure()
			end
		end
	end
	buttons.mirror.clicked = function()
		local form = structureForm
		if form then
			form.mirror = StructureForm.nextMirror(form.mirror)
			refreshStructure()
		end
	end
	buttons.previousPart.clicked = function()
		dataPart -= 1
		refreshStructure()
	end
	buttons.nextPart.clicked = function()
		dataPart += 1
		refreshStructure()
	end
	buttons.detect.clicked = function()
		send("detect")
	end
	buttons.save.clicked = function()
		send("save")
	end
	buttons.load.clicked = function()
		send("load")
	end
	buttons.done.clicked = function()
		if send("update") then
			finish()
		end
	end
	buttons.cancel.clicked = finish

	panel = {
		root = root,
		size = function(): Vector2
			return Vector2.new(WIDTH, StructureForm.STRUCTURE_HEIGHT)
		end,
		closed = function()
			structureForm = nil
		end,
		firstSelectable = function(): GuiObject?
			return buttons.mode.button
		end,
	}
	return panel
end

--[[ Jigsaw screen ]]

local function buildJigsaw(): Screens.Panel
	local root = newRoot("Jigsaw", StructureForm.JIGSAW_HEIGHT)
	local fields: { [string]: FormWidgets.EditBox } = {}
	local buttons: { [string]: FormWidgets.Button } = {}
	local labels: { [string]: FormWidgets.Label } = {}
	local slider: FormWidgets.Slider? = nil
	-- (A vertical front's layout has every widget; horizontal ones leave the joint out.)
	for _, w in StructureForm.jigsawLayout("Up") do
		local x, y = position(w)
		if w.kind == "label" then
			labels[w.id] = FormWidgets.label(root, w.text or "", x, y, w.w, LABEL)
		elseif w.kind == "field" then
			fields[w.id] = FormWidgets.editBox(root, x, y, w.w, w.h, 4, StructureForm.filterName)
		elseif w.kind == "slider" then
			slider = FormWidgets.slider(root, x, y, w.w, w.h, 0, Settings.MAX_LEVELS, function(value: number): string
				return `Levels: {value}`
			end)
		else
			buttons[w.id] = FormWidgets.button(root, w.text or "", x, y, w.w, w.h)
		end
	end
	local levels = slider :: FormWidgets.Slider

	refreshJigsaw = function()
		local form = jigsawForm
		if form == nil then
			return
		end
		local shown: { [string]: boolean } = {}
		for _, w in StructureForm.jigsawLayout(form.front) do
			shown[w.id] = true
		end
		for id, field in fields do
			local value = (form.fields :: any)[id]
			if value ~= nil and not field.box:IsFocused() then
				field:setText(value)
			end
		end
		labels.jointLabel:setVisible(shown.jointLabel == true)
		buttons.joint:setVisible(shown.joint == true)
		buttons.joint:setText(StructureForm.JOINT_NAMES[form.joint] or form.joint)
		levels:setValue(form.levels)
		buttons.keepJigsaws:setText(`Keep Jigsaws: {if form.keepJigsaws then "ON" else "OFF"}`)
		local problem = StructureForm.jigsawProblem(form)
		buttons.done:setEnabled(problem == nil)
		buttons.generate:setEnabled(problem == nil)
		local status, colour = statusText(problem)
		labels.status:setText(status, colour)
	end

	local panel: Screens.Panel
	local function finish()
		jigsawForm = nil
		Screens.closePanel(panel)
	end

	local function send(op: string): boolean
		local form = jigsawForm
		local a = actions
		if form == nil or a == nil or StructureForm.jigsawProblem(form) then
			refreshJigsaw()
			return false
		end
		local settings = StructureForm.jigsawSettings(form)
		StructureForm.markJigsawSent(form, settings)
		notice = nil
		a.jigsaw(op, form.x, form.y, form.z, settings, form.levels, form.keepJigsaws)
		return true
	end

	for id, field in fields do
		field.changed = function(text: string)
			local form = jigsawForm
			if form then
				(form.fields :: any)[id] = text
				refreshJigsaw()
			end
		end
	end
	buttons.joint.clicked = function()
		local form = jigsawForm
		if form then
			form.joint = StructureForm.nextJoint(form.joint)
			refreshJigsaw()
		end
	end
	levels.changed = function(value: number)
		local form = jigsawForm
		if form then
			form.levels = value
			refreshJigsaw()
		end
	end
	buttons.keepJigsaws.clicked = function()
		local form = jigsawForm
		if form then
			form.keepJigsaws = not form.keepJigsaws
			refreshJigsaw()
		end
	end
	-- Minecraft's Generate: the fields, then the assembly, and the screen closes.
	buttons.generate.clicked = function()
		if send("generate") then
			finish()
		end
	end
	buttons.done.clicked = function()
		if send("update") then
			finish()
		end
	end
	buttons.cancel.clicked = finish

	panel = {
		root = root,
		size = function(): Vector2
			return Vector2.new(WIDTH, StructureForm.JIGSAW_HEIGHT)
		end,
		closed = function()
			jigsawForm = nil
		end,
		firstSelectable = function(): GuiObject?
			return buttons.done.button
		end,
	}
	return panel
end

--[[ Public ]]

-- Opens the screen of the structure block at (x, y, z), which holds `settings`.
function StructureScreen.openStructure(x: number, y: number, z: number, settings: StructureSettings)
	local panel = structurePanel
	if panel == nil or not ClientInventory.isCreative() then
		return
	end
	jigsawForm = nil
	structureForm = StructureForm.newStructure(x, y, z, settings)
	notice = nil
	resetStructure()
	Screens.showPanel(panel)
	refreshStructure()
end

-- Opens the screen of the jigsaw `block` at (x, y, z), which holds `settings`.
function StructureScreen.openJigsaw(x: number, y: number, z: number, block: number, settings: JigsawSettings)
	local panel = jigsawPanel
	local front, top = Blocks.jigsawOrientation(block)
	if panel == nil or front == nil or top == nil or not ClientInventory.isCreative() then
		return
	end
	structureForm = nil
	jigsawForm = StructureForm.newJigsaw(x, y, z, front, top, settings)
	notice = nil
	Screens.showPanel(panel)
	refreshJigsaw()
end

local function closeAll()
	local s, j = structurePanel, jigsawPanel
	structureForm = nil
	jigsawForm = nil
	if s then
		Screens.closePanel(s)
	end
	if j then
		Screens.closePanel(j)
	end
end

-- The server's settings for the structure block at (x, y, z) (nil: it is gone).
function StructureScreen.structureRecord(x: number, y: number, z: number, settings: StructureSettings?)
	local form = structureForm
	if form == nil or form.x ~= x or form.y ~= y or form.z ~= z then
		return
	end
	if settings == nil then
		closeAll()
	else
		local waited = form.awaiting ~= nil
		if StructureForm.merge(form, settings) or waited then
			refreshStructure()
		end
	end
end

-- The server's settings for the jigsaw at (x, y, z) (nil: it is gone).
function StructureScreen.jigsawRecord(x: number, y: number, z: number, settings: JigsawSettings?)
	local form = jigsawForm
	if form == nil or form.x ~= x or form.y ~= y or form.z ~= z then
		return
	end
	if settings == nil then
		closeAll()
	elseif StructureForm.mergeJigsaw(form, settings) then
		refreshJigsaw()
	end
end

-- Something the screens show changed elsewhere (a SAVE's data arrived, an upload moved on).
function StructureScreen.refresh()
	if structureForm then
		refreshStructure()
	elseif jigsawForm then
		refreshJigsaw()
	end
end

--[[
	Builds the screens. `actions` sends what their buttons ask (Net/StructureNet). Call after
	Screens.start.
]]
function StructureScreen.start(a: Actions)
	if started then
		return
	end
	started = true
	actions = a
	structurePanel = buildStructure()
	jigsawPanel = buildJigsaw()

	-- The server's answers (Saved structure ..., Structure loaded ...) on the status line.
	Notices.listen(function(text: string)
		if StructureScreen.isOpen() then
			notice = text
			noticeAt = os.clock()
			StructureScreen.refresh()
		end
	end)
	-- Leaving creative closes them.
	ClientInventory.changed:Connect(function()
		if StructureScreen.isOpen() and not ClientInventory.isCreative() then
			closeAll()
		end
	end)
	-- The status line forgets an old answer.
	task.spawn(function()
		while true do
			task.wait(1)
			if StructureScreen.isOpen() and notice and os.clock() - noticeAt >= NOTICE_SECONDS then
				notice = nil
				StructureScreen.refresh()
			end
		end
	end)
end

return StructureScreen
