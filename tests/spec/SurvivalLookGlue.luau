--[[
	The inventory family's glue on a fake Roblox client (tests/lib/FakeClient: the real
	Ui/InventoryScreen, Style, Theme, HoverTip, InventoryColumns, SlotWidgets, ContainerPanel,
	GroundStrip and Masks; stand-ins only for what draws 3D, reads the device or talks to the
	server). Each test is a review finding that could not happen again:

	  live view   with the recipe view open the VICINITY column stays shown and live: a furnace's
	              progress bar follows its data when the screen is drawn under the view (and
	              Ui/Screens draws it there: its source is checked), with no hover outline left.
	  inert view  under the view the column takes nothing: the creative "items" button and the
	              section bars ignore clicks and are not Selectable, the GROUND strip and every
	              shown slot are not Selectable; all of it comes back when the view closes.
	  effects     the open inventory offers the effect icons a place in its band (screen pixels,
	              inside the root's band, beside the quickbar), none while the view covers it.
	  tooltips    a block section rebuilt (another block opened) leaves nothing attached in
	              Ui/HoverTip: its bar's entry goes when the bar is destroyed, though the bar's
	              "expand"/"collapse" function reaches the bar (Luau's weak keys are not
	              ephemerons).
	  outlines    the creative scrollbar's and the recipe view's "+" button's hairlines follow
	              their screen's scale like every other outline (OUTLINE_PX screen pixels); every
	              outline builder's call in the client passes a scale registry.
	  masks       a mask is drawn a few rows a frame: a mask far slower than a frame's budget is
	              spread over many frames, no frame drawing much more than the budget, and its
	              images fill in when it is done.
]]

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local FakeClient = require("../lib/FakeClient")

local Vector2 = roblox.Vector2
local UDim2 = roblox.UDim2
local Instance = FakeClient.Instance

return function(t, shared, sharedRequire, _server, _client)
	local Blocks = sharedRequire(shared.Blocks)
	local Types = sharedRequire(shared.Inventory.Types)

	local device = { touch = false }
	local clientWindow: any = nil

	local stubs: { [string]: any } = {}
	stubs["src/client/Ui/UiScale.luau"] = {
		changed = FakeClient.signal(),
		touch = function()
			return device.touch
		end,
		setting = function()
			return 0
		end,
		setSetting = function() end,
		base = function()
			return 4
		end,
		layerOf = function()
			return 1
		end,
	}
	stubs["src/client/Settings/Keybinds.luau"] = {
		changed = FakeClient.signal(),
		name = function(action: string): string
			return string.sub(action, 7)
		end,
	}
	stubs["src/client/Inventory/ClientInventory.luau"] = {
		mode = function()
			return "survival"
		end,
		apply = function() end,
		window = function()
			return clientWindow
		end,
	}
	stubs["src/client/Audio/SoundPlayer.luau"] = { click = function() end }
	stubs["src/client/Player/ProgressionState.luau"] = {
		get = function()
			return nil
		end,
		lockText = function()
			return nil
		end,
		gate = function()
			return nil
		end,
	}
	stubs["src/client/Entities/EntityRenderer.luau"] = {
		itemsNear = function()
			return {}
		end,
	}
	local Preview = {}
	Preview.__index = Preview
	function Preview.new(parent)
		local frame = Instance.new("ViewportFrame")
		frame.Parent = parent
		return setmetatable({ frame = frame }, Preview)
	end
	function Preview.setRect(self, x, y, w, h)
		self.frame.Position = UDim2.fromOffset(x, y)
		self.frame.Size = UDim2.fromOffset(w, h)
	end
	function Preview.opened() end
	function Preview.closed() end
	function Preview.update() end
	function Preview.follow() end
	stubs["src/client/Ui/PlayerPreview.luau"] = Preview
	-- ItemIcon: `new` a bare root; `slot` as the real one builds its parts.
	stubs["src/client/Ui/ItemIcon.luau"] = function(req, node)
		local Icon = {}
		Icon.__index = Icon
		local M = { TAB_HEIGHT = 26, TAB_WIDTH = 28 }
		function M.new(parent, x, y, z)
			local root = Instance.new("Frame")
			root.Name = "ItemIcon"
			root.BackgroundTransparency = 1
			root.Position = UDim2.fromOffset(x, y)
			root.Size = UDim2.fromOffset(16, 16)
			root.ZIndex = z or 5
			root.Parent = parent
			return setmetatable({ root = root, item = nil, count = 0 }, Icon)
		end
		function Icon.set(self, item, count)
			self.item, self.count = item, count
		end
		function Icon.setDimmed() end
		function Icon.destroy(self)
			self.root:Destroy()
		end
		function Icon.setTransparency() end
		function Icon.setScale() end
		function M.slot(parent, x, y, z, big, scaled)
			local Style = req(node("src/client/Ui/Style.luau", true))
			local Dayz, Theme = Style.Dayz, Style.Theme
			local button = Style.itemButton(parent, x, y, z)
			local size = if big then Theme.Size.BIG_FACE else Theme.Size.CELL
			local offset = if big then 1 - (Theme.Size.BIG_FACE - Style.ITEM) // 2 else 1
			local face = Dayz.slotFace(button, offset, offset, size, size, 1)
			local icon = M.new(button, 1, 1, 5)
			local hover = Instance.new("Frame")
			hover.Name = "Hover"
			hover.BackgroundTransparency = 1
			hover.BorderSizePixel = 0
			hover.Position = UDim2.fromOffset(offset, offset)
			hover.Size = UDim2.fromOffset(size, size)
			hover.ZIndex = 10
			hover.Visible = false
			Dayz.outline(hover, nil, nil, scaled)
			hover.Parent = button
			return { button = button, icon = icon, hover = hover, face = face }
		end
		return M
	end

	local heartbeat = FakeClient.signal()
	local services = {
		TextService = {
			GetTextSize = function(_, text: string, size: number)
				return Vector2.new(#text * size / 2, size)
			end,
		},
		RunService = { Heartbeat = heartbeat, RenderStepped = FakeClient.signal() },
		AssetService = {
			CreateEditableImage = function()
				error("no EditableImage in Lune")
			end,
		},
		Players = { LocalPlayer = { Character = nil, DisplayName = "Tester" } },
		GuiService = { SelectedObject = nil },
		UserInputService = {
			TouchEnabled = false,
			GetLastInputType = function()
				return roblox.Enum.UserInputType.MouseMovement
			end,
		},
	}

	local load = FakeClient.loader(shared, sharedRequire, stubs, services)
	local InventoryScreen = load("src/client/Ui/InventoryScreen.luau")
	local Style = load("src/client/Ui/Style.luau")
	local Theme = load("src/client/Ui/Theme.luau")
	local HoverTip = load("src/client/Ui/HoverTip.luau")
	local Masks = load("src/client/Ui/Masks.luau")

	local VIEW = { w = 1920, h = 1080, top = 58, base = 4, touch = false }
	local gui = Instance.new("ScreenGui")

	local function windowOf(container: any): any
		local inventory = Types.newInventory()
		inventory.accessorySlots = 5
		return {
			id = if container and container.kind ~= "crafting" then 3 else 0,
			inventory = inventory,
			container = container,
		}
	end

	-- A screen laid out for VIEW with `container` open (nil: window 0), drawn once.
	local function build(container: any?, tabs: boolean?): (any, any)
		FakeClient.VIEW.w, FakeClient.VIEW.h = VIEW.w, VIEW.h
		local screen = InventoryScreen.new(gui)
		local uiScale = Instance.new("UIScale")
		uiScale.Parent = screen.root
		screen.root.Visible = true
		local window = windowOf(container or Types.newCrafting("inventory", 0))
		screen:setLayout(window.container, tabs == true)
		uiScale.Scale = screen:place(VIEW)
		clientWindow = window
		screen:render(window, nil, {})
		return screen, window
	end

	local function setViewing(screen: any, viewing: boolean)
		screen:setViewing(viewing)
		screen.root.UIScale.Scale = screen:place(VIEW)
	end

	t.test("survival look glue: under the recipe view the VICINITY column stays live", function()
		local furnace = { kind = "furnace", block = Blocks.id.Furnace, size = 3, slots = {} }
		local screen, window = build(furnace)
		setViewing(screen, true)
		t.ok(FakeClient.shown(screen.sections.container.root), "the furnace's section shows beside the view")
		t.ok(not FakeClient.shown(screen.band.frame), "the band hides under the view")
		local progress = screen.panel and screen.panel.progress
		t.ok(progress ~= nil, "the furnace has a progress bar")
		if progress then
			local function sizes(): string
				local list = {}
				for _, d in progress.track:GetDescendants() do
					table.insert(list, tostring(d.Size))
				end
				return table.concat(list, ",")
			end
			local before = sizes()
			furnace.data = { 100, 200, 100, 200 }
			screen:render(window, nil, {})
			t.ok(sizes() ~= before, "drawn under the view, the progress bar follows the furnace")
			furnace.data = nil
		end
		-- (Ui/Screens draws the inventory under the view, with no hover and no drag routed.)
		local source = fs.readFile("src/client/Ui/Screens.luau")
		local from = string.find(source, "local point, hover = pointer()\n\t\tlocal viewing = jei:viewOpen()", 1, true)
		t.ok(from ~= nil, "Screens' frame reads the view")
		if from then
			local branch = string.sub(source, from, (string.find(source, 'elseif current == "creative"', from, true)))
			t.ok(
				string.find(branch, "inventory:render(shown, nil, dragged)", 1, true) ~= nil,
				"Screens keeps drawing the inventory while the view is open"
			)
		end
		setViewing(screen, false)
	end)

	t.test("survival look glue: under the recipe view the VICINITY column takes nothing", function()
		local screen, window = build(nil, true)
		local tabbed = 0
		screen.onTab = function()
			tabbed += 1
		end
		local craft = screen.sections.craft
		local jei = screen.sections.jei
		t.ok(screen.itemsButton.Visible, "the creative items button shows")
		setViewing(screen, true)
		screen:render(window, nil, {})
		t.ok(FakeClient.shown(craft.root) and FakeClient.shown(screen.itemsButton), "CRAFTING and the button show")
		for _, button in { screen.itemsButton, craft.header, jei.header, screen.ground.button } do
			t.ok(not button.Selectable, `{button.Name}: not Selectable under the view`)
			t.ok(not button.Active, `{button.Name}: not Active under the view`)
		end
		screen.itemsButton.Activated:Fire()
		t.eq(tabbed, 0, "the items button does not switch pages under the view")
		local collapsed = screen.collapsed
		craft.header.Activated:Fire()
		jei.header.Activated:Fire()
		t.eq(screen.collapsed, collapsed, "the section bars do not fold under the view")
		local shownSlots, selectable = 0, 0
		for _, widget in screen.widgets.widgets do
			local button = widget.view.button
			if FakeClient.shown(button) then
				shownSlots += 1
				if button.Selectable then
					selectable += 1
				end
			end
		end
		t.ok(shownSlots >= 5, `CRAFTING's slots show ({shownSlots})`)
		t.eq(selectable, 0, "no slot a gamepad can stop on under the view")
		-- The view closes: everything takes input again.
		setViewing(screen, false)
		for _, button in { screen.itemsButton, craft.header, jei.header, screen.ground.button } do
			t.ok(button.Selectable and button.Active, `{button.Name}: takes input again`)
		end
		local craftSelectable = 0
		for _, widget in screen.widgets.widgets do
			if widget.group == "craft" and widget.view.button.Selectable then
				craftSelectable += 1
			end
		end
		t.eq(craftSelectable, 5, "CRAFTING's slots Selectable again")
		craft.header.Activated:Fire()
		t.ok(screen.collapsed ~= collapsed, "the bar folds its section again")
		screen.itemsButton.Activated:Fire()
		t.eq(tabbed, 1, "the items button switches pages again")
	end)

	t.test("survival look glue: the band offers the effect icons a place", function()
		local screen = build(nil)
		local rect, scale = screen:effectsRect()
		t.ok(rect ~= nil, "a place for the effects")
		if rect then
			local x, y, w, h = FakeClient.absRect(screen.root)
			t.ok(rect.x >= x and rect.x + rect.w <= x + w + 1e-6, "inside the root across")
			t.ok(rect.y >= y and rect.y + rect.h <= y + h + 1e-6, "inside the root down")
			local band = screen.arrangement.band
			t.ok(rect.y >= y + band.y * scale - 1e-6, "in the band")
			t.eq(rect.h, screen.arrangement.quickbar.h * scale, "as tall as the quickbar")
			t.ok(rect.w >= 3 * rect.h, "room for three icons at least")
		end
		setViewing(screen, true)
		t.eq(screen:effectsRect(), nil, "none while the view covers the band")
		setViewing(screen, false)
		t.ok(screen:effectsRect() ~= nil, "back when it closes")
	end)

	t.test("survival look glue: a rebuilt block section leaves nothing in the button tooltips", function()
		local furnace = { kind = "furnace", block = Blocks.id.Furnace, size = 3, slots = {} }
		local screen = build(furnace)
		local header = screen.sections.container.header
		t.ok(HoverTip.textOf(header) ~= nil, "the furnace's bar says what a click does")
		local chest = { kind = "chest", block = Blocks.id.Chest, size = 27, slots = {} }
		screen:setLayout(chest, false)
		t.ok(screen.sections.container.header ~= header, "the chest's section is a new one")
		t.eq(HoverTip.textOf(header), nil, "the destroyed bar's entry is gone")
		t.ok(HoverTip.textOf(screen.sections.container.header) ~= nil, "the chest's bar has its own")
	end)

	t.test("survival look glue: every outline follows its screen's scale", function()
		local Dayz = Style.Dayz
		local scaled = Dayz.scaled()
		local parent = Instance.new("Frame")
		local scrollbar = Dayz.scrollbar(parent, 0, 0, 4, 40, 4, scaled)
		local plus = Dayz.toggleButton(parent, "+", 0, 0, 12, 12, 6, scaled)
		local button = Dayz.button(parent, "x", 0, 0, 12, 12, 6, scaled)
		scaled:setScale(4)
		local want = Theme.strokeThickness(4, Theme.STROKE_FOLLOWS_UISCALE)
		for name, object in { scrollbar = scrollbar.track, plus = plus, button = button } do
			local stroke = object:FindFirstChildOfClass("UIStroke")
			t.ok(stroke ~= nil, `{name}: an outline`)
			if stroke then
				t.eq(stroke.Thickness, want, `{name}: OUTLINE_PX screen pixels at scale 4`)
			end
		end
		-- Every outline builder's call in the client passes a scale registry last (the review found
		-- the creative scrollbar and the recipe view's "+" without one).
		local builders = { "Dayz.outline", "Dayz.focus", "Dayz.button", "Dayz.field", "Dayz.scrollbar" }
		table.insert(builders, "Dayz.toggleButton")
		table.insert(builders, "buttonParts")
		local checked = 0
		local function scan(dir: string)
			for _, entry in fs.readDir(dir) do
				local path = `{dir}/{entry}`
				if fs.isDir(path) then
					scan(path)
				elseif string.sub(entry, -5) == ".luau" then
					local source = fs.readFile(path)
					for _, builder in builders do
						local at = 1
						while true do
							local s, e = string.find(source, builder .. "(", at, true)
							if s == nil then
								break
							end
							at = e + 1
							local before = string.sub(source, math.max(1, s - 9), s - 1)
							if before ~= "function " and not string.find(before, "%.$") then
								-- (The call's arguments, to its closing parenthesis.)
								local depth, i = 1, e + 1
								while depth > 0 and i <= #source do
									local c = string.sub(source, i, i)
									if c == "(" then
										depth += 1
									elseif c == ")" then
										depth -= 1
									end
									i += 1
								end
								local args = string.split(string.sub(source, e + 1, i - 2), ",")
								local last = string.gsub(args[#args], "%s", "")
								local line = select(2, string.gsub(string.sub(source, 1, s), "\n", "")) + 1
								t.ok(
									string.find(string.lower(last), "scaled") ~= nil,
									`{path}:{line}: {builder} passes a scale registry (last: {last})`
								)
								checked += 1
							end
						end
					end
				end
			end
		end
		scan("src/client")
		t.ok(checked >= 20, `{checked} outline builder calls`)
	end)

	t.test("survival look glue: a mask is drawn a few rows a frame", function()
		local Dayz = Style.Dayz
		-- A drawing far slower than a frame's budget: many shapes for each sample.
		local ops = {}
		for i = 1, 120 do
			local a = i * 2.399
			table.insert(
				ops,
				{ shape = { kind = "circle", x = 0.5 + 0.3 * math.cos(a), y = 0.5 + 0.3 * math.sin(a), r = 0.05 } }
			)
		end
		local started = os.clock()
		local whole = Masks.render(ops, 48, 48, 3)
		local wholeTime = os.clock() - started
		-- The same drawing a few rows at a time is the same mask.
		local job = Masks.begin(ops, 48, 48, 3)
		local steps = 0
		while not Masks.step(job, 5) do
			steps += 1
		end
		t.eq(steps, 9, "48 rows five at a time: ten steps")
		local same = true
		for i, a in whole.alpha do
			same = same and job.mask.alpha[i] == a
		end
		t.ok(same, "drawn in steps, the same mask")
		-- Queued in the look: drawn over many frames, none much over the budget.
		local parent = Instance.new("Frame")
		local image = Dayz.maskImage(parent, "spec.heavy", function()
			return Masks.begin(ops, 48, 48, 3)
		end, 0, 0, 11, 11, Dayz.Colour.Icon, 0, 1)
		local frames, longest = 0, 0
		while image:FindFirstChild("Blocks") == nil and frames < 5000 do
			local from = os.clock()
			heartbeat:Fire()
			longest = math.max(longest, os.clock() - from)
			frames += 1
		end
		t.ok(image:FindFirstChild("Blocks") ~= nil, `the image filled in ({frames} frames)`)
		t.ok(frames >= 4, `spread over frames ({frames})`)
		t.ok(
			longest < wholeTime / 3,
			`no frame draws the whole mask (longest {math.floor(longest * 1000 + 0.5)} ms, the mask {math.floor(
				wholeTime * 1000 + 0.5
			)} ms)`
		)
	end)
end
