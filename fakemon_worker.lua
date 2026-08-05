require("love.thread")
require("love.system")
require("love.filesystem")
require("love.data")
require("love.image")

local channelName, requestBody, contextBody, tag = ...
local channel = love.thread.getChannel(channelName)
local ok, Client = pcall(require, "mods.nvidia_fakemon.fakemon_client")
if not ok then
  channel:push('{"ok":false,"error":"could not load Fakemon NIM client"}')
  return
end

local Json = require("src.link.Json")
local context = Json.decode(contextBody or "{}") or {}
local ran, body, err = pcall(Client.perform, requestBody, tag)
if not ran then
  channel:push(Client.encodeEnvelope(false, body))
elseif not body then
  channel:push(Client.encodeEnvelope(false, err))
else
  local pipelineOk, Pipeline = pcall(require, "mods.nvidia_fakemon.fakemon_pipeline")
  if not pipelineOk then
    channel:push(Client.encodeEnvelope(false, "could not load Fakemon image pipeline"))
    return
  end
  local completed, result, pipelineErr = pcall(Pipeline.fromCompletion, body, context, tag)
  if not completed then
    channel:push(Client.encodeEnvelope(false, result))
  elseif result then
    channel:push(Client.encodeEnvelope(true, result))
  else
    channel:push(Client.encodeEnvelope(false, pipelineErr))
  end
end
