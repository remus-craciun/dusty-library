package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

const bookCols = `id, user_id, shelf_id, title, author, filename, size_bytes, page_count, current_page, page_offset, progress_updated_at, last_read_at, created_at, updated_at`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanBook(r rowScanner) (*Book, error) {
	var b Book
	var progressAt, lastRead sql.NullString
	if err := r.Scan(&b.ID, &b.UserID, &b.ShelfID, &b.Title, &b.Author, &b.Filename, &b.SizeBytes, &b.PageCount, &b.CurrentPage, &b.PageOffset, &progressAt, &lastRead, &b.CreatedAt, &b.UpdatedAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if progressAt.Valid {
		b.ProgressUpdatedAt = &progressAt.String
	}
	if lastRead.Valid {
		b.LastReadAt = &lastRead.String
	}
	return &b, nil
}

// ListBooks returns all books of the user, optionally filtered by shelf.
func (s *Store) ListBooks(ctx context.Context, userID int64, shelfID *int64) ([]Book, error) {
	q := `SELECT ` + bookCols + ` FROM books WHERE user_id = ?`
	args := []any{userID}
	if shelfID != nil {
		q += ` AND shelf_id = ?`
		args = append(args, *shelfID)
	}
	q += ` ORDER BY COALESCE(last_read_at, created_at) DESC, id DESC`
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Book{}
	for rows.Next() {
		b, err := scanBook(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *b)
	}
	return out, rows.Err()
}

// BookByID returns one book owned by the user.
func (s *Store) BookByID(ctx context.Context, userID, id int64) (*Book, error) {
	return scanBook(s.db.QueryRowContext(ctx, `SELECT `+bookCols+` FROM books WHERE user_id = ? AND id = ?`, userID, id))
}

// NewBook describes a book to insert.
type NewBook struct {
	ShelfID   int64
	Title     string
	Author    string
	Filename  string
	SizeBytes int64
	PageCount int
}

// CreateBook inserts a book row and returns it.
func (s *Store) CreateBook(ctx context.Context, userID int64, nb NewBook) (*Book, error) {
	ts := now()
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO books (user_id, shelf_id, title, author, filename, size_bytes, page_count, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID, nb.ShelfID, nb.Title, nb.Author, nb.Filename, nb.SizeBytes, nb.PageCount, ts, ts)
	if err != nil {
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return s.BookByID(ctx, userID, id)
}

// BookPatch lists optional fields to change on a book.
type BookPatch struct {
	Title     *string
	Author    *string
	ShelfID   *int64
	PageCount *int
}

// UpdateBook applies a patch. Returns ErrNotFound if the book is not the user's.
func (s *Store) UpdateBook(ctx context.Context, userID, id int64, p BookPatch) (*Book, error) {
	sets := []string{"updated_at = ?"}
	args := []any{now()}
	if p.Title != nil {
		sets = append(sets, "title = ?")
		args = append(args, *p.Title)
	}
	if p.Author != nil {
		sets = append(sets, "author = ?")
		args = append(args, *p.Author)
	}
	if p.ShelfID != nil {
		sets = append(sets, "shelf_id = ?")
		args = append(args, *p.ShelfID)
	}
	if p.PageCount != nil {
		sets = append(sets, "page_count = ?")
		args = append(args, *p.PageCount)
	}
	args = append(args, userID, id)
	res, err := s.db.ExecContext(ctx, `UPDATE books SET `+strings.Join(sets, ", ")+` WHERE user_id = ? AND id = ?`, args...)
	if err != nil {
		return nil, err
	}
	if err := affectedOrNotFound(res); err != nil {
		return nil, err
	}
	return s.BookByID(ctx, userID, id)
}

// UpdateProgress applies a progress report using last-write-wins on updatedAt
// (RFC3339). Reports older than the stored one are ignored and the current
// book is returned unchanged.
func (s *Store) UpdateProgress(ctx context.Context, userID, id int64, currentPage int, pageOffset float64, updatedAt string) (*Book, error) {
	b, err := s.BookByID(ctx, userID, id)
	if err != nil {
		return nil, err
	}
	incoming, err := time.Parse(time.RFC3339Nano, updatedAt)
	if err != nil {
		return nil, fmt.Errorf("invalid updated_at: %w", err)
	}
	if b.ProgressUpdatedAt != nil {
		if existing, err := time.Parse(time.RFC3339Nano, *b.ProgressUpdatedAt); err == nil && !incoming.After(existing) {
			return b, nil
		}
	}
	if _, err := s.db.ExecContext(ctx,
		`UPDATE books SET current_page = ?, page_offset = ?, progress_updated_at = ?, last_read_at = ?, updated_at = ? WHERE user_id = ? AND id = ?`,
		currentPage, pageOffset, updatedAt, updatedAt, now(), userID, id); err != nil {
		return nil, err
	}
	return s.BookByID(ctx, userID, id)
}

// DeleteBook removes the row. The caller is responsible for the file on disk.
func (s *Store) DeleteBook(ctx context.Context, userID, id int64) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM books WHERE user_id = ? AND id = ?`, userID, id)
	if err != nil {
		return err
	}
	return affectedOrNotFound(res)
}
