-- Modifier observation for the switcher. No keys are grabbed or remapped.
-- The popup alone decides whether a press should reverse its selection.
local pluginId = ... -- Pass the manifest ID when loading this file (see README).
assert(type(pluginId) == "string" and pluginId:match("^[%w][%w._-]*$"), "Invalid plugin ID")
local down = {}
hl.on("input.keyboard.key", function(keycode, _, state)
  if keycode ~= 50 and keycode ~= 62 then return end -- XKB left/right Shift
  if state == 0 then down[keycode] = nil; return end
  if state ~= 1 or down[keycode] then return end
  down[keycode] = true

  local held = {}
  for _, pair in ipairs({ { "Control", "ctrl" }, { "Alt", "alt" }, { "Super", "super" } }) do
    if hl.is_key_down(pair[1] .. "_L") or hl.is_key_down(pair[1] .. "_R") then
      held[#held + 1] = pair[2]
    end
  end
  if #held > 0 then
    -- Quiet IPC is a no-op while the plugin is disabled or its popup is closed.
    hl.exec_cmd("omarchy-shell -q " .. pluginId .. " shiftPress " .. table.concat(held, ","))
  end
end)
