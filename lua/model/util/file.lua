local M = {}

M.file_exists = function(file)
  return vim.loop.fs_stat(file) ~= nil
end

M.read_file = function(file)
  if not M.file_exists(file) then return end

  local fd = assert(io.open(file, "r"))
  local content = fd:read("*a")
  fd:close()
  return content
end

M.read_json_file = function(file)
  local content = M.read_file(file)
  if not content then return end

  local json_ok, json_data = pcall(vim.json.decode, content)
  return json_ok and json_data or nil
end

M.write_json_file = function(file, content)
  local json_ok, json_data = pcall(vim.json.encode, content)
  if not json_ok then return end

  local fd = assert(io.open(file, "w+"))
  fd:write(json_data)
  fd:close()
end


return M
