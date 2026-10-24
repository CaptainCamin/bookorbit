--[[--
Turns Hardcover GraphQL rows into the tables BookOrbit's server sends the
catalog screens, so the screens read the same fields from either source.

Pure functions: no network, no KOReader modules. The shapes follow
KoreaderCatalogBookListItem, KoreaderCatalogBookDetail and
KoreaderCatalogDashboardResponse in packages/types/src/koreader.ts.
]]

local Shape = {}

-- Hardcover's user_books.status_id mapped onto BookOrbit's read status strings.
local READ_STATUS = {
    [1] = "want_to_read",
    [2] = "reading",
    [3] = "read",
    [4] = "on_hold",
    [5] = "abandoned",
}
Shape.READ_STATUS = READ_STATUS

local GENRE_LIMIT = 4
local TAG_LIMIT = 5
-- Crowd-sourced tags that describe the edition, not the book.
local FORMAT_TAGS = { audiobook = true, physical = true, ["dual-format"] = true, ebook = true }

local function present(value)
    if type(value) == "string" then
        value = value:match("^%s*(.-)%s*$")
        if value == "" then return nil end
    end
    return value
end

function Shape.readStatus(status_id)
    return READ_STATUS[tonumber(status_id) or 0]
end

-- Hardcover dates are plain days or full timestamps; BookOrbit sends ISO instants.
function Shape.isoInstant(value)
    value = present(value)
    if type(value) ~= "string" then return nil end
    if value:match("^%d%d%d%d%-%d%d%-%d%d$") then return value .. "T00:00:00Z" end
    return value
end

local function day(value)
    value = present(value)
    return type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d") or nil
end
Shape.day = day

-- Half stars have no slot in BookOrbit's five-star row.
function Shape.stars(rating)
    rating = tonumber(rating)
    if not rating or rating <= 0 then return nil end
    return math.min(5, math.floor(rating + 0.5))
end

function Shape.coverUrl(book)
    local image = type(book) == "table" and book.cached_image
    if type(image) == "table" then return present(image.url) end
    return nil
end

-- Narrators and illustrators share contributions with authors.
function Shape.authors(book)
    local all, authors = {}, {}
    for _i, contribution in ipairs(type(book) == "table" and book.contributions or {}) do
        local name = type(contribution.author) == "table" and present(contribution.author.name)
        if name then
            table.insert(all, name)
            local role = present(contribution.contribution)
            if role == nil or role == "Author" then table.insert(authors, name) end
        end
    end
    return #authors > 0 and authors or all
end

local function addDistinct(list, seen, value, limit)
    local key = value:lower()
    if #list >= limit or seen[key] then return end
    seen[key] = true
    table.insert(list, value)
end

-- cached_tags is { Genre = { { tag, count }, ... }, Mood = ..., Tag = ... },
-- each ordered by count. Some genre values bundle several ("A | B").
function Shape.genres(book)
    local tags = type(book) == "table" and book.cached_tags
    local genres, seen = {}, {}
    for _i, entry in ipairs(type(tags) == "table" and tags.Genre or {}) do
        for part in tostring(entry.tag or ""):gmatch("[^|]+") do
            part = present(part)
            if part and not FORMAT_TAGS[part:lower()] then addDistinct(genres, seen, part, GENRE_LIMIT) end
        end
    end
    return genres
end

function Shape.tags(book)
    local tags = type(book) == "table" and book.cached_tags
    local out, seen = {}, {}
    for _i, entry in ipairs(type(tags) == "table" and tags.Tag or {}) do
        local tag = present(entry.tag)
        if tag and not FORMAT_TAGS[tag:lower()] then addDistinct(out, seen, tag, TAG_LIMIT) end
    end
    return out
end

-- The read in progress, else the latest one.
function Shape.currentRead(user_book)
    local reads = type(user_book) == "table" and user_book.user_book_reads or {}
    for _i, read in ipairs(reads) do
        if not read.finished_at then return read, true end
    end
    return reads[1], false
end

local function pages(user_book)
    local edition = type(user_book.edition) == "table" and user_book.edition or {}
    local book = type(user_book.book) == "table" and user_book.book or {}
    local count = tonumber(edition.pages) or tonumber(book.pages)
    if count and count > 0 then return count end
    return nil
end

-- 0 to 100, or nil when Hardcover cannot say. A finished book is whole; a book
-- that was started never reads 0% on a shelf.
function Shape.progressPercentage(user_book)
    if user_book.status_id == 3 then return 100 end
    if user_book.status_id == 1 or user_book.status_id == nil then return nil end
    local read = Shape.currentRead(user_book)
    local total = pages(user_book)
    local done = read and tonumber(read.progress_pages)
    if not total or not done then return nil end
    return math.max(0, math.min(100, math.floor(100 * done / total + 0.5)))
end

local function series(book)
    local entry = type(book) == "table" and type(book.book_series) == "table" and book.book_series[1]
    if type(entry) ~= "table" or type(entry.series) ~= "table" then return nil, nil, nil end
    return entry.series.id, present(entry.series.name), tonumber(entry.position)
end

-- Hardcover has no "last read" for an unfinished book (last_read_date is only
-- set once a read finishes), so recency is when the open read started.
local function recency(user_book)
    local read, open = Shape.currentRead(user_book)
    if open and read then return Shape.isoInstant(read.started_at) end
    return Shape.isoInstant(user_book.last_read_date)
end

-- A KoreaderCatalogBookListItem. updatedAt doubles as the cover cache token on
-- the device, so it is the day the book was shelved and never moves when
-- progress does.
function Shape.listItem(user_book)
    local book = type(user_book.book) == "table" and user_book.book or {}
    local cover = Shape.coverUrl(book)
    local series_id, series_name, series_index = series(book)
    local added = Shape.isoInstant(user_book.date_added) or "1970-01-01T00:00:00Z"
    return {
        id = user_book.book_id or book.id,
        title = present(book.title) or "",
        authors = Shape.authors(book),
        seriesId = series_id,
        seriesName = series_name,
        seriesIndex = series_index,
        progressPercentage = Shape.progressPercentage(user_book),
        lastReadAt = recency(user_book),
        readStatus = Shape.readStatus(user_book.status_id),
        formats = {},
        hasCover = cover ~= nil,
        thumbnailUrl = cover,
        detailUrl = "hardcover:book/" .. tostring(user_book.book_id or book.id),
        addedAt = added,
        updatedAt = added,
    }
end

-- Open reads first, newest start first; the rest keep Hardcover's order.
function Shape.sortByRecentStart(user_books)
    local keyed = {}
    for index, user_book in ipairs(user_books) do
        local read, open = Shape.currentRead(user_book)
        table.insert(keyed, { item = user_book, index = index, open = open, started = read and day(read.started_at) or "" })
    end
    table.sort(keyed, function(a, b)
        if a.open ~= b.open then return a.open end
        if a.started ~= b.started then return a.started > b.started end
        return a.index < b.index
    end)
    local sorted = {}
    for _i, entry in ipairs(keyed) do table.insert(sorted, entry.item) end
    return sorted
end

function Shape.listItems(user_books)
    local items = {}
    for _i, user_book in ipairs(user_books or {}) do table.insert(items, Shape.listItem(user_book)) end
    return items
end

-- Finished shelf entries also carry the local day the book was finished.
function Shape.finishedItems(user_books)
    local items = {}
    for _i, user_book in ipairs(user_books or {}) do
        local item = Shape.listItem(user_book)
        item.finishedOn = day(user_book.last_read_date)
        table.insert(items, item)
    end
    return items
end

-- The goal that covers today, else the first books goal, else the first goal.
function Shape.readingGoal(goals, today)
    local chosen
    for _i, goal in ipairs(goals or {}) do
        local starts, ends = day(goal.start_date), day(goal.end_date)
        local current = starts and ends and starts <= today and today <= ends
        if goal.metric == "book" and current then chosen = goal break end
        chosen = chosen or goal
    end
    if not chosen then
        return { goalBooks = nil, completedBooks = 0, year = tonumber(today:sub(1, 4)) }
    end
    return {
        goalBooks = tonumber(chosen.goal),
        completedBooks = tonumber(chosen.progress) or 0,
        year = tonumber((day(chosen.end_date) or today):sub(1, 4)),
        metric = chosen.metric,
    }
end

local function relatedBook(item)
    return {
        id = item.id,
        title = item.title,
        authors = item.authors,
        seriesIndex = item.seriesIndex,
        hasCover = item.hasCover,
        thumbnailUrl = item.thumbnailUrl,
        detailUrl = item.detailUrl,
        updatedAt = item.updatedAt,
    }
end

-- user_books of one series, in series order. The same position can hold
-- several editions of a book, so one entry per position.
function Shape.seriesPath(series_user_books)
    local members, related, seen = {}, {}, {}
    for _i, user_book in ipairs(series_user_books or {}) do
        local item = Shape.listItem(user_book)
        local position = item.seriesIndex
        local key = position and tostring(position) or ("id" .. tostring(item.id))
        if not seen[key] then
            seen[key] = true
            table.insert(members, { id = item.id, title = item.title, seriesIndex = position, readStatus = item.readStatus })
            table.insert(related, relatedBook(item))
        end
    end
    local function order(a, b)
        local pa, pb = a.seriesIndex or math.huge, b.seriesIndex or math.huge
        if pa ~= pb then return pa < pb end
        return tostring(a.id) < tostring(b.id)
    end
    table.sort(members, order)
    table.sort(related, order)
    return members, related
end

-- A KoreaderCatalogBookDetail. `series_books` is the shelved books of the same
-- series (optional). Hardcover sells no files, so files stays empty and the
-- detail page offers nothing to download.
function Shape.detail(user_book, series_books)
    local book = type(user_book.book) == "table" and user_book.book or {}
    local edition = type(user_book.edition) == "table" and user_book.edition or {}
    local item = Shape.listItem(user_book)
    local detail = item
    detail.subtitle = present(book.subtitle)
    detail.description = present(book.description)
    detail.publisher = type(edition.publisher) == "table" and present(edition.publisher.name) or nil
    detail.publishedDate = day(edition.release_date) or day(book.release_date)
    detail.publishedYear = tonumber(book.release_year) or (detail.publishedDate and tonumber(detail.publishedDate:sub(1, 4))) or nil
    detail.language = type(edition.language) == "table" and present(edition.language.code2) or nil
    detail.isbn10 = present(edition.isbn_10)
    detail.isbn13 = present(edition.isbn_13)
    detail.libraryId = 0
    detail.libraryName = "Hardcover"
    detail.rating = Shape.stars(user_book.rating)
    detail.pageCount = pages(user_book)
    detail.collections = {}
    detail.genres = Shape.genres(book)
    detail.tags = Shape.tags(book)
    detail.progress = nil
    detail.files = {}
    detail.relatedSections = {}
    if series_books and #series_books > 0 then
        local members, related = Shape.seriesPath(series_books)
        detail.seriesMembers = members
        table.insert(detail.relatedSections, { id = "series", title = detail.seriesName or "Series", books = related })
    end
    return detail
end

-- Same shape for a book the reader has not shelved: community data only.
function Shape.unshelvedDetail(book)
    return Shape.detail({
        book_id = book.id,
        book = book,
        edition = book.default_physical_edition or book.default_ebook_edition,
        user_book_reads = {},
    })
end

return Shape
