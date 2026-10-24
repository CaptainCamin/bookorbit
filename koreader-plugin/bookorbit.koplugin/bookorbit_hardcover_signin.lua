--[[--
The Hardcover sign-in screen: shows the device code, then polls on the interval
Hardcover asked for until the reader approves, declines or cancels.

Polling runs on UIManager timers, so KOReader stays responsive and Cancel
works. Tokens are stored by bookorbit_hardcover_auth.
]]

local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

local Toast = setmetatable({}, { __index = function(_t, k) return require("bookorbit_toast")[k] end })

local SignIn = {}

local function codeText(device)
    local minutes = tonumber(device.expires_in)
    return T(_("1. Open %1 on any device\n2. Enter this code:\n\n%2\n\n3. Approve the request. This screen carries on by itself.%3"),
        device.verification_uri or "hardcover.app/device",
        device.user_code,
        minutes and T(_("\n\nThe code works for %1 minutes."), math.max(1, math.floor(minutes / 60 + 0.5))) or "")
end

-- on_done(true) after a successful sign-in; on_done(false) otherwise.
function SignIn.start(auth, on_done)
    NetworkMgr:runWhenConnected(function()
        local pill = Toast.loading(_("Contacting Hardcover…"), { dismissable = false })
        local device, err = auth:beginDeviceFlow()
        pill:close()
        if not device then
            Toast.error(err and err.error == "timeout" and _("Hardcover took too long to answer. Try again.")
                or _("Could not start the Hardcover sign-in."))
            if on_done then on_done(false) end
            return
        end

        local cancelled = false
        local dialog
        local function finish(ok, message)
            cancelled = true
            if dialog then UIManager:close(dialog) end
            if message then
                if ok then Toast.show(message) else Toast.error(message) end
            end
            if on_done then on_done(ok) end
        end

        dialog = InfoMessage:new{
            text = codeText(device),
            show_icon = false,
            dismissable = true,
            dismiss_callback = function()
                if not cancelled then finish(false) end
            end,
        }
        UIManager:show(dialog)

        local function poll()
            if cancelled then return end
            local outcome = auth:pollOnce()
            if outcome == "success" then
                finish(true, _("Signed in to Hardcover"))
            elseif outcome == "denied" then
                finish(false, _("Hardcover sign-in was declined."))
            elseif outcome == "expired" then
                finish(false, _("The code expired. Try signing in again."))
            elseif outcome == "error" then
                finish(false, _("Could not sign in to Hardcover."))
            else
                UIManager:scheduleIn(auth:pollDelay(outcome), poll)
            end
        end
        UIManager:scheduleIn(auth:pollDelay("pending"), poll)
    end)
end

return SignIn
