--- @class DragState
--- @field balance boolean
--- @field entities LuaEntity[]
--- @field item {name: string, quality: string}
--- @field labels table<uint, LuaRenderObject>
--- @field last_tick uint
--- @field player LuaPlayer

--- @class LastSelectedState
--- @field cursor_count uint
--- @field entity LuaEntity
--- @field hand_location ItemStackLocation
--- @field item ItemStackDefinition
--- @field tick uint

--- @type table<string, Color>
local colors = {
  red = { r = 1 },
  white = { r = 1, g = 1, b = 1 },
  yellow = { r = 1, g = 1 },
}

--- @type table<string, defines.inventory[]>
local fast_transfer_inventories = {
  ["ammo-turret"] = defines.inventory.turret_ammo,
  ["artillery-turret"] = { defines.inventory.artillery_turret_ammo },
  ["artillery-wagon"] = { defines.inventory.artillery_wagon_ammo },
  ["assembling-machine"] = { defines.inventory.assembling_machine_input, defines.inventory.assembling_machine_modules },
  ["beacon"] = { defines.inventory.beacon_modules },
  ["car"] = { defines.inventory.car_trunk, defines.inventory.car_trunk },
  ["cargo-landing-pad"] = { defines.inventory.cargo_landing_pad_main },
  ["cargo-wagon"] = { defines.inventory.cargo_wagon },
  ["character"] = {
    defines.inventory.character_ammo,
    defines.inventory.character_armor,
    defines.inventory.character_guns,
    defines.inventory.character_main,
    defines.inventory.character_vehicle,
  },
  ["container"] = { defines.inventory.chest },
  ["furnace"] = { defines.inventory.furnace_source, defines.inventory.furnace_modules },
  ["lab"] = { defines.inventory.lab_input, defines.inventory.lab_modules },
  ["logistic-container"] = { defines.inventory.chest },
  ["mining-drill"] = { defines.inventory.mining_drill_modules },
  ["roboport"] = { defines.inventory.roboport_material, defines.inventory.roboport_robot },
  ["rocket-silo"] = {
    defines.inventory.rocket_silo_input,
    defines.inventory.rocket_silo_rocket,
    defines.inventory.rocket_silo_modules,
  },
  ["space-platform-hub"] = { defines.inventory.hub_main },
  ["spidertron"] = { defines.inventory.spider_ammo, defines.inventory.spider_trunk },
}

--- @param entity LuaEntity
--- @param item ItemIDAndQualityIDPair
--- @return uint
local function get_entity_item_count(entity, item)
  local total = 0
  local inventories = fast_transfer_inventories[entity.type]
  assert(inventories, "Entity inventories were nil")
  for _, inventory_type in pairs(inventories) do
    local inventory = entity.get_inventory(inventory_type)
    if inventory then
      total = total + inventory.get_item_count(item)
    end
  end
  return total
end

--- @param entities LuaEntity[]
--- @param item ItemIDAndQualityIDPair
--- @param player_total uint
--- @return integer[]
local function get_balanced_distribution(entities, item, player_total)
  local num_entities = #entities

  -- Determine total and individual entity contents
  --- @type uint[]
  local entity_counts = {}
  local total = player_total
  for i = 1, num_entities do
    local count = get_entity_item_count(entities[i], item)
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
--- @param item ItemIDAndQualityIDPair
--- @return uint
local function get_item_count(inventory, cursor_stack, item)
  local count = inventory.get_item_count(item)
  if cursor_stack.valid_for_read and cursor_stack.name == item.name and cursor_stack.quality.name == item.quality then
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
  storage.drag = {}
  --- @type table<uint, LastSelectedState>
  storage.last_selected = {}
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
    storage.last_selected[e.player_index] = nil
    return
  end
  local main_inventory = player.get_main_inventory()
  if not main_inventory then
    return
  end

  --- @type LastSelectedState
  storage.last_selected[e.player_index] = {
    cursor_count = cursor_stack.count,
    entity = selected,
    hand_location = player.hand_location,
    item = {
      name = cursor_stack.name,
      quality = cursor_stack.quality.name,
      count = get_item_count(
        main_inventory,
        cursor_stack,
        { name = cursor_stack.name, quality = cursor_stack.quality.name }
      ),
    },
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

  local selected_state = storage.last_selected[e.player_index]
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
  local new_count = get_item_count(main_inventory, cursor_stack, selected_state.item --[[@as ItemIDAndQualityIDPair]])
  local inserted = selected_state.item.count - new_count
  if inserted > 0 then
    -- Remove items from the destination and restore the player's inventory state
    local spec = { name = selected_state.item.name, quality = selected_state.item.quality, count = inserted }
    entity.remove_item(spec)
    if cursor_stack.valid_for_read then
      player.insert(spec)
    else
      cursor_stack.set_stack(spec)

      player.hand_location = selected_state.hand_location
    end
  elseif
    get_entity_item_count(entity, { name = selected_state.item.name, quality = selected_state.item.quality }) == 0
  then
    -- This item can't be inserted at all
    return
  end

  -- Create or retrieve drag state
  local drag_state = storage.drag[e.player_index]
  if not drag_state then
    --- @type DragState
    drag_state = {
      balance = e.is_split ~= settings.get_player_settings(player)["edl-swap-balance"].value,
      entities = {},
      item = { name = selected_state.item.name, quality = selected_state.item.quality },
      last_tick = game.tick,
      labels = {},
      player = player,
    }
    storage.drag[e.player_index] = drag_state
  end

  drag_state.last_tick = game.tick

  -- Remove game-generated flying text.
  player.clear_local_flying_texts()

  validate_entities(drag_state)

  local entities = drag_state.entities
  local labels = drag_state.labels
  local unit_number = entity.unit_number
  --- @cast unit_number -?

  if not labels[unit_number] then
    table.insert(entities, entity)
  end

  -- Update item counts
  local total = selected_state.item.count
  --- @cast total -?
  if drag_state.balance then
    for i = 1, #entities do
      total = total + get_entity_item_count(entities[i], drag_state.item)
    end
  end
  local counts = get_even_distribution(total, #entities)
  for i = 1, #entities do
    local entity = entities[i]
    local unit_number = entity.unit_number
    --- @cast unit_number -?
    local label = labels[unit_number]
    if not label or not label.valid then
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
      labels[unit_number] = label
    end
    label.text = counts[i]
  end
end)

--- @param drag_state DragState
local function finish_drag(drag_state)
  if not drag_state.player.valid then
    return
  end

  -- Destroy labels
  for _, label in pairs(drag_state.labels) do
    if label.valid then
      label.destroy()
    end
  end

  validate_entities(drag_state)

  local entities = drag_state.entities
  local num_entities = #entities
  local item = drag_state.item
  local item_localised_name = prototypes.item[item.name].localised_name
  if item.quality ~= "normal" then
    item_localised_name = { "", item_localised_name, " (", prototypes.quality[item.quality].localised_name, ")" }
  end

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
  local player_total = get_item_count(main_inventory, cursor_stack, item)
  if drag_state.balance then
    counts = get_balanced_distribution(entities, item, player_total)
  else
    counts = get_even_distribution(player_total, num_entities)
  end

  for i = 1, num_entities do
    local entity = entities[i]
    local to_insert = counts[i]

    -- TODO: Item durability
    -- FIXME: Spoilage!!! Entity info!!! This is trash!!!
    -- Insert into or remove from entity
    local delta = 0
    if to_insert > 0 then
      --- @cast to_insert uint
      delta = entity.insert({ name = item.name, count = to_insert, quality = item.quality })
    elseif to_insert < 0 then
      local count = math.abs(to_insert) --[[@as uint]]
      delta = entity.remove_item({ name = item.name, count = count, quality = item.quality })
    end

    -- Insert into or remove from player
    if delta > 0 and to_insert > 0 then
      player_total = player_total - remove_item(main_inventory, cursor_stack, item.name, delta)
    elseif delta > 0 then
      player_total = player_total + player.insert({ name = item.name, count = delta, quality = item.quality })
    end

    -- Show flying text
    local color = colors.white
    if delta == 0 then
      color = colors.red
    elseif delta ~= math.abs(to_insert) then
      color = colors.yellow
    end
    --- @diagnostic disable-next-line missing-field
    player.create_local_flying_text({
      text = { "", to_insert > 0 and "-" or "+", delta, " [item=", item.name, "] ", item_localised_name },
      position = entity.position,
      color = color,
    })
  end
end

script.on_event(defines.events.on_player_cursor_stack_changed, function(e)
  local drag_state = storage.drag[e.player_index]
  if not drag_state then
    return
  end

  if not drag_state.player.mod_settings["edl-clear-cursor"].value then
    return
  end

  local cursor_stack = drag_state.player.cursor_stack
  local cursor_item = cursor_stack and cursor_stack.valid_for_read and cursor_stack.name
  if drag_state.item.name == cursor_item then
    return
  end

  storage.drag[e.player_index] = nil
  finish_drag(drag_state)
end)

script.on_event(defines.events.on_tick, function()
  for player_index, drag_state in pairs(storage.drag) do
    local clear_cursor = drag_state.player.mod_settings["edl-clear-cursor"].value
    if not clear_cursor then
      local ticks = drag_state.player.mod_settings["edl-ticks"].value
      if drag_state.last_tick + ticks <= game.tick then
        storage.drag[player_index] = nil
        finish_drag(drag_state)
      end
    end
  end
end)
