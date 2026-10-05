-- How far down the current page the reader was, as a fraction from 0 (top)
-- to 1 (bottom). Together with current_page this is the reading position.
ALTER TABLE books ADD COLUMN page_offset REAL NOT NULL DEFAULT 0;
