package store

// Shelf kinds. Active and Completed are created for every user and cannot be
// renamed or deleted; Custom shelves are user managed.
const (
	ShelfActive    = "active"
	ShelfCompleted = "completed"
	ShelfCustom    = "custom"
)

// Reader filters understood by the client.
var ValidFilters = map[string]bool{
	"none":  true,
	"paper": true,
	"sepia": true,
	"dark":  true,
}

// User is the single account on the server.
type User struct {
	ID           int64  `json:"id"`
	Username     string `json:"username"`
	PasswordHash string `json:"-"`
	CreatedAt    string `json:"created_at"`
}

// Shelf groups books.
type Shelf struct {
	ID        int64  `json:"id"`
	UserID    int64  `json:"-"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	SortOrder int    `json:"sort_order"`
	CreatedAt string `json:"created_at"`
}

// Book formats. PDFs are rendered as pages by the client; Word documents are
// converted to paragraphs of text on upload and read as reflowable text.
const (
	FormatPDF  = "pdf"
	FormatDocx = "docx"
	FormatDoc  = "doc"
)

// Book is an uploaded PDF or Word document together with its reading
// progress. For Word documents PageCount is the number of paragraphs and
// CurrentPage/PageOffset are a paragraph index and a fraction through it.
type Book struct {
	ID                int64   `json:"id"`
	UserID            int64   `json:"-"`
	ShelfID           int64   `json:"shelf_id"`
	Title             string  `json:"title"`
	Author            string  `json:"author"`
	Filename          string  `json:"filename"`
	Format            string  `json:"format"`
	SizeBytes         int64   `json:"size_bytes"`
	PageCount         int     `json:"page_count"`
	CurrentPage       int     `json:"current_page"`
	PageOffset        float64 `json:"page_offset"`
	ProgressUpdatedAt *string `json:"progress_updated_at"`
	LastReadAt        *string `json:"last_read_at"`
	CreatedAt         string  `json:"created_at"`
	UpdatedAt         string  `json:"updated_at"`
}

// Settings are per-user reader preferences.
type Settings struct {
	Zoom   float64 `json:"zoom"`
	Filter string  `json:"filter"`
}

// DefaultSettings returns the settings applied to a fresh account.
func DefaultSettings() Settings { return Settings{Zoom: 1.0, Filter: "none"} }
