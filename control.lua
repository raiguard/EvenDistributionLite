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

--- @param inventory LuaInventory
--- @param cursor_stack LuaItemStack
--- @return uint
local function get_item_count(inventory, cursor_stack, name)
  local count = inventory.get_item_count(name)
  if cursor_stack.valid_for_read and cursor_stack.name == name then
    count = count + cursor_stack.count
  end
  return count
end

--- @param inventory LuaInventory
--- @param cursor_stack LuaItemStack
--- @param name string
--- @param count uint
--- @return uint
local function remove_item(inventory, cursor_stack, name, count)
  local removed = 0
  if cursor_stack.valid_for_read and cursor_stack.name == name then
    removed = math.min(cursor_stack.count, count)
    cursor_stack.count = cursor_stack.count - removed
  end
  if removed < count then
    inventory.remove({ name = name, count = count - removed })
  end
  return removed
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
  if
    not selected
    or selected.type == "loader"
    or selected.type == "loader-1x1"
    or not cursor_stack
    or not cursor_stack.valid_for_read
  then
    global.last_selected[e.player_index] = nil
    return
  end
  local main_inventory = player.get_main_inventory()
  if not main_inventory then
    return
  end

  --- @type LastSelectedState
  global.last_selected[e.player_index] = {
    cursor_count = cursor_stack.count,
    entity = selected,
    hand_location = player.hand_location,
    item_count = get_item_count(main_inventory, cursor_stack, cursor_stack.name),
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

  local main_inventory = player.get_main_inventory()
  if not main_inventory then
    return
  end

  -- Get the number of items that were inserted by the fast transfer
  local new_count = get_item_count(main_inventory, cursor_stack, selected_state.item_name)
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
      balance = e.is_split ~= settings.get_player_settings(player)["edl-swap-balance"].value,
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

  validate_entities(drag_state)

  local entities = drag_state.entities
  local labels = drag_state.labels

  if not labels[entity.unit_number] then
    table.insert(entities, entity)
  end

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

  local player = drag_state.player
  local cursor_stack = player.cursor_stack
  if not cursor_stack then
    return
  end
  local main_inventory = player.get_main_inventory()
  if not main_inventory then
    return
  end

  -- Calculate entity deltas
  local counts
  local player_total = get_item_count(main_inventory, cursor_stack, item_name)
  if drag_state.balance then
    counts = get_balanced_distribution(entities, drag_state.item_name, player_total)
  else
    counts = get_even_distribution(player_total, num_entities)
  end

  for i = 1, num_entities do
    local entity = entities[i]
    local to_insert = counts[i]

    -- TODO: Item durability
    -- Insert into or remove from entity
    local delta = 0
    if to_insert > 0 then
      --- @cast to_insert uint
      delta = entity.insert({ name = item_name, count = to_insert })
    elseif to_insert < 0 then
      local count = math.abs(to_insert) --[[@as uint]]
      delta = entity.remove_item({ name = item_name, count = count })
    end

    -- Insert into or remove from player
    if delta > 0 and to_insert > 0 then
      player_total = player_total - remove_item(main_inventory, cursor_stack, item_name, delta)
    elseif delta > 0 then
      player_total = player_total + player.insert({ name = item_name, count = delta })
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
      text = { "", to_insert > 0 and "-" or "+", delta, " ", item_localised_name },
    })
  end
end

script.on_event(defines.events.on_player_cursor_stack_changed, function(e)
  local drag_state = global.drag[e.player_index]
  if not drag_state then
    return
  end

  if not drag_state.player.mod_settings["edl-clear-cursor"].value then
    return
  end

  local cursor_stack = drag_state.player.cursor_stack
  local cursor_item = cursor_stack and cursor_stack.valid_for_read and cursor_stack.name
  if drag_state.item_name == cursor_item then
    return
  end
  
  global.drag[e.player_index] = nil
  finish_drag(drag_state)
end)

script.on_event(defines.events.on_tick, function()
  for player_index, drag_state in pairs(global.drag) do
    local clear_cursor = drag_state.player.mod_settings["edl-clear-cursor"].value
    if not clear_cursor then
      local ticks = drag_state.player.mod_settings["edl-ticks"].value
      if drag_state.last_tick + ticks <= game.tick then
        global.drag[player_index] = nil
        finish_drag(drag_state)
      end
    end
  end
end)
