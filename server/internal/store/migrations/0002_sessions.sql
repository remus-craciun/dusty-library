-- Login sessions. A token is valid for as long as its row exists; logging out
-- deletes the row. Tokens are stored hashed so a leaked database does not
-- leak usable credentials.
CREATE TABLE IF NOT EXISTS sessions (
    id           INTEGER PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash   TEXT    NOT NULL UNIQUE,
    user_agent   TEXT    NOT NULL DEFAULT '',
    created_at   TEXT    NOT NULL,
    last_used_at TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
