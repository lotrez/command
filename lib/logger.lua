Logger = {}

local LOG_LEVELS = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    FATAL = 5,
    TRACE = 0
}

local current_log_level = LOG_LEVELS[CONFIG.log_level] or LOG_LEVELS.INFO

function Logger:log(level, message, component)
    if LOG_LEVELS[level] >= current_log_level then
        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        local log_message = string.format("%s :: %-5s :: %s :: %s", timestamp, level, component or "", message)
        if level == "TRACE" then
            sendTraceMessage(log_message, component)
        elseif level == "DEBUG" then
            sendDebugMessage(log_message, component)
        elseif level == "INFO" then
            sendInfoMessage(log_message, component)
        elseif level == "WARN" then
            sendWarnMessage(log_message, component)
        elseif level == "ERROR" then
            sendErrorMessage(log_message, component)
        elseif level == "FATAL" then
            sendFatalMessage(log_message, component)
        end
    end
end

function Logger:debug(message, component)
    self:log("DEBUG", message, component)
end

function Logger:info(message, component)
    self:log("INFO", message, component)
end

function Logger:warn(message, component)
    self:log("WARN", message, component)
end

function Logger:error(message, component)
    self:log("ERROR", message, component)
end

return Logger
