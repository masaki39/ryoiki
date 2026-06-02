-- chooser.lua
-- hs.chooser wrapper for Ryoiki.spoon

local M = {}

-- Create a new chooser instance.
-- getLayouts: function() → array of layout tables (with .name, .keybind, .description)
-- applyFn: function(layoutName)
-- builtins: optional array of { name, description } for built-in actions
function M.new(getLayouts, applyFn, builtins)
    local self = {}
    local chooser = nil
    local currentChoices = {}

    local function buildSubText(lay)
        local parts = {}
        if lay.keybind then parts[#parts + 1] = lay.keybind end
        if lay.description and lay.description ~= "" then parts[#parts + 1] = lay.description end
        return table.concat(parts, " | ")
    end

    local function buildChoices()
        local withKey = {}
        local noKey   = {}
        for _, lay in ipairs(getLayouts()) do
            local choice = {
                text    = lay.name,
                subText = buildSubText(lay),
            }
            if lay.keybind then
                withKey[#withKey + 1] = choice
            else
                noKey[#noKey + 1] = choice
            end
        end
        table.sort(withKey, function(a, b) return a.text < b.text end)
        table.sort(noKey,   function(a, b) return a.text < b.text end)
        local choices = {}
        for _, c in ipairs(withKey) do choices[#choices + 1] = c end
        for _, c in ipairs(noKey)   do choices[#choices + 1] = c end
        if builtins then
            for _, b in ipairs(builtins) do
                choices[#choices + 1] = { text = b.name, subText = b.description or "Built-in action" }
            end
        end
        return choices
    end

    local navHotkeys = {}
    local choiceCount = 0

    local function unbindNav()
        for _, hk in ipairs(navHotkeys) do hk:delete() end
        navHotkeys = {}
    end

    local function bindNav()
        unbindNav()
        local function moveDown()
            local row = chooser:selectedRow()
            chooser:selectedRow(row < choiceCount and row + 1 or 1)
        end
        local function moveUp()
            local row = chooser:selectedRow()
            chooser:selectedRow(row > 1 and row - 1 or choiceCount)
        end
        navHotkeys[1] = hs.hotkey.bind({"ctrl"}, "j", moveDown, nil, moveDown)
        navHotkeys[2] = hs.hotkey.bind({"ctrl"}, "k", moveUp,   nil, moveUp)
    end

    local function onCreate()
        chooser = hs.chooser.new(function(choice)
            unbindNav()
            if choice then
                applyFn(choice.text)
            end
        end)
        chooser:placeholderText("Select layout…  (^J ↓  ^K ↑)")
        chooser:queryChangedCallback(function(query)
            local filtered
            if not query or query == "" then
                filtered = currentChoices
            else
                local lq = query:lower()
                filtered = {}
                for _, c in ipairs(currentChoices) do
                    if (c.text and c.text:lower():find(lq, 1, true)) or
                       (c.subText and c.subText:lower():find(lq, 1, true)) then
                        filtered[#filtered + 1] = c
                    end
                end
            end
            choiceCount = #filtered
            chooser:choices(filtered)
        end)
    end

    function self.show()
        if not chooser then onCreate() end
        currentChoices = buildChoices()
        choiceCount = #currentChoices
        chooser:query("")
        chooser:choices(currentChoices)
        chooser:show()
        bindNav()
    end

    function self.destroy()
        if chooser then
            chooser:delete()
            chooser = nil
        end
    end

    return self
end

-- Bind ctrl+j/k navigation to any hs.chooser instance.
-- getCount: function() → number of current choices
-- Returns a table of hotkey objects; pass to unbindNav when done.
function M.bindNav(c, getCount)
    local hks = {}
    local function moveDown()
        local row = c:selectedRow()
        c:selectedRow(row < getCount() and row + 1 or 1)
    end
    local function moveUp()
        local row = c:selectedRow()
        c:selectedRow(row > 1 and row - 1 or getCount())
    end
    hks[1] = hs.hotkey.bind({"ctrl"}, "j", moveDown, nil, moveDown)
    hks[2] = hs.hotkey.bind({"ctrl"}, "k", moveUp,   nil, moveUp)
    return hks
end

function M.unbindNav(hks)
    for _, hk in ipairs(hks) do hk:delete() end
end

return M
