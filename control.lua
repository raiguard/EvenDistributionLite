local bounding_box = require("__flib__/bounding-box")

require("__core__/lualib/util")

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

--- @class ActiveDragData
--- @field entities table<uint, EntityData>
--- @field initial_cursor_count uint
--- @field item_name string
--- @field item_count uint
--- @field last_tick uint
--- @field num_entities integer
--- @field original_group LuaPermissionGroup?
--- @field player LuaPlayer

--- @class EntityData
--- @field entity LuaEntity
--- @field label uint64

script.on_init(function()
	--- @type table<uint, ActiveDragData>
	global.active_drags = {}
end)

script.on_event({ "edl-linked-fast-entity-transfer", "edl-linked-fast-entity-split" }, function(e)
	local player = game.get_player(e.player_index)
	if not player or not player.valid then
		return
	end

	local selected = player.selected
	-- Only do logic if the player doesn't start on an entity
	if selected then
		return
	end

	-- Only do logic if they are holding an item
	local cursor_stack = player.cursor_stack
	if not cursor_stack or not cursor_stack.valid_for_read then
		return
	end

	global.active_drags[e.player_index] = {
		entities = {},
		initial_cursor_count = cursor_stack.count,
		item_count = get_item_count(player, cursor_stack.name),
		item_name = cursor_stack.name,
		last_tick = game.tick,
		num_entities = 0,
		player = player,
	}
end)

script.on_event(defines.events.on_player_fast_transferred, function(e)
	if not e.from_player then
		return
	end

	local data = global.active_drags[e.player_index]
	if not data then
		return
	end

	local player = data.player
	if not player.valid then
		return
	end

	local cursor_stack = player.cursor_stack
	if not cursor_stack then
		return
	end

	local entity = e.entity
	if not entity.valid then
		return
	end

	local new_count = get_item_count(player, data.item_name)
	local inserted = data.item_count - new_count
	if inserted == 0 then
		return
	end

	-- Remove items from the destination and put them back into the player
	entity.remove_item({ name = data.item_name, count = inserted })
	local new_cursor_count = cursor_stack.valid_for_read and cursor_stack.count or 0
	local cursor_delta = data.initial_cursor_count - new_cursor_count
	if cursor_delta > 0 then
		cursor_stack.set_stack({ name = data.item_name, count = data.initial_cursor_count })
	end
	new_count = new_count + cursor_delta
	if new_count < data.item_count then
		player.insert({ name = data.item_name, count = data.item_count - new_count })
	end

	data.last_tick = game.tick

	-- Add entity data if needed
	local entity_data = data.entities[entity.unit_number]
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
			entity = entity,
			label = label,
		}
		data.entities[entity.unit_number] = entity_data

		data.num_entities = data.num_entities + 1
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
	for _, entity_data in pairs(data.entities) do
		rendering.set_text(entity_data.label, math.floor(data.item_count / data.num_entities))
	end
end)

local colors = {
	white = { r = 1, g = 1, b = 1 },
	yellow = { r = 1, g = 1 },
	red = { r = 1 },
}

--- @param player_index uint
--- @param entity LuaEntity
--- @param color Color
--- @param text LocalisedString
local function flying_text(player_index, entity, color, text)
	entity.surface.create_entity({
		name = "flying-text",
		color = color,
		position = entity.position,
		render_player_index = player_index,
		text = text,
	})
end

--- @param data ActiveDragData
local function finish_drag(data)
	-- TODO: Insert all items as best as possible
	local to_insert = math.floor(data.item_count / data.num_entities) --[[@as uint]]
	local item_name = data.item_name
	local item_localised_name = game.item_prototypes[item_name].localised_name
	for _, entity_data in pairs(data.entities) do
		rendering.destroy(entity_data.label)
		local inserted = entity_data.entity.insert({ name = item_name, count = to_insert })
		local color = colors.white
		if inserted == 0 then
			color = colors.red
		elseif inserted < to_insert then
			color = colors.yellow
		end
		flying_text(data.player.index, entity_data.entity, color, { "", "-", inserted, " ", item_localised_name })
		if inserted > 0 then
			data.player.remove_item({ name = item_name, count = inserted })
		end
	end
end

script.on_event(defines.events.on_tick, function()
	for player_index, drag_data in pairs(global.active_drags) do
		if drag_data.last_tick + 60 <= game.tick then
			global.active_drags[player_index] = nil
			finish_drag(drag_data)
		end
	end
end)
