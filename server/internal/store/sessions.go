package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// Session is one signed-in device.
type Session struct {
	ID         int64  `json:"id"`
	UserID     int64  `json:"-"`
	UserAgent  string `json:"user_agent"`
	CreatedAt  string `json:"created_at"`
	LastUsedAt string `json:"last_used_at"`
}

// CreateSession records a new login token (already hashed).
func (s *Store) CreateSession(ctx context.Context, userID int64, tokenHash, userAgent string) (*Session, error) {
	ts := now()
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO sessions (user_id, token_hash, user_agent, created_at, last_used_at) VALUES (?, ?, ?, ?, ?)`,
		userID, tokenHash, userAgent, ts, ts)
	if err != nil {
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &Session{ID: id, UserID: userID, UserAgent: userAgent, CreatedAt: ts, LastUsedAt: ts}, nil
}

// SessionByTokenHash resolves a token to its session, returning ErrNotFound
// for unknown or revoked tokens.
func (s *Store) SessionByTokenHash(ctx context.Context, tokenHash string) (*Session, error) {
	var se Session
	err := s.db.QueryRowContext(ctx,
		`SELECT id, user_id, user_agent, created_at, last_used_at FROM sessions WHERE token_hash = ?`, tokenHash).
		Scan(&se.ID, &se.UserID, &se.UserAgent, &se.CreatedAt, &se.LastUsedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &se, nil
}

// TouchSession updates last_used_at if it is older than the given interval,
// to keep writes rare on hot paths.
func (s *Store) TouchSession(ctx context.Context, se *Session, minInterval time.Duration) error {
	last, err := time.Parse(time.RFC3339Nano, se.LastUsedAt)
	if err == nil && time.Since(last) < minInterval {
		return nil
	}
	_, err = s.db.ExecContext(ctx, `UPDATE sessions SET last_used_at = ? WHERE id = ?`, now(), se.ID)
	return err
}

// DeleteSession revokes a single token (logout on this device).
func (s *Store) DeleteSession(ctx context.Context, userID, id int64) error {
	res, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE user_id = ? AND id = ?`, userID, id)
	if err != nil {
		return err
	}
	return affectedOrNotFound(res)
}

// DeleteAllSessions revokes every token of the user (logout everywhere).
func (s *Store) DeleteAllSessions(ctx context.Context, userID int64) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM sessions WHERE user_id = ?`, userID)
	return err
}
