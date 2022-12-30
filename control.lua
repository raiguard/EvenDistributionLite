local bounding_box = require("__flib__/bounding-box")

--- @class DragState
--- @field entities LuaEntity[]
--- @field item_name string
--- @field labels table<uint, uint64>
--- @field last_tick uint
--- @field mode DistributionMode
--- @field player LuaPlayer

--- @class LastSelectedState
--- @field cursor_count uint
--- @field entity LuaEntity
--- @field hand_location ItemStackLocation
--- @field item_count uint
--- @field item_name string
--- @field tick uint

--- @type table<string, Color>
local colors = {
	red = { r = 1 },
	white = { r = 1, g = 1, b = 1 },
	yellow = { r = 1, g = 1 },
}

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

--- @param total uint
--- @param num_entities integer
--- @return uint[]
local function get_even_distribution(total, num_entities)
	local base = math.floor(total / num_entities)
	local remainder = total % num_entities
	--- @type uint[]
	local out = {}
	for i = 1, num_entities do
		local count = base
		if remainder > 0 then
			remainder = remainder - 1
			count = count + 1
		end
		out[i] = count --[[@as uint]]
	end
	return out
end

--- @param drag_state DragState
local function validate_entities(drag_state)
	local entities = {}
	local i = 0
	for _, entity in pairs(drag_state.entities) do
		if entity.valid then
			i = i + 1
			entities[i] = entity
		end
	end
	drag_state.entities = entities
end

--- @enum DistributionMode
local distribution_mode = {
	balance = 1,
	even = 2,
}

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

	--- @type LastSelectedState
	global.last_selected[e.player_index] = {
		cursor_count = cursor_stack.count,
		entity = selected,
		hand_location = player.hand_location,
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
	if
		not selected_state
		or selected_state.tick ~= game.tick
		or not selected_state.entity.valid
		or selected_state.entity ~= entity
	then
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

	-- Get the number of items that were inserted by the fast transfer
	local new_count = get_item_count(player, selected_state.item_name)
	local inserted = selected_state.item_count - new_count --[[@as uint]]
	if inserted == 0 then
		return
	end

	-- Remove items from the destination and restore the player's inventory state
	local spec = { name = selected_state.item_name, count = inserted }
	entity.remove_item(spec)
	if cursor_stack.valid_for_read then
		player.insert(spec)
	else
		cursor_stack.set_stack(spec)
		player.hand_location = selected_state.hand_location
	end

	-- Create or retrieve drag state
	local drag_state = global.drag[e.player_index]
	if not drag_state then
		local mode = distribution_mode.even
		if e.is_split then
			mode = distribution_mode.balance
		end
		--- @type DragState
		drag_state = {
			entities = {},
			item_name = selected_state.item_name,
			last_tick = game.tick,
			labels = {},
			mode = mode,
			player = player,
		}
		global.drag[e.player_index] = drag_state
	end

	drag_state.last_tick = game.tick

	-- Destroy flying text from transfer
	local flying_text = entity.surface.find_entities_filtered({
		name = "flying-text",
		area = bounding_box.recenter_on(entity.prototype.selection_box, entity.position),
	})[1]
	if flying_text then
		flying_text.destroy()
	end

	local entities = drag_state.entities
	local labels = drag_state.labels

	-- Add entity if needed
	if not labels[entity.unit_number] then
		table.insert(entities, entity)
	end

	-- Remove invalid entities
	validate_entities(drag_state)

	-- Update item counts
	local counts = get_even_distribution(selected_state.item_count, #entities)
	for i = 1, #entities do
		local entity = entities[i]
		local label = labels[entity.unit_number]
		if not label or not rendering.is_valid(label) then
			local color = colors.white
			if drag_state.mode == distribution_mode.balance then
				color = colors.yellow
			end
			label = rendering.draw_text({
				color = color,
				players = { e.player_index },
				surface = entity.surface,
				target = entity,
				text = "",
			})
			labels[entity.unit_number] = label
		end
		rendering.set_text(label, counts[i])
	end
end)

--- @param drag_state DragState
local function finish_drag(drag_state)
	if not drag_state.player.valid then
		return
	end

	for _, label in pairs(drag_state.labels) do
		if rendering.is_valid(label) then
			rendering.destroy(label)
		end
	end

	validate_entities(drag_state)

	local entities = drag_state.entities
	local num_entities = #entities
	local total = get_item_count(drag_state.player, drag_state.item_name)
	local counts = get_even_distribution(total, num_entities)
	local item_name = drag_state.item_name
	local item_localised_name = game.item_prototypes[item_name].localised_name
	for i = 1, num_entities do
		local entity = entities[i]
		local to_insert = counts[i]

		-- Insert into entity, remove from player
		local inserted = entity.insert({ name = item_name, count = to_insert })
		if inserted == 0 then
			goto continue
		end
		drag_state.player.remove_item({ name = item_name, count = inserted })

		-- Show flying text
		local color = colors.white
		if inserted == 0 then
			color = colors.red
		elseif inserted < to_insert then
			color = colors.yellow
		end
		entity.surface.create_entity({
			name = "flying-text",
			color = color,
			position = entity.position,
			render_player_index = drag_state.player.index,
			text = { "", -inserted, " ", item_localised_name },
		})

		::continue::
	end
end

script.on_event(defines.events.on_tick, function()
	for player_index, drag_state in pairs(global.drag) do
		if drag_state.last_tick + 60 <= game.tick then
			global.drag[player_index] = nil
			finish_drag(drag_state)
		end
	end
end)
