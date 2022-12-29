data:extend({
	{
		type = "tips-and-tricks-item",
		name = "edl-about",
		category = "game-interaction",
		order = "ga",
		indent = 1,
		dependencies = { "entity-transfers" },
		simulation = {
			save = "__EvenDistributionLite__/simulation-save.zip",
			init_file = "__EvenDistributionLite__/simulation-control.lua",
		},
	},
})
