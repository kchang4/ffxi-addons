addon.name      = 'FFXI-AI'
addon.author    = 'Jules'
addon.version   = '0.1'
addon.desc      = 'Integrates with Ollama to bring AI to FFXI.'
addon.link      = ''

require('common')
local http = require('socket.http')
local ltn12 = require('ltn12')
local json = require('json')

local OLLAMA_URL = 'http://localhost:11434/api/generate'
local DEFAULT_MODEL = 'llama3'

function send_prompt(prompt, model)
    model = model or DEFAULT_MODEL
    local data = {
        model = model,
        prompt = prompt,
        stream = false
    }
    local request_body = json.stringify(data)

    local response_body = {}
    local res, code, headers, status = http.request{
        url = OLLAMA_URL,
        method = "POST",
        headers = {
            ["content-type"] = "application/json",
            ["content-length"] = #request_body
        },
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_body)
    }

    if res then
        local body = json.parse(table.concat(response_body))
        return body.response
    else
        return 'Error communicating with Ollama: ' .. tostring(code)
    end
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args()
    if (#args == 0) then
        return
    end

    if (string.lower(args[1]) ~= '/ask') then
        return
    end

    e.blocked = true

    -- Check for a model specified with -m or --model
    local model = nil
    local prompt_args = {}
    for i = 2, #args do
        if (args[i] == '-m' or args[i] == '--model') and args[i+1] then
            model = args[i+1]
            i = i + 1 -- Skip the model name argument
        else
            table.insert(prompt_args, args[i])
        end
    end
    local prompt = table.concat(prompt_args, ' ')

    print('Sending prompt to AI...')
    local response = send_prompt(prompt, model)
    print('[AI] ' .. response)
end)
