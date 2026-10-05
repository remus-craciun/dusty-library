package store

import (
	"context"
	"database/sql"
	"errors"
)

// UserCount returns how many accounts exist (0 or 1 in practice).
func (s *Store) UserCount(ctx context.Context) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users`).Scan(&n)
	return n, err
}

// CreateUser registers the single account, its predefined shelves and default
// settings in one transaction. Returns ErrConflict if an account already exists.
func (s *Store) CreateUser(ctx context.Context, username, passwordHash string) (*User, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var n int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM users`).Scan(&n); err != nil {
		return nil, err
	}
	if n > 0 {
		return nil, ErrConflict
	}

	ts := now()
	res, err := tx.ExecContext(ctx, `INSERT INTO users (username, password_hash, created_at) VALUES (?, ?, ?)`, username, passwordHash, ts)
	if err != nil {
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	for i, sh := range []struct{ name, kind string }{{"Active", ShelfActive}, {"Completed", ShelfCompleted}} {
		if _, err := tx.ExecContext(ctx, `INSERT INTO shelves (user_id, name, kind, sort_order, created_at) VALUES (?, ?, ?, ?, ?)`, id, sh.name, sh.kind, i, ts); err != nil {
			return nil, err
		}
	}
	def := DefaultSettings()
	if _, err := tx.ExecContext(ctx, `INSERT INTO settings (user_id, zoom, filter) VALUES (?, ?, ?)`, id, def.Zoom, def.Filter); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &User{ID: id, Username: username, PasswordHash: passwordHash, CreatedAt: ts}, nil
}

// UserByUsername looks up an account by name.
func (s *Store) UserByUsername(ctx context.Context, username string) (*User, error) {
	return s.scanUser(s.db.QueryRowContext(ctx, `SELECT id, username, password_hash, created_at FROM users WHERE username = ?`, username))
}

// UserByID looks up an account by id.
func (s *Store) UserByID(ctx context.Context, id int64) (*User, error) {
	return s.scanUser(s.db.QueryRowContext(ctx, `SELECT id, username, password_hash, created_at FROM users WHERE id = ?`, id))
}

func (s *Store) scanUser(row *sql.Row) (*User, error) {
	var u User
	if err := row.Scan(&u.ID, &u.Username, &u.PasswordHash, &u.CreatedAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &u, nil
}
