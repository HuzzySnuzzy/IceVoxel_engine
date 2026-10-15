--[[
	The HUD's quickbar (client Ui/Quickbar) built on Lune's Roblox instances (@lune/roblox: Frames,
	TextLabels and UIStrokes with Roblox's own properties), with the game's real Ui/Style, Theme,
	Masks and HudLayout, and stand-ins only for what draws in 3D or reads the device: Ui/ItemIcon
	(its root Frame, made as the real one makes it: 16 x 16 at (x, y) of its parent, ZIndex z;
	checked against its source), Ui/UiScale (a mouse screen) and Settings/Keybinds (the keys "1"
	to "9").

	What draws over what is worked out as Roblox does for the HUD's ScreenGuis, which order their
	children by sibling (Ui/UiScale.screenGui): a child draws over its ancestors, and of two
	branches the one whose top (the child of their lowest common ancestor) has the higher ZIndex
	draws over the other; equal ZIndexes have no promised order, so they count as neither.

	  layers  with items in eight slots and the ninth empty, every occupied slot's number box (boxed
	          in the top right corner) draws over its item's picture, which it overlaps, and the
	          picture over the cell's face; the empty slot's faint centred box over its face; the
	          selection outline and the hover outlines over every picture. Each picture sits at
	          HudLayout.quickIcon in the HUD's canvas (the spectator menu's icon math). Named
	          regression: the pictures were made beside the bar at z 5, which drew them over the
	          whole bar, number boxes included (25 of a box's 36 pixels and its digit covered); the
	          same check run on that old arrangement says so.
	  paint   the faces: the selected slot's olive, occupied ones filled, the empty one empty; the
	          numbers: the key names, shown only for a scale whose tiny text is 8 screen pixels
	          tall or more, and never on a touch screen.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local GLOBALS = "script, require, game, Instance, Color3, UDim2, UDim, Vector2, Enum, Font"
local ITEM_ICON = "src/client/Ui/ItemIcon.luau"

-- A module's source with GLOBALS declared from the chunk's arguments (after the --! lines).
local function withHeader(source: string): string
	local lines = string.split(source, "\n")
	local i = 1
	while lines[i] and string.sub(lines[i], 1, 3) == "--!" do
		i += 1
	end
	lines[i] = `local {GLOBALS} = ...; ` .. (lines[i] or "")
	return table.concat(lines, "\n")
end

-- A stand-in signal: Connect keeps the function; `fire` calls them all.
local function signal(): any
	local functions = {}
	return {
		Connect = function(_, fn)
			table.insert(functions, fn)
			return { Disconnect = function() end }
		end,
		fire = function()
			for _, fn in functions do
				fn()
			end
		end,
	}
end

return function(t, shared, sharedRequire, _server, _client)
	local Instance = roblox.Instance
	local UDim2 = roblox.UDim2

	-- The device: a mouse screen unless a test says touch.
	local device = { touch = false }

	-- Ui/ItemIcon's stand-in: the root as ItemIcon.new makes it (checked against the source below).
	local ItemIconStub = {}
	ItemIconStub.__index = ItemIconStub
	function ItemIconStub.new(parent: any, x: number, y: number, z: number?, look: string?, _scaled: any): any
		local root = Instance.new("Frame")
		root.Name = "ItemIcon"
		root.BackgroundTransparency = 1
		root.BorderSizePixel = 0
		root.Position = UDim2.fromOffset(x, y)
		root.Size = UDim2.fromOffset(16, 16)
		root.ZIndex = z or 5
		root.Parent = parent
		return setmetatable({ root = root, look = look, item = nil, transparency = 0 }, ItemIconStub)
	end
	function ItemIconStub.set(self: any, item: number?)
		self.item = item
	end
	function ItemIconStub.setTransparency(self: any, transparency: number)
		self.transparency = transparency
	end
	function ItemIconStub.setScale() end

	local stubs: { [string]: any } = {
		[ITEM_ICON] = ItemIconStub,
		["src/client/Ui/UiScale.luau"] = {
			changed = signal(),
			touch = function(): boolean
				return device.touch
			end,
			setting = function(): number
				return 0
			end,
			setSetting = function() end,
		},
		["src/client/Settings/Keybinds.luau"] = {
			changed = signal(),
			-- ("hotbar3" is bound to "3".)
			name = function(action: string): string
				return string.sub(action, 7)
			end,
		},
	}

	local game = {
		GetService = function(_, name: string): any
			if name == "ReplicatedStorage" then
				return {
					WaitForChild = function(_, child: string)
						assert(child == "IceVoxel", child)
						return shared
					end,
				}
			elseif name == "TextService" then
				return {
					GetTextSize = function(_, text: string, size: number)
						return roblox.Vector2.new(#text * size / 2, size)
					end,
				}
			elseif name == "RunService" then
				-- (Style queues Ui/Silhouettes' masks as it loads and draws them on Heartbeat,
				-- which never fires here: the quickbar draws no mask.)
				return { Heartbeat = signal() }
			elseif name == "AssetService" then
				return {
					CreateEditableImage = function()
						error("no EditableImage in Lune")
					end,
				}
			end
			error(`no stand-in service {name}`)
		end,
	}

	-- Fake script nodes for src/client: a folder's child is its `.luau` file or its sub-folder
	-- (the tree read once here: Lune cannot read files inside a metamethod).
	local kinds: { [string]: "file" | "dir" } = {}
	local function scan(dir: string)
		for _, entry in fs.readDir(dir) do
			local full = `{dir}/{entry}`
			if fs.isDir(full) then
				kinds[full] = "dir"
				scan(full)
			elseif string.sub(entry, -5) == ".luau" then
				kinds[string.sub(full, 1, -6)] = "file"
			end
		end
	end
	scan("src/client")
	local nodes: { [string]: any } = {}
	local function node(path: string, file: boolean): any
		local found = nodes[path]
		if found then
			return found
		end
		local made = setmetatable({ __fake = true, path = path, file = file }, {
			__index = function(self, key: string): any
				local own = rawget(self, "path")
				if key == "Parent" then
					return node(string.match(own, "^(.*)/[^/]+$") :: string, false)
				end
				assert(not rawget(self, "file"), `{own} has no child {key}`)
				local child = `{own}/{key}`
				local kind = kinds[child]
				assert(kind ~= nil, `{own} has no child {key}`)
				return if kind == "file" then node(child .. ".luau", true) else node(child, false)
			end,
		})
		nodes[path] = made
		return made
	end

	local cache: { [string]: any } = {}
	local function req(target: any): any
		if type(target) ~= "table" or rawget(target, "__fake") == nil then
			return sharedRequire(target)
		end
		local path = rawget(target, "path")
		if stubs[path] ~= nil then
			return stubs[path]
		end
		if cache[path] ~= nil then
			return cache[path]
		end
		local chunk = luau.load(withHeader(fs.readFile(path)), { debugName = path })
		local result = chunk(
			target,
			req,
			game,
			Instance,
			roblox.Color3,
			UDim2,
			roblox.UDim,
			roblox.Vector2,
			roblox.Enum,
			roblox.Font
		)
		cache[path] = result
		return result
	end

	local Quickbar = req(node("src/client/Ui/Quickbar.luau", true))
	local Style = req(node("src/client/Ui/Style.luau", true))
	local Theme = req(node("src/client/Ui/Theme.luau", true))
	local HudLayout = req(node("src/client/Ui/HudLayout.luau", true))

	-- `object`'s ancestors from the ScreenGui down to it.
	local function chain(object: any): { any }
		local list = {}
		local at = object
		while at ~= nil do
			table.insert(list, 1, at)
			at = at.Parent
		end
		return list
	end

	-- Does `a` draw over `b` in a ScreenGui with sibling ordering (see the header)?
	local function drawsOver(a: any, b: any): boolean
		local ca, cb = chain(a), chain(b)
		assert(ca[1] == cb[1], "both in the same tree")
		local i = 1
		while ca[i + 1] ~= nil and ca[i + 1] == cb[i + 1] do
			i += 1
		end
		local topA, topB = ca[i + 1], cb[i + 1]
		if topB == nil then
			return topA ~= nil -- (b is an ancestor of a)
		elseif topA == nil then
			return false -- (a is an ancestor of b)
		end
		return topA.ZIndex > topB.ZIndex
	end

	-- `object`'s rect in `root`'s coordinates (offsets only, no anchor points: how the HUD is built).
	local function rectIn(object: any, root: any): HudLayout.Rect
		local x, y = 0, 0
		local at = object
		while at ~= root do
			assert(at ~= nil, "under the root")
			x += at.Position.X.Offset
			y += at.Position.Y.Offset
			at = at.Parent
		end
		return { x = x, y = y, w = object.Size.X.Offset, h = object.Size.Y.Offset }
	end

	-- Ui/Hud's tree: a ScreenGui (sibling ordering), the canvas, the Hotbar frame.
	local function hud(): (any, any)
		local gui = Instance.new("ScreenGui")
		gui.ZIndexBehavior = roblox.Enum.ZIndexBehavior.Sibling
		local canvas = Instance.new("Frame")
		canvas.Parent = gui
		local hotbar = Instance.new("Frame")
		hotbar.Name = "Hotbar"
		hotbar.Parent = canvas
		return gui, hotbar
	end

	local BAR = HudLayout.QUICK.bar
	-- Items in slots 1..8 (the stand-in icon shows any number), slot 9 empty, slot 3 selected.
	local function window(): any
		local slots = {}
		for i = 1, 8 do
			slots[i] = { item = 100 + i, count = i }
		end
		return { id = 0, inventory = { slots = slots, selected = 3 } }
	end

	t.test("quickbar: the stand-in icon's root is ItemIcon.new's", function()
		local source = fs.readFile(ITEM_ICON)
		local body = string.match(source, "function ItemIcon%.new%((.-)\nend\n")
		t.ok(body ~= nil, "ItemIcon.new found")
		local text = body :: string
		for _, line in
			{
				"root.Position = UDim2.fromOffset(x, y)",
				"root.Size = UDim2.fromOffset(Style.ITEM, Style.ITEM)",
				"root.ZIndex = z or 5",
				"root.Parent = parent",
			}
		do
			t.ok(string.find(text, line, 1, true) ~= nil, `ItemIcon.new: {line}`)
		end
		t.eq(Style.ITEM, 16)
	end)

	t.test("quickbar: number boxes over the pictures, pictures over the faces, outlines on top", function()
		device.touch = false
		local _, hotbar = hud()
		local scaled = Style.Dayz.scaled()
		scaled:setScale(4)
		local bar = Quickbar.build(hotbar, BAR, scaled)
		local w = window()
		bar:render(0, "play", w, 3, false)
		local selection = bar.selection:FindFirstChild("Outline")
		t.ok(selection ~= nil, "the selection's outline")
		for i = 1, 9 do
			local cell, icon = bar.cells[i], bar.icons[i]
			local occupied = i <= 8
			local picture = rectIn(icon.root, hotbar)
			local want = HudLayout.quickIcon(i, BAR)
			t.ok(
				picture.x == want.x and picture.y == want.y and picture.w == 16 and picture.h == 16,
				`slot {i}: the picture at HudLayout.quickIcon ({picture.x}, {picture.y})`
			)
			t.ok(cell.box.Visible, `slot {i}: its number box shows`)
			t.eq(cell.digit.Text, tostring(i), `slot {i}: its key`)
			local bx, by, bw, bh = Theme.quickNumber(occupied)
			local box = rectIn(cell.box, cell.base)
			t.ok(box.x == bx and box.y == by and box.w == bw and box.h == bh, `slot {i}: Theme.quickNumber's box`)
			t.ok(drawsOver(cell.box, cell.face), `slot {i}: the number box over the face`)
			t.ok(drawsOver(icon.root, cell.face), `slot {i}: the picture over the face`)
			t.ok(drawsOver(icon.root, cell.base), `slot {i}: the picture over the cell`)
			t.ok(drawsOver(selection, icon.root), `slot {i}: the selection outline over the picture`)
			t.ok(drawsOver(bar.hovers[i], icon.root), `slot {i}: the hover outline over the picture`)
			if occupied then
				t.ok(
					HudLayout.overlaps(rectIn(cell.box, hotbar), picture),
					`slot {i}: the corner box overlaps the picture (so the order shows)`
				)
				t.ok(drawsOver(cell.box, icon.root), `slot {i}: the number box over the picture`)
				t.ok(drawsOver(cell.digit, icon.root), `slot {i}: its digit over the picture`)
			end
		end
	end)

	t.test("quickbar: the old arrangement (pictures beside the bar at z 5) covered the boxes", function()
		local _, hotbar = hud()
		local bar = Quickbar.build(hotbar, BAR, Style.Dayz.scaled())
		local r = HudLayout.quickIcon(1, BAR)
		local old = ItemIconStub.new(hotbar, r.x, r.y, 5, "dayz", nil)
		local box = bar.cells[1].box
		t.ok(not drawsOver(box, old.root), "the box under a picture made beside the bar")
		t.ok(drawsOver(old.root, box), "the picture over the box")
		t.ok(drawsOver(box, bar.icons[1].root), "and over the picture made in its cell")
	end)

	t.test("quickbar: faces and numbers painted for the selection, the items and the scale", function()
		device.touch = false
		local _, hotbar = hud()
		local scaled = Style.Dayz.scaled()
		scaled:setScale(1)
		local bar = Quickbar.build(hotbar, BAR, scaled)
		local w = window()
		bar:render(0, "play", w, 3, false)
		local Colour, Alpha = Style.Dayz.Colour, Style.Dayz.Alpha
		local function faceIs(i: number, state: string): boolean
			local key, transparency = Theme.face(state)
			local face = bar.cells[i].face
			return face.BackgroundColor3 == Colour[key] and math.abs(face.BackgroundTransparency - transparency) < 1e-6
		end
		t.ok(faceIs(3, "selected"), "the selected slot olive")
		t.ok(faceIs(1, "filled") and faceIs(8, "filled"), "occupied slots filled")
		t.ok(faceIs(9, "empty"), "the empty slot empty")
		t.ok(Alpha.QuickCell ~= nil, "the cells' grey")
		-- 6 x 1 = 6 screen pixels of text: too small, no numbers.
		for i = 1, 9 do
			t.ok(not bar.cells[i].box.Visible, `slot {i}: no number at scale 1`)
		end
		-- Scale 2: 12 pixels, the numbers show; the selection moves with the selected slot.
		scaled:setScale(2)
		bar:render(1, "play", w, 5, false)
		for i = 1, 9 do
			t.ok(bar.cells[i].box.Visible, `slot {i}: its number at scale 2`)
		end
		t.ok(faceIs(5, "selected") and faceIs(3, "filled"), "the selection moved to slot 5")
		t.eq(bar.selection.Position.X.Offset, -1 + HudLayout.QUICK_STEP * 4, "the outline over slot 5")
		-- A touch screen has no keys: no numbers.
		device.touch = true
		bar:render(2, "play", w, 5, false)
		for i = 1, 9 do
			t.ok(not bar.cells[i].box.Visible, `slot {i}: no number on touch`)
		end
		device.touch = false
	end)
end
