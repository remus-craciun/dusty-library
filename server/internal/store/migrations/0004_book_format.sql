-- What kind of file the book is: 'pdf', 'docx' or 'doc'. Word documents are
-- read as reflowable text extracted on upload; for them page_count is the
-- number of paragraphs and current_page/page_offset a paragraph position.
ALTER TABLE books ADD COLUMN format TEXT NOT NULL DEFAULT 'pdf';
