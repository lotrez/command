local socket = require "socket"
local json = require "json"

sendInfoMessage("Loading http server", "CommandHttpServer")

HttpServer = {}
HttpServer.__index = HttpServer

function HttpServer:new(port)
  local server = {
    port = port or 8080,
    routes = {},
    server_socket = nil,
    running = false
  }
  setmetatable(server, self)
  return server
end

-- Add route handler
function HttpServer:route(method, path, handler)
  if not self.routes[method] then
    self.routes[method] = {}
  end
  self.routes[method][path] = handler
end

-- Convenience methods for different HTTP methods
function HttpServer:get(path, handler)
  self:route("GET", path, handler)
end

function HttpServer:post(path, handler)
  self:route("POST", path, handler)
end

function HttpServer:put(path, handler)
  self:route("PUT", path, handler)
end

function HttpServer:delete(path, handler)
  self:route("DELETE", path, handler)
end

-- Create HTTP response
function HttpServer:create_response(status_code, headers, body)
  local status_text = {
    [200] = "OK",
    [201] = "Created",
    [400] = "Bad Request",
    [404] = "Not Found",
    [500] = "Internal Server Error"
  }

  local response = "HTTP/1.1 " .. status_code .. " " .. (status_text[status_code] or "Unknown") .. "\r\n"

  -- Default headers
  headers = headers or {}
  if not headers["Content-Type"] then
    headers["Content-Type"] = "application/json"
  end
  headers["Content-Length"] = tostring(#body)
  headers["Connection"] = "close"

  -- Add headers
  for key, value in pairs(headers) do
    response = response .. key .. ": " .. value .. "\r\n"
  end

  response = response .. "\r\n" .. body
  return response
end

-- JSON response helper
function HttpServer:json_response(data, status_code)
  status_code = status_code or 200
  local json_body = json.encode(data)
  return self:create_response(status_code, { ["Content-Type"] = "application/json" }, json_body)
end

-- Error response helper
function HttpServer:error_response(message, status_code)
  status_code = status_code or 500
  return self:json_response({ error = message }, status_code)
end

-- Find matching route
function HttpServer:find_route(method, path)
  if not self.routes[method] then
    return nil
  end

  -- Exact match first
  if self.routes[method][path] then
    return self.routes[method][path], {}
  end

  -- Pattern matching for dynamic routes
  for route_path, handler in pairs(self.routes[method]) do
    local params = {}
    local pattern = route_path:gsub(":([^/]+)", "([^/]+)")
    local matches = { path:match("^" .. pattern .. "$") }

    if #matches > 0 then
      -- Extract parameter names
      local param_names = {}
      for param_name in route_path:gmatch(":([^/]+)") do
        table.insert(param_names, param_name)
      end

      -- Map matches to parameter names
      for i, match in ipairs(matches) do
        if param_names[i] then
          params[param_names[i]] = match
        end
      end

      return handler, params
    end
  end

  return nil
end

-- Fixed HTTP request parsing with proper body handling
function HttpServer:parse_request(request_str)
  if not request_str then return nil end

  -- Split headers and body properly
  local headers_end = request_str:find("\r\n\r\n")
  if not headers_end then
    headers_end = request_str:find("\n\n")
  end

  local headers_part = headers_end and request_str:sub(1, headers_end - 1) or request_str
  local body = headers_end and request_str:sub(headers_end + 4) or ""

  -- If we used \n\n instead of \r\n\r\n, adjust offset
  if not request_str:find("\r\n\r\n") and request_str:find("\n\n") then
    body = request_str:sub(headers_end + 2)
  end

  local lines = {}
  for line in headers_part:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  if #lines == 0 then return nil end

  -- Parse request line
  local method, path, version = lines[1]:match("([A-Z]+) ([^ ]+) HTTP/([0-9.]+)")
  if not method then return nil end

  -- Parse headers
  local headers = {}
  for i = 2, #lines do
    if lines[i] ~= "" then
      local key, value = lines[i]:match("([^:]+): (.+)")
      if key and value then
        headers[key:lower()] = value:gsub("^%s*(.-)%s*$", "%1") -- trim whitespace
      end
    end
  end

  -- Parse query parameters
  local query = {}
  local path_clean = path
  if path:find("?") then
    path_clean, query_string = path:match("([^?]+)%?(.+)")
    for param in query_string:gmatch("([^&]+)") do
      local key, value = param:match("([^=]+)=(.+)")
      if key and value then
        query[key] = value
      end
    end
  end

  return {
    method = method,
    path = path_clean,
    version = version,
    headers = headers,
    body = body,
    query = query
  }
end

-- Fixed client request handling with proper body reading
function HttpServer:handle_client(client)
  client:settimeout(5) -- Increase timeout to 5 seconds

  -- Read request line
  local request_line = client:receive("*l")
  if not request_line then
    client:close()
    return
  end

  -- Read headers
  local headers = {}
  local content_length = 0
  repeat
    local line = client:receive("*l")
    if line and line ~= "" then
      local key, value = line:match("([^:]+): (.+)")
      if key and value then
        key = key:lower()
        value = value:gsub("^%s*(.-)%s*$", "%1") -- trim whitespace
        headers[key] = value
        if key == "content-length" then
          content_length = tonumber(value) or 0
        end
      end
    end
  until not line or line == ""

  -- Read body if content-length is specified
  local body = ""
  if content_length > 0 then
    body = client:receive(content_length)
    if not body then
      client:send(self:error_response("Failed to read request body", 400))
      client:close()
      return
    end
  end

  -- Reconstruct full request
  local full_request = request_line .. "\r\n"
  for key, value in pairs(headers) do
    full_request = full_request .. key .. ": " .. value .. "\r\n"
  end
  full_request = full_request .. "\r\n" .. body

  -- Parse request
  local request = self:parse_request(full_request)
  if not request then
    client:send(self:error_response("Bad Request", 400))
    client:close()
    return
  end

  -- Find route handler
  local handler, params = self:find_route(request.method, request.path)
  if not handler then
    client:send(self:json_response({ error = "Not Found" }, 404))
    client:close()
    return
  end

  -- Create request context with improved JSON parsing
  local context = {
    method = request.method,
    path = request.path,
    headers = request.headers,
    query = request.query,
    params = params,
    body = request.body,
    json = function()
      if request.headers["content-type"] and
          request.headers["content-type"]:find("application/json") then
        local success, result = pcall(json.decode, request.body)
        if success then
          return result
        else
          return nil
        end
      end
      return nil
    end
  }

  -- Call handler
  local success, response = pcall(handler, context)
  if not success then
    client:send(self:error_response("Internal Server Error: " .. tostring(response), 500))
  else
    client:send(response)
  end

  client:close()
end

-- Start server
function HttpServer:start()
  self.server_socket = socket.bind("127.0.0.1", self.port)
  if not self.server_socket then
    error("Failed to bind to port " .. self.port)
  end

  self.server_socket:settimeout(0) -- Non-blocking
  self.running = true

  print("HTTP server started on http://127.0.0.1:" .. self.port)
  return true
end

-- Process requests (call this in your game loop)
function HttpServer:process()
  if not self.running or not self.server_socket then
    return
  end

  local client = self.server_socket:accept()
  if client then
    self:handle_client(client)
  end
end

-- Stop server
function HttpServer:stop()
  self.running = false
  if self.server_socket then
    self.server_socket:close()
    self.server_socket = nil
  end
end

return HttpServer
