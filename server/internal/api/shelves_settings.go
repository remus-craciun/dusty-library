package api

import (
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/remus/dusty-library/server/internal/store"
)

type shelfBody struct {
	Name string `json:"name"`
}

func validShelfName(name string) (string, bool) {
	name = strings.TrimSpace(name)
	l := utf8.RuneCountInString(name)
	return name, l >= 1 && l <= 64
}

func (s *Server) handleListShelves(w http.ResponseWriter, r *http.Request) {
	shelves, err := s.store.ListShelves(r.Context(), mustUser(r))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, shelves)
}

func (s *Server) handleCreateShelf(w http.ResponseWriter, r *http.Request) {
	var b shelfBody
	if err := decodeJSON(w, r, &b); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	name, ok := validShelfName(b.Name)
	if !ok {
		writeError(w, http.StatusBadRequest, "name must be 1-64 characters")
		return
	}
	sh, err := s.store.CreateShelf(r.Context(), mustUser(r), name)
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, sh)
}

func (s *Server) handleRenameShelf(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	var b shelfBody
	if err := decodeJSON(w, r, &b); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	name, ok := validShelfName(b.Name)
	if !ok {
		writeError(w, http.StatusBadRequest, "name must be 1-64 characters")
		return
	}
	uid := mustUser(r)
	sh, err := s.store.ShelfByID(r.Context(), uid, id)
	if err != nil {
		s.fail(w, err)
		return
	}
	if sh.Kind != store.ShelfCustom {
		writeError(w, http.StatusForbidden, "predefined shelves cannot be renamed")
		return
	}
	if err := s.store.RenameShelf(r.Context(), uid, id, name); err != nil {
		s.fail(w, err)
		return
	}
	sh.Name = name
	writeJSON(w, http.StatusOK, sh)
}

func (s *Server) handleDeleteShelf(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	uid := mustUser(r)
	sh, err := s.store.ShelfByID(r.Context(), uid, id)
	if err != nil {
		s.fail(w, err)
		return
	}
	if sh.Kind != store.ShelfCustom {
		writeError(w, http.StatusForbidden, "predefined shelves cannot be deleted")
		return
	}
	if err := s.store.DeleteShelf(r.Context(), uid, id); err != nil {
		s.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetSettings(w http.ResponseWriter, r *http.Request) {
	st, err := s.store.GetSettings(r.Context(), mustUser(r))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) handlePutSettings(w http.ResponseWriter, r *http.Request) {
	var st store.Settings
	if err := decodeJSON(w, r, &st); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if st.Zoom < 0.25 || st.Zoom > 8 {
		writeError(w, http.StatusBadRequest, "zoom must be between 0.25 and 8")
		return
	}
	if !store.ValidFilters[st.Filter] {
		writeError(w, http.StatusBadRequest, "filter must be one of none, paper, sepia, dark")
		return
	}
	if err := s.store.PutSettings(r.Context(), mustUser(r), st); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}
