package store

import (
	"context"
	"database/sql"
	"errors"
)

// GetSettings returns the user's reader settings, falling back to defaults.
func (s *Store) GetSettings(ctx context.Context, userID int64) (Settings, error) {
	var st Settings
	err := s.db.QueryRowContext(ctx, `SELECT zoom, filter FROM settings WHERE user_id = ?`, userID).Scan(&st.Zoom, &st.Filter)
	if errors.Is(err, sql.ErrNoRows) {
		return DefaultSettings(), nil
	}
	return st, err
}

// PutSettings replaces the user's reader settings.
func (s *Store) PutSettings(ctx context.Context, userID int64, st Settings) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO settings (user_id, zoom, filter) VALUES (?, ?, ?)
		 ON CONFLICT(user_id) DO UPDATE SET zoom = excluded.zoom, filter = excluded.filter`,
		userID, st.Zoom, st.Filter)
	return err
}
