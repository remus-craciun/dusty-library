// Package extract recognises uploaded book files and pulls the body text out
// of Word documents (.docx and legacy binary .doc) as a list of paragraphs.
//
// Everything here is pure Go so the server keeps building without CGO and
// needs no conversion tools installed on the host.
package extract

import (
	"bytes"
	"errors"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Formats returned by Detect. They match the store's format column.
const (
	PDF  = "pdf"
	Docx = "docx"
	Doc  = "doc"
)

// HeadSize is how many leading bytes Detect needs.
const HeadSize = 8

var (
	magicPDF = []byte("%PDF-")
	magicZip = []byte("PK\x03\x04")
	magicCFB = []byte{0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1}
)

// ErrNoText means the document parsed but contained no readable body text.
var ErrNoText = errors.New("document contains no text")

// ErrUnsupported is wrapped by errors for files that are well-formed
// containers but not a document this package can read (for example a zip
// that is not a Word document, or a password-protected .doc).
var ErrUnsupported = errors.New("unsupported document")

// Detect identifies a book file by its first bytes. It does not look at the
// file name: .docx is reported for any zip and is confirmed by Paragraphs.
func Detect(head []byte) (string, bool) {
	switch {
	case bytes.HasPrefix(head, magicPDF):
		return PDF, true
	case bytes.HasPrefix(head, magicZip):
		return Docx, true
	case bytes.HasPrefix(head, magicCFB):
		return Doc, true
	}
	return "", false
}

// Version of the extracted [Book] format. Stored books with an older
// version are extracted again (version 1 had no notes, version 2 no
// headings).
const Version = 3

// Book is the readable text of a Word document.
type Book struct {
	Version    int       `json:"version"`
	Paragraphs []string  `json:"paragraphs"`
	Notes      []Note    `json:"notes"`
	Headings   []Heading `json:"headings"`
}

// Heading is a paragraph the document marks as a title (a volume, part,
// chapter...), for the table of contents. Level 1 is the outermost.
type Heading struct {
	Paragraph int    `json:"paragraph"`
	Level     int    `json:"level"`
	Title     string `json:"title"`
}

// rawBook is what a format reader produces before clean-up: paragraphs with
// note markers, each paragraph's heading level (0 for body text), and the
// note texts in marker order.
type rawBook struct {
	paras  []string
	levels []int
	notes  []string
}

// maxHeadingRunes caps a contents entry; anything longer is not a title.
const maxHeadingRunes = 200

// Note is a footnote or endnote. Its marker (the label in superscript
// digits) is part of paragraph [Paragraph], starting at [Offset] counted in
// UTF-16 code units, as the client's strings index text.
type Note struct {
	Paragraph int    `json:"paragraph"`
	Offset    int    `json:"offset"`
	Label     string `json:"label"`
	Text      string `json:"text"`
}

// noteMark stands in for a note reference while text is being cleaned up. It
// is a private-use character, so whitespace handling leaves it alone.
const noteMark = '\uE000'

// Extract reads the Word document at path. format is Docx or Doc as
// returned by Detect. Paragraphs are the non-empty body paragraphs; each
// footnote or endnote gets a superscript number in the text where it is
// referenced; paragraphs styled as titles are listed as headings.
func Extract(path, format string) (*Book, error) {
	var (
		raw *rawBook
		err error
	)
	switch format {
	case Docx:
		raw, err = docxBook(path)
	case Doc:
		raw, err = docBook(path)
	default:
		return nil, ErrUnsupported
	}
	if err != nil {
		return nil, err
	}
	paras, from := normalizeIdx(raw.paras)
	b, at := assemble(paras, raw.notes)
	if len(b.Paragraphs) == 0 {
		return nil, ErrNoText
	}
	b.Headings = []Heading{}
	for i, src := range from {
		if src >= len(raw.levels) || raw.levels[src] <= 0 || at[i] < 0 {
			continue
		}
		title := headingTitle(b.Paragraphs[at[i]])
		if title == "" || utf8.RuneCountInString(title) > maxHeadingRunes {
			continue
		}
		b.Headings = append(b.Headings, Heading{Paragraph: at[i], Level: raw.levels[src], Title: title})
	}
	return b, nil
}

// headingTitle is a heading paragraph as a one-line contents entry: line
// breaks become spaces and note markers go.
func headingTitle(p string) string {
	p = strings.Map(func(r rune) rune {
		if strings.ContainsRune(superscriptDigits, r) {
			return -1
		}
		return r
	}, p)
	return strings.Join(strings.Fields(p), " ")
}

// Paragraphs is [Extract] without the notes.
func Paragraphs(path, format string) ([]string, error) {
	b, err := Extract(path, format)
	if err != nil {
		return nil, err
	}
	return b.Paragraphs, nil
}

// assemble replaces each note marker in [paras] with the note's number and
// records where it is. [notes] holds one text per marker, in order; markers
// whose note is empty are dropped. A paragraph left with nothing but markers
// is merged into the one before it. The second result gives, for each of
// [paras], its index in the book, or -1 when it was merged or dropped.
func assemble(paras []string, notes []string) (*Book, []int) {
	b := &Book{Version: Version, Paragraphs: make([]string, 0, len(paras)), Notes: []Note{}, Headings: []Heading{}}
	at := make([]int, len(paras))
	next := 0
	for pi, p := range paras {
		at[pi] = -1
		var (
			sb      strings.Builder
			units   int // UTF-16 length of sb
			found   []Note
			hasText bool
		)
		for _, r := range p {
			if r != noteMark {
				sb.WriteRune(r)
				units += utf16Len(r)
				hasText = true
				continue
			}
			text := ""
			if next < len(notes) {
				text = normalizeNote(notes[next])
			}
			next++
			if text == "" {
				continue
			}
			label := strconv.Itoa(len(b.Notes) + len(found) + 1)
			found = append(found, Note{Offset: units, Label: label, Text: text})
			sup := superscript(label)
			sb.WriteString(sup)
			units += len([]rune(sup)) // superscript digits are single UTF-16 units
		}
		text := strings.TrimSpace(sb.String())
		lead := units - utf16Units(strings.TrimLeft(sb.String(), " ")) // spaces trimmed off the front
		if !hasText || strings.Trim(text, superscriptDigits) == "" {
			if len(b.Paragraphs) == 0 {
				if text == "" {
					continue
				}
			} else {
				// Only markers: they belong at the end of the previous paragraph.
				last := len(b.Paragraphs) - 1
				shift := utf16Units(b.Paragraphs[last]) - lead
				for i := range found {
					found[i].Paragraph = last
					found[i].Offset += shift
				}
				b.Paragraphs[last] += text
				b.Notes = append(b.Notes, found...)
				continue
			}
		}
		for i := range found {
			found[i].Paragraph = len(b.Paragraphs)
			found[i].Offset -= lead
		}
		at[pi] = len(b.Paragraphs)
		b.Paragraphs = append(b.Paragraphs, text)
		b.Notes = append(b.Notes, found...)
	}
	return b, at
}

// normalizeNote tidies a note's text like body text, keeping its line breaks.
func normalizeNote(s string) string {
	s = strings.ReplaceAll(s, string(noteMark), "")
	return strings.Join(normalize([]string{s}), "\n")
}

const superscriptDigits = "⁰¹²³⁴⁵⁶⁷⁸⁹"

func superscript(label string) string {
	digits := []rune(superscriptDigits)
	var sb strings.Builder
	for _, r := range label {
		sb.WriteRune(digits[r-'0'])
	}
	return sb.String()
}

func utf16Len(r rune) int {
	if r >= 0x10000 {
		return 2
	}
	return 1
}

func utf16Units(s string) int {
	n := 0
	for _, r := range s {
		n += utf16Len(r)
	}
	return n
}

// normalize tidies whitespace inside each paragraph and drops the empty ones
// Word documents use for vertical spacing. Explicit line breaks are kept.
func normalize(raw []string) []string {
	out, _ := normalizeIdx(raw)
	return out
}

// normalizeIdx is [normalize] that also returns, for each kept paragraph,
// its index in [raw].
func normalizeIdx(raw []string) ([]string, []int) {
	out := make([]string, 0, len(raw))
	from := make([]int, 0, len(raw))
	for i, p := range raw {
		lines := strings.Split(p, "\n")
		kept := lines[:0]
		for _, l := range lines {
			l = collapseSpaces(l)
			if l != "" {
				kept = append(kept, l)
			}
		}
		if len(kept) > 0 {
			out = append(out, strings.Join(kept, "\n"))
			from = append(from, i)
		}
	}
	return out, from
}

// collapseSpaces trims a line and squeezes runs of spaces (but not tabs,
// which are usually deliberate) into one. Other control characters go.
func collapseSpaces(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	space := false
	for _, r := range s {
		switch {
		case r == '\t':
			b.WriteRune(r)
			space = false
		case r == ' ' || r == '\u00a0' || unicode.IsSpace(r):
			space = true
		case unicode.IsControl(r) || r == '\ufffd' || r == '\ufeff':
			// drop
		default:
			if space && b.Len() > 0 {
				b.WriteByte(' ')
			}
			space = false
			b.WriteRune(r)
		}
	}
	return strings.Trim(b.String(), "\t ")
}
