local segment = require('model.util.segment')
local util = require('model.util')
local juice = require('model.util.juice')
local input = require('model.core.input')

local M = {}

---@class ChatPrompt
---@field provider Provider The API provider for this prompt
---@field create fun(input: string, context: Context): string | ChatContents Converts input and context to the first message text or ChatContents
---@field run fun(messages: ChatMessage[], config: ChatConfig): table | fun(resolve: fun(params: table): nil ) ) Converts chat messages and config into completion request params
---@field system? string System instruction
---@field params? table Static request parameters
---@field options? table Provider options

---@class ChatMessage
---@field role 'user' | 'assistant'
---@field content string

---@alias ChatConfig { system?: string, params?: table, options?: table }

---@class ChatContents
---@field config ChatConfig Configuration for this chat buffer, used by chatprompt.run
---@field messages ChatMessage[] Messages in the chat buffer

--- Splits lines into array of { role: 'user' | 'assistant', content: string }
--- If first line starts with '> ', then the rest of that line is system message
---@param text string Text of buffer. '\n======\n' denote alternations between user and assistant roles
---@return { messages: { role: 'user'|'assistant', content: string}[], system?: string }
local function split_messages(text)
  local lines = vim.fn.split(text, '\n')
  local messages = {}

  local system;

  local chunk_lines = {}
  local chunk_is_user = true

  --- Insert message and reset/toggle chunk state. User text is trimmed.
  local function add_message()
    local text_ = table.concat(chunk_lines, '\n')

    table.insert(messages, {
      role = chunk_is_user and 'user' or 'assistant',
      content = chunk_is_user and vim.trim(text_) or text_
    })

    chunk_lines = {}
    chunk_is_user = not chunk_is_user
  end

  for i, line in ipairs(lines) do
    if i == 1 then
      system = line:match('^> (.+)')

      if system == nil then
        table.insert(chunk_lines, line)
      end

    elseif line == '======' then
      add_message()
    else
      table.insert(chunk_lines, line)
    end
  end

  -- add text after last `======` if not empty
  if table.concat(chunk_lines, '') ~= '' then
    add_message()
  end

  return {
    system = system,
    messages = messages
  }
end

---@param text string Input text of buffer
---@return { chat: string, config?: table, rest: string }
local function parse_config(text)

  if text:match('^---$') then
    error('Chat buffer must start with chat name, not config')
  end

  if text:match('^>') then
    error('Chat buffer must start with chat name, not system instruction')
  end

  local chat_name, name_rest = text:match('^(.-)\n(.*)')
  local params_text, rest = name_rest:match('%-%-%-\n(.-)\n%-%-%-\n(.*)')

  if chat_name == '' then
    error('Chat buffer must start with chat name, not empty line')
  end

  if params_text == nil then
    return {
      config = {},
      rest = vim.fn.trim(name_rest),
      chat = chat_name
    }
  else
    local config = vim.fn.luaeval(params_text)

    if type(config) ~= 'table' then
      error('Evaluated config text is not a lua table')
    end

    return {
      config = config,
      rest = vim.fn.trim(rest),
      chat = chat_name
    }
  end
end

--- Parse a chat file. Must start with a chat name, can follow with a lua table
--- of config between `---`. If the next line starts with `> `, it is parsed as
--- the system instruction. The rest of the text is parsed as alternating
--- user/assistant messages, with `\n======\n` delimiters.
---@param text string
---@return { contents: ChatContents, chat: string }
function M.parse(text)
  local parsed = parse_config(text)
  local messages_and_system = split_messages(parsed.rest)
  parsed.config.system = messages_and_system.system

  return {
    contents = {
      messages = messages_and_system.messages,
      config = parsed.config
    },
    chat = parsed.chat
  }
end

---@param contents ChatContents
---@param name string
---@return string
function M.to_string(contents, name)
  local result = name .. '\n'

  if not vim.tbl_isempty(contents.config) then
    -- TODO consider refactoring this so we're not treating system special
    -- Either remove it from contents.config so that it sits next to config
    -- or just let it be a normal config field
    local without_system = util.table.without(contents.config, 'system')

    if without_system and not vim.tbl_isempty(without_system) then
      result = result .. '---\n' .. vim.inspect(without_system) .. '\n---\n'
    end

    if contents.config.system then
      result = result .. '> ' .. contents.config.system .. '\n'
    end
  end


  for i,message in ipairs(contents.messages) do
    if i ~= 1 then
      result = result .. '\n======\n'
    end

    if message.role == 'user' then
      result = result .. '\n' .. message.content .. '\n'
    else
      result = result .. message.content
    end
  end

  local last = contents.messages[#contents.messages]

  if #contents.messages % 2 == 0 then
    result = result .. '\n======\n'
  end

  return vim.fn.trim(result, '\n', 2) -- trim trailing newline
end

function M.build_contents(chat_prompt, input_context)
  local first_message_or_contents = chat_prompt.create(
    input_context.input,
    input_context.context
  )

  local config = {
    options = chat_prompt.options,
    params = chat_prompt.params,
    system = chat_prompt.system,
  }

  ---@type ChatContents
  local chat_contents

  if type(first_message_or_contents) == 'string' then
    chat_contents = {
      config = config,
      messages = {
        {
          role = 'user',
          content = first_message_or_contents
        }
      }
    }
  elseif type(first_message_or_contents) == 'table' then
    chat_contents = vim.tbl_deep_extend(
      'force',
      { config = config },
      first_message_or_contents
    )
  else
    error('ChatPrompt.create() needs to return a string for the first message or an ChatContents')
  end

  return chat_contents
end

function M.create_buffer(text, smods)
  if smods.tab > 0 then
    vim.cmd.tabnew()
  elseif smods.horizontal then
    vim.cmd.new()
  else
    vim.cmd.vnew()
  end

  vim.o.ft = 'mchat'
  vim.cmd.syntax({'sync', 'fromstart'})

  local lines = vim.fn.split(text, '\n')
  ---@cast lines string[]

  vim.api.nvim_buf_set_lines(
    0,
    0,
    0,
    false,
    lines
  )
end

local function needs_nl(buf_lines)
  local last_line = buf_lines[#buf_lines]

  return not last_line or vim.fn.trim(last_line) ~= ''
end

---@param opts { chats?: table<string, ChatPrompt> }
function M.run_chat(opts)
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local parsed = M.parse(
    table.concat(buf_lines, '\n')
  )

  local chat_name = assert(
    parsed.chat,
    'Chat buffer first line must be a chat prompt name'
  )

  ---@type ChatPrompt
  local chat_prompt = assert(
    vim.tbl_get(opts, 'chats', chat_name),
    'Chat "' .. chat_name .. '" not found'
  )

  local run_params = chat_prompt.run(
    parsed.contents.messages,
    parsed.contents.config
  )
  if run_params == nil then
    error('Chat prompt run() returned nil')
  end

  local seg = segment.create_segment_at(#buf_lines, 0)

  local starter_seperator = needs_nl(buf_lines) and '\n======\n' or '======\n'
  seg.add(starter_seperator)

  local sayer = juice.sayer()

  ---@type StreamHandlers
  local handlers = {
    on_partial = function(text)
      seg.add(text)
      sayer.say(text)
    end,
    on_finish = function(text, reason)
      sayer.finish()

      if text then
        seg.set_text(starter_seperator .. text .. '\n======\n')
      else
        seg.add('\n======\n')
      end

      seg.clear_hl()

      if reason and reason ~= 'stop' and reason ~= 'done' then
        util.notify(reason)
      end
    end,
    on_error = function(err, label)
      util.notify(vim.inspect(err), vim.log.levels.ERROR, { title = label })
      seg.set_text('')
      seg.clear_hl()
    end,
    segment = seg
  }

  local options = parsed.contents.config.options or {}
  local params = parsed.contents.config.params or {}

  if type(run_params) == 'function' then
    run_params(function(async_params)
      local merged_params = vim.tbl_deep_extend(
        'force',
        params,
        async_params
      )

      seg.data.cancel = chat_prompt.provider.request_completion(
        handlers,
        merged_params,
        options
      )
    end)
  else
    seg.data.cancel = chat_prompt.provider.request_completion(
      handlers,
      vim.tbl_deep_extend(
        'force',
        params,
        run_params
      ),
      options
    )
  end
end

M.chat_contents_var_name = "model_chat_contents"

M.get_chat_contents_var = function()
  local chat_exists, encoded_contents = pcall(
    vim.api.nvim_buf_get_var,
    vim.api.nvim_get_current_buf(),
    M.chat_contents_var_name
  )
  local chat_contents = chat_exists and vim.json.decode(encoded_contents) or nil
  return chat_exists, chat_contents
end

M.has_chat_contents_var = function()
  local chat_exists, chat_contents = M.get_chat_contents_var()
  return chat_exists and chat_contents ~= nil
end

M.get_chat_contents_var_or_raise = function()
  local chat_exists, chat_contents = M.get_chat_contents_var()

  if not (chat_exists and chat_contents) then
    error("Chat not found")
  end

  return chat_contents
end

M.set_chat_contents_var = function(chat_contents, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local encoded_contents = vim.json.encode(chat_contents)
  vim.api.nvim_buf_set_var(bufnr, M.chat_contents_var_name, encoded_contents)
end

M.update_chat_contents = function(chat_contents, role, content)
  local last_message = chat_contents.messages[#chat_contents.messages]

  content = content or ""
  if last_message and last_message.role == role then
    last_message.content = last_message.content .. "\n" .. content
  else
    table.insert(chat_contents.messages, { role = role, content = content })
  end
end

M.update_chat_contents_using_args = function(chat_contents, args)
  M.update_chat_contents(chat_contents, "user", args)
end

M.has_chat_contents_query_message = function(chat_contents)
  local last_message = chat_contents.messages[#chat_contents.messages]
  return last_message and string.len(last_message.content or "") > 0
end

M.create_markdown_buffer = function(chat_name, chat_contents, smods)
  local chat_markdown = vim.list_extend(
    M.chat_name_header(chat_name),
    M.contents_to_markdown(chat_contents)
  )

  if smods.tab > 0 then
    vim.cmd.tabnew()
  elseif smods.horizontal then
    vim.cmd.new()
  else
    vim.cmd.vnew()
  end

  vim.o.ft = "markdown"

  local bufnr = vim.api.nvim_get_current_buf()
  local date = os.date("%Y-%m-%d %H:%M:%S")
  vim.api.nvim_buf_set_name(bufnr, string.format("chat at %s.md", date))
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chat_markdown)
  util.cursor.place_at_end()

  vim.api.nvim_set_option_value("wrap", true, { scope = "local" })
  vim.api.nvim_set_option_value("linebreak", true, { scope = "local" })

  M.set_chat_contents_var(chat_contents, bufnr)
end

local header_kind = {
  CHAT = "chat",
  SYSTEM = "system",
  USER = "user",
  ASSISTANT = "assistant"
}

local header_level = {
  H1 = "#",
  H2 = "##"
}

M.markdown = {
  separator = "",
  headers = {
    [header_kind.CHAT] = header_level.H1 .. " Chat",
    [header_kind.SYSTEM] = header_level.H2 .. " System",
    [header_kind.USER] = header_level.H2 .. " User",
    [header_kind.ASSISTANT] = header_level.H2 .. " Assistant",
  },
}

M.chat_name_header = function(chat_name)
  return M.to_markdown_section(header_kind.CHAT, chat_name)
end

M.to_markdown_header = function(kind)
  return { M.markdown.headers[kind], M.markdown.separator }
end

M.to_markdown_header_with_separator = function(kind)
  local markdown = M.to_markdown_header(kind)
  table.insert(markdown, M.markdown.separator)
  return markdown
end

M.to_markdown_section = function(kind, content)
  local markdown = M.to_markdown_header(kind)

  content = content or ""
  if type(content) == "table" and vim.tbl_islist(content) then
    vim.list_extend(markdown, content)
  else
    table.insert(markdown, content)
  end

  table.insert(markdown, M.markdown.separator)

  return markdown
end

M.contents_to_markdown = function(chat_contents)
  local markdown = {}

  for _, message in ipairs(chat_contents.messages) do
    local content = vim.fn.split(message.content, "\n")
    vim.list_extend(markdown, M.to_markdown_section(message.role, content))
  end

  local last_message = chat_contents.messages[#chat_contents.messages]
  if last_message.role ~= "user" then
    vim.list_extend(markdown, M.to_markdown_header(header_kind.USER))
  end

  return markdown
end

M.markdown_to_text = function(markdown)
  return table.concat(markdown, "\n")
end

M.chat_name_from_markdown = function()
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local chat_header_start = "^" .. header_level.H1 .. "[ ]*"

  local chat_header_idx = nil
  for idx, buf_line in ipairs(buf_lines) do
    if buf_line:match(chat_header_start) then
      chat_header_idx = idx
      break
    end
  end

  local chat_name = nil
  if chat_header_idx ~= nil then
    local chat_name_idx = chat_header_idx + 1
    while buf_lines[chat_name_idx] == "" and chat_name_idx < #buf_lines do
      chat_name_idx = chat_name_idx + 1
    end
    chat_name = buf_lines[chat_name_idx]
  end

  if chat_name == nil then
    error("Chat name not found in markdown")
  end

  return chat_name
end

M.contents_from_markdown = function(chat_prompt)
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local header_start = "^" .. header_level.H2 .. "[ ]*"

  local sections_idx = {}
  for idx, buf_line in ipairs(buf_lines) do
    if buf_line:match(header_start) then
      table.insert(sections_idx, idx)
    end
  end

  local chat_contents = {}
  for idx, section_idx in ipairs(sections_idx) do
    local next_section_idx = sections_idx[idx + 1] and sections_idx[idx + 1] or #buf_lines

    local contents_start = section_idx + 1
    while buf_lines[contents_start] == "" and contents_start < next_section_idx do
      contents_start = contents_start + 1
    end

    local contents_end = next_section_idx < #buf_lines and next_section_idx - 1 or #buf_lines
    while buf_lines[contents_end] == "" and contents_end > contents_start do
      contents_end = contents_end - 1
    end

    local role = string.lower(string.gsub(buf_lines[section_idx], header_start, ""))
    local content = table.concat({ unpack(buf_lines, contents_start, contents_end) }, "\n")
    table.insert(chat_contents, { role = role, content = content })
  end

  return {
    config = {
      options = chat_prompt.options,
      params = chat_prompt.params,
      system = chat_prompt.system,
    },
    messages = chat_contents,
  }
end

M.create_markdown_chat = function(cmd_params, chat_name, chat_prompt)
  local args = table.concat(cmd_params.fargs, " ")
  local input_context = input.get_input_context(
    input.get_source(cmd_params.range ~= 0), -- want_visual_selection
    args
  )

  local chat_exists, chat_contents = M.get_chat_contents_var()

  if chat_exists and chat_contents then
    -- copy current messages to a new built buffer with target settings
  else
    -- create chat_contents and build new chat buffer
    chat_contents = M.build_contents(chat_prompt, input_context)

    if args ~= "" then
      M.update_chat_contents_using_args(chat_contents, args)
    end

    M.create_markdown_buffer(chat_name, chat_contents, cmd_params.smods)
  end
end

M.finalize_markdown_chat = function(buf_segment, chat_contents, text)
  local markdown = {}
  vim.list_extend(markdown, M.to_markdown_section(header_kind.ASSISTANT, text))
  vim.list_extend(markdown, M.to_markdown_header_with_separator(header_kind.USER))
  buf_segment.set_text(M.markdown_to_text(markdown))

  M.update_chat_contents(chat_contents, "assistant", text)
  M.update_chat_contents(chat_contents, "user")
end

M.maybe_insert_newline_at_buffer_end = function(bufnr, buf_lines)
  if needs_nl(buf_lines) then
    table.insert(buf_lines, "")
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "" })
  end
end

M.run_markdown_chat = function(chat_prompt)
  local chat_contents = M.get_chat_contents_var_or_raise()
  if not M.has_chat_contents_query_message(chat_contents) then
    return
  end

  local run_params = chat_prompt.run(
    chat_contents.messages,
    chat_contents.config
  )
  if run_params == nil then
    error("Chat prompt run() returned nil")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  M.maybe_insert_newline_at_buffer_end(bufnr, buf_lines)

  local buf_segment = segment.create_segment_at(#buf_lines, 0, nil, bufnr)
  local sayer = juice.sayer()

  ---@type StreamHandlers
  local handlers = {
    on_partial = function(text)
      buf_segment.add(text)
      sayer.say(text)
    end,
    on_finish = function(text, reason)
      if text then
        M.finalize_markdown_chat(buf_segment, chat_contents, text)
        M.set_chat_contents_var(chat_contents, bufnr)
      end
      sayer.finish()
      buf_segment.clear_hl()

      if reason and reason ~= "stop" and reason ~= "done" then
        util.notify(reason)
      end
    end,
    on_error = function(err, label)
      util.eshow(err, label)
      buf_segment.set_text("")
      buf_segment.clear_hl()
    end,
    segment = buf_segment,
  }

  buf_segment.add(
    M.markdown_to_text(M.to_markdown_header_with_separator(header_kind.ASSISTANT))
  )

  if type(run_params) == "function" then
    -- TODO
  else
    local params = chat_contents.config.params or {}
    buf_segment.data.cancel = chat_prompt.provider.request_completion(
      handlers,
      vim.tbl_deep_extend("force", params, run_params),
      chat_contents.config.options
    )
  end
end


return M
