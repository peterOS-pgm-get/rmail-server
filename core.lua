if _G.pgm.rmail_server then
    _G.pgm.rmail_server.unregister()
end

local sha256 = pos.require("hash.sha256")
local log = pos.Logger('rmail-server.log')
log:info('Starting rmail-server')
local cfg = {
    db = {
        url = 'database.lan',
        name = 'rmail',
        user = 'rmail',
        password = 'rmail'
    },
    hostname = ''
}
local cfgPath = '/home/.appdata/rmail-server/cfg.json'
if not fs.exists(cfgPath) then
    log:warn('Could not find config file, creating one at ' .. cfgPath)
    local f = fs.open(cfgPath, 'w')
    if not f then
        log:error('Could not write to config file, using default configuration')
    else
        f.write(textutils.serialiseJSON(cfg))
        log:info('Created config file from default')
    end
else
    local f = fs.open(cfgPath, 'r')
    if not f then
        log:fatal('Could not read config file at ' .. cfgPath)
        return
    end
    cfg = textutils.unserialiseJSON(f.readAll())
    f.close()
    if not cfg then
        log:fatal('Config file was corrupted')
        return
    end
    log:info('Loaded configuration from file')
end

if not net.setup() then
    log:fatal('Net module was unavailable')
    return
end

net.open(net.standardPorts.rmail)

local db = netdb.open(cfg.db.url, cfg.db.name)
if not db then
    log:fatal('Could not connect to database')
    return
end
db:setCredentials(cfg.db.user, cfg.db.password)

---@class RMail.DBUser
---@field name string
---@field pHash string

---Get user data by name
---@param userName string
---@return RMail.DBUser?
local function getUser(userName)
    log:debug('Getting user info for ' .. userName)
    local s, r = db:run('SELECT * FROM users WHERE name = "' .. userName .. '"')
    if not s then
        log:error('DB error: ' .. r .. '; ' .. debug.traceback())
        return nil
    end
    return r[1]
end

---Verify if provided user data is correct
---@param user RMail.User
---@return RMail.DBUser?
local function authUser(user)
    local u = getUser(user.name)
    if not u then
        return nil
    end
    -- do hash thing here
    local pHash = sha256.hash(user.pass)
    if pHash ~= u.pHash then
        return nil
    end
    return u
end

---Get a new UUID string for mail
---@return string uuid
local function getNewUUID()
    return cfg.hostname .. "." .. tostring(os.epoch('utc'))
end

---Store new mail to the database
---@param mail RMail.Mail
---@return boolean stored
local function storeMail(mail)
    local s, r = db:run('INSERT INTO mail uuid, time, from, to, subject, body VALUES "' ..
        mail.uuid .. '", ' .. mail.time .. ', "' .. mail.from ..
        '", "' .. textutils.serialiseJSON(mail.to) .. '", "' .. mail.subject .. '", "' .. mail.body .. '"')
    if not s then
        log:error('DB error: ' .. r .. '; ' .. debug.traceback())
        return false
    end
    s, r = db:run('INSERT INTO recipients uuid, user VALUES "' .. mail.uuid .. '", "' .. mail.from .. '"')
    if not s then
        log:error('DB error: ' .. r .. '; ' .. debug.traceback())
        return false
    end
    for _, u in pairs(mail.to) do
        s, r = db:run('INSERT INTO recipients uuid, user VALUES "' .. mail.uuid .. '", "' .. u .. '"')
        if not s then
            log:error('DB error: ' .. r .. '; ' .. debug.traceback())
            return false
        end
    end
    return true
end

---Get mail from database by UUID
---@param uuid string
---@return RMail.Mail?
local function getMailByUUID(uuid)
    local s, r = db:run('SELECT * FROM mail WHERE uuid = "' .. uuid .. '"')
    if not s then
        log:error('DB error: ' .. r .. '; ' .. debug.traceback())
        return nil
    end
    if not r[1] then
        return nil
    end
    r[1].to = textutils.unserialiseJSON(r[1].to)
    return r[1]
end
---Get all mail for user
---@param user string Username
---@return RMail.Mail[]? mail
---@return { [string]: boolean }? read
local function getMailByUser(user)
    local s, r = db:run('SELECT uuid FROM recipients WHERE user = "' .. user .. '@' .. cfg.hostname .. '"')
    if not s then
        log:error('DB error: ' .. r .. '; ' .. debug.traceback())
        return nil
    end
    ---@cast r table
    local uuids = r

    local uuidList = ''
    for i, el in pairs(uuids) do
        if i > 1 then
            uuidList = uuidList .. ','
        end
        uuidList = uuidList .. '"' .. el.uuid .. '"'
    end
    s, r = db:run('SELECT uuid, time, to, from, subject FROM mail WHERE uuid IN (' .. uuidList .. ')')
    if not s then
        log:error('DB error: ' .. r .. '; ' .. debug.traceback())
        return nil
    end
    ---@cast r table
    local mail = {}
    for _, m in pairs(r) do
        m.to = textutils.unserialiseJSON(m.to)
        mail[m.uuid] = m
    end

    s, r = db:run('SELECT uuid FROM read WHERE user = "' .. user .. '@' .. cfg.hostname .. '"')
    if not s then
        log:error('DB error: ' .. r .. '; ' .. debug.traceback())
        return nil
    end
    ---@cast r table
    local read = {}
    for _, el in pairs(r) do
        read[el.uuid] = true
    end
    return mail, read
end

---Mark mail as read by user by UUID
---@param uuid string
---@param user RMail.DBUser
---@return boolean marked
local function markRead(uuid, user)
    local s, r = db:run('INSERT INTO read uuid, user VALUES "' ..
        uuid .. '", "' .. user.name .. '@' .. cfg.hostname .. '"')
    if not s then
        log:error('DB error: ' .. r .. '; ' .. debug.traceback())
        return false
    end
    return true
end

---Respond to message with failure
---@param msg RMail.Messages.Client
---@param type RMail.Messages.Server.RType
---@param text string
local function respondFail(msg, type, text)
    msg:reply(net.standardPorts.rmail,
        { type = "rmail", cmpt = false, rtype = type, rtext = text }, {})
end

---Handle net message
---@param msg NetMessage
local function handleMessage(msg)
    if msg.port ~= net.standardPorts.rmail or msg.header.type ~= "rmail" then return end
    ---@cast msg RMail.Messages.Client

    if not msg.body.user then
        respondFail(msg, 'MALFORMED_REQUEST', 'Must include `user` in body'); return
    end
    if not msg.body.user.name then
        respondFail(msg, 'MALFORMED_REQUEST', 'Must include `name` in `user`'); return
    end
    if not msg.body.user.pass then
        respondFail(msg, 'MALFORMED_REQUEST', 'Must include `pass` in `user`'); return
    end

    local user = authUser(msg.body.user)
    if user == nil then
        -- respondFail(message.origin, "INVALID_CREDENTIALS")
        net.reply(net.standardPorts.rmail, msg, { type = "rmail", cmpt = false, rtype = "INVALID_CREDENTIALS" }, {})
        return true
    end

    if msg.header.method == "SEND" then
        local mail = msg.body.mail
        ---@cast mail -?
        for i = 1, #mail.to do
            local to = mail.to[i]
            local toA = to:split("@")
            if #toA == 1 or toA[2] == cfg.hostname then
                local u2 = getUser(toA[1])
                if u2 == nil then
                    -- respondFail(message.origin, "UNKNOWN_USER", to)
                    net.reply(net.standardPorts.rmail, msg, {
                        type = "rmail",
                        cmpt = false,
                        rtype = "UNKNOWN_USER",
                        rtext = to
                    }, {})
                    return
                end
            else
                -- This means that it is a user on a different server
                -- We need to check if they exist, but for now, I think that I will not implement this
                respondFail(msg, 'OUT_OF_DOMAIN', 'Address ' .. to .. ' is not under this mail server')
                log:warn('Someone tried to send mail to a address outside this domain')
                log:warn('- This is not yet supported, and has canceled message send')
                return
            end
        end

        ---@cast mail +RMail.Mail
        ---@cast mail -RMail.Messages.Client.Mail
        mail.from = user.name .. "@" .. cfg.hostname
        mail.uuid = getNewUUID()
        mail.time = os.epoch('utc')

        if not storeMail(mail) then
            net.reply(net.standardPorts.rmail, msg,
                { type = "rmail", cmpt = false, rtype = "INTERNAL_ERROR", rtext = 'Could not store mail to database' },
                {})
            return
        end
        net.reply(net.standardPorts.rmail, msg, { type = "rmail", cmpt = true, rtype = "SENT" }, { mailUUID = mail.uuid })
        return true
    elseif msg.header.method == "GET" then
        local uuid = msg.body.mailUUID ---@cast uuid -?
        local canGet = false
        local mail = getMailByUUID(uuid)
        if not mail then
            net.reply(net.standardPorts.rmail, msg,
                { type = "rmail", cmpt = false, rtype = "INVALID_UUID", rtext = "No mail with uuid " .. uuid }, {})
            return
        end
        local uName = user.name .. "@" .. cfg.hostname
        if mail.from == uName then
            canGet = true
        else
            for _, u in pairs(mail.to) do
                if u == uName then
                    canGet = true
                    break
                end
            end
        end

        if not canGet then
            respondFail(msg, "UNAUTHORIZED", "You do not have access to the mail with uuid " .. uuid)
            return
        end
        net.reply(net.standardPorts.rmail, msg, { type = "rmail", cmpt = true, rtype = "MAIL", }, { mail = mail })
        return
    elseif msg.header.method == "LIST" then
        local list, read = getMailByUser(user.name)
        if not list then
            respondFail(msg, 'INTERNAL_ERROR', 'Could not load mail list')
            return
        end
        net.reply(net.standardPorts.rmail, msg, { type = "rmail", cmpt = true, rtype = "LIST" },
            { list = list, read = read })
        return
    elseif msg.header.method == 'MARK_READ' then
        if not markRead(msg.body.uuid, user) then
            respondFail(msg, 'INTERNAL_ERROR', 'Database error')
            return
        end
        net.reply(net.standardPorts.rmail, msg, { type = 'rmail', cmpt = true, rtype = 'OK' }, {})
        return
    end
    respondFail(msg, 'UNKNOWN_METHOD', 'Method "' .. msg.header.method .. '" is not valid')
end

local handlerId = net.registerMsgHandler(handleMessage)
log:info('Started rmail-server')

_G.pgm.rmail_server = {}
function _G.pgm.rmail_server.unregister()
    net.unregisterMsgHandler(handlerId)
end
