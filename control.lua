local bounding_box = require("__flib__/bounding-box")

--- @class DragState
--- @field entities table<uint, EntityData>
--- @field item_name string
--- @field last_tick uint
--- @field num_entities integer
--- @field player LuaPlayer

--- @class EntityData
--- @field count uint
--- @field entity LuaEntity
--- @field label uint64

--- @class LastSelectedState
--- @field cursor_count uint
--- @field entity LuaEntity
--- @field item_count uint
--- @field item_name string
--- @field tick uint

--- @param player LuaPlayer
--- @param item_name string
--- @return uint
local function get_item_count(player, item_name)
	local count = 0
	local cursor_stack = player.cursor_stack
	if cursor_stack and cursor_stack.valid_for_read and cursor_stack.name == item_name then
		count = count + cursor_stack.count
	end
	local main_inventory = player.get_main_inventory()
	if main_inventory and main_inventory.valid then
		count = count + main_inventory.get_item_count(item_name)
	end
	return count --[[@as uint]]
end

script.on_init(function()
	--- @type table<uint, DragState>
	global.drag = {}
	--- @type table<uint, LastSelectedState>
	global.last_selected = {}
end)

script.on_event(defines.events.on_selected_entity_changed, function(e)
	local player = game.get_player(e.player_index)
	if not player or not player.valid then
		return
	end

	local selected = player.selected
	local cursor_stack = player.cursor_stack
	if not selected or not cursor_stack or not cursor_stack.valid_for_read then
		global.last_selected[e.player_index] = nil
		return
	end

	global.last_selected[e.player_index] = {
		cursor_count = cursor_stack.count,
		entity = selected,
		item_count = get_item_count(player, cursor_stack.name),
		item_name = cursor_stack.name,
		tick = game.tick,
	}
end)

script.on_event(defines.events.on_player_fast_transferred, function(e)
	if not e.from_player then
		return
	end

	local entity = e.entity
	if not entity.valid then
		return
	end

	local selected_state = global.last_selected[e.player_index]
	if not selected_state or selected_state.tick ~= game.tick or selected_state.entity ~= entity then
		return
	end

	local player = game.get_player(e.player_index)
	if not player or not player.valid then
		return
	end

	local cursor_stack = player.cursor_stack
	if not cursor_stack then
		return
	end

	local drag_state = global.drag[e.player_index]
	if not drag_state then
		--- @type DragState
		drag_state = {
			entities = {},
			item_name = selected_state.item_name,
			last_tick = game.tick,
			num_entities = 0,
			player = player,
		}
		global.drag[e.player_index] = drag_state
	end

	local new_count = get_item_count(player, drag_state.item_name)
	local inserted = selected_state.item_count - new_count --[[@as uint]]
	if inserted == 0 then
		return
	end

	-- Remove items from the destination and put them back into the player
	entity.remove_item({ name = drag_state.item_name, count = inserted })
	local new_cursor_count = cursor_stack.valid_for_read and cursor_stack.count or 0
	local cursor_delta = selected_state.cursor_count - new_cursor_count
	if cursor_delta > 0 then
		cursor_stack.set_stack({ name = drag_state.item_name, count = selected_state.cursor_count })
	end
	new_count = new_count + cursor_delta
	if new_count < selected_state.item_count then
		player.insert({ name = drag_state.item_name, count = selected_state.item_count - new_count })
	end

	drag_state.last_tick = game.tick

	-- Add entity data if needed
	local entity_data = drag_state.entities[entity.unit_number]
	if not entity_data then
		local label = rendering.draw_text({
			color = { r = 1, g = 1, b = 1 },
			only_in_alt_mode = true,
			players = { e.player_index },
			surface = entity.surface,
			target = entity,
			text = "",
		})
		entity_data = {
			count = 0,
			entity = entity,
			label = label,
		}
		drag_state.entities[entity.unit_number] = entity_data

		drag_state.num_entities = drag_state.num_entities + 1
	end

	-- Destroy flying text from transfer
	local flying_text = entity.surface.find_entities_filtered({
		name = "flying-text",
		area = bounding_box.recenter_on(entity.prototype.selection_box, entity.position),
	})[1]
	if flying_text then
		flying_text.destroy()
	end

	-- Update all item counts
	local base = math.floor(selected_state.item_count / drag_state.num_entities) --[[@as uint]]
	local remainder = selected_state.item_count % drag_state.num_entities
	for _, entity_data in pairs(drag_state.entities) do
		local count = base
		if remainder > 0 then
			count = count + 1
			remainder = remainder - 1
		end
		entity_data.count = count
		rendering.set_text(entity_data.label, count)
	end
end)

--- @param data DragState
local function finish_drag(data)
	if not data.player.valid then
		return
	end
	local item_name = data.item_name
	local item_localised_name = game.item_prototypes[item_name].localised_name
	for _, entity_data in pairs(data.entities) do
		rendering.destroy(entity_data.label)
		if entity_data.count == 0 then
			goto continue
		end
		local inserted = entity_data.entity.insert({ name = item_name, count = entity_data.count })
		local entity = entity_data.entity
		entity.surface.create_entity({
			name = "flying-text",
			-- Color yellow if inventory limit was reached
			color = inserted == entity_data.count and { r = 1, g = 1, b = 1 } or { r = 1, g = 1 },
			position = entity.position,
			render_player_index = data.player.index,
			text = { "", "-", inserted, " ", item_localised_name },
		})
		if inserted > 0 then
			data.player.remove_item({ name = item_name, count = inserted })
		end
		::continue::
	end
end

script.on_event(defines.events.on_tick, function()
	for player_index, drag_data in pairs(global.drag) do
		if drag_data.last_tick + 60 <= game.tick then
			global.drag[player_index] = nil
			finish_drag(drag_data)
		end
	end
end)
