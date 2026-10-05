package api

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/remus/dusty-library/server/internal/store"
)

func (s *Server) bookPath(id int64) string {
	return filepath.Join(s.booksDir, fmt.Sprintf("%d.pdf", id))
}

func (s *Server) handleListBooks(w http.ResponseWriter, r *http.Request) {
	var shelfID *int64
	if v := r.URL.Query().Get("shelf_id"); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid shelf_id")
			return
		}
		shelfID = &id
	}
	books, err := s.store.ListBooks(r.Context(), mustUser(r), shelfID)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, books)
}

func (s *Server) handleGetBook(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	b, err := s.store.BookByID(r.Context(), mustUser(r), id)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, b)
}

// handleUploadBook accepts multipart/form-data with fields:
//
//	file       the PDF (required)
//	title      display title (defaults to the file name without extension)
//	author     optional
//	page_count optional, computed client-side
//	shelf_id   optional, defaults to the Active shelf
func (s *Server) handleUploadBook(w http.ResponseWriter, r *http.Request) {
	uid := mustUser(r)
	r.Body = http.MaxBytesReader(w, r.Body, s.maxUploadBytes)
	mr, err := r.MultipartReader()
	if err != nil {
		writeError(w, http.StatusBadRequest, "expected multipart/form-data")
		return
	}

	var (
		nb       store.NewBook
		fileSeen bool
		tmpPath  string
	)
	cleanup := func() {
		if tmpPath != "" {
			os.Remove(tmpPath)
		}
	}

	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			cleanup()
			writeError(w, http.StatusBadRequest, "malformed multipart body")
			return
		}
		switch part.FormName() {
		case "file":
			if fileSeen {
				cleanup()
				writeError(w, http.StatusBadRequest, "only one file allowed")
				return
			}
			fileSeen = true
			nb.Filename = filepath.Base(part.FileName())
			if err := os.MkdirAll(s.booksDir, 0o755); err != nil {
				cleanup()
				s.fail(w, err)
				return
			}
			tmp, err := os.CreateTemp(s.booksDir, "upload-*.tmp")
			if err != nil {
				cleanup()
				s.fail(w, err)
				return
			}
			tmpPath = tmp.Name()
			head := make([]byte, 5)
			n, _ := io.ReadFull(part, head)
			if !bytes.HasPrefix(head[:n], []byte("%PDF-")) {
				tmp.Close()
				cleanup()
				writeError(w, http.StatusBadRequest, "file is not a PDF")
				return
			}
			written, err := io.Copy(tmp, io.MultiReader(bytes.NewReader(head[:n]), part))
			tmp.Close()
			if err != nil {
				cleanup()
				var tooBig *http.MaxBytesError
				if errors.As(err, &tooBig) {
					writeError(w, http.StatusRequestEntityTooLarge, "file too large")
					return
				}
				s.fail(w, err)
				return
			}
			nb.SizeBytes = written
		default:
			val, err := io.ReadAll(io.LimitReader(part, 4096))
			if err != nil {
				cleanup()
				writeError(w, http.StatusBadRequest, "malformed multipart body")
				return
			}
			v := strings.TrimSpace(string(val))
			switch part.FormName() {
			case "title":
				nb.Title = v
			case "author":
				nb.Author = v
			case "page_count":
				if v != "" {
					pc, err := strconv.Atoi(v)
					if err != nil || pc < 0 {
						cleanup()
						writeError(w, http.StatusBadRequest, "invalid page_count")
						return
					}
					nb.PageCount = pc
				}
			case "shelf_id":
				if v != "" {
					id, err := strconv.ParseInt(v, 10, 64)
					if err != nil {
						cleanup()
						writeError(w, http.StatusBadRequest, "invalid shelf_id")
						return
					}
					nb.ShelfID = id
				}
			}
		}
		part.Close()
	}

	if !fileSeen {
		writeError(w, http.StatusBadRequest, "missing file")
		return
	}
	if nb.Title == "" {
		nb.Title = strings.TrimSuffix(nb.Filename, filepath.Ext(nb.Filename))
	}
	if nb.Title == "" {
		nb.Title = "Untitled"
	}
	if utf8.RuneCountInString(nb.Title) > 200 {
		nb.Title = string([]rune(nb.Title)[:200])
	}
	if nb.ShelfID == 0 {
		active, err := s.store.ShelfByKind(r.Context(), uid, store.ShelfActive)
		if err != nil {
			cleanup()
			s.fail(w, err)
			return
		}
		nb.ShelfID = active.ID
	} else if _, err := s.store.ShelfByID(r.Context(), uid, nb.ShelfID); err != nil {
		cleanup()
		writeError(w, http.StatusBadRequest, "unknown shelf_id")
		return
	}

	book, err := s.store.CreateBook(r.Context(), uid, nb)
	if err != nil {
		cleanup()
		s.fail(w, err)
		return
	}
	if err := os.Rename(tmpPath, s.bookPath(book.ID)); err != nil {
		cleanup()
		_ = s.store.DeleteBook(r.Context(), uid, book.ID)
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, book)
}

type bookPatchBody struct {
	Title     *string `json:"title"`
	Author    *string `json:"author"`
	ShelfID   *int64  `json:"shelf_id"`
	PageCount *int    `json:"page_count"`
}

func (s *Server) handlePatchBook(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	var body bookPatchBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	uid := mustUser(r)
	patch := store.BookPatch{Author: body.Author, PageCount: body.PageCount}
	if body.Title != nil {
		t := strings.TrimSpace(*body.Title)
		if t == "" || utf8.RuneCountInString(t) > 200 {
			writeError(w, http.StatusBadRequest, "title must be 1-200 characters")
			return
		}
		patch.Title = &t
	}
	if body.PageCount != nil && *body.PageCount < 0 {
		writeError(w, http.StatusBadRequest, "invalid page_count")
		return
	}
	if body.ShelfID != nil {
		if _, err := s.store.ShelfByID(r.Context(), uid, *body.ShelfID); err != nil {
			writeError(w, http.StatusBadRequest, "unknown shelf_id")
			return
		}
		patch.ShelfID = body.ShelfID
	}
	b, err := s.store.UpdateBook(r.Context(), uid, id, patch)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, b)
}

func (s *Server) handleDeleteBook(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	if err := s.store.DeleteBook(r.Context(), mustUser(r), id); err != nil {
		s.fail(w, err)
		return
	}
	if err := os.Remove(s.bookPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		s.log.Warn("remove book file", "id", id, "err", err)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleBookFile(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	b, err := s.store.BookByID(r.Context(), mustUser(r), id)
	if err != nil {
		s.fail(w, err)
		return
	}
	f, err := os.Open(s.bookPath(id))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeError(w, http.StatusNotFound, "file missing")
			return
		}
		s.fail(w, err)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		s.fail(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", fmt.Sprintf("inline; filename=%q", b.Filename))
	w.Header().Set("Cache-Control", "private, max-age=0")
	http.ServeContent(w, r, b.Filename, info.ModTime(), f)
}

type progressBody struct {
	CurrentPage int     `json:"current_page"`
	PageOffset  float64 `json:"page_offset"`
	UpdatedAt   string  `json:"updated_at"`
}

// handleProgress stores where the reader left off: the page and how far down
// that page (0 at the top, 1 at the bottom). The client supplies the time the
// position was reached (RFC3339) so that queued offline updates replayed
// later cannot overwrite newer progress from another device.
func (s *Server) handleProgress(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	var body progressBody
	if err := decodeJSON(w, r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if body.CurrentPage < 0 {
		writeError(w, http.StatusBadRequest, "invalid current_page")
		return
	}
	if math.IsNaN(body.PageOffset) || body.PageOffset < 0 || body.PageOffset > 1 {
		writeError(w, http.StatusBadRequest, "invalid page_offset")
		return
	}
	ts := time.Now().UTC()
	if body.UpdatedAt != "" {
		parsed, err := time.Parse(time.RFC3339Nano, body.UpdatedAt)
		if err != nil {
			writeError(w, http.StatusBadRequest, "updated_at must be RFC3339")
			return
		}
		if parsed.Before(ts) {
			ts = parsed.UTC()
		}
	}
	b, err := s.store.UpdateProgress(r.Context(), mustUser(r), id, body.CurrentPage, body.PageOffset, ts.Format(time.RFC3339Nano))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, b)
}
