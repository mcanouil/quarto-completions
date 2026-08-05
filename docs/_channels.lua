--- @module channels
--- @license MIT
--- @copyright 2026 Mickaël Canouil
--- @author Mickaël Canouil
---
--- The `{{< channels >}}` shortcode: a table of every published channel, read
--- from `completions/` at render time so a channel added by the generation
--- workflow appears on the site without touching the prose.
---
--- The directory is resolved against the page the shortcode is written on, and
--- the links are relative to it, so the shortcode belongs on a page sitting
--- beside `completions/`. Anywhere else it fails on the directory it cannot
--- find rather than emitting links that go nowhere.

--- @type string Directory holding one subdirectory per channel.
local CHANNELS_DIRECTORY = 'completions'

--- @type table<string, integer> Rank of each channel that is not a Quarto minor.
local CHANNEL_RANK = { ['release'] = 1, ['pre-release'] = 2, ['dev'] = 3 }

--- @type integer Rank shared by the Quarto minors, which sort among themselves.
local VERSION_RANK = 4

--- @type table<string, integer> Rank of each file, ahead of anything unrecognised.
local FILE_RANK = {
  ['_quarto'] = 1,
  ['quarto.bash'] = 2,
  ['quarto.fish'] = 3,
  ['quarto.ps1'] = 4,
  ['spec.json'] = 5,
  ['manifest.json'] = 6,
}

--- @type string[] Manifest fields the table is built from.
local REQUIRED_FIELDS = { 'quartoVersion', 'generated' }

--- Stops the render, naming what could not be read.
--- @param format string
--- @param ... any
local function fail(format, ...)
  error(string.format('channels: ' .. format, ...), 0)
end

--- Names in a directory, or a failure naming the directory that could not be read.
--- @param path string
--- @return string[]
local function list_directory(path)
  local ok, entries = pcall(pandoc.system.list_directory, path)
  if not ok then
    fail('cannot read %s: %s', path, tostring(entries))
  end
  return entries
end

--- The major and minor of a version channel, or nil for anything else.
--- @param channel string
--- @return integer|nil major
--- @return integer|nil minor
local function version_parts(channel)
  local major, minor = channel:match('^(%d+)%.(%d+)$')
  if major == nil then
    return nil, nil
  end
  return tonumber(major), tonumber(minor)
end

--- Channel directories, newest first: release, pre-release, dev, then each
--- Quarto minor descending. An unrecognised directory stops the render rather
--- than dropping out of the table unnoticed.
--- @param directory string
--- @return string[]
local function channels(directory)
  local names = list_directory(directory)
  for _, name in ipairs(names) do
    if CHANNEL_RANK[name] == nil and version_parts(name) == nil then
      fail(
        "'%s' in %s is neither release, pre-release, dev, nor a Quarto minor such as '1.9'",
        name,
        directory
      )
    end
  end
  table.sort(names, function(left, right)
    local left_rank = CHANNEL_RANK[left] or VERSION_RANK
    local right_rank = CHANNEL_RANK[right] or VERSION_RANK
    if left_rank ~= right_rank then
      return left_rank < right_rank
    end
    if left_rank ~= VERSION_RANK then
      return false
    end
    local left_major, left_minor = version_parts(left)
    local right_major, right_minor = version_parts(right)
    if left_major ~= right_major then
      return left_major > right_major
    end
    return left_minor > right_minor
  end)
  return names
end

--- Files of a channel, in `FILE_RANK` and then alphabetically, so a file the
--- generator gains is listed without editing that table.
--- @param directory string
--- @return string[]
local function files(directory)
  local names = list_directory(directory)
  table.sort(names, function(left, right)
    local left_rank = FILE_RANK[left] or math.huge
    local right_rank = FILE_RANK[right] or math.huge
    if left_rank ~= right_rank then
      return left_rank < right_rank
    end
    return left < right
  end)
  return names
end

--- The manifest of a channel, or a failure naming the file that is missing,
--- unreadable, or short of the two fields the table is built from.
--- @param directory string
--- @return table
local function manifest(directory)
  local path = pandoc.path.join({ directory, 'manifest.json' })
  local handle = io.open(path, 'r')
  if handle == nil then
    fail('cannot read %s', path)
  end
  local contents = handle:read('a')
  handle:close()
  local ok, decoded = pcall(quarto.json.decode, contents)
  if not ok or type(decoded) ~= 'table' then
    fail('cannot decode %s as JSON', path)
  end
  for _, field in ipairs(REQUIRED_FIELDS) do
    if type(decoded[field]) ~= 'string' then
      fail("%s has no '%s'", path, field)
    end
  end
  return decoded
end

--- One row of the table: the channel, the Quarto it was generated from, the
--- date it was generated, and a link to each of its files.
--- @param channel string
--- @param root string Directory the page and `completions/` both sit in.
--- @return string
local function row(channel, root)
  local directory = pandoc.path.join({ root, CHANNELS_DIRECTORY, channel })
  local metadata = manifest(directory)
  local links = {}
  for _, name in ipairs(files(directory)) do
    table.insert(links, string.format('[`%s`](%s/%s/%s)', name, CHANNELS_DIRECTORY, channel, name))
  end
  return string.format(
    '| `%s` | %s | %s | %s |',
    channel,
    metadata['quartoVersion'],
    metadata['generated'],
    table.concat(links, ', ')
  )
end

--- @param _args table
--- @param _kwargs table
--- @param _meta table
--- @return pandoc.Blocks
local function channels_shortcode(_args, _kwargs, _meta)
  local root = pandoc.path.directory(quarto.doc.input_file)
  local lines = {
    '| Channel | Quarto | Generated | Files |',
    '| --- | --- | --- | --- |',
  }
  for _, channel in ipairs(channels(pandoc.path.join({ root, CHANNELS_DIRECTORY }))) do
    table.insert(lines, row(channel, root))
  end
  return quarto.utils.string_to_blocks(table.concat(lines, '\n'))
end

return {
  ['channels'] = channels_shortcode,
}
