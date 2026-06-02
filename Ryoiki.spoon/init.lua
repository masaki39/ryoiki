-- Ryoiki.spoon/init.lua
-- Spoon entry point for Ryoiki

-- Resolve the directory containing this file so we can dofile sibling modules
local _spoonDir = (function()
	local info = debug.getinfo(1, "S")
	local src = info.source:match("^@(.+)$") or info.source
	return src:match("^(.+)/[^/]+$") or "."
end)()

local function _require(name)
	return dofile(_spoonDir .. "/" .. name .. ".lua")
end

local parser = _require("parser")
local hotkeys = _require("hotkeys")
local layout = _require("layout")
local chooser = _require("chooser")

-- Spoon object
local obj = {}
obj.__index = obj

obj.name = "Ryoiki"
obj.version = "2.2.3"
obj.author = "masaki39"
obj.license = "MIT"

-- Directory containing *.lua layout files; caller can override before :start()
obj.layouts_dir = hs.configdir .. "/layouts"

-- Internal state
obj._layouts       = {} -- array of parsed layout tables
obj._layoutHotkeys = {} -- hs.hotkey objects for per-layout keybinds (rebuilt on reloadConfig)
obj._spoonHotkeys  = {} -- hs.hotkey objects for spoon-level bindings (showChooser etc.)
obj._chooser       = nil -- chooser instance

obj.centerCursor = false -- move cursor to center of focused window after layout apply

-- Load (or reload) layouts from layouts_dir
function obj:_loadLayouts()
	local ok, result = pcall(parser.loadDir, self.layouts_dir)
	if ok then
		self._layouts = result
	else
		hs.notify.show("Ryoiki", "", "Failed to load layouts: " .. tostring(result))
		self._layouts = {}
	end
end

-- Bind per-layout hotkeys (stored in _layoutHotkeys)
function obj:_bindLayoutHotkeys()
	local bindings = {}
	for _, ld in ipairs(self._layouts) do
		if ld.keybind then
			local name = ld.name
			bindings[#bindings + 1] = {
				combo = ld.keybind,
				fn = function()
					self:applyLayout(name)
				end,
			}
		end
	end
	self._layoutHotkeys = hotkeys.bindAll(bindings)
end

-- Start the spoon: load config, bind hotkeys, create chooser
function obj:start()
	self:_loadLayouts()
	self:_bindLayoutHotkeys()

	local builtins = {
		{ name = "Tile All",            description = "Arrange visible windows in a grid on the cursor screen" },
		{ name = "Maximize All",        description = "Maximize all visible windows" },
		{ name = "Unhide All",          description = "Restore all hidden application windows" },
		{ name = "Save Current Layout", description = "Save current window arrangement as a layout file" },
		{ name = "Delete Layout",       description = "Delete an existing layout file" },
	}

	self._chooser = chooser.new(function()
		return self._layouts
	end, function(name)
		self:applyLayout(name)
	end, builtins)

	return self
end

-- Stop: delete all hotkeys, destroy chooser, cancel pending layout timers
function obj:stop()
	layout.cancelPending()
	hotkeys.deleteAll(self._layoutHotkeys)
	hotkeys.deleteAll(self._spoonHotkeys)
	self._layoutHotkeys = {}
	self._spoonHotkeys  = {}

	if self._chooser then
		self._chooser.destroy()
		self._chooser = nil
	end

	return self
end

-- Bind additional hotkeys — stored in _spoonHotkeys
-- map: { showChooser, tileAll, maximizeAll, unhideAll, saveLayout, deleteLayout } = { mods, key }
function obj:bindHotkeys(map)
	local actions = {
		showChooser  = function() if self._chooser then self._chooser.show() end end,
		tileAll      = function() self:tileAll() end,
		maximizeAll  = function() self:maximizeAll() end,
		unhideAll    = function() self:unhideAll() end,
		saveLayout   = function() self:showSaveChooser() end,
		deleteLayout = function() self:showDeleteChooser() end,
	}
	for action, fn in pairs(actions) do
		if map[action] then
			local mods, key = map[action][1], map[action][2]
			self._spoonHotkeys[#self._spoonHotkeys + 1] = hs.hotkey.bind(mods, key, fn)
		end
	end
	return self
end

-- Apply a layout by name, or a built-in action name
function obj:applyLayout(name)
	if name == "Tile All"            then return self:tileAll() end
	if name == "Maximize All"        then return self:maximizeAll() end
	if name == "Unhide All"          then return self:unhideAll() end
	if name == "Save Current Layout" then return self:showSaveChooser() end
	if name == "Delete Layout"       then return self:showDeleteChooser() end
	for _, ld in ipairs(self._layouts) do
		if ld.name == name then
			layout.apply(ld, { centerCursor = self.centerCursor })
			return
		end
	end
	hs.notify.show("Ryoiki", "", "Layout not found: " .. tostring(name))
end

-- Arrange all visible standard windows on the main screen in a grid
function obj:tileAll()
	local screen = hs.screen.find(hs.mouse.absolutePosition()) or hs.screen.mainScreen()
	local sf = screen:frame()
	local windows = {}
	for _, win in ipairs(hs.window.visibleWindows()) do
		if win:isStandard() and win:screen() == screen then
			windows[#windows + 1] = win
		end
	end
	local n = #windows
	if n == 0 then return self end
	local cols = math.ceil(math.sqrt(n))
	local rows = math.ceil(n / cols)
	local w = sf.w / cols
	local h = sf.h / rows
	for i, win in ipairs(windows) do
		local col = (i - 1) % cols
		local row = math.floor((i - 1) / cols)
		win:setFrame({ x = sf.x + col * w, y = sf.y + row * h, w = w, h = h }, 0)
	end
	return self
end

-- Maximize all visible standard windows
function obj:maximizeAll()
	for _, win in ipairs(hs.window.visibleWindows()) do
		if win:isStandard() then win:maximize(0) end
	end
	return self
end

-- Unhide all running GUI applications
function obj:unhideAll()
	for _, app in ipairs(hs.application.runningApplications()) do
		if app:kind() == 1 then app:unhide() end
	end
	return self
end

-- Resolve symlinks in a directory path
local function resolveDir(dir)
	return hs.fs.pathToAbsolute(dir) or dir
end

-- Escape a string for embedding in a Lua string literal
local function luaEscape(s)
	return s:gsub('\\', '\\\\'):gsub('"', '\\"')
end

-- Save the current window arrangement as a .lua layout file
function obj:saveCurrentLayout(name)
	-- Preserve keybind/description when overwriting an existing layout
	local existingKeybind, existingDescription
	for _, ld in ipairs(self._layouts) do
		if ld.name == name then
			existingKeybind    = ld.keybind
			existingDescription = ld.description
			break
		end
	end

	local lines = { "return {" }
	if existingKeybind    then lines[#lines + 1] = '    keybind = "'     .. luaEscape(existingKeybind)     .. '",' end
	if existingDescription then lines[#lines + 1] = '    description = "' .. luaEscape(existingDescription) .. '",' end
	lines[#lines + 1] = "    windows = {"

	local focusedId = hs.window.focusedWindow() and hs.window.focusedWindow():id()
	for _, win in ipairs(hs.window.visibleWindows()) do
		if win:isStandard() then
			local app = win:application()
			local bundleID = app and app:bundleID()
			if bundleID then
				local scr = win:screen()
				local sf  = scr:frame()
				local f   = win:frame()
				local focusStr = (win:id() == focusedId) and ", focus = true" or ""
				lines[#lines + 1] = string.format(
					'        { app = "%s", screen = "%s", x = %.4f, y = %.4f, w = %.4f, h = %.4f%s },',
					luaEscape(bundleID), luaEscape(scr:name() or "primary"),
					(f.x - sf.x) / sf.w, (f.y - sf.y) / sf.h,
					f.w / sf.w, f.h / sf.h, focusStr
				)
			end
		end
	end
	lines[#lines + 1] = "    },"
	lines[#lines + 1] = "}"

	local dir  = resolveDir(self.layouts_dir)
	local path = dir .. "/" .. name .. ".lua"
	local f    = io.open(path, "w")
	if not f then
		hs.notify.show("Ryoiki", "", "Could not write: " .. path)
		return
	end
	f:write(table.concat(lines, "\n") .. "\n")
	f:close()
	self:reloadConfig()
	hs.notify.show("Ryoiki", "", "Saved: " .. name)
end

-- Delete a layout file by name
function obj:deleteLayout(name)
	local dir  = resolveDir(self.layouts_dir)
	local path = dir .. "/" .. name .. ".lua"
	local ok, err = os.remove(path)
	if ok then
		self:reloadConfig()
		hs.notify.show("Ryoiki", "", "Deleted: " .. name)
	else
		hs.notify.show("Ryoiki", "", "Could not delete: " .. tostring(err))
	end
end

-- Show a chooser to name and save the current layout
function obj:showSaveChooser()
	local navHks  = {}
	local count   = 0
	local c
	c = hs.chooser.new(function(choice)
		chooser.unbindNav(navHks)
		c:delete()
		c = nil
		if choice then self:saveCurrentLayout(choice.name) end
	end)
	c:searchSubText(false)
	c:placeholderText("Layout name…  (^J ↓  ^K ↑)")
	c:queryChangedCallback(function(query)
		local choices = {}
		if query and query ~= "" then
			choices[#choices + 1] = { text = 'Save as "' .. query .. '"', name = query }
		end
		for _, ld in ipairs(self._layouts) do
			choices[#choices + 1] = { text = ld.name .. "  (overwrite)", name = ld.name }
		end
		count = #choices
		c:choices(choices)
	end)
	c:choices({})
	c:show()
	navHks = chooser.bindNav(c, function() return count end)
end

-- Show a chooser to select and delete a layout
function obj:showDeleteChooser()
	local choices = {}
	for _, ld in ipairs(self._layouts) do
		choices[#choices + 1] = { text = ld.name }
	end
	if #choices == 0 then
		hs.notify.show("Ryoiki", "", "No layouts to delete")
		return
	end
	local navHks = {}
	local c
	c = hs.chooser.new(function(choice)
		chooser.unbindNav(navHks)
		c:delete()
		c = nil
		if choice then self:deleteLayout(choice.text) end
	end)
	c:placeholderText("Select layout to delete…  (^J ↓  ^K ↑)")
	c:choices(choices)
	c:show()
	navHks = chooser.bindNav(c, function() return #choices end)
end

-- Reload layouts and rebind layout hotkeys only (spoon hotkeys preserved)
function obj:reloadConfig()
	layout.cancelPending()
	hotkeys.deleteAll(self._layoutHotkeys)
	self._layoutHotkeys = {}
	self:_loadLayouts()
	self:_bindLayoutHotkeys()
	-- Keep chooser alive; it pulls layouts lazily via getLayouts()
end

return obj
