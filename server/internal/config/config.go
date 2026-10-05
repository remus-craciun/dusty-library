// Package config loads server configuration from flags and environment variables.
package config

import (
	"flag"
	"os"
	"path/filepath"
	"strconv"
)

// Config holds runtime configuration for the server.
type Config struct {
	// Addr is the listen address, e.g. ":8080".
	Addr string
	// DataDir holds the SQLite database and uploaded books.
	DataDir string
	// MaxUploadBytes caps the size of a single uploaded PDF.
	MaxUploadBytes int64
}

// Load parses command line flags, falling back to DUSTY_* environment variables
// and finally to defaults.
func Load(args []string) (Config, error) {
	fs := flag.NewFlagSet("dusty", flag.ContinueOnError)
	var cfg Config
	fs.StringVar(&cfg.Addr, "addr", envOr("DUSTY_ADDR", ":8080"), "listen address")
	fs.StringVar(&cfg.DataDir, "data", envOr("DUSTY_DATA_DIR", "./data"), "data directory")
	fs.Int64Var(&cfg.MaxUploadBytes, "max-upload", envInt64Or("DUSTY_MAX_UPLOAD_BYTES", 512<<20), "maximum upload size in bytes")
	if err := fs.Parse(args); err != nil {
		return cfg, err
	}
	abs, err := filepath.Abs(cfg.DataDir)
	if err != nil {
		return cfg, err
	}
	cfg.DataDir = abs
	return cfg, nil
}

// DBPath returns the SQLite file path.
func (c Config) DBPath() string { return filepath.Join(c.DataDir, "dusty.db") }

// BooksDir returns the directory where uploaded PDFs are stored.
func (c Config) BooksDir() string { return filepath.Join(c.DataDir, "books") }

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt64Or(key string, def int64) int64 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			return n
		}
	}
	return def
}
