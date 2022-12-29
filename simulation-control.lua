--- @type LuaPlayer
local player = game.create_test_player({ name = "big k" }) --- @diagnostic disable-line
player.teleport({ 0, 4 })

game.camera_player = player
game.camera_player_cursor_position = player.position
game.camera_alt_info = true

local path = {
	{
		on_started = function()
			game.camera_player_cursor_position = { 0, 4 }
			player.clear_cursor()
		end,
		wait_time = 30,
	},
	{
		on_started = function()
			player.character.cursor_stack.set_stack({ name = "copper-plate", count = 100 })
		end,
		wait_time = 30,
	},
	{
		target = { -7, -1 },
		wait_time = 30,
	},
	{
		target = { 7, -1 },
		wait_time = 120,
	},
	{
		target = { 0, 4 },
	},
}

local step = 1
local started = false
local wait_until_tick = 0

script.on_event(defines.events.on_tick, function()
	if wait_until_tick > game.tick then
		return
	end
	local data = path[step]
	if not data then
		step = 1
		started = false
		return
	end
	if not started and data.on_started then
		started = true
		data.on_started()
	end
	local finished = true
	if data.target then
		finished = game.move_cursor({ position = data.target, speed = data.speed }) --- @diagnostic disable-line
		if data.on_moved then
			data.on_moved()
		end
	end
	if not finished then
		return
	end
	step = step + 1
	started = false
	if data.on_finished then
		data.on_finished()
	end
	if data.wait_time then
		wait_until_tick = game.tick + data.wait_time
	end
end)
