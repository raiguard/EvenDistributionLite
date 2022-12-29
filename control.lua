-- FIXME: This doesn't actually detect control+drag, it just detects control+click at the start

--- @class ActiveDragData
--- @field entities table<uint, EntityData>
--- @field item ItemStackIdentification
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

	local group = game.permissions.create_group("Evenly Distributing")
	if not group then
		error("Unable to create permission group")
	end
	group.set_allows_action(defines.input_action.fast_entity_transfer, false)
	group.set_allows_action(defines.input_action.fast_entity_split, false)
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

	local count = cursor_stack.count
	local main_inventory = player.get_main_inventory()
	if main_inventory and main_inventory.valid then
		count = count + main_inventory.get_item_count(cursor_stack.name)
	end

	if e.input_name == "edl-linked-fast-entity-split" then
		count = math.ceil(count / 2) --[[@as uint]]
	end

	local group = player.permission_group
	if group then
		group.remove_player(player)
	end
	local ed_group = game.permissions.get_group("Evenly Distributing")
	if not ed_group then
		error("Even Distribution permission group was not created")
	end
	ed_group.add_player(player)

	global.active_drags[e.player_index] = {
		entities = {},
		item = { name = cursor_stack.name, count = count },
		last_tick = game.tick,
		num_entities = 0,
		original_group = group,
		player = player,
	}
end)

script.on_event(defines.events.on_selected_entity_changed, function(e)
	local drag_data = global.active_drags[e.player_index]
	if not drag_data then
		return
	end

	local player = drag_data.player
	if not player.valid then
		return -- Will be cleaned up in on_tick
	end

	local entity = player.selected
	if not entity then
		return
	end

	-- Transport belts will incorrectly return true in can_insert
	if entity.type == "transport-belt" or entity.type == "underground-belt" or entity.type == "splitter" then
		return
	end

	if not entity.can_insert(drag_data.item) then
		return
	end

	drag_data.last_tick = game.tick

	local entity_data = drag_data.entities[entity.unit_number]
	if entity_data then
		return
	end

	drag_data.entities[entity.unit_number] = {
		entity = entity,
		label = rendering.draw_text({
			color = { r = 1, g = 1, b = 1 },
			only_in_alt_mode = true,
			players = { e.player_index },
			surface = entity.surface,
			target = entity,
			text = "",
		}),
	}

	local num_entities = drag_data.num_entities + 1
	drag_data.num_entities = num_entities

	for _, entity_data in pairs(drag_data.entities) do
		rendering.set_text(entity_data.label, math.floor(drag_data.item.count / num_entities))
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
	-- Reset permission group
	local player = data.player
	local group = player.permission_group
	if group then
		group.remove_player(player)
	end
	local original_group = data.original_group
	if original_group and original_group.valid then
		original_group.add_player(player)
	end

	-- Insert items
	local to_insert = math.floor(data.item.count / data.num_entities) --[[@as uint]]
	local item_name = data.item.name
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
