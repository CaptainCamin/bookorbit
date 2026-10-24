--[[--
Reading days from Hardcover, merged with this device's own statistics.

The device is exact (real seconds, real day) for what it saw; Hardcover covers
every device but counts pages and dates them when the sync landed. The two are
never added for the same reading: each Hardcover progress step covers the
interval since the previous step of that book, and when the device has reading
inside that interval worth at least half of what the step needs, the step is
"witnessed" and dropped. What is left happened elsewhere. See
combined-reading-stats-design.md.

Pure functions over plain tables, so they run under a test with no KOReader.
]]

local Stats = {}

local DAY = 86400
-- One step larger than this, or spread over more than two days, is a catch-up
-- (an offline sync, a manual page entry), not a day of reading.
Stats.BULK_PAGES = 150
Stats.BULK_DAYS = 2
Stats.WITNESS_SHARE = 0.5
Stats.WINDOW_DAYS = 364
-- Longest interval walked day by day when asking the device about it.
local MAX_INTERVAL_DAYS = 31

-- UTC seconds of "2026-10-17T17:45:24.611758+00:00" or "...Z" or a plain day.
function Stats.parseTime(value)
    if type(value) ~= "string" then return nil end
    local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    local hh, mm, ss = value:match("T(%d%d):(%d%d):(%d%d)")
    -- days from civil (Howard Hinnant), so no os.time and no timezone
    local yy = m <= 2 and y - 1 or y
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    local seconds = days * DAY + (tonumber(hh) or 0) * 3600 + (tonumber(mm) or 0) * 60 + (tonumber(ss) or 0)
    local sign, oh, om = value:match("([+-])(%d%d):?(%d%d)$")
    if sign and value:find("T", 1, true) then
        local offset = tonumber(oh) * 3600 + tonumber(om) * 60
        seconds = seconds - (sign == "+" and offset or -offset)
    end
    return seconds
end

local function dateKey(t)
    return os.date("%Y-%m-%d", t)
end
Stats.dateKey = dateKey

function Stats.newState()
    return { watermark = nil, last = {}, days = {} }
end

local function stepKey(row)
    local meta = type(row.metadata) == "table" and row.metadata or {}
    return meta.user_book_read_id and ("r" .. meta.user_book_read_id) or ("b" .. tostring(row.book_id))
end

-- Seconds the device recorded on the local days an interval touches.
local function deviceSeconds(device_daily, from, to)
    local total, steps = 0, 0
    local last = dateKey(to)
    local t = from
    while steps < MAX_INTERVAL_DAYS do
        local key = dateKey(t)
        total = total + (tonumber(device_daily[key]) or 0)
        if key == last then break end
        t = t + DAY
        steps = steps + 1
    end
    return total
end

-- Folds journal rows (oldest first) into the state. opts:
--   device_daily  { ["YYYY-MM-DD"] = seconds } from the device
--   seconds_per_page  the reader's own pace, or nil
function Stats.apply(state, rows, opts)
    opts = opts or {}
    local device_daily = opts.device_daily or {}
    local pace = tonumber(opts.seconds_per_page)
    for _i, row in ipairs(rows or {}) do
        local meta = type(row.metadata) == "table" and row.metadata or {}
        local at = Stats.parseTime(row.action_at)
        local progress = tonumber(meta.progress_pages)
        if at and progress then
            local key = stepKey(row)
            local previous = state.last[key]
            local base = previous and previous.progress or tonumber(meta.progress_pages_was) or 0
            local from = previous and previous.at or (at - DAY)
            local delta = progress - base
            if delta > 0 then
                local witnessed = false
                if pace and pace > 0 then
                    local seen = deviceSeconds(device_daily, math.min(from, at), at)
                    witnessed = seen >= Stats.WITNESS_SHARE * delta * pace
                end
                if not witnessed then
                    local key_day = dateKey(at)
                    local entry = state.days[key_day] or { pages = 0 }
                    entry.pages = entry.pages + delta
                    if delta > Stats.BULK_PAGES or (at - from) > Stats.BULK_DAYS * DAY then
                        entry.bulk = true
                    end
                    state.days[key_day] = entry
                end
            end
            -- Backwards and repeated steps move the baseline, never the totals.
            state.last[key] = { progress = progress, at = at }
        end
        if row.action_at and (not state.watermark or row.action_at > state.watermark) then
            state.watermark = row.action_at
        end
    end
    return state
end

-- Forgets days older than the window so the file stays small.
function Stats.prune(state, today)
    local oldest = dateKey(today - (Stats.WINDOW_DAYS + 31) * DAY)
    for day in pairs(state.days) do
        if day < oldest then state.days[day] = nil end
    end
    return state
end

local function windowDays(today)
    local days = {}
    for i = Stats.WINDOW_DAYS, 1, -1 do
        days[#days + 1] = dateKey(today - (i - 1) * DAY)
    end
    return days
end

-- The server's readingYear shape (oldest first, ending today) holding only the
-- estimated minutes from other devices, plus flags for which days they are.
-- Pages per day are capped so one catch-up cannot flatten the other weeks.
function Stats.readingYear(state, today, seconds_per_page)
    local pace = tonumber(seconds_per_page)
    local days = windowDays(today)
    local minutes, bulk = {}, {}
    for index, day in ipairs(days) do
        local entry = state.days[day]
        local value = 0
        if entry and pace and pace > 0 then
            value = math.floor(math.min(entry.pages, Stats.BULK_PAGES) * pace / 60 + 0.5)
        end
        minutes[index] = value
        bulk[index] = entry ~= nil and entry.bulk == true
    end
    return { startDate = days[1], minutes = minutes, bulk = bulk, additive = true }
end

-- Current and longest streak over the window, and the last seven days. A day
-- counts when the device read in it, another device made steady progress in it
-- (not a catch-up), or a read was finished in it.
function Stats.streak(state, today, device_daily, finished_days)
    device_daily = device_daily or {}
    finished_days = finished_days or {}
    local days = windowDays(today)
    local active = {}
    for index, day in ipairs(days) do
        local entry = state.days[day]
        active[index] = (tonumber(device_daily[day]) or 0) > 0
            or (entry ~= nil and entry.pages > 0 and not entry.bulk)
            or finished_days[day] == true
    end
    local longest, run = 0, 0
    for index = 1, #days do
        run = active[index] and run + 1 or 0
        if run > longest then longest = run end
    end
    -- Today may not have its reading yet; the streak is alive until it ends.
    local current, index = 0, #days
    if not active[index] then index = index - 1 end
    while index >= 1 and active[index] do
        current = current + 1
        index = index - 1
    end
    local last_seven = {}
    for i = #days - 6, #days do last_seven[#last_seven + 1] = active[i] == true end
    return { currentStreak = current, longestStreak = longest, lastSevenDays = last_seven }
end

return Stats
