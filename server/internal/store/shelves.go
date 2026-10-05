package store

import (
	"context"
	"database/sql"
	"errors"
)

const shelfCols = `id, user_id, name, kind, sort_order, created_at`

// ListShelves returns the user's shelves ordered by sort_order then id.
func (s *Store) ListShelves(ctx context.Context, userID int64) ([]Shelf, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+shelfCols+` FROM shelves WHERE user_id = ? ORDER BY sort_order, id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Shelf{}
	for rows.Next() {
		var sh Shelf
		if err := rows.Scan(&sh.ID, &sh.UserID, &sh.Name, &sh.Kind, &sh.SortOrder, &sh.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, sh)
	}
	return out, rows.Err()
}

// ShelfByID returns one shelf owned by the user.
func (s *Store) ShelfByID(ctx context.Context, userID, id int64) (*Shelf, error) {
	var sh Shelf
	err := s.db.QueryRowContext(ctx, `SELECT `+shelfCols+` FROM shelves WHERE user_id = ? AND id = ?`, userID, id).
		Scan(&sh.ID, &sh.UserID, &sh.Name, &sh.Kind, &sh.SortOrder, &sh.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &sh, nil
}

// ShelfByKind returns the predefined shelf of the given kind.
func (s *Store) ShelfByKind(ctx context.Context, userID int64, kind string) (*Shelf, error) {
	var sh Shelf
	err := s.db.QueryRowContext(ctx, `SELECT `+shelfCols+` FROM shelves WHERE user_id = ? AND kind = ? ORDER BY id LIMIT 1`, userID, kind).
		Scan(&sh.ID, &sh.UserID, &sh.Name, &sh.Kind, &sh.SortOrder, &sh.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &sh, nil
}

// CreateShelf adds a custom shelf at the end of the list.
func (s *Store) CreateShelf(ctx context.Context, userID int64, name string) (*Shelf, error) {
	var maxOrder sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `SELECT MAX(sort_order) FROM shelves WHERE user_id = ?`, userID).Scan(&maxOrder); err != nil {
		return nil, err
	}
	order := int(maxOrder.Int64) + 1
	ts := now()
	res, err := s.db.ExecContext(ctx, `INSERT INTO shelves (user_id, name, kind, sort_order, created_at) VALUES (?, ?, ?, ?, ?)`, userID, name, ShelfCustom, order, ts)
	if err != nil {
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return &Shelf{ID: id, UserID: userID, Name: name, Kind: ShelfCustom, SortOrder: order, CreatedAt: ts}, nil
}

// RenameShelf changes a custom shelf's name.
func (s *Store) RenameShelf(ctx context.Context, userID, id int64, name string) error {
	res, err := s.db.ExecContext(ctx, `UPDATE shelves SET name = ? WHERE user_id = ? AND id = ? AND kind = ?`, name, userID, id, ShelfCustom)
	if err != nil {
		return err
	}
	return affectedOrNotFound(res)
}

// DeleteShelf removes a custom shelf, moving its books to the Active shelf.
func (s *Store) DeleteShelf(ctx context.Context, userID, id int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var activeID int64
	if err := tx.QueryRowContext(ctx, `SELECT id FROM shelves WHERE user_id = ? AND kind = ? ORDER BY id LIMIT 1`, userID, ShelfActive).Scan(&activeID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE books SET shelf_id = ?, updated_at = ? WHERE user_id = ? AND shelf_id = ?`, activeID, now(), userID, id); err != nil {
		return err
	}
	res, err := tx.ExecContext(ctx, `DELETE FROM shelves WHERE user_id = ? AND id = ? AND kind = ?`, userID, id, ShelfCustom)
	if err != nil {
		return err
	}
	if err := affectedOrNotFound(res); err != nil {
		return err
	}
	return tx.Commit()
}

func affectedOrNotFound(res sql.Result) error {
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
