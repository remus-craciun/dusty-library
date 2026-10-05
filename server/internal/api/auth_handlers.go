package api

import (
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/remus/dusty-library/server/internal/auth"
	"github.com/remus/dusty-library/server/internal/store"
)

type credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// tokenResponse is returned by register and login. Tokens do not expire; they
// stay valid until POST /api/auth/logout revokes them.
type tokenResponse struct {
	Token string      `json:"token"`
	User  *store.User `json:"user"`
}

// handleStatus tells clients whether an account exists so they can show the
// register or login screen.
func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	n, err := s.store.UserCount(r.Context())
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"name":       "dusty-library",
		"registered": n > 0,
	})
}

// handleRegister creates the single account. Once one exists it answers 409.
func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var c credentials
	if err := decodeJSON(w, r, &c); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	c.Username = strings.TrimSpace(c.Username)
	if l := utf8.RuneCountInString(c.Username); l < 2 || l > 64 {
		writeError(w, http.StatusBadRequest, "username must be 2-64 characters")
		return
	}
	if l := utf8.RuneCountInString(c.Password); l < 6 || len(c.Password) > 72 {
		writeError(w, http.StatusBadRequest, "password must be 6-72 characters")
		return
	}
	hash, err := auth.HashPassword(c.Password)
	if err != nil {
		s.fail(w, err)
		return
	}
	u, err := s.store.CreateUser(r.Context(), c.Username, hash)
	if err != nil {
		if err == store.ErrConflict {
			writeError(w, http.StatusConflict, "an account already exists; registration is disabled")
			return
		}
		s.fail(w, err)
		return
	}
	s.issue(w, r, u)
}

// handleLogin validates credentials and returns a bearer token.
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var c credentials
	if err := decodeJSON(w, r, &c); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	u, err := s.store.UserByUsername(r.Context(), strings.TrimSpace(c.Username))
	if err != nil || !auth.CheckPassword(u.PasswordHash, c.Password) {
		// Run bcrypt even for unknown users to keep timing uniform.
		if err != nil {
			auth.CheckPassword("$2a$10$7EqJtq98hPqEX7fNZaFWoOhi5XnB4p4h4g7Q3zY6g1oWqV9P1D1d2", c.Password)
		}
		writeError(w, http.StatusUnauthorized, "invalid username or password")
		return
	}
	s.issue(w, r, u)
}

// issue creates a session for the user and returns its token.
func (s *Server) issue(w http.ResponseWriter, r *http.Request, u *store.User) {
	tok, hash, err := auth.NewToken()
	if err != nil {
		s.fail(w, err)
		return
	}
	ua := r.UserAgent()
	if len(ua) > 200 {
		ua = ua[:200]
	}
	if _, err := s.store.CreateSession(r.Context(), u.ID, hash, ua); err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, tokenResponse{Token: tok, User: u})
}

// handleLogout revokes the token used for this request.
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	p, _ := auth.From(r.Context())
	if err := s.store.DeleteSession(r.Context(), p.UserID, p.SessionID); err != nil && err != store.ErrNotFound {
		s.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleLogoutAll revokes every token of the user (all devices).
func (s *Server) handleLogoutAll(w http.ResponseWriter, r *http.Request) {
	if err := s.store.DeleteAllSessions(r.Context(), mustUser(r)); err != nil {
		s.fail(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleMe returns the authenticated user.
func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	u, err := s.store.UserByID(r.Context(), mustUser(r))
	if err != nil {
		s.fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, u)
}
