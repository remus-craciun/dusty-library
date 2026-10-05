CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY,
    username      TEXT    NOT NULL UNIQUE,
    password_hash TEXT    NOT NULL,
    created_at    TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS shelves (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT    NOT NULL,
    kind       TEXT    NOT NULL CHECK (kind IN ('active', 'completed', 'custom')),
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_shelves_user ON shelves(user_id, sort_order);

CREATE TABLE IF NOT EXISTS books (
    id                  INTEGER PRIMARY KEY,
    user_id             INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    shelf_id            INTEGER NOT NULL REFERENCES shelves(id),
    title               TEXT    NOT NULL,
    author              TEXT    NOT NULL DEFAULT '',
    filename            TEXT    NOT NULL,
    size_bytes          INTEGER NOT NULL DEFAULT 0,
    page_count          INTEGER NOT NULL DEFAULT 0,
    current_page        INTEGER NOT NULL DEFAULT 0,
    progress_updated_at TEXT,
    last_read_at        TEXT,
    created_at          TEXT    NOT NULL,
    updated_at          TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_books_user_shelf ON books(user_id, shelf_id);

CREATE TABLE IF NOT EXISTS settings (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    zoom    REAL    NOT NULL DEFAULT 1.0,
    filter  TEXT    NOT NULL DEFAULT 'none'
);
