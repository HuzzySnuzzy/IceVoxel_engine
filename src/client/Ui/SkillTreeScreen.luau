--!strict
--[[
	The skill tree screen (Shared/Progression/Skills), shown through Ui/Screens as a panel like the
	Options menu (the darkened world, the free mouse, the controls off). Minecraft's advancement
	screen in this game's UI style: a panel of WIDTH x HEIGHT GUI pixels.

	  Opening   Config.Progression.Key (K) or GamepadButton (D-pad left) with no screen open, and
	            the HUD's touch button over the gear (Hud.onSkillsButton). K, E, Escape, gamepad B
	            and Done close it (the D-pad moves the gamepad's selection while it is open).
	  Header    "Skills", then the player's Age, knowledge level and skill points to spend.
	  Columns   one per Age (Progression/Ages), titled with its name: in its colour once reached,
	            grey before. Hovering (or selecting) a title shows what entering it takes: the
	            level and each milestone, green when met (the Progress message's bits).
	  Nodes     a framed square per skill on its row (Skills `row`), its item inside (Skills
	            `icon`), joined to its prerequisites by lines (straight along a row; else out of
	            the prerequisite into the gap after its column, down or up, then along). The
	            frame says its state: gold unlocked, white available (Progression.canUnlock),
	            dark locked (the item dimmed); a line is gold when both ends are unlocked.
	  Info      hovering or selecting a node shows its name, what it does, its cost and what it
	            needs (the Age, the prerequisites, the points), in light text with Minecraft's shadow
	            on the grid's dark backdrop (the Ages' colours and the red and green read there, not
	            on the light panel), long lines wrapped at word breaks (Style.textWidth). The
	            panel's own title and header are dark text without a shadow, as on the inventory.
	            Clicking a node selects it, and
	            Unlock sends it to the server (Protocol UnlockSkill), which checks it all again
	            and answers with the new state (or a chat notice).
	  Gamepad   the nodes, the titles and the buttons are selectable; A selects / presses.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("IceVoxel")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Progression = require(Shared.Progression)

local SoundPlayer = require(script.Parent.Parent.Audio.SoundPlayer)
local ProgressionState = require(script.Parent.Parent.Player.ProgressionState)
local FormWidgets = require(script.Parent.FormWidgets)
local Hud = require(script.Parent.Hud)
local ItemIcon = require(script.Parent.ItemIcon)
local Screens = require(script.Parent.Screens)
local Style = require(script.Parent.Style)
local TextWrap = require(script.Parent.TextWrap)

local Ages = Progression.Ages
local Skills = Progression.Skills
local Knowledge = Progression.Knowledge

type Skill = Progression.Skill
type Age = Progression.Age

-- Layout (GUI pixels).
local MARGIN = 8
-- (80: "Industrial" and the longest header fit at Style.TEXT_SIZE: a pixel font shrunk to 6 or 7
-- blurs.)
local COLUMN = 80
local ROW = 28
local NODE = 22
local WIDTH = MARGIN * 2 + COLUMN * Ages.count
local HEADER_Y = 7
local GRID_Y = 20
local TITLE_H = 12
local NODES_Y = GRID_Y + TITLE_H + 2
local GRID_H = TITLE_H + 4 + ROW * Skills.ROWS
-- The info lines, on their own dark backdrop under the grid (the panel's whole width).
-- (5 lines: the most a skill needs; the panel stays short enough for GUI scale 3 on 900 pixel
-- tall screens and 1.25 on phones.)
local INFO_Y = GRID_Y + GRID_H + 6
local LINE = 10
local INFO_LINES = 5
local INFO_PAD = 3
local BUTTON_W, BUTTON_H = 56, 18
-- The buttons' row, under the info backdrop.
local BUTTONS_Y = INFO_Y + LINE * INFO_LINES + INFO_PAD + 4
local HEIGHT = BUTTONS_Y + BUTTON_H + 6
local LINE_WIDTH = 2

-- Colours: the grid's dark backdrop (darker than the text shadows, as Minecraft's tooltips, so
-- shadows lift the text instead of smearing it), the nodes' slot grey well, their frames by state,
-- the lines.
local BACKDROP = Color3.fromRGB(22, 20, 18)
local WELL = Style.Colour.Slot
local UNLOCKED = Color3.fromRGB(240, 200, 60)
local AVAILABLE = Color3.fromRGB(240, 240, 240)
local LOCKED = Color3.fromRGB(70, 70, 70)
local LINE_DONE = Color3.fromRGB(240, 200, 60)
local LINE_OPEN = Color3.fromRGB(170, 170, 170)
local LINE_LOCKED = Color3.fromRGB(70, 70, 70)
-- Text on the dark backdrops (with shadows): names white, the rest light grey, Ages not reached
-- yet a dimmer grey that still reads (reached ones in their colour, brightened: `reachedColour`).
local GREEN = Color3.fromRGB(85, 255, 85)
local WHITE = Color3.fromRGB(255, 255, 255)
local LIGHT = Color3.fromRGB(225, 225, 225)
local GRAY = Color3.fromRGB(190, 190, 190)
local DIM = Color3.fromRGB(115, 115, 115)

-- Gamepad selection on this screen: an outline only, so a selected node's state colour and a
-- selected title's text stay readable (Style.selectionImage washes them out).
local SELECTION = Instance.new("Frame")
SELECTION.BackgroundTransparency = 1
SELECTION.Size = UDim2.fromScale(1, 1)
do
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 1
	stroke.Parent = SELECTION
end

type NodeView = {
	skill: Skill,
	button: TextButton,
	frame: { Frame },
	icon: ItemIcon.ItemIcon,
	lines: { { frames: { Frame }, from: Skill } },
}

local SkillTreeScreen = {}

local started = false
local panel: Screens.Panel? = nil
-- Set by start.
local refresh: () -> () = function() end
local close: () -> () = function() end

function SkillTreeScreen.isOpen(): boolean
	local p = panel
	return p ~= nil and Screens.panelShown(p)
end

-- A reached Age's title colour: its own, brightened a quarter of the way to white (so the Stone
-- Age's grey stands well clear of DIM).
local function reachedColour(age: Age): Color3
	return Color3.fromRGB(age.color[1], age.color[2], age.color[3]):Lerp(WHITE, 0.25)
end

-- An Age's name without " Age" (the column titles: "Industrial").
local function shortName(age: Age): string
	return (string.gsub(age.name, " Age$", ""))
end

-- Centre of the node cell of `skill` (GUI pixels in the panel).
local function nodeCentre(skill: Skill): (number, number)
	return MARGIN + (skill.age - 1) * COLUMN + COLUMN // 2, NODES_Y + (skill.row - 1) * ROW + ROW // 2
end

--[[
	The line from prerequisite `from` to `to`: frames LINE_WIDTH thick (straight along a row or a
	column, else out of `from`, along the gap after its column, then along `to`'s row).
]]
local function drawLine(parent: Instance, from: Skill, to: Skill): { Frame }
	local frames: { Frame } = {}
	local half = NODE // 2
	local fx, fy = nodeCentre(from)
	local tx, ty = nodeCentre(to)
	local function segment(x1: number, y1: number, x2: number, y2: number)
		local x, y = math.min(x1, x2), math.min(y1, y2)
		local w, h = math.abs(x2 - x1), math.abs(y2 - y1)
		local frame = Style.frame(
			parent,
			x - (if w == 0 then LINE_WIDTH // 2 else 0),
			y - (if h == 0 then LINE_WIDTH // 2 else 0),
			math.max(w, LINE_WIDTH),
			math.max(h, LINE_WIDTH),
			LINE_LOCKED,
			3
		)
		table.insert(frames, frame)
	end
	if fx == tx then
		local direction = if ty > fy then 1 else -1
		segment(fx, fy + direction * half, tx, ty - direction * half)
	elseif fy == ty then
		segment(fx + half, fy, tx - half, ty)
	else
		local gap = MARGIN + from.age * COLUMN
		segment(fx + half, fy, gap, fy)
		segment(gap, fy, gap, ty)
		segment(gap, ty, tx - half, ty)
	end
	return frames
end

-- The node's frame: four borders of 2 pixels around the item (its colour says the state).
local function drawNode(parent: Instance, skill: Skill): NodeView
	local x, y = nodeCentre(skill)
	local button = Instance.new("TextButton")
	button.Name = skill.id
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = WELL
	button.Position = UDim2.fromOffset(x - NODE // 2, y - NODE // 2)
	button.Size = UDim2.fromOffset(NODE, NODE)
	button.ZIndex = 4
	button.SelectionImageObject = SELECTION
	button.Parent = parent
	local frame = Style.border(button, 0, 0, NODE, NODE, 2, LOCKED, 5)
	local icon = ItemIcon.new(button, (NODE - Style.ITEM) // 2, (NODE - Style.ITEM) // 2, 6)
	local ok, item = pcall(function()
		return Items.id[skill.icon]
	end)
	icon:set(if ok then item else nil, 1)
	return { skill = skill, button = button, frame = frame, icon = icon, lines = {} }
end

type Line = { text: string, colour: Color3 }

-- What entering an Age takes, a line each (its name, the level, each milestone), green when met.
local function ageLines(age: Age, status: Progression.Status?): { Line }
	local reached = status ~= nil and status.age >= age.index
	local lines: { Line } = {
		{
			text = age.name .. (if reached then " (reached)" else ""),
			colour = Color3.fromRGB(age.color[1], age.color[2], age.color[3]),
		},
	}
	if age.index == 1 then
		table.insert(lines, { text = "Where everyone starts", colour = GRAY })
		return lines
	end
	local level = if status then Knowledge.levelOf(status.points) else 0
	table.insert(
		lines,
		{ text = `Knowledge level {age.level}`, colour = if reached or level >= age.level then GREEN else GRAY }
	)
	for i, milestone in Ages.MILESTONES do
		if table.find(age.milestones, milestone) then
			local met = reached or (status ~= nil and status.milestones[i] == true)
			table.insert(lines, { text = milestone.text, colour = if met then GREEN else GRAY })
		end
	end
	return lines
end

-- The info lines for a node.
local function skillLines(skill: Skill, state: Progression.State): { Line }
	local lines: { Line } = {}
	local unlocked = state.skills[skill.id] == true
	table.insert(lines, { text = skill.name, colour = if unlocked then UNLOCKED else WHITE })
	table.insert(lines, { text = skill.description, colour = LIGHT })
	local needs: { string } = {}
	for _, id in skill.requires do
		local before = Skills.byId(id)
		if before then
			table.insert(needs, before.name)
		end
	end
	local age = Ages.get(skill.age) :: Age
	table.insert(lines, {
		text = `Costs {skill.cost} skill point{if skill.cost == 1 then "" else "s"}, in the {age.name}`,
		colour = GRAY,
	})
	if #needs > 0 then
		table.insert(lines, { text = `Needs {table.concat(needs, ", ")}`, colour = GRAY })
	end
	if unlocked then
		table.insert(lines, { text = "Unlocked", colour = UNLOCKED })
	else
		local ok, _, why = Progression.canUnlock(state, skill.id)
		table.insert(
			lines,
			if ok
				then { text = "Ready to unlock", colour = GREEN }
				else { text = why or "Locked", colour = Style.Colour.Red }
		)
	end
	return lines
end

-- Builds the screen and registers it with the HUD's touch button. Call after Screens.start.
function SkillTreeScreen.start()
	if started or not ProgressionState.enabled() then
		return
	end
	started = true

	local root = Instance.new("Frame")
	root.Name = "SkillTree"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	root.Visible = false
	root.ZIndex = 2
	Style.panel(root, 0, 0, WIDTH, HEIGHT)

	-- (Dark text on the light panel, without a shadow, as the inventory's titles.)
	FormWidgets.label(root, "Skills", MARGIN, HEADER_Y, 60, Style.Colour.Title, nil, nil, true)
	local header = FormWidgets.label(
		root,
		"",
		MARGIN + 50,
		HEADER_Y,
		WIDTH - MARGIN * 2 - 50,
		Style.Colour.Title,
		"right",
		nil,
		true
	)

	-- The grid: a dark backdrop, the Age titles, the lines, the nodes.
	Style.inset(root, MARGIN - 2, GRID_Y - 2, WIDTH - MARGIN * 2 + 4, GRID_H + 4, 2, BACKDROP)
	local titles: { [number]: FormWidgets.Label } = {}
	local titleButtons: { TextButton } = {}
	for index, age in Ages.list do
		local x = MARGIN + (index - 1) * COLUMN
		titles[index] = FormWidgets.label(root, shortName(age), x, GRID_Y + 2, COLUMN, DIM, "centre", 6)
		local button = Instance.new("TextButton")
		button.Text = ""
		button.BackgroundTransparency = 1
		button.Position = UDim2.fromOffset(x, GRID_Y)
		button.Size = UDim2.fromOffset(COLUMN, TITLE_H)
		button.ZIndex = 7
		button.SelectionImageObject = SELECTION
		button.Parent = root
		table.insert(titleButtons, button)
	end
	-- (Column separators.)
	for index = 1, Ages.count - 1 do
		local separator = Style.frame(root, MARGIN + index * COLUMN, GRID_Y, 1, GRID_H, Color3.fromRGB(60, 55, 50), 3)
		separator.BackgroundTransparency = 0.3
	end

	local nodes: { NodeView } = {}
	for _, skill in Skills.list do
		table.insert(nodes, drawNode(root, skill))
	end
	for _, view in nodes do
		for _, id in view.skill.requires do
			local from = Skills.byId(id)
			if from then
				table.insert(view.lines, { frames = drawLine(root, from, view.skill), from = from })
			end
		end
	end

	-- The info lines (on a dark backdrop like the grid's) and the buttons.
	local infoWidth = WIDTH - MARGIN * 2 - 4
	Style.inset(
		root,
		MARGIN - 2,
		INFO_Y - INFO_PAD,
		WIDTH - MARGIN * 2 + 4,
		LINE * INFO_LINES + INFO_PAD * 2 - 1,
		2,
		BACKDROP
	)
	local info: { FormWidgets.Label } = {}
	for i = 1, INFO_LINES do
		info[i] = FormWidgets.label(root, "", MARGIN + 2, INFO_Y + (i - 1) * LINE, infoWidth, GRAY)
	end
	local unlock = FormWidgets.button(root, "Unlock", WIDTH - MARGIN * 2 - BUTTON_W * 2, BUTTONS_Y, BUTTON_W, BUTTON_H)
	local done = FormWidgets.button(root, "Done", WIDTH - MARGIN - BUTTON_W, BUTTONS_Y, BUTTON_W, BUTTON_H)

	-- What the info shows: a hovered node or title, else the selected node.
	local selected: Skill? = nil
	local hoveredSkill: Skill? = nil
	local hoveredAge: Age? = nil

	-- `lines`, wrapped at word breaks to the info's width (Ui/TextWrap.fit: when they don't all fit,
	-- the last line, the status, keeps its place).
	local function measure(text: string): number
		return Style.textWidth(text)
	end
	local function showLines(lines: { Line })
		local rows = TextWrap.fit(lines, INFO_LINES, infoWidth, measure)
		for i = 1, INFO_LINES do
			local entry = rows[i]
			info[i]:setText(if entry then entry.text else "", if entry then entry.colour else GRAY)
		end
	end

	refresh = function()
		local status = ProgressionState.get()
		local state = ProgressionState.state()
		local level = Knowledge.levelOf(state.points)
		local age = Ages.get(state.age) :: Age
		local points = Progression.skillPoints(state)
		header:setText(`{age.name}, level {level}, {points} skill point{if points == 1 then "" else "s"}`)
		for index, title in titles do
			local entry = Ages.get(index) :: Age
			local reached = state.age >= index
			title:setText(shortName(entry), if reached then reachedColour(entry) else DIM)
		end
		for _, view in nodes do
			local skill = view.skill
			local unlocked = state.skills[skill.id] == true
			local available = not unlocked and (Progression.canUnlock(state, skill.id))
			Style.paint(view.frame, if unlocked then UNLOCKED elseif available then AVAILABLE else LOCKED)
			view.icon:setDimmed(not (unlocked or available), true)
			for _, line in view.lines do
				local fromDone = state.skills[line.from.id] == true
				Style.paint(
					line.frames,
					if unlocked and fromDone then LINE_DONE elseif fromDone then LINE_OPEN else LINE_LOCKED
				)
			end
		end
		local shown = hoveredSkill or selected
		if hoveredAge then
			showLines(ageLines(hoveredAge, status))
		elseif shown then
			showLines(skillLines(shown, state))
		else
			showLines({
				{ text = "Select a skill to see what it does", colour = GRAY },
				{ text = "One skill point a knowledge level", colour = GRAY },
			})
		end
		local target = selected
		unlock:setEnabled(target ~= nil and (Progression.canUnlock(state, target.id)))
	end

	for _, view in nodes do
		local skill = view.skill
		local function hover(on: boolean)
			hoveredSkill = if on then skill elseif hoveredSkill == skill then nil else hoveredSkill
			refresh()
		end
		view.button.MouseEnter:Connect(function()
			hover(true)
		end)
		view.button.MouseLeave:Connect(function()
			hover(false)
		end)
		view.button.SelectionGained:Connect(function()
			hover(true)
		end)
		view.button.SelectionLost:Connect(function()
			hover(false)
		end)
		view.button.Activated:Connect(function()
			SoundPlayer.click()
			selected = skill
			refresh()
		end)
	end
	for index, button in titleButtons do
		local age = Ages.get(index) :: Age
		local function hover(on: boolean)
			hoveredAge = if on then age elseif hoveredAge == age then nil else hoveredAge
			refresh()
		end
		button.MouseEnter:Connect(function()
			hover(true)
		end)
		button.MouseLeave:Connect(function()
			hover(false)
		end)
		button.SelectionGained:Connect(function()
			hover(true)
		end)
		button.SelectionLost:Connect(function()
			hover(false)
		end)
	end
	unlock.clicked = function()
		local target = selected
		if target then
			SoundPlayer.click()
			ProgressionState.unlock(target.id)
		end
	end

	local thePanel: Screens.Panel
	close = function()
		Screens.closePanel(thePanel)
	end
	done.clicked = function()
		SoundPlayer.click()
		close()
	end

	-- Gamepad: down / up through the rows of a column, left / right through the columns.
	for _, view in nodes do
		local skill = view.skill
		local function nearest(age: number, row: number): GuiObject?
			local best: NodeView? = nil
			for _, other in nodes do
				if
					other.skill.age == age
					and (best == nil or math.abs(other.skill.row - row) < math.abs(best.skill.row - row))
				then
					best = other
				end
			end
			return if best then best.button else nil
		end
		view.button.NextSelectionLeft = nearest(skill.age - 1, skill.row) or view.button
		view.button.NextSelectionRight = nearest(skill.age + 1, skill.row) or unlock.button
	end

	thePanel = {
		root = root,
		size = function(): Vector2
			return Vector2.new(WIDTH, HEIGHT)
		end,
		closed = function()
			hoveredSkill = nil
			hoveredAge = nil
		end,
		firstSelectable = function(): GuiObject?
			return nodes[1] and nodes[1].button
		end,
	}
	panel = thePanel

	ProgressionState.changed:Connect(function()
		if SkillTreeScreen.isOpen() then
			refresh()
		end
	end)
	Hud.onSkillsButton(SkillTreeScreen.toggle)

	-- K (and the gamepad button) with no screen open; K again closes it (Screens closes panels
	-- with E, Escape and B).
	local key = Config.Progression.Key
	local pad = Config.Progression.GamepadButton
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local code = input.KeyCode
		-- (Not while typing: the chat and text boxes take the key.)
		if (code.Name ~= key and code.Name ~= pad) or processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if SkillTreeScreen.isOpen() then
			-- (The D-pad moves the gamepad's selection here: B closes, as Screens does.)
			if code.Name == key then
				close()
			end
		elseif not Screens.isOpen() and not GuiService.MenuIsOpen then
			SkillTreeScreen.toggle()
		end
	end)
end

-- Opens the screen when no screen is open, or closes it when it is shown.
function SkillTreeScreen.toggle()
	local p = panel
	if p == nil then
		return
	end
	if Screens.panelShown(p) then
		close()
	elseif not Screens.isOpen() then
		refresh()
		Screens.showPanel(p)
	end
end

return SkillTreeScreen
