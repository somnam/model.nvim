local async = require("model.util.async")
local curl = require("model.util.curl")
local file = require("model.util.file")
local util = require("model.util")
local instructions = require("model.instructions.copilot")


local copilot = {
  -- Githu Copilot config path
  config_paths = {
    "$XDG_CONFIG_HOME/github-copilot",
    "~/.config/github-copilot",
    "~/AppData/Local/github-copilot",
  },
  config_path = nil,
  -- Gitub oauth token
  hosts_file = "hosts.json",
  oauth_token = nil,
  -- Github Copilot api key
  api_key_file = "api-key.json",
  api_key_headers = {
    ["Editor-Version"] = "vscode/1.86.0",
    ["Editor-Plugin-Version"] = "copilot-chat/0.12.2023122001",
    ["User-Agent"] = "GitHubCopilotChat/0.12.2023122001",
  },
  api_key_url = "https://api.github.com/copilot_internal/v2/",
  api_key_endpoint = "token",
  api_key = nil,
}

copilot.get_config_path = function()
  if copilot.config_path ~= nil then
    return copilot.config_path
  end

  for _, location in pairs(copilot.config_paths) do
    local expanded = vim.fn.expand(location)
    if expanded and vim.fn.isdirectory(expanded) > 0 then
      copilot.config_path = expanded
      return expanded
    end
  end
  error("Could not find Copilot config. Copilot plugin not authenticated?")
end

copilot.read_hosts_file = function(config_path)
  local json_file = string.format("%s/%s", config_path, copilot.hosts_file)
  return file.read_json_file(json_file)
end

copilot.get_oauth_token = function()
  if copilot.oauth_token ~= nil then
    return copilot.oauth_token
  end

  local config_path = copilot.get_config_path()
  local hosts_data = copilot.read_hosts_file(config_path)

  if hosts_data ~= nil and hosts_data["github.com"] ~= nil then
    local oauth_token = hosts_data["github.com"].oauth_token
    if oauth_token ~= nil then
      copilot.oauth_token = oauth_token
      return oauth_token
    end
  end
  error("Could not retrieve Github oauth token. Copilot plugin not authenticated?")
end

copilot.read_api_key_file = function()
  local json_file = string.format("%s/%s", copilot.config_path, copilot.api_key_file)
  return file.read_json_file(json_file)
end

copilot.write_api_key_file = function(api_key)
  local json_file = string.format("%s/%s", copilot.config_path, copilot.api_key_file)
  return file.write_json_file(json_file, api_key)
end

copilot.should_generate_new_api_key = function(api_key)
  if api_key == nil then
    return true
  end

  if api_key.expires_at == nil or api_key.token == nil then
    return true
  end

  return api_key.expires_at <= os.time()
end

copilot.generate_new_api_key = function(on_complete, on_error)

  local oauth_token = copilot.get_oauth_token()
  local headers = vim.tbl_deep_extend(
    "force",
    copilot.api_key_headers,
    { Authorization = string.format("token %s", oauth_token) }
  )
  local url = string.format(
    "%s%s",
    copilot.api_key_url,
    copilot.api_key_endpoint
  )

  curl.stream(
    { method = "GET", headers = headers, url = url },
    function(response)
      local body, err = util.json.decode(response)
      if body == nil then
        on_error("Could not generate Copilot api key: " .. err)
        error("Could not generate Copilot api key: " .. err)
      end

      local api_key = { token = body.token, expires_at = body.expires_at }
      copilot.write_api_key_file(api_key)

      on_complete(api_key)
    end,
    util.eshow
  )
end

local chat_kind = {
  COMMIT = "commit",
  DEFAULT = "default",
  EXPLAIN = "explain",
  FIX = "fix",
  NEW = "new",
  REFACTOR = "refactor",
  TESTS = "tests",
  WORKSPACE = "workspace",
}

copilot.chat = {
  url = "https://api.githubcopilot.com/",
  endpoint = "chat/completions",
  headers = {
    ["Editor-Version"] = "vscode/1.86.0",
    ["Editor-Plugin-Version"] = "copilot-chat/0.12.2023122001",
    ["User-Agent"] = "GitHubCopilotChat/0.12.2023122001",
    ["Openai-Organization"] = "github-copilot",
    ["Openai-Intent"] = "conversation-panel",
    ["Content-Type"] = "application/json",
  },
  params = {
    model = "copilot-chat",
    intent = true,
    stream = true,
    n = 1,
    temperature = 0.1,
    top_p = 1,
  },
  filetype = "markdown",
  kind = chat_kind,
  instructions = {
    [chat_kind.DEFAULT] = instructions.INSTRUCTION,
    [chat_kind.EXPLAIN] = instructions.EXPLAIN_INSTRUCTION,
    [chat_kind.FIX] = instructions.FIX_INSTRUCTION,
    [chat_kind.NEW] = instructions.NEW_INSTRUCTION,
    [chat_kind.REFACTOR] = instructions.SENIOR_INSTRUCTION,
    [chat_kind.TESTS] = instructions.TESTS_INSTRUCTION,
    [chat_kind.COMMIT] = instructions.COMMIT_INSTRUCTION,
  },
}

copilot.chat.extract_chat_data = function(data)
  if data ~= nil and data.choices ~= nil then
    if #data.choices > 0 then
      return {
        content = (data.choices[1].delta or {}).content,
        finish_reason = data.choices[1].finish_reason
      }
    else
      return { content = "", finish_reason = nil }
    end
  end
end

copilot.chat.request_completion = function(handlers, params, _)
  async(function(wait, resolve)
    local api_key = copilot.api_key or copilot.read_api_key_file()
    local should_generate_new_api_key = copilot.should_generate_new_api_key(api_key)

    if should_generate_new_api_key then
      copilot.api_key = wait(copilot.generate_new_api_key(
        resolve, handlers.on_error
      ))
    else
      copilot.api_key = api_key
    end

    local authorization = string.format("Bearer %s", copilot.api_key.token)
    local headers = vim.tbl_deep_extend(
      "force",
      copilot.chat.headers,
      { Authorization = authorization }
    )
    local url = string.format(
      "%s%s",
      copilot.chat.url,
      copilot.chat.endpoint
    )

    local completion = ""

    return require("model.util.sse").curl_client(
      { headers = headers, method = "POST", url = url, body = params },
      {
        on_message = function(message, _)
          local data = copilot.chat.extract_chat_data(
            util.json.decode(message.data)
          )

          if data ~= nil and data.content ~= nil then
            completion = completion .. data.content
            handlers.on_partial(data.content)
          end

          if data ~= nil and data.finish_reason ~= nil then
            handlers.on_finish(completion, data.finish_reason)
          end
        end,
        on_other = function(content)
          handlers.on_error(content, "Copilot Chat API error")
        end,
        on_error = handlers.on_error,
      }
    )
  end)

end

copilot.chat.instruction_from_kind = function(kind)
  return (
    copilot.chat.instructions[kind]
    or copilot.chat.instructions.default
  )
end

copilot.chat.builder = function(input, context)
  return copilot.chat.user_selection_and_args(input, context)
end

copilot.chat.adapt = function(standard_prompt)
  table.insert(standard_prompt.messages, 1, {
    role = "system",
    content = standard_prompt.instruction,
  })

  return { messages = standard_prompt.messages }
end

copilot.chat.default_prompt = {
  provider = copilot.chat,
  instruction = copilot.chat.instructions.default,
  builder = copilot.chat.builder,
  params = copilot.chat.params,
}

copilot.chat.to_user_content = function(context)
  if context.args ~= nil and #context.args > 0 then
    return context.args
  end
end

copilot.chat.user_args = function(context)
  return {
    messages = {
      {
        role = "user",
        content = (copilot.chat.to_user_content(context) or ""),
      }
    }
  }
end

copilot.chat.to_user_selection = function(input, context)
  if context.selection then
    local filetype = vim.bo.filetype or ""
    return util.markdown.format_active_selection(input, filetype)
  end
end

copilot.chat.user_selection_and_args = function(input, context)
  local content = {}
  local user_content = copilot.chat.to_user_content(context)
  if user_content ~= nil then
    table.insert(content, user_content)
  end
  local user_selection = copilot.chat.to_user_selection(input, context)
  if user_selection ~= nil then
    table.insert(content, user_selection)
  end

  return {
    messages = {
      {
        role = "user",
        content = table.concat(content, "\n"),
      }
    }
  }
end

copilot.chat.run = function(messages, config)
  table.insert(messages, 1, {
    role = "system",
    content = config.system,
  })

  return { messages = messages }
end

copilot.chat.build_prompt = function(prompt)
  prompt = prompt or {}
  prompt = vim.tbl_deep_extend(
    "force",
    prompt,
    {
      params = vim.tbl_deep_extend(
        "force",
        copilot.chat.params,
        (prompt.params or {})
      ),
    }
  )
  prompt = vim.tbl_deep_extend(
    "force",
    copilot.chat.default_prompt,
    prompt
  )
  return vim.tbl_deep_extend(
    "force",
    prompt,
    {
      builder = function(input, context)
        return copilot.chat.adapt(
          vim.tbl_deep_extend(
            "force",
            prompt.builder(input, context),
            { instruction = prompt.instruction }
          )
        )
      end,
    }
  )
end

copilot.chat.default_chat = {
  provider = copilot.chat,
  system = copilot.chat.instructions.default,
  params = copilot.chat.params,
  create = copilot.chat.user_selection_and_args,
  run = copilot.chat.run,
}

copilot.chat.build_chat = function(chat)
  chat = chat or {}
  chat = vim.tbl_deep_extend(
    "force",
    chat,
    {
      params = vim.tbl_deep_extend(
        "force",
        copilot.chat.params,
        (chat.params or {})
      ),
    }
  )
  return vim.tbl_deep_extend(
    "force",
    copilot.chat.default_chat,
    chat
  )
end

return copilot
