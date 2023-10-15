data:extend({
  {
    type = "int-setting",
    name = "edl-ticks",
    setting_type = "runtime-per-user",
    default_value = 60,
    minimum_value = 1,
    order = "a"
  },
  {
    type = "bool-setting",
    name = "edl-swap-balance",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "b"
  },
  {
    type = "bool-setting",
    name = "edl-clear-cursor",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "c"
  },
})
