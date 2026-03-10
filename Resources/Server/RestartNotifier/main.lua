-- ============================================================
--  RestartNotifier V1.0 - A BeamMP plugin to notify players of scheduled server restarts with customizable warnings and manual trigger options.
--  By: DeadEndReece (UkDrifter) & Help with AI (People judge, but hey, if it does what you want thats all that matters right? - Reece 2026)
--  Please read the read me before touching any of the code, there are a lot of comments to help you understand how it works and how to customize it. If you have any questions or need help, feel free to ask in my discord. (https://discord.com/invite/WDeb9fxuhq)
-- ============================================================

-- Settings and state variables
local SETTINGS_PATH = "Resources/Server/RestartNotifier/time.txt" -- This is the path where the plugin will save and load its configuration. The plugin will create the file if it doesn't exist, and it will be overwritten with default settings on first run.

-- The AUTHORIZED_USERS table is used to keep track of which players are allowed to use the in-game commands to change settings or trigger restarts.
local AUTHORIZED_USERS = {} -- This will be empty as the data is loaded from the settings file, but it's defined here for clarity and to avoid nil reference issues.

-- This CONFIG table holds all the customizable settings for the plugin. 
-- You can change these values directly in the code, or use the in-game commands to modify them at runtime. 
-- The settings include timezone offset, daylight saving toggle, scheduled restart time, warning message formats, and more. Each setting has a comment explaining its purpose and how to use it.
local CONFIG = {
    timezone_offset       = 0,      -- Offset from UTC in hours (e.g., -5 for EST, 0 for GMT, +1 for CET)
    dst_active            = 0,      -- 0 for off, 1 for on
    restart_hour          = 0,      -- Hour of the day for scheduled restart (0-23)
    restart_min           = 0,      -- Minute of the hour for scheduled restart (0-59)
    warn_start_minutes    = 5,      -- How many minutes before the scheduled restart to start sending warnings. Set to 0 to disable minute-based warnings.
    warn_interval_minutes = 1,      -- For minute-based warnings, how often to repeat the message (in minutes). Set to 0 to only send one warning per minute threshold.
    tick_ms               = 1000,-- How often the plugin checks for restart conditions (in milliseconds). Higher frequency allows for more accurate second-based warnings but may use more resources. 1000ms is a good balance for most servers.
    warning_message       = "^l^bSCHEDULED ^l^cRESTART ^l^bIN ^l^c%d ^l^fMINUTE(S)",        -- This is used for the minute-based warnings leading up to the restart.
    seconds_warning_msg   = "^l^bSERVER ^l^cRESTART ^l^bIN ^l^c%d ^l^fSECOND(S)!",      -- This is used for the final 60 seconds countdown, separate from the minute-based warnings.
    final_message         = "^l^bSERVER ^l^cRESTARTING ^l^bNOW!",       -- This is the final message broadcasted right before the restart command is executed.
    manual_warning_msg    = "^l^bMANUAL ^l^cRESTART ^l^bIN ^l^c%d ^l^fMINUTE(S)",       -- This is used for the manual restart countdown, separate from the scheduled one.
    manual_scheduled_msg  = "^l^bA MANUAL ^l^cRESTART ^l^bHAS BEEN SCHEDULED IN ^l^c%d ^l^fMINUTE(S)",      -- This is immediately broadcasted when a manual restart is initiated.
    msg_manual_cancelled  = "^l^bMANUAL ^l^cRESTART ^l^bHAS BEEN ^l^aCANCELLED.",       -- This is sent when a manual restart is cancelled.
    msg_no_manual_cancel  = "^l^bNO MANUAL ^l^cRESTART ^l^bIS ACTIVE TO ^l^aCANCEL",        -- This is sent when a user tries to cancel a manual restart but there isn't one currently active.
    msg_no_perm_config    = "^1^cYOU DO NOT HAVE PERMISSION TO USE THAT SPECIFIC CONFIGURATION COMMAND IN-GAME.",       -- This is sent when a non-authorized user tries to use commands that change settings (like time, timezone, DST) in-game. Console commands are unaffected.
    msg_no_perm_cmd       = "^c^lYOU DO NOT HAVE PERMISSION TO USE RESTART COMMANDS.",      -- This is sent when a non-authorized user tries to use any restart command.
    msg_manual_initiated  = "^l^bMANUAL ^l^cRESTART ^l^bINITIATED.",        -- This is sent as a confirmation to the user who started the manual restart.
    console_echo          = true, 
}

-- Internal state variables
local startup_time       = os.time() 
local last_notified_min  = -1 
local last_notified_sec  = -1 
local manual_restart_at  = nil
local restart_triggered  = false 

---- TIMEZONE MAP FOR USER-FRIENDLY DISPLAY AND INPUT ----
-- You can expand this map with more timezones as needed. 
-- The key is the timezone name (for display and user input), and the value is the offset from UTC in hours. 
-- The plugin will use this to calculate local time and display it in status messages, as well as to allow users to set their timezone using familiar names instead of just numeric offsets.
local TIMEZONE_MAP = {
    ["PST"] = -8, ["MST"] = -7, ["CST"] = -6, ["EST"] = -5,
    ["GMT"] = 0,  ["CET"] = 1,  ["EET"] = 2,  ["JST"] = 9
}

-- This function takes a timezone offset and returns the corresponding name from the TIMEZONE_MAP. 
-- If the offset is not found in the map, it returns "Custom". This is used for displaying the current timezone in status messages.
local function get_timezone_name(offset)
    for name, val in pairs(TIMEZONE_MAP) do
        if val == offset then return name end
    end
    return "Custom"
end

---- SAVE/LOAD LOGIC ----
-- This function saves the current configuration and authorized users to the specified file. 
-- It writes a single line containing all the relevant data, which can be easily parsed when loading. 
-- The format is: HH:MM|TimezoneOffset|DSTActive|User1,User2,User3
local function save_settings()
    local f = io.open(SETTINGS_PATH, "w")
    if f then
        local users_list = {}
        for user, _ in pairs(AUTHORIZED_USERS) do
            table.insert(users_list, user)
        end
        local users_str = table.concat(users_list, ",")

        f:write(string.format("%02d:%02d|%d|%d|%s", 
            CONFIG.restart_hour, CONFIG.restart_min, CONFIG.timezone_offset, CONFIG.dst_active, users_str))
        f:close()
        print("[RestartNotifier] Settings saved.")
    end
end

-- This function loads the settings from the specified file. It reads the configuration line, parses it, and updates the CONFIG table and AUTHORIZED_USERS list accordingly.
local function load_settings()
    local f = io.open(SETTINGS_PATH, "r")
    if f then
        local line = f:read("*line")
        f:close()
        if line then
            local h, m, off, dst, users = line:match("(%d+):(%d+)|(%-?%d+)|(%d+)|(.*)")
            
            if not h then
                h, m, off, dst = line:match("(%d+):(%d+)|(%-?%d+)|(%d+)")
                users = ""
            end

            if h then
                CONFIG.restart_hour = tonumber(h)
                CONFIG.restart_min  = tonumber(m)
                CONFIG.timezone_offset = tonumber(off)
                CONFIG.dst_active = tonumber(dst) or 0
                
                AUTHORIZED_USERS = {}
                if users and users ~= "" then
                    for user in string.gmatch(users, "([^,]+)") do
                        AUTHORIZED_USERS[user] = true
                    end
                end

                print(string.format("[RestartNotifier] Loaded: %02d:%02d (Zone: %s, DST: %s)", 
                    h, m, get_timezone_name(CONFIG.timezone_offset), (CONFIG.dst_active == 1 and "ON" or "OFF")))
            end
        end
    else
        print("[RestartNotifier] No time.txt found. Building default config (00:00, GMT)...")
        CONFIG.restart_hour = 0
        CONFIG.restart_min = 0
        CONFIG.timezone_offset = 0
        CONFIG.dst_active = 0
        save_settings()
    end
end

--- UTILITY FUNCTIONS ----

-- This function handles broadcasting messages to all players. It also optionally echoes the message to the server console based on the configuration.
local function broadcast(msg)
    if CONFIG.console_echo then print("[RestartNotifier] " .. msg) end
    MP.SendChatMessage(-1, msg)
end

-- This function is used to send a message back to a specific player, usually as a response to a command they issued. It also prints the message to the server console for logging purposes.
local function reply(sender_id, msg)
    print("[RestartNotifier] " .. msg)
    if sender_id then
        MP.SendChatMessage(sender_id, msg)
    end
end

-- This function calculates the number of minutes until the next scheduled restart time, taking into account the configured timezone and daylight saving settings. 
-- It returns the number of minutes as an integer. If the target time has already passed for the current day, it will calculate the time until the target on the next day.
local function get_minutes_until_target()
    local t_utc = os.date("!*t", os.time())
    local now_mins_utc = (t_utc.hour * 60) + t_utc.min
    local total_offset = CONFIG.timezone_offset + CONFIG.dst_active
    local target_mins_utc = (CONFIG.restart_hour * 60) + CONFIG.restart_min - (total_offset * 60)
    
    local diff = target_mins_utc - now_mins_utc
    while diff <= 0 do diff = diff + 1440 end
    return diff
end

-- This function processes commands issued by players or the console. It checks the command against known patterns, validates permissions, and executes the appropriate actions such as scheduling a manual restart, cancelling it, changing settings, or providing status information. 
-- The function also handles sending feedback messages to the command issuer and broadcasting relevant information to all players when necessary.
local function ProcessCommand(args, sender_id)
    local command = args[1]:lower()

    if sender_id ~= nil then
        if command ~= "restart.status" and command ~= "r.s" and
           command ~= "restart.firein" and command ~= "r.f" and
           command ~= "restart.cancel" and command ~= "r.c" and
           command ~= "restart.help"   and command ~= "r.h" then
            reply(sender_id, CONFIG.msg_no_perm_config)
            return
        end
    end

    if command == "restart.help" or command == "r.h" then
        if sender_id then
            reply(sender_id, "---------- RestartNotifier (In-Game) ----------")
            reply(sender_id, "restart.status (r.s)             - Current status & countdown")
            reply(sender_id, "restart.firein (r.f) <mins>      - Start manual countdown")
            reply(sender_id, "restart.cancel (r.c)             - Cancel manual countdown")
            reply(sender_id, "-----------------------------------------------")
        else
            print("-------------------- RestartNotifier Commands --------------------")
            print("restart.status (r.s)             - Current status & countdown")
            print("restart.settime (r.st) HH:MM     - Set daily restart time")
            print("restart.settimezone (r.sz) <name>- Set timezone (EST, GMT, CET")
            print("restart.zones (r.z)              - List available timezones")
            print("restart.dst (r.dst) <on/off>     - Toggle Daylight Saving (+1 hr)")
            print("restart.firein (r.f) <mins>      - Start manual countdown")
            print("restart.cancel (r.c)             - Cancel manual countdown")
            print("restart.adduser (r.au) <name>    - Add auth player (Console Only)")
            print("restart.removeuser (r.ru) <name> - Remove auth player (Console Only)")
            print("restart.users (r.us)             - List auth players (Console Only)")
            print("------------------------------------------------------------------")
        end


    elseif command == "restart.adduser" or command == "r.au" then
        if sender_id ~= nil then return end -- Extra safety net
        local new_user = args[2]
        if new_user then
            AUTHORIZED_USERS[new_user] = true
            save_settings()
            print("[RestartNotifier] Added " .. new_user .. " to authorized users.")
        else
            print("[RestartNotifier] Usage: restart.adduser <name>")
        end

    elseif command == "restart.removeuser" or command == "r.ru" then
        if sender_id ~= nil then return end
        local del_user = args[2]
        if del_user then
            if AUTHORIZED_USERS[del_user] then
                AUTHORIZED_USERS[del_user] = nil
                save_settings()
                print("[RestartNotifier] Removed " .. del_user .. " from authorized users.")
            else
                print("[RestartNotifier] User " .. del_user .. " is not in the list.")
            end
        else
            print("[RestartNotifier] Usage: restart.removeuser <name>")
        end

    elseif command == "restart.users" or command == "r.us" then
        if sender_id ~= nil then return end
        print("---------- Authorized Users ----------")
        local count = 0
        for u, _ in pairs(AUTHORIZED_USERS) do
            print("- " .. u)
            count = count + 1
        end
        if count == 0 then print("No authorized users found.") end
        print("--------------------------------------")
    
    elseif command == "restart.zones" or command == "r.z" then
        print("-- Timezones --")
        local zones = {}
        for name, offset in pairs(TIMEZONE_MAP) do
            local sign = offset >= 0 and "+" or ""
            table.insert(zones, string.format("%s (UTC%s%d)", name, sign, offset))
        end
        table.sort(zones)
        for _, zone_info in ipairs(zones) do
            print(zone_info)
        end
        print("---------------")

    elseif command == "restart.dst" or command == "r.dst" then
        if args[2] == "on" then
            CONFIG.dst_active = 1
            save_settings()
            print("[RestartNotifier] Daylight Saving enabled (+1 hour applied).")
        elseif args[2] == "off" then
            CONFIG.dst_active = 0
            save_settings()
            print("[RestartNotifier] Daylight Saving disabled.")
        else
            print("[RestartNotifier] Usage: restart.dst on OR restart.dst off")
        end

    elseif command == "restart.settimezone" or command == "r.sz" then
        local input = args[2] and args[2]:upper() or ""
        local new_off = TIMEZONE_MAP[input] or tonumber(input)
        if new_off then
            CONFIG.timezone_offset = new_off
            save_settings()
            print(string.format("[RestartNotifier] Zone set to %s", get_timezone_name(new_off)))
        else
            print("[RestartNotifier] Invalid timezone.")
        end

    elseif command == "restart.settime" or command == "r.st" then
        local h, m = (args[2] or ""):match("(%d+):(%d+)")
        if h and m then
            CONFIG.restart_hour = tonumber(h)
            CONFIG.restart_min = tonumber(m)
            save_settings()
            print(string.format("[RestartNotifier] Daily restart set to %02d:%02d", CONFIG.restart_hour, CONFIG.restart_min))
        else
            print("[RestartNotifier] Usage: restart.settime HH:MM")
        end

    elseif command == "restart.firein" or command == "r.f" then
        local mins = tonumber(args[2])
        if mins and mins >= 1 then
            manual_restart_at = os.time() + (mins * 60)
            last_notified_min = mins
            last_notified_sec = -1 
            broadcast(string.format(CONFIG.manual_scheduled_msg, mins))
            if sender_id then reply(sender_id, CONFIG.msg_manual_initiated) end
        else
            reply(sender_id, "Usage: r.f or restart.firein <minutes>")
        end

    elseif command == "restart.cancel" or command == "r.c" then
        if manual_restart_at then
            manual_restart_at = nil
            last_notified_min = -1
            last_notified_sec = -1 
            broadcast(CONFIG.msg_manual_cancelled)
        else
            reply(sender_id, CONFIG.msg_no_manual_cancel)
        end

    elseif command == "restart.status" or command == "r.s" then
        local diff = get_minutes_until_target()
        local t_utc = os.date("!*t", os.time())
        local total_offset = CONFIG.timezone_offset + CONFIG.dst_active
        local local_hr = (t_utc.hour + total_offset) % 24
        
        reply(sender_id, "---------- RestartNotifier Status ----------")
        reply(sender_id, string.format("Local Time Now   : %02d:%02d (%s%s)", 
            local_hr, t_utc.min, get_timezone_name(CONFIG.timezone_offset), (CONFIG.dst_active == 1 and "+DST" or "")))
        
        if manual_restart_at then
            local left = math.ceil((manual_restart_at - os.time()) / 60)
            reply(sender_id, string.format("MANUAL RESTART   : In %d minutes", left))
        else
            reply(sender_id, string.format("Scheduled Target : %02d:%02d", CONFIG.restart_hour, CONFIG.restart_min))
            reply(sender_id, string.format("Time Remaining   : %dh %dm", math.floor(diff / 60), diff % 60))
        end
        reply(sender_id, "--------------------------------------------")
    end
end

-- This function is called on every tick (based on the configured tick_ms interval) and is responsible for checking if it's time to send warnings or execute the restart. 
-- It handles both the scheduled restart logic and the manual restart logic, sending appropriate messages to players as the time approaches. 
-- It also ensures that the final restart command is only executed once when the time comes.
function OnRestartTick()
    if manual_restart_at then
        local secs_left = manual_restart_at - os.time()
        if secs_left <= 0 then
            if not restart_triggered then
                restart_triggered = true
                broadcast(CONFIG.final_message)
                MP.Sleep(5000)
                exit()
            end
            return
        end
        
        if secs_left < 60 then
            local sec_bucket = math.ceil(secs_left / 10) * 10
            if sec_bucket <= 50 and sec_bucket ~= last_notified_sec and sec_bucket > 0 then
                last_notified_sec = sec_bucket
                broadcast(string.format(CONFIG.seconds_warning_msg, sec_bucket))
            end
        else
            local mins = math.ceil(secs_left / 60)
            if mins ~= last_notified_min then
                last_notified_min = mins
                broadcast(string.format(CONFIG.manual_warning_msg, mins))
            end
        end
        return 
    end

    local diff = get_minutes_until_target()
    
    if diff == 1440 and (os.time() - startup_time) > 90 then
        if not restart_triggered then
            restart_triggered = true
            broadcast(CONFIG.final_message)
            MP.Sleep(5000)
            exit()
        end
    elseif diff == 1 then
        local t_utc = os.date("!*t", os.time())
        local secs_left = 60 - t_utc.sec
        local sec_bucket = math.ceil(secs_left / 10) * 10
        
        if sec_bucket <= 50 and sec_bucket ~= last_notified_sec and sec_bucket > 0 then
            last_notified_sec = sec_bucket
            broadcast(string.format(CONFIG.seconds_warning_msg, sec_bucket))
        elseif sec_bucket == 60 and last_notified_min ~= 1 then
            last_notified_min = 1
            broadcast(string.format(CONFIG.warning_message, 1))
        end
    elseif diff <= CONFIG.warn_start_minutes and diff ~= last_notified_min then
        last_notified_min = diff
        broadcast(string.format(CONFIG.warning_message, diff))
    end
end

-- This function is called whenever a command is entered in the server console. It parses the command and its arguments, and then passes them to the ProcessCommand function for handling.
function OnConsoleInput(cmd)
    local args = {}
    for word in cmd:gmatch("%S+") do table.insert(args, word) end
    if #args == 0 then return end
    
    ProcessCommand(args, nil)
end

-- This function is called whenever a chat message is sent by a player. It checks if the message is a command (starts with "/"), and if so, it parses the command and its arguments. 
-- It then checks if the command is one of the restart-related commands and if the sender has permission to execute it. 
-- If the sender is authorized, it processes the command; otherwise, it sends a no-permission message back to the sender.
function OnChatMessage(sender_id, sender_name, message)
    if message:sub(1, 1) == "/" then
        local cmd = message:sub(2) 
        local args = {}
        for word in cmd:gmatch("%S+") do table.insert(args, word) end
        if #args == 0 then return end
        
        local command = args[1]:lower()
        
        if command:match("^restart%.") or command:match("^r%.") then
            if AUTHORIZED_USERS[sender_name] then
                ProcessCommand(args, sender_id)
            else
                MP.SendChatMessage(sender_id, CONFIG.msg_no_perm_cmd)
            end
            
            return 1 
        end
    end
end

-- Initialization
load_settings()
MP.RegisterEvent("onConsoleInput", "OnConsoleInput")
MP.RegisterEvent("onChatMessage", "OnChatMessage") 
MP.RegisterEvent("OnRestartTick", "OnRestartTick")
MP.CreateEventTimer("OnRestartTick", CONFIG.tick_ms)