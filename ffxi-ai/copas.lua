--[[
Copas is a dispatcher based on coroutines that can be used for asynchronous
networking.

It uses LuaSocket and can be used with any library that uses it as a backend.

Copas can handle several requests in parallel and lets them block waiting for
a response without blocking the whole application.

Copas was designed by Andre Carregal and is currently maintained by
David Burgess and Javier Guerra.

Copas is free software. See LICENSE for details.
]]

local coroutine = require "coroutine"
local socket = require "socket"

local copas = { _version = "Copas 4.2.0" }
local _M = copas

-- active socket list
local active = {}
-- sockets ready for reading
local rlist = {}
-- sockets ready for writing
local wlist = {}
-- list of threads waiting for requests to finish
local waiting = {}
-- list of timers
local timers = {}
-- server socket list
local servers = {}
-- sockets that must be closed
local mustclose = {}
-- sockets that must be removed
local mustremove = {}
-- sockets that must be shutdown
local mustshutdown = {}
-- time when step was last called
local last = 0
-- time for next timer to fire
local nexttimer = math.huge
-- status message
copas.status = "started"
-- for backwards compatibility
copas.running = true
-- time out for socket.select
copas.timeout = 0
-- friendly name for the main thread
copas.mainthread = coroutine.running()

--- Returns the socket's friendly name.
-- @param sock socket handler.
-- @return a string containing the socket's name.
local function name(sock)
  local peer = sock:getpeername()
  if peer then
    return peer
  else
    local self = sock:getsockname()
    return (self or "?") .. ":?:?"
  end
end

--- Returns the current time (socket.gettime).
-- @return a number representing the current time.
function copas.gettime()
  return socket.gettime()
end

--- Add a socket to the list of active sockets.
-- @param sock socket handler to be added.
-- @param server boolean, true if it's a server socket that accepts connections.
function copas.add(sock, server)
  sock:settimeout(0)
  active[sock] = { sock = sock, name = name(sock) }
  if server then servers[sock] = true end
end

--- Alias for copas.add for backwards compatibility.
-- @param sock socket handler to be added.
copas.addsocket = copas.add

--- Removes a socket from the lists of active sockets.
-- @param sock socket handler to be removed.
function copas.remove(sock)
  if not active[sock] then return end
  active[sock] = nil
  rlist[sock] = nil
  wlist[sock] = nil
  servers[sock] = nil
end

--- Waits for a read or write operation on a socket.
-- This is the dispatcher's main loop.
-- @param sock socket handler
-- @param what string containing 'r' for read and 'w' for write.
-- @param timeout number of seconds to wait for the operation to complete.
-- @return true, nil on success, false, string with error message on failure.
function copas.wait(sock, what, timeout)
  local s = active[sock]
  if not s then
    copas.add(sock)
    s = active[sock]
  end

  local co = coroutine.running()
  -- main thread is not a coroutine, so it can't yield
  if co == copas.mainthread then
    error("copas.wait cannot be called by the main thread, you must wrap it in a coroutine", 2)
  end

  s.thread = co
  s.what = what
  s.timeout = timeout and (socket.gettime() + timeout)

  if what:find "r" then rlist[sock] = true end
  if what:find "w" then wlist[sock] = true end

  -- yield control to copas
  return coroutine.yield()
end

--- A wrapper for socket:accept that is copas-friendly.
-- @param sock server socket handler.
-- @param timeout number of seconds to wait for a connection.
-- @return a client socket handler, nil on timeout.
function copas.accept(sock, timeout)
  if not active[sock] then
    copas.add(sock, true)
  end
  while true do
    local cl, err = sock:accept()
    if cl then
      cl:settimeout(0)
      return cl
    end
    if err == "timeout" then
      local ok, err = copas.wait(sock, "r", timeout)
      if not ok then
        -- if wait failed then there was probably a timeout
        return nil, err or "timeout"
      end
    else
      return nil, err
    end
  end
end

--- A wrapper for socket:connect that is copas-friendly.
-- @param sock client socket handler.
-- @param address string with the address to connect to.
-- @param port number with the port to connect to.
-- @return true, nil on success, nil, string with error message on failure.
function copas.connect(sock, address, port)
  if not active[sock] then
    copas.add(sock)
  end
  -- try to connect
  local res, err = sock:connect(address, port)
  if res then return true end
  if err ~= "timeout" then return nil, err end

  -- wait for connection to be established
  local success, err = copas.wait(sock, "w")
  if not success then return nil, err end

  -- check if it really connected
  local peer = sock:getpeername()
  if peer then
    return true
  else
    -- find out why it failed
    local _, err = sock:send ""
    return nil, err
  end
end

--- A wrapper for socket:receive that is copas-friendly.
-- @param sock socket handler.
-- @param pattern string with the read pattern (see luasocket's socket:receive).
-- @param prefix string with the read prefix (see luasocket's socket:receive).
-- @param timeout number of seconds to wait for the operation.
-- @return depends on the pattern used, see luasocket's reference.
function copas.receive(sock, pattern, prefix, timeout)
  if not active[sock] then
    copas.add(sock)
  end
  pattern = pattern or "*l"
  while true do
    local data, err, partial = sock:receive(pattern, prefix)
    if data then return data end
    if partial then return partial end
    if err == "timeout" then
      local ok, err = copas.wait(sock, "r", timeout)
      if not ok then
        -- if wait failed then there was probably a timeout
        return nil, err or "timeout", partial
      end
    else
      return nil, err, partial
    end
  end
end

--- A wrapper for socket:send that is copas-friendly.
-- @param sock socket handler.
-- @param data string with data to be sent.
-- @param i number with the initial position of data to be sent.
-- @param j number with the final position of data to be sent.
-- @param timeout number of seconds to wait for the operation.
-- @return the number of bytes sent, or nil, string with error and number with position of the string that was sent.
function copas.send(sock, data, i, j, timeout)
  if not active[sock] then
    copas.add(sock)
  end
  local i = i or 1
  while true do
    local sent, err, last = sock:send(data, i, j)
    if sent then return sent end
    if err == "timeout" then
      local ok, err = copas.wait(sock, "w", timeout)
      if not ok then
        -- if wait failed then there was probably a timeout
        return nil, err or "timeout", last
      end
    else
      return nil, err, last
    end
  end
end

--- A wrapper for socket:close that is copas-friendly.
-- It might not close the socket right away, as it may be in use by another coroutine.
-- Sockets will be closed on the next call to copas.step()
-- @param sock socket handler.
function copas.close(sock)
  if not active[sock] or mustclose[sock] or mustshutdown[sock] then return end
  mustclose[sock] = true
end

--- A wrapper for socket:shutdown that is copas-friendly.
-- It might not shutdown the socket right away, as it may be in use by another coroutine.
-- Sockets will be shutdown on the next call to copas.step()
-- @param sock socket handler.
-- @param how string 'receive', 'send' or 'both'
function copas.shutdown(sock, how)
  if not active[sock] or mustclose[sock] or mustshutdown[sock] then return end
  mustshutdown[sock] = how or "both"
end

--- Detaches a socket, so it can be handled by another thread or process.
-- @param sock socket handler.
function copas.detach(sock)
  if not active[sock] then return end
  mustremove[sock] = true
end

--- Creates a new thread and adds it to the list of waiting threads.
-- @param func function to be executed inside the new thread.
-- @param ... parameters to be passed to func.
function copas.addthread(func, ...)
  local co = coroutine.create(func)
  local args = { ... }
  waiting[co] = {
    args = args,
    wake = socket.gettime(),
  }
  return co
end

--- Puts a thread to sleep for a given amount of time.
-- @param delay number of seconds to sleep.
function copas.sleep(delay)
  local co = coroutine.running()
  -- main thread is not a coroutine, so it can't yield
  if co == copas.mainthread then
    error("copas.sleep cannot be called by the main thread, you must wrap it in a coroutine", 2)
  end
  local s = active[co]
  if not s then
    active[co] = { sock = co, name = "timer" }
    s = active[co]
  end
  s.thread = co
  s.timeout = socket.gettime() + delay
  timers[co] = true
  return coroutine.yield()
end

--- Processes all sockets and timers, resuming waiting coroutines.
-- @param t number of seconds to wait for socket.select.
function copas.step(t)
  last = socket.gettime()

  -- resume waiting threads
  for co, v in pairs(waiting) do
    if last >= v.wake then
      waiting[co] = nil
      local success, err = coroutine.resume(co, unpack(v.args))
      if not success then
        -- catch error so the main thread doesn't die
        socket.try(
          pcall(copas.error, err, co)
        )
      end
    end
  end

  local readers, writers = {}, {}
  local rn, wn = 0, 0
  for sock, s in pairs(active) do
    if type(sock) == "table" then -- ignore timers
      if s.thread and coroutine.status(s.thread) == "suspended" then
        if rlist[sock] then
          rn = rn + 1
          readers[rn] = sock
        end
        if wlist[sock] then
          wn = wn + 1
          writers[wn] = sock
        end
      else
        s.thread = nil
        rlist[sock] = nil
        wlist[sock] = nil
        if mustclose[sock] or mustshutdown[sock] or mustremove[sock] then
          -- was waiting for thread to finish, now we can process it
        elseif not servers[sock] then
          -- was not given to a handler, so we should close it
          mustclose[sock] = true
        end
      end
    end
  end

  local readable, writeable, err
  if rn > 0 or wn > 0 then
    -- if there are timers, we must calculate the timeout for select
    local timeout = t or copas.timeout
    if nexttimer ~= math.huge then
      timeout = math.min(timeout, nexttimer - last)
      timeout = math.max(0, timeout)
    end
    readable, writeable, err = socket.select(readers, writers, timeout)
    if err then copas.error(err) end
  else
    -- no sockets to check, so we can sleep until the next timer
    if nexttimer ~= math.huge then
      local delay = nexttimer - last
      if delay > 0 then socket.sleep(delay) end
    elseif t and t > 0 then
      socket.sleep(t)
    end
    readable, writeable = {}, {}
  end

  last = socket.gettime()

  -- check for sockets with data to read
  for _, sock in ipairs(readable) do
    local s = active[sock]
    if s and s.thread then
      -- mark as ready
      s.status = "ready"
    end
  end
  -- check for sockets ready for writing
  for _, sock in ipairs(writeable) do
    local s = active[sock]
    if s and s.thread then
      -- mark as ready
      s.status = "ready"
    end
  end

  -- check for timeouts
  nexttimer = math.huge
  for sock, s in pairs(active) do
    if s.timeout and last > s.timeout then
      s.status = "timeout"
    elseif s.timeout then
      nexttimer = math.min(nexttimer, s.timeout)
    end
  end

  -- resume threads for sockets that are ready
  for sock, s in pairs(active) do
    if s.status then
      local co = s.thread
      if co and coroutine.status(co) == "suspended" then
        s.thread = nil
        s.timeout = nil
        local status = s.status
        s.status = nil
        if timers[sock] then
          timers[sock] = nil
          active[sock] = nil
        else
          rlist[sock] = nil
          wlist[sock] = nil
        end
        local success, err = coroutine.resume(co, status == "ready", status == "timeout" and "timeout")
        if not success then
          -- catch error so the main thread doesn't die
          socket.try(
            pcall(copas.error, err, co)
          )
        end
      end
    end
  end

  -- process sockets that must be closed or removed
  for sock, how in pairs(mustshutdown) do
    mustshutdown[sock] = nil
    if active[sock] then
      socket.try(sock:shutdown(how))
      copas.remove(sock)
    end
  end
  for sock in pairs(mustclose) do
    mustclose[sock] = nil
    if active[sock] then
      socket.try(sock:close())
      copas.remove(sock)
    end
  end
  for sock in pairs(mustremove) do
    mustremove[sock] = nil
    copas.remove(sock)
  end

  -- for backwards compatibility
  return #readers + #writers
end

--- Main loop, processes all sockets and timers until there are no active sockets left.
-- or copas.status is set to 'done' or 'closed'.
-- @param t number of seconds to wait for socket.select.
function copas.loop(t)
  copas.status = "started"
  copas.running = true -- for backwards compatibility
  while copas.status == "started" do
    if not next(active) and not next(waiting) then
      copas.status = "done"
    else
      copas.step(t)
    end
  end
  copas.running = false -- for backwards compatibility
  -- cleanup
  for sock in pairs(active) do
    if type(sock) == "table" then
      socket.try(sock:close())
    end
  end
  active = {}
  rlist = {}
  wlist = {}
  waiting = {}
  timers = {}
  servers = {}
  mustclose = {}
end

--- Default error handler, prints the error message to stderr.
-- Can be replaced by a custom error handler.
-- @param err error message.
-- @param co coroutine that caused the error.
function copas.error(err, co)
  local msg = tostring(err)
  local where = debug.traceback(co or 2, msg, 2)
  io.stderr:write(where, "\n")
end

return copas
