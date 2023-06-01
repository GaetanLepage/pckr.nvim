--- @class PluginHandler
--- @field installer   fun(plugin: Plugin, display: Display): string[]?
--- @field updater     fun(plugin: Plugin, display: Display): string[]?
--- @field revert_last fun(plugin: Plugin): string[]?
--- @field revert_to   fun(plugin: Plugin, commit: string): string[]?
--- @field diff        fun(plugin: Plugin, commit: string, callback: function)
--- @field get_rev     fun(plugin: Plugin): string?

--- @type table<string,PluginHandler>
local plugin_types = {}

return setmetatable(plugin_types, {
  __index = function(_, k)
    if k == 'git' then
      return require('pckr.plugin_types.git')
    elseif k == 'local' then
      return require('pckr.plugin_types.local')
    end
  end,
})
