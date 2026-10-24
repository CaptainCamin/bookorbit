--[[--
Hardcover sign-in for the catalog: the OAuth device grant, token storage and
refresh. Adapted from HardcoverSync.koplugin's hardcover/lib/auth.lua.

Tokens live in their own settings file, never in the BookOrbit settings. A
refresh token is single-use and a replay revokes the whole chain, so every read
goes back to the file: a catalog request may refresh inside a forked child,
and the parent must see the replacement rather than spend the old one again.

Scopes are read-only. The catalog never writes to a Hardcover account.
]]

local logger = require("logger")

local OAuth = require("bookorbit_hardcover_oauth")
local OAuthClient = require("bookorbit_hardcover_oauth_client")

local SETTINGS_FILE = "bookorbit_hardcover_auth.lua"

-- HardcoverSync's registered OAuth app. A client id is public (the device grant
-- is what protects the account), but the consent screen names that app, so a
-- BookOrbit-specific app can replace it through the hardcover_client_id setting.
local DEFAULT_CLIENT_ID = "636a2d1e-c265-45cb-9811-7452d6e49240"
local DEFAULT_SCOPE = "read:catalog read:catalog:search read:me:content read:library read:journal"

local TOKEN_KEYS = { "access_token", "refresh_token", "token_type", "expires_at", "obtained_at", "scope" }

local Auth = {}
Auth.__index = Auth
Auth.DEFAULT_CLIENT_ID = DEFAULT_CLIENT_ID
Auth.DEFAULT_SCOPE = DEFAULT_SCOPE

-- opts: client_id, scope, client (OAuthClient), open_settings (path -> settings).
function Auth.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Auth)
    self.client_id = (opts.client_id and opts.client_id ~= "") and opts.client_id or DEFAULT_CLIENT_ID
    self.scope = opts.scope or DEFAULT_SCOPE
    self.client = opts.client or OAuthClient
    self.open_settings = opts.open_settings or function(path)
        return require("luasettings"):open(path)
    end
    self.path = opts.path or (require("datastorage"):getSettingsDir() .. "/" .. SETTINGS_FILE)
    self.guard = OAuth.RefreshGuard()
    self:reload()
    return self
end

function Auth:reload()
    self.settings = self.open_settings(self.path)
    local access_token = self.settings:readSetting("access_token")
    if not access_token then
        self.tokens = nil
        return nil
    end
    self.tokens = {
        access_token = access_token,
        refresh_token = self.settings:readSetting("refresh_token"),
        token_type = self.settings:readSetting("token_type") or "Bearer",
        expires_at = self.settings:readSetting("expires_at"),
        obtained_at = self.settings:readSetting("obtained_at"),
        scope = self.settings:readSetting("scope"),
    }
    return self.tokens
end

function Auth:persist(tokens)
    if not OAuth.shouldPersist(tokens, self.tokens) then return false end
    -- The refresh token goes first: lose it and the reader has to consent again.
    self.settings:saveSetting("refresh_token", tokens.refresh_token)
    for _i, key in ipairs(TOKEN_KEYS) do
        if key ~= "refresh_token" then self.settings:saveSetting(key, tokens[key]) end
    end
    self.settings:flush()
    self.tokens = tokens
    return true
end

-- The Hardcover user id, kept beside the tokens so list queries need no extra
-- request. It goes when the tokens do: a different account may sign in next.
function Auth:cachedUserId()
    self:reload()
    return tonumber(self.settings:readSetting("user_id"))
end

function Auth:rememberUserId(id)
    self.settings:saveSetting("user_id", id)
    self.settings:flush()
end

function Auth:clear()
    self.settings:saveSetting("user_id", nil)
    for _i, key in ipairs(TOKEN_KEYS) do self.settings:saveSetting(key, nil) end
    self.settings:flush()
    self.tokens = nil
    self.guard = OAuth.RefreshGuard()
end

-- True while a sign-in exists that can still produce a token.
function Auth:isSignedIn()
    self:reload()
    return self.tokens ~= nil and not OAuth.needsReauth(self.guard, self.tokens)
end

function Auth:needsReauth()
    self:reload()
    return OAuth.needsReauth(self.guard, self.tokens)
end

-- The Bearer token to send, refreshed first when it is about to lapse. nil
-- means sign in again (or the refresh outcome is unknown and is not retried).
function Auth:accessToken()
    self:reload()
    local action = OAuth.preflight(self.tokens)
    if action == "use" then return self.tokens.access_token end
    if action == "refresh" then return self:refresh() end
    return nil
end

-- At most one refresh, never retried: a second try with a spent token would
-- get the chain revoked.
function Auth:refresh()
    if not OAuth.canStartRefresh(self.guard) then return nil end
    if not OAuth.canRefresh(self.tokens) then return nil end
    OAuth.beginRefresh(self.guard)

    local called, outcome, body = pcall(self.client.refresh, self.client, self.client_id, self.tokens.refresh_token)
    if not called then
        logger.warn("BookOrbit: Hardcover refresh raised, outcome unknown", outcome)
        OAuth.endRefresh(self.guard, "unknown")
        return nil
    end

    if outcome == "ok" then
        local fresh = OAuth.applyRefresh(self.tokens, body, os.time())
        self:persist(fresh)
        OAuth.endRefresh(self.guard, "ok")
        return fresh.access_token
    end

    local code = body and body.error
    if code == "timeout" or code == "bad_response" or (type(code) == "string" and code:match("^http_5")) then
        OAuth.endRefresh(self.guard, "unknown")
        return nil
    end

    OAuth.endRefresh(self.guard, "error")
    if code == "invalid_grant" then self:clear() end
    return nil
end

-- Hardcover answered 401: treat the access token as lapsed so the next call
-- refreshes. The refresh token may still be good.
function Auth:invalidateAccessToken()
    self:reload()
    if not self.tokens then return end
    self.tokens.expires_at = 0
    self.settings:saveSetting("expires_at", 0)
    self.settings:flush()
end

function Auth:beginDeviceFlow()
    local device, err = self.client:startDeviceFlow(self.client_id, self.scope)
    if not device then
        logger.warn("BookOrbit: Hardcover device flow failed", err and err.error)
        return nil, err
    end
    self.device = device
    self.device_started_at = os.time()
    return device
end

-- One poll. Returns the outcome (success, pending, slow_down, denied, expired, error).
function Auth:pollOnce()
    if not self.device then return "error" end
    if OAuth.isExpired(os.time(), self.device.expires_in, self.device_started_at) then
        self.device = nil
        return "expired"
    end

    local outcome, body = self.client:pollToken(self.client_id, self.device.device_code)
    if outcome == "success" then
        local tokens = OAuth.tokenSetFrom(body, os.time())
        if tokens then
            self.tokens = nil
            self:persist(tokens)
            self.guard = OAuth.RefreshGuard()
            self.device = nil
            return "success"
        end
        outcome = "error"
    end
    if outcome == "denied" or outcome == "expired" or outcome == "error" then
        self.device = nil
    end
    return outcome
end

function Auth:pollDelay(outcome)
    return OAuth.nextPollDelay(self.device and self.device.interval or 5, outcome)
end

-- Revokes on Hardcover's side first, so the app also leaves the reader's
-- Authorized Apps page, then forgets the tokens.
function Auth:signOut()
    self:reload()
    local tokens = self.tokens
    if tokens then
        local token = tokens.refresh_token or tokens.access_token
        pcall(self.client.revoke, self.client, self.client_id, token, tokens.refresh_token and "refresh_token" or "access_token")
    end
    self:clear()
end

return Auth
