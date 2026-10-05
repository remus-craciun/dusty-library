// Package api exposes the HTTP API and wires it to the store.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/remus/dusty-library/server/internal/auth"
	"github.com/remus/dusty-library/server/internal/store"
)

// Server holds handler dependencies.
type Server struct {
	store          *store.Store
	booksDir       string
	maxUploadBytes int64
	log            *slog.Logger
}

// Options configures a Server.
type Options struct {
	Store          *store.Store
	BooksDir       string
	MaxUploadBytes int64
	Logger         *slog.Logger
	// Web serves the Flutter build for every non-API path. May be nil.
	Web http.Handler
}

// New builds the full HTTP handler (API + web UI).
func New(o Options) http.Handler {
	if o.Logger == nil {
		o.Logger = slog.Default()
	}
	if o.MaxUploadBytes <= 0 {
		o.MaxUploadBytes = 512 << 20
	}
	s := &Server{store: o.Store, booksDir: o.BooksDir, maxUploadBytes: o.MaxUploadBytes, log: o.Logger}

	public := http.NewServeMux()
	public.HandleFunc("GET /api/status", s.handleStatus)
	public.HandleFunc("POST /api/auth/register", s.handleRegister)
	public.HandleFunc("POST /api/auth/login", s.handleLogin)

	private := http.NewServeMux()
	private.HandleFunc("POST /api/auth/logout", s.handleLogout)
	private.HandleFunc("POST /api/auth/logout-all", s.handleLogoutAll)
	private.HandleFunc("GET /api/me", s.handleMe)
	private.HandleFunc("GET /api/settings", s.handleGetSettings)
	private.HandleFunc("PUT /api/settings", s.handlePutSettings)
	private.HandleFunc("GET /api/shelves", s.handleListShelves)
	private.HandleFunc("POST /api/shelves", s.handleCreateShelf)
	private.HandleFunc("PATCH /api/shelves/{id}", s.handleRenameShelf)
	private.HandleFunc("DELETE /api/shelves/{id}", s.handleDeleteShelf)
	private.HandleFunc("GET /api/books", s.handleListBooks)
	private.HandleFunc("POST /api/books", s.handleUploadBook)
	private.HandleFunc("GET /api/books/{id}", s.handleGetBook)
	private.HandleFunc("PATCH /api/books/{id}", s.handlePatchBook)
	private.HandleFunc("DELETE /api/books/{id}", s.handleDeleteBook)
	private.HandleFunc("GET /api/books/{id}/file", s.handleBookFile)
	private.HandleFunc("PUT /api/books/{id}/progress", s.handleProgress)

	public.Handle("/api/", auth.Middleware(s.resolveToken, private))

	root := http.NewServeMux()
	root.Handle("/api/", public)
	if o.Web != nil {
		root.Handle("/", o.Web)
	}
	return cors(logRequests(o.Logger, root))
}

// resolveToken turns a bearer token hash into a principal by looking up the
// session row. Revoked (deleted) sessions yield ErrInvalidToken.
func (s *Server) resolveToken(ctx context.Context, tokenHash string) (auth.Principal, error) {
	se, err := s.store.SessionByTokenHash(ctx, tokenHash)
	if errors.Is(err, store.ErrNotFound) {
		return auth.Principal{}, auth.ErrInvalidToken
	}
	if err != nil {
		return auth.Principal{}, err
	}
	if err := s.store.TouchSession(ctx, se, time.Hour); err != nil {
		s.log.Warn("touch session", "err", err)
	}
	return auth.Principal{UserID: se.UserID, SessionID: se.ID}, nil
}

// --- helpers ---------------------------------------------------------------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// fail maps store errors to HTTP status codes.
func (s *Server) fail(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not found")
	case errors.Is(err, store.ErrConflict):
		writeError(w, http.StatusConflict, "conflict")
	default:
		s.log.Error("internal error", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

func pathID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id, err == nil && id > 0
}

func mustUser(r *http.Request) int64 {
	id, _ := auth.UserID(r.Context())
	return id
}

// --- middleware ------------------------------------------------------------

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if origin := r.Header.Get("Origin"); origin != "" {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			w.Header().Set("Access-Control-Max-Age", "600")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func logRequests(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Info("http", "method", r.Method, "path", r.URL.Path, "status", rec.status, "dur", time.Since(start).Round(time.Millisecond))
	})
}
