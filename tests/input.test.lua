local callback, commands, keys = nil, {}, {}
hl = {
  on = function(event, fn) assert(event == "input.keyboard.key"); callback = fn end,
  is_key_down = function(key) return keys[key] == true end,
  exec_cmd = function(command) commands[#commands + 1] = command end,
}
assert(loadfile(arg[1] or "input.lua"))("example.switcher")
local function event(key, state) callback(key, 0, state) end
event(50, 1); event(50, 0)
assert(#commands == 0, "Shift without a held switch modifier must be ignored")
keys.Control_L = true -- keyd normalizes the sided Ctrl here
event(50, 1)
assert(#commands == 1 and commands[1] == "omarchy-shell -q example.switcher shiftPress ctrl")
event(50, 1); event(50, 2)
assert(#commands == 1, "duplicate/repeated press must not send again")
event(50, 0)
assert(#commands == 1, "release must not reverse")
event(50, 1); event(62, 1)
assert(#commands == 3, "each physical Shift has an independent press edge")
event(62, 0); keys.Alt_R = true; event(62, 1)
assert(commands[4]:match("shiftPress ctrl,alt$"), "additional modifiers must be retained")
event(38, 1); event(38, 0)
assert(#commands == 4, "ordinary keys must not be forwarded")
print("Passed raw Shift observer checks (no key injection)")
