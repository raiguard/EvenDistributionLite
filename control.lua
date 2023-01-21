local bounding_box = require("__flib__/bounding-box")

--- @class DragState
--- @field balance boolean
--- @field entities LuaEntity[]
--- @field item_name string
--- @field labels table<uint, uint64>
--- @field last_tick uint
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

--- @param entities LuaEntity[]
--- @param item_name string
--- @param player_total uint
--- @return integer[]
local function get_balanced_distribution(entities, item_name, player_total)
	local num_entities = #entities

	-- Determine total and individual entity contents
	--- @type uint[]
	local entity_counts = {}
	local total = player_total
	for i = 1, num_entities do
		local count = entities[i].get_item_count(item_name)
		entity_counts[i] = count
		total = total + count
	end

	-- Get even distribution and calculate deltas for each entity
	local base = math.floor(total / num_entities)
	local remainder = total % num_entities
	--- @type integer[]
	local out = {}
	for i = 1, num_entities do
		local current_count = entity_counts[i]
		local target_count = base
		if remainder > 0 then
			remainder = remainder - 1
			target_count = target_count + 1
		end
		out[i] = target_count - current_count
	end
	return out
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
		item_count = player.get_item_count(cursor_stack.name),
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
	local new_count = player.get_item_count(selected_state.item_name)
	local inserted = selected_state.item_count - new_count --[[@as uint]]
	if inserted > 0 then
		-- Remove items from the destination and restore the player's inventory state
		local spec = { name = selected_state.item_name, count = inserted }
		entity.remove_item(spec)
		if cursor_stack.valid_for_read then
			player.insert(spec)
		else
			cursor_stack.set_stack(spec)
			player.hand_location = selected_state.hand_location
		end
	elseif entity.get_item_count(selected_state.item_name) == 0 then
		-- This item can't be inserted at all
		return
	else
		-- The base game won't play the sound, so we have to
		player.play_sound({ path = "utility/inventory_move" })
	end

	-- Create or retrieve drag state
	local drag_state = global.drag[e.player_index]
	if not drag_state then
		--- @type DragState
		drag_state = {
			balance = e.is_split,
			entities = {},
			item_name = selected_state.item_name,
			last_tick = game.tick,
			labels = {},
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
	local total = selected_state.item_count
	if drag_state.balance then
		for i = 1, #entities do
			total = total + entities[i].get_item_count(drag_state.item_name)
		end
	end
	local counts = get_even_distribution(total, #entities)
	for i = 1, #entities do
		local entity = entities[i]
		local label = labels[entity.unit_number]
		if not label or not rendering.is_valid(label) then
			local color = colors.white
			if drag_state.balance then
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

	-- Destroy labels
	for _, label in pairs(drag_state.labels) do
		if rendering.is_valid(label) then
			rendering.destroy(label)
		end
	end

	validate_entities(drag_state)

	local entities = drag_state.entities
	local num_entities = #entities
	local item_name = drag_state.item_name
	local item_localised_name = game.item_prototypes[item_name].localised_name

	-- Calculate entity deltas
	local counts
	local player_total = drag_state.player.get_item_count(drag_state.item_name)
	if drag_state.balance then
		counts = get_balanced_distribution(entities, drag_state.item_name, player_total)
	else
		counts = get_even_distribution(player_total, num_entities)
	end

	for i = 1, num_entities do
		local entity = entities[i]
		local to_insert = counts[i]

		-- Insert into or remove from entity
		local delta = 0
		if to_insert > 0 then
			delta = entity.insert({ name = item_name, count = to_insert })
		elseif to_insert < 0 then
			local count = math.abs(to_insert) --[[@as uint]]
			delta = entity.remove_item({ name = item_name, count = count })
		end

		-- Insert into or remove from player
		if delta > 0 and to_insert > 0 then
			player_total = player_total - drag_state.player.remove_item({ name = item_name, count = delta })
		elseif delta > 0 then
			player_total = player_total + drag_state.player.insert({ name = item_name, count = delta })
		end

		-- Show flying text
		local color = colors.white
		if delta == 0 then
			color = colors.red
		elseif delta ~= math.abs(to_insert) then
			color = colors.yellow
		end
		entity.surface.create_entity({
			name = "flying-text",
			color = color,
			position = entity.position,
			render_player_index = drag_state.player.index,
			text = { "", to_insert > 0 and "-" or "+", delta, " ", item_localised_name },
		})
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
