local a = require('packer.async')
local config = require('packer.config')
local jobs = require('packer.jobs')
local log = require('packer.log')
local util = require('packer.util')

local async = a.sync

local fmt = string.format

--- @class PluginHandler
local M = {}

--- @type string[]
local job_env = {}

do
  local blocked_env_vars = {
    GIT_DIR = true,
    GIT_INDEX_FILE = true,
    GIT_OBJECT_DIRECTORY = true,
    GIT_TERMINAL_PROMPT = true,
    GIT_WORK_TREE = true,
    GIT_COMMON_DIR = true,
  }

  for k, v in pairs(vim.fn.environ()) do
    if not blocked_env_vars[k] then
      job_env[#job_env + 1] = k .. '=' .. v
    end
  end

  job_env[#job_env + 1] = 'GIT_TERMINAL_PROMPT=0'
end

---@param tag string
---@return boolean
local function has_wildcard(tag)
  return tag and tag:match('*') ~= nil
end

local BREAK_TAG_PAT = '[[bB][rR][eE][aA][kK]!?:]'
local BREAKING_CHANGE_PAT = '[[bB][rR][eE][aA][kK][iI][nN][gG][ _][cC][hH][aA][nN][gG][eE]]'
local TYPE_EXCLAIM_PAT = '[[a-zA-Z]+!:]'
local TYPE_SCOPE_EXPLAIN_PAT = '[[a-zA-Z]+%([^)]+%)!:]'

---@param x string
---@return boolean
local function is_breaking(x)
  return x and (
    x:match(BREAKING_CHANGE_PAT) or
    x:match(BREAK_TAG_PAT) or
    x:match(TYPE_EXCLAIM_PAT) or
    x:match(TYPE_SCOPE_EXPLAIN_PAT)) ~=
    nil
end

---@param commit_bodies string[]
---@return string[]
local function get_breaking_commits(commit_bodies)
  local ret = {} --- @type string[]
  local commits = vim.gsplit(table.concat(commit_bodies, '\n'), '===COMMIT_START===', { plain = true })

  for commit in commits do
    local commit_parts = vim.split(commit, '===BODY_START===')
    local body = commit_parts[2]
    local lines = vim.split(commit_parts[1], '\n')
    if is_breaking(body) or is_breaking(lines[2]) then
      ret[#ret + 1] = lines[1]
    end
  end
  return ret
end

--- @param args string[]
--- @param opts? JobOpts
--- @return boolean, string[]
local function git_run(args, opts)
  opts = opts or {}
  opts.env = opts.env or job_env
  local jr = jobs.run({ config.git.cmd, unpack(args) }, opts)
  local ok = jr.exit_code == 0
  if ok then
    return true, jr.stdout
  end
  return false, jr.stderr
end

--- @type {[1]: integer, [2]: integer, [3]: integer}
local git_version

--- @param version string
--- @return {[1]: integer, [2]: integer, [3]: integer}
local function parse_version(version)
  assert(version:match('%d+%.%d+%.%w+'), 'Invalid git version: ' .. version)
  local parts = vim.split(version, '%.')
  local ret = {} --- @type number[]
  ret[1] = tonumber(parts[1])
  ret[2] = tonumber(parts[2])

  if parts[3] == 'GIT' then
    ret[3] = 0
  else
    ret[3] = tonumber(parts[3])
  end

  return ret
end

local function set_version()
  if git_version then
    return
  end

  local vok, out = git_run({ '--version' })
  if vok then
    local line = out[1]
    local ok, err = pcall(function()
      assert(vim.startswith(line, 'git version'), 'Unexpected output: ' .. line)
      local parts = vim.split(line, '%s+')
      git_version = parse_version(parts[3])
    end)
    if not ok then
      log.error(err)
      return
    end
  end
end

--- @param version {[1]: integer, [2]: integer, [3]: integer}
--- @return boolean
local function check_version(version)
  set_version()

  if not git_version then
    return false
  end

  if git_version[1] < version[1] then
    return false
  end

  if version[2] and git_version[2] < version[2] then
    return false
  end

  if version[3] and git_version[3] < version[3] then
    return false
  end

  return true
end

--- @param ... string
--- @return string?
local function head(...)
  local lines = util.file_lines(util.join_paths(...))
  if lines then
    return lines[1]
  end
end

local SHA_PAT = string.rep('%x', 40)

---@param dir string
---@param ref string
---@return string?
local function resolve_ref(dir, ref)
  if ref:match(SHA_PAT) then
    return ref
  end
  local ptr = ref:match('^ref: (.*)')
  if ptr then
    return head(dir, '.git', unpack(vim.split(ptr, '/')))
  end
end

---@param dir string
---@return string?
local function get_head(dir)
  return resolve_ref(dir, assert(head(dir, '.git', 'HEAD')))
end

---@param dir string
---@return table<string,string>
local function packed_refs(dir)
  local refs = util.join_paths(dir, '.git', 'packed-refs')
  local lines = util.file_lines(refs)
  local ret = {} --- @type table<string,string>
  for _, line in ipairs(lines or {}) do
    local ref, name = line:match("^(.*) refs/(.*)$")
    if ref then
      ret[name] = ref
    end
  end
  return ret
end

---@param dir string
---@param ... string
---@return string
local function ref(dir, ...)
  local x = head(dir, '.git', 'refs', ...)
  if x then
    return x
  end
  local r = table.concat({ ... }, "/")
  return packed_refs(dir)[r]
end

---@param plugin Plugin
---@return string
local function get_current_branch(plugin)
  -- first try local HEAD
  local remote_head = ref(plugin.install_path, 'remotes', 'origin', 'HEAD')
  if remote_head then
    local branch = remote_head:match('^ref: refs/remotes/origin/(.*)')
    if branch then
      return branch
    end
  end

  -- fallback to local HEAD
  local local_head = head(plugin.install_path, '.git', 'HEAD')

  if local_head then
    local branch = local_head:match('^ref: refs/heads/(.*)')
    if branch then
      return branch
    end
  end

  error('Could not get current branch for ' .. plugin.install_path)
end

---@param messages string|string[]
---@return string[]
local function split_messages(messages)
  if type(messages) == "string" then
    messages = { messages }
  end
  local lines = {}
  for _, message in ipairs(messages) do
    vim.list_extend(lines, vim.split(message, '\n'))
    table.insert(lines, '')
  end
  return lines
end

---@param x string
---@return string[]
local function process_progress(x)
  -- Only consider text after the last \r
  local rlines = vim.split(x, '\r')
  local line --- @type string
  if rlines[#rlines] == '' then
    line = rlines[#rlines - 1]
  else
    line = rlines[#rlines]
  end

  local lines = vim.split(line, '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  return lines
end

---@param plugin Plugin
---@return string?, string[]?
local function resolve_tag(plugin)
  local tag = plugin.tag
  local ok, out = git_run({
    'tag', '-l', tag,
    '--sort', '-version:refname',
  }, {
      cwd = plugin.install_path,
    })

  if ok then
    tag = vim.split(out[#out], '\n')[1]
    return tag
  end

  log.fmt_warn(
    'Wildcard expansion did not find any tag for plugin %s: defaulting to latest commit...',
    plugin.name)

  -- Wildcard is not found, then we bypass the tag
  return nil, out
end

--- @param plugin Plugin
--- @param disp? Display
--- @return boolean, string[]
local function checkout(plugin, disp)
  local function update_disp(msg, info)
    if disp then
      disp:task_update(plugin.name, msg, info)
    end
  end

  update_disp('fetching reference...')

  --- @type string?
  local tag = plugin.tag

  -- Resolve tag
  if tag and has_wildcard(tag) then
    update_disp(fmt('getting tag for wildcard %s...', tag))
    local tagerr
    tag, tagerr = resolve_tag(plugin)
    if not tag then
      return false, assert(tagerr)
    end
  end

  local target --- @type string
  local branch --- @type string?
  local checkout_args = {} --- @type string[]

  if plugin.commit then
    target = plugin.commit
  elseif tag then
    --- @type string
    target = 'tags/' .. tag
  else
    branch = plugin.branch or get_current_branch(plugin)
    vim.list_extend(checkout_args, { '-B', branch })
    local remote_target = ref(plugin.install_path, 'remotes', 'origin', branch)
    target = remote_target or ref(plugin.install_path, 'heads', branch)
  end

  assert(target, 'Could not determine target for ' .. plugin.install_path)

  update_disp('checking out...')
  local cmd = vim.list_extend({'checkout', '--progress', target}, checkout_args)
  return git_run(cmd, {
      cwd = plugin.install_path,
      on_stderr = function(chunk)
        update_disp('checking out... ', process_progress(chunk))
      end,
    })
end

--- @param plugin Plugin
--- @param disp Display
--- @return boolean, string[]
local function mark_breaking_changes(plugin, disp)
  disp:task_update(plugin.name, 'checking for breaking changes...')
  local ok, out = git_run({
    'log',
    '--color=never',
    '--no-show-signature',
    '--pretty=format:===COMMIT_START===%h%n%s===BODY_START===%b',
    'HEAD@{1}...HEAD',
  }, {
      cwd = plugin.install_path,
    })
  if ok then
    plugin.breaking_commits = get_breaking_commits(out)
  end
  return ok, out
end

local function clone(plugin, disp, timeout)
  local function task_update(info)
    disp:task_update(plugin.name, 'cloning...', info)
  end

  task_update()

  local clone_cmd = {
    'clone',
    '--no-checkout',
    '--progress',
  }

  -- partial clone support
  if check_version({ 2, 19, 0 }) then
    vim.list_extend(clone_cmd, {
      "--filter=blob:none",
    })
  end

  vim.list_extend(clone_cmd, { plugin.url, plugin.install_path })

  return git_run(clone_cmd, {
    timeout = timeout,
    on_stderr = function(chunk)
      task_update(process_progress(chunk))
    end,
  })
end

--- @param plugin Plugin
--- @param disp Display
--- @return boolean?, string[]
local function install(plugin, disp)
  local ok, out = clone(plugin, disp, config.git.clone_timeout)
  if not ok then
    return nil, out
  end

  ok, out = checkout(plugin, disp)
  if not ok then
    return nil, out
  end

  return true, out
end

--- @param plugin Plugin
--- @param disp Display
--- @return string[]?
M.installer = async(function(plugin, disp)
  local ok, out = install(plugin, disp)

  if ok then
    plugin.messages = out
    return
  end

  plugin.err = out

  return out
end, 2)

--- @param plugin Plugin
--- @param msg string
--- @param x any
local function log_err(plugin, msg, x)
  local x1 = type(x) == "string" and x or table.concat(x, '\n')
  log.fmt_debug('%s: $s: %s', plugin.name, msg, x1)
end

--- @param plugin Plugin
--- @param disp Display
--- @return boolean, string[]?
local function update(plugin, disp)
  disp:task_update(plugin.name, 'checking current commit...')

  plugin.revs[1] = get_head(plugin.install_path)

  local function fetch_update(info)
    disp:task_update(plugin.name, 'fetching updates...', info)
  end

  fetch_update()
  local ok, out = git_run({
    'fetch',
    '--tags',
    '--force',
    '--update-shallow',
    '--progress',
  }, {
      cwd = plugin.install_path,
      on_stderr = function(chunk)
        fetch_update(process_progress(chunk))
      end,
    })
  if not ok then
    return false, out
  end

  disp:task_update(plugin.name, 'pulling updates...')
  ok, out = checkout(plugin, disp)

  if not ok then
    log_err(plugin, 'failed checkout', out)
    return false, out
  end

  plugin.revs[2] = get_head(plugin.install_path)

  if plugin.revs[1] ~= plugin.revs[2] then
    disp:task_update(plugin.name, 'getting commit messages...')
    ok, out = git_run({
      'log',
      '--color=never',
      '--pretty=format:%h %s (%cr)',
      '--no-show-signature',
      fmt('%s...%s', plugin.revs[1], plugin.revs[2]),
    }, {
        cwd = plugin.install_path,
      })

    if not ok then
      log_err(plugin, 'failed getting commit messages', out)
      return false, out
    end

    plugin.messages = out

    ok, out = mark_breaking_changes(plugin, disp)
    if not ok then
      log_err(plugin, 'failed marking breaking changes', out)
      return false, out
    end
  end

  return true
end

--- @param plugin Plugin
--- @param disp Display
--- @return string[]?
M.updater = async(function(plugin, disp)
  local ok, out = update(plugin, disp)
  if not ok then
    plugin.err = out
    return plugin.err
  end
end, 2)

--- @param plugin Plugin
--- @return string?
M.remote_url = async(function(plugin)
  local ok, out = git_run({ 'remote', 'get-url', 'origin' }, {
    cwd = plugin.install_path,
  })

  if ok then
    return out[1]
  end
end, 1)

--- @param plugin Plugin
--- @param commit string
--- @param callback fun(_: string[]?, _: string[]?)
M.diff = async(function(plugin, commit, callback)
  local ok, out = git_run({
    'show', '--no-color',
    '--pretty=medium',
    commit,
  }, {
      cwd = plugin.install_path,
    })

  if ok then
    callback(split_messages(out))
  else
    callback(nil, out)
  end
end, 3)

--- @param plugin Plugin
--- @return string[]?
M.revert_last = async(function(plugin)
  local ok, out = git_run({ 'reset', '--hard', 'HEAD@{1}' }, {
    cwd = plugin.install_path,
  })

  if not ok then
    log.fmt_error('Reverting update for %s failed!', plugin.name)
    return out
  end

  ok, out = checkout(plugin)
  if not ok then
    log.fmt_error('Reverting update for %s failed!', plugin.name)
    return out
  end

  log.fmt_info('Reverted update for %s', plugin.name)
end, 1)

--- Reset the plugin to `commit`
--- @param plugin Plugin
--- @param commit string
--- @return string[]?
M.revert_to = async(function(plugin, commit)
  assert(type(commit) == 'string', fmt("commit: string expected but '%s' provided", type(commit)))
  log.fmt_debug("Reverting '%s' to commit '%s'", plugin.name, commit)
  local ok, out = git_run({ 'reset', '--hard', commit, '--' }, {
    cwd = plugin.install_path,
  })

  if not ok then
    return out
  end
end, 2)

--- Returns HEAD's short hash
--- @param plugin Plugin
--- @return string?
M.get_rev = async(function(plugin)
  return get_head(plugin.install_path)
end, 1)

return M
