-- maki-files: dockable right-side file tree (file manager pane).
-- https://github.com/ehalil2004/maki-files
-- MIT licensed.
--
-- The pane never takes keyboard focus, so typing in the chat input keeps
-- working while it is open. Navigation uses Alt-prefixed keys, the same
-- approach as other side panes; clicks work too.
--
-- Toggle with Alt-E or /files.
-- Keys: Alt-j/Alt-k move, Alt-l expand or open, Alt-h collapse or go to the
-- parent, Alt-a new file, Alt-n new directory, Alt-r rename, Alt-d delete,
-- Alt-s hidden files, Alt-u refresh, Alt-i this list.

local M = {
  width = 40,
  toggle_key = "<M-e>",
  show_hidden = false,
}
local FOOTER = { { "Alt-j/k", "move" }, { "Alt-l", "open" }, { "Alt-d", "del" } }

-- Every key the pane answers while it is on screen. Claimed on the window, so
-- the chat input keeps the plain letters, Alt+Left/Right (word motion),
-- Alt+Enter (newline), Alt+O (edit input) and Alt+T (thinking).
local NAV_KEYS = {
  "<M-j>",
  "<M-k>",
  "<M-Up>",
  "<M-Down>",
  "<M-l>",
  "<M-h>",
  "<M-a>",
  "<M-n>",
  "<M-r>",
  "<M-d>",
  "<M-s>",
  "<M-u>",
  "<M-i>",
}

local DIR_CLOSED = "▸"
local DIR_OPEN = "▾"
local FILE_ICON = "·"
local ELLIPSIS = "..."
-- A directory with more entries than this is cut, so expanding a
-- node_modules cannot build a 40k line buffer.
local MAX_ENTRIES = 2000

-- Single-width glyphs only: a double-width icon shifts the border.
local ICONS = {
  lua = "◇",
  luau = "◇",
  py = "◈",
  rs = "◆",
  js = "◉",
  ts = "◉",
  json = "{}",
  md = "≡",
  markdown = "≡",
  toml = "▫",
  yaml = "▫",
  yml = "▫",
  sh = "❯",
  bash = "❯",
  zsh = "❯",
  ps1 = "❯",
  go = "●",
  c = "▪",
  h = "▪",
  cpp = "▪",
  hpp = "▪",
  cs = "▪",
  java = "▪",
  kt = "▪",
  swift = "▪",
  html = "◫",
  css = "◫",
  scss = "◫",
  vue = "◫",
  svelte = "◫",
  txt = "·",
  lock = "▤",
  png = "▣",
  jpg = "▣",
  jpeg = "▣",
  gif = "▣",
  svg = "▣",
  webp = "▣",
  ico = "▣",
  pdf = "▤",
  zip = "▤",
  gitignore = "▤",
}

local pane

local function clip(text, width)
  if width <= 0 then
    return ""
  end
  if maki.ui.display_width(text) <= width then
    return text
  end
  if width <= #ELLIPSIS then
    return maki.ui.truncate_text(text, width).head
  end
  return maki.ui.truncate_text(text, width - #ELLIPSIS).head .. ELLIPSIS
end

local function ext_of(name)
  return name:match("%.([%w_%-]+)$")
end

local function is_dot(name)
  return name:sub(1, 1) == "."
end

local function icon_for(name)
  local ext = ext_of(name)
  return (ext and ICONS[ext:lower()]) or FILE_ICON
end

local function flash(msg)
  maki.ui.flash(msg)
end

local function failed(msg)
  if maki.toast and maki.toast.show then
    maki.toast.show(msg, { title = "files", timeout_secs = 6 })
  else
    maki.ui.flash(msg)
  end
end

local function basename_title(root)
  local name = maki.fs.basename(root)
  return " " .. (name ~= "" and name or root) .. " "
end

-- "<M-e>" -> "Alt-E", for the hints a user reads.
local function human_key(notation)
  local out = notation:gsub("^<", ""):gsub(">$", "")
  out = out:gsub("C%-", "Ctrl-"):gsub("M%-", "Alt-"):gsub("S%-", "Shift-")
  return (out:gsub("^(%a+%-)(%l)$", function(prefix, letter)
    return prefix .. string.upper(letter)
  end))
end

-- Directory loading ---------------------------------------------------------

local function load_dir(p, dir)
  local entries, err = maki.fs.dir(dir)
  if not entries then
    p.cache[dir] = false
    return nil, err
  end
  local list = {}
  for _, e in ipairs(entries) do
    local name, kind = e[1], e[2]
    if p.show_hidden or not is_dot(name) then
      local path = maki.fs.joinpath(dir, name)
      local is_dir = kind == "directory"
      if kind == "link" then
        local meta = maki.fs.metadata(path)
        is_dir = meta ~= nil and meta.is_dir == true
      end
      list[#list + 1] = { name = name, path = path, is_dir = is_dir }
    end
  end
  table.sort(list, function(a, b)
    if a.is_dir ~= b.is_dir then
      return a.is_dir
    end
    local an, bn = a.name:lower(), b.name:lower()
    if an == bn then
      return a.name < b.name
    end
    return an < bn
  end)
  if #list > MAX_ENTRIES then
    local more = #list - MAX_ENTRIES
    for i = #list, MAX_ENTRIES + 1, -1 do
      list[i] = nil
    end
    list[#list + 1] = { name = string.format("... %d more", more), more = true }
  end
  p.cache[dir] = list
  return list
end

local function entries_of(p, dir)
  local list = p.cache[dir]
  if list ~= nil then
    return list or nil
  end
  return load_dir(p, dir)
end

local function flatten(p)
  local nodes = {}
  local function walk(dir, depth)
    local list = entries_of(p, dir)
    if not list then
      return
    end
    for _, e in ipairs(list) do
      nodes[#nodes + 1] = {
        name = e.name,
        path = e.path,
        depth = depth,
        is_dir = e.is_dir,
        more = e.more,
      }
      if e.is_dir and p.expanded[e.path] then
        walk(e.path, depth + 1)
      end
    end
  end
  walk(p.root, 0)
  p.nodes = nodes
  if p.sel > #nodes then
    p.sel = math.max(1, #nodes)
  end
end

local function select_path(p, path)
  for i, n in ipairs(p.nodes) do
    if n.path == path then
      p.sel = i
      return
    end
  end
end

-- Rendering ----------------------------------------------------------------

local function render(p)
  local inner = math.max(8, p.width - 2)
  local lines = {}

  if #p.nodes == 0 then
    lines[#lines + 1] = { { "  (empty)", "dim" } }
  else
    for _, n in ipairs(p.nodes) do
      local depth = n.depth
      local pad = string.rep("  ", depth)
      -- Keep the name column readable when the tree nests deeper than the pane.
      local max_pad = math.max(0, math.floor((inner - 6) / 2))
      if depth > max_pad then
        pad = string.rep("  ", max_pad)
      end
      if n.more then
        lines[#lines + 1] = { { clip(pad .. n.name, inner), "dim" } }
      else
        local mark = n.is_dir and (p.expanded[n.path] and DIR_OPEN or DIR_CLOSED) or icon_for(n.name)
        local prefix = pad .. mark .. " "
        local avail = inner - maki.ui.display_width(prefix)
        local name = clip(n.name, math.max(1, avail))
        local name_span
        if n.is_dir then
          name_span = { name, { bold = true } }
        elseif is_dot(n.name) then
          name_span = { name, "dim" }
        else
          name_span = { name }
        end
        lines[#lines + 1] = { { prefix, n.is_dir and "path" or "dim" }, name_span }
      end
    end
  end

  p.buf:set_lines(lines)
  p.win:set_cursor(p.sel)
end

-- Writes -------------------------------------------------------------------

local function can_write()
  local plan = maki.plan
  if not plan or not plan.read then
    return true
  end
  local ok, snapshot = pcall(plan.read)
  if ok and snapshot and snapshot.mode == "plan" then
    flash("files: plan mode, file changes are disabled")
    return false
  end
  return true
end

local function valid_name(name)
  if name == "" then
    return false, "empty name"
  end
  if name:find("[/\\]") then
    return false, "name must not contain a separator"
  end
  if name == "." or name == ".." then
    return false, "invalid name"
  end
  return true
end

local function target_dir(p)
  local node = p.nodes[p.sel]
  if not node or node.more then
    return p.root
  end
  if node.is_dir then
    return node.path
  end
  return maki.fs.dirname(node.path)
end

local function refresh_dir(p, dir)
  if dir then
    p.cache[dir] = nil
  end
  flatten(p)
  render(p)
end

-- Text entry ---------------------------------------------------------------
--
-- The pane holds no focus, so typing has to happen in a focused float. It
-- closes on submit and the keyboard lands back in the chat input.

local function drop_char(text)
  if text == "" then
    return text
  end
  local ok, off = pcall(function()
    return utf8.offset(text, -1)
  end)
  if ok and off and off > 1 then
    return text:sub(1, off - 1)
  end
  return text:sub(1, -2)
end

-- Returns the typed line, "y" for a confirmed instant question, or nil when
-- the user cancels.
local function ask(label, initial, instant)
  local buf = maki.ui.buf({ scratch = true })
  local win = maki.ui.open_win(buf, {
    title = " files ",
    width = "52%",
    height = 3,
    border = "rounded",
    zindex = 80,
  })
  local text = initial or ""
  local function draw()
    local line = label .. text
    if not instant then
      line = line .. "▏"
    end
    buf:set_lines({ { { line, "bold" } } })
  end
  draw()

  local answer
  while true do
    local ev = win:recv()
    if not ev or ev.type == "close" then
      break
    end
    if ev.type == "paste" then
      if not instant then
        text = text .. ev.text:gsub("%c", "")
        draw()
      end
    elseif ev.type == "key" then
      local k = ev.key
      if instant then
        if k == "y" or k == "Y" then
          answer = "y"
          break
        elseif k == "n" or k == "N" or k == "<Esc>" then
          break
        end
      elseif k == "<CR>" then
        answer = text
        break
      elseif k == "<Esc>" then
        break
      elseif k == "<BS>" or k == "<Del>" then
        text = drop_char(text)
        draw()
      elseif k == "<C-u>" then
        text = ""
        draw()
      elseif k == "<Space>" then
        text = text .. " "
        draw()
      elseif #k == 1 then
        text = text .. k
        draw()
      end
    end
  end

  win:close()
  return answer
end

-- Actions ------------------------------------------------------------------

local function expand(p, node)
  if not node.is_dir then
    return
  end
  if p.cache[node.path] == nil then
    local list, err = load_dir(p, node.path)
    if not list then
      failed("files: " .. tostring(err))
      return
    end
  end
  p.expanded[node.path] = true
  local path = node.path
  flatten(p)
  select_path(p, path)
  render(p)
end

local function collapse(p, node)
  if p.expanded[node.path] then
    p.expanded[node.path] = nil
    local path = node.path
    flatten(p)
    select_path(p, path)
    render(p)
    return
  end
  local parent = maki.fs.dirname(node.path)
  if parent and parent ~= node.path then
    select_path(p, parent)
    render(p)
  end
end

local function open_file(node)
  local code = maki.ui.open_editor(node.path)
  if code ~= 0 then
    flash("files: editor exited with " .. tostring(code))
  end
end

local function create(p, kind)
  local dir = target_dir(p)
  local name = ask(kind == "mkdir" and "New dir: " or "New file: ")
  if not name then
    return
  end
  local ok, why = valid_name(name)
  if not ok then
    failed("files: " .. why)
    return
  end
  if not can_write() then
    return
  end
  local path = maki.fs.joinpath(dir, name)
  local done, err
  if kind == "mkdir" then
    done, err = maki.fs.mkdir(path)
  else
    done, err = maki.fs.write(path, "")
  end
  if not done then
    failed("files: " .. tostring(err))
    return
  end
  p.expanded[dir] = true
  refresh_dir(p, dir)
  select_path(p, path)
  render(p)
end

local function rename_node(p, node)
  local name = ask("Rename: ", node.name)
  if not name or name == node.name then
    return
  end
  local ok, why = valid_name(name)
  if not ok then
    failed("files: " .. why)
    return
  end
  if not can_write() then
    return
  end
  local dest = maki.fs.joinpath(maki.fs.dirname(node.path), name)
  local moved, err = maki.fs.rename(node.path, dest)
  if not moved then
    failed("files: " .. tostring(err))
    return
  end
  refresh_dir(p, maki.fs.dirname(node.path))
  select_path(p, dest)
  render(p)
end

local function delete_node(p, node)
  if node.path == p.root then
    failed("files: refusing to delete the workspace root")
    return
  end
  local what = node.is_dir and "directory " or "file "
  local answer = ask("Delete " .. what .. node.name .. "? [y/N] ", nil, true)
  if answer ~= "y" then
    return
  end
  if not can_write() then
    return
  end
  local ok, err = maki.fs.rm(node.path, { recursive = node.is_dir })
  if not ok then
    failed("files: " .. tostring(err))
    return
  end
  refresh_dir(p, maki.fs.dirname(node.path))
  flash("files: deleted " .. node.name)
end

-- Keys ---------------------------------------------------------------------

local function show_help()
  local close_key = human_key(M.toggle_key)
  local help = table.concat({
    "Alt-j/Alt-k move   Alt-l expand or open   Alt-h collapse/parent",
    "Alt-a new file   Alt-n new dir   Alt-r rename   Alt-d delete",
    "Alt-s hidden   Alt-u refresh   " .. close_key .. " close",
  }, "\n")
  if maki.toast and maki.toast.show then
    maki.toast.show(help, { title = "files", timeout_secs = 8 })
  else
    flash("files: Alt-j/k move, Alt-l open, Alt-a new, Alt-d del, " .. close_key .. " close")
  end
end

local function handle_key(p, key)
  if key == "<M-j>" or key == "<M-Down>" then
    if #p.nodes > 0 then
      p.sel = math.min(p.sel + 1, #p.nodes)
      p.win:set_cursor(p.sel)
    end
    return
  end
  if key == "<M-k>" or key == "<M-Up>" then
    if #p.nodes > 0 then
      p.sel = math.max(p.sel - 1, 1)
      p.win:set_cursor(p.sel)
    end
    return
  end

  local node = p.nodes[p.sel]
  if node and node.more then
    return
  end

  if key == "<M-l>" then
    if not node then
      return
    end
    if node.is_dir then
      if p.expanded[node.path] then
        local nxt = p.nodes[p.sel + 1]
        if nxt and nxt.depth > node.depth then
          p.sel = p.sel + 1
          p.win:set_cursor(p.sel)
        end
      else
        expand(p, node)
      end
    else
      open_file(node)
    end
    return
  end

  if key == "<M-h>" then
    if node then
      collapse(p, node)
    end
    return
  end

  if key == "<M-a>" then
    create(p, "write")
    return
  end

  if key == "<M-n>" then
    create(p, "mkdir")
    return
  end

  if key == "<M-r>" then
    if node then
      rename_node(p, node)
    end
    return
  end

  if key == "<M-d>" then
    if node then
      delete_node(p, node)
    end
    return
  end

  if key == "<M-s>" then
    p.show_hidden = not p.show_hidden
    p.cache = {}
    flatten(p)
    render(p)
    return
  end

  if key == "<M-u>" then
    p.cache = {}
    local path = node and node.path
    flatten(p)
    if path then
      select_path(p, path)
    end
    render(p)
    return
  end

  if key == "<M-i>" then
    show_help()
  end
end

local function handle_click(p, ev)
  if not ev.row then
    return
  end
  local node = p.nodes[ev.row]
  if not node or node.more then
    return
  end
  p.sel = ev.row
  p.win:set_cursor(p.sel)
  if node.is_dir then
    if p.expanded[node.path] then
      collapse(p, node)
    else
      expand(p, node)
    end
  else
    open_file(node)
  end
end

-- Pane lifecycle -----------------------------------------------------------

local function reset_root(p)
  p.root = maki.uv.cwd()
  p.cache = {}
  p.expanded = {}
  p.nodes = {}
  p.sel = 1
  flatten(p)
  p.win:set_config({ title = basename_title(p.root) })
  render(p)
end

local function loop(p)
  while true do
    local ev = p.win:recv()
    if not ev or ev.type == "close" then
      break
    end
    if ev.type == "key" then
      handle_key(p, ev.key)
    elseif ev.type == "click" then
      handle_click(p, ev)
    elseif ev.type == "resize" then
      p.width = ev.width
      render(p)
    end
  end
  if pane == p then
    pane = nil
  end
end

local function open_pane()
  if pane then
    return
  end
  local p = {
    buf = maki.ui.buf({ scratch = true }),
    root = maki.uv.cwd(),
    cache = {},
    expanded = {},
    nodes = {},
    sel = 1,
    width = M.width,
    show_hidden = M.show_hidden,
  }
  flatten(p)
  p.win = maki.ui.open_win(p.buf, {
    title = basename_title(p.root),
    split = "right",
    width = M.width,
    border = "rounded",
    -- No focus: the chat input keeps the plain letters, this window only
    -- takes the Alt-prefixed ones.
    focus = false,
    cursor_line = true,
    keys = NAV_KEYS,
    footer = FOOTER,
  })
  p.width = p.win.width
  render(p)
  pane = p
  -- spawn, not run: a run task is killed after 60 seconds, and this loop
  -- lives as long as the pane does.
  p.task = maki.async.spawn(function()
    loop(p)
  end)
end

local function toggle()
  if pane then
    local p = pane
    pane = nil
    p.win:close()
    return
  end
  maki.async.run(open_pane)
end

local function refresh()
  local p = pane
  if not p or not p.win:is_open() then
    return
  end
  local path = p.nodes[p.sel] and p.nodes[p.sel].path
  p.cache = {}
  flatten(p)
  if path then
    select_path(p, path)
  end
  render(p)
end

-- Public surface -----------------------------------------------------------

M.open = open_pane
M.toggle = toggle
M.refresh = refresh

--- Closes the pane if it is open.
function M.close()
  if not pane then
    return
  end
  local p = pane
  pane = nil
  p.win:close()
end

--- Registers the keybinding, the /files command and the autocmds.
--- Call once at load; calling it again after a reload is safe.
--- @param opts table? `width` (integer), `toggle_key` (string), `show_hidden` (boolean)
--- @return table module
function M.setup(opts)
  opts = opts or {}
  M.width = opts.width or M.width
  M.toggle_key = opts.toggle_key or M.toggle_key
  if opts.show_hidden ~= nil then
    M.show_hidden = opts.show_hidden
  end
  if M._registered then
    return M
  end
  M._registered = true

  local close_key = human_key(M.toggle_key)
  maki.log.info("file_tree: loaded, toggle " .. close_key)

  maki.keymap.set({ "n", "i" }, M.toggle_key, toggle, { desc = "File tree" })

  -- Bound directly rather than only claimed on the window: a claim that never
  -- fires leaves a visible but deaf pane. The window keeps its claim too, so
  -- either mechanism can deliver the key, and whichever fires consumes it.
  for _, key in ipairs(NAV_KEYS) do
    maki.keymap.set({ "n", "i" }, key, function()
      if pane then
        handle_key(pane, key)
      end
    end, { desc = "File tree" })
  end

  maki.api.register_command({
    name = "/files",
    description = "Toggle the file tree pane (" .. close_key .. "); it never takes keyboard focus",
    handler = toggle,
  })

  maki.api.create_autocmd({ "SessionCwdChanged", "SessionFocusChanged" }, {
    callback = function()
      if pane then
        maki.async.run(function()
          if pane then
            reset_root(pane)
          end
        end)
      end
    end,
  })

  maki.api.create_autocmd("FileIndexReady", {
    callback = function()
      if pane then
        maki.async.run(refresh)
      end
    end,
  })

  maki.api.create_autocmd("SessionEnd", {
    callback = function()
      M.close()
    end,
  })

  return M
end

return M
