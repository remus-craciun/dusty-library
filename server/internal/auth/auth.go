// Package auth implements password hashing, opaque session tokens and the HTTP
// middleware that authenticates API requests.
//
// Tokens never expire on their own: a token is valid for as long as its
// session row exists, and logging out deletes that row.
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"golang.org/x/crypto/bcrypt"
)

// HashPassword hashes a plaintext password with bcrypt.
func HashPassword(password string) (string, error) {
	h, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	return string(h), err
}

// CheckPassword reports whether password matches hash.
func CheckPassword(hash, password string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

// NewToken returns a fresh random bearer token and the hash to persist.
func NewToken() (token, hash string, err error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", "", err
	}
	token = hex.EncodeToString(raw)
	return token, HashToken(token), nil
}

// HashToken derives the storage key for a token. Tokens are high-entropy, so
// an unsalted SHA-256 is sufficient and keeps lookups indexable.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// Principal identifies the caller of an authenticated request.
type Principal struct {
	UserID    int64
	SessionID int64
}

// ErrInvalidToken is returned by a Resolver for unknown or revoked tokens.
var ErrInvalidToken = errors.New("invalid token")

// Resolver maps a token hash to the principal it belongs to.
type Resolver func(ctx context.Context, tokenHash string) (Principal, error)

type ctxKey struct{}

// From extracts the principal from the request context.
func From(ctx context.Context) (Principal, bool) {
	p, ok := ctx.Value(ctxKey{}).(Principal)
	return p, ok
}

// UserID extracts the authenticated user id from the request context.
func UserID(ctx context.Context) (int64, bool) {
	p, ok := From(ctx)
	return p.UserID, ok
}

// Middleware rejects requests without a valid bearer token and stores the
// principal in the request context for downstream handlers.
func Middleware(resolve Resolver, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			unauthorized(w, "missing bearer token")
			return
		}
		token := strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
		if token == "" {
			unauthorized(w, "missing bearer token")
			return
		}
		p, err := resolve(r.Context(), HashToken(token))
		if err != nil {
			if errors.Is(err, ErrInvalidToken) {
				unauthorized(w, "invalid or revoked token")
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprint(w, `{"error":"internal error"}`)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, p)))
	})
}

func unauthorized(w http.ResponseWriter, msg string) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	fmt.Fprintf(w, `{"error":%q}`, msg)
}
