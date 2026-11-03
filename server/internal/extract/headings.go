package extract

import (
	"regexp"
	"strconv"
	"strings"
)

// Headings for the table of contents come from how a document marks its
// titles, in this order:
//
//  1. an outline level set on the paragraph itself;
//  2. an outline level set on its style, or on the style it is based on;
//  3. a built-in "heading N" style (Word's Heading 1-9);
//  4. the document's own table of contents: a TOC field with \t "Style;1;..."
//     says which (custom) styles make up which level, the way many converted
//     books mark "Volume", "Part" and "Chapter".
//
// Outline level 9 means body text and stops the search.

const (
	outlineUnset = -1
	outlineBody  = 9
)

// paraStyle is what a reader records for each raw paragraph.
type paraStyle struct {
	style   string // style id (docx) or index (doc), "" for the default
	outline int    // direct outline level 0-9, or outlineUnset
}

type styleInfo struct {
	name    string
	base    string // style it is based on, "" for none
	outline int    // 0-9, or outlineUnset
	heading int    // 1-9 for built-in heading styles
}

type styleSheet map[string]*styleInfo

var headingName = regexp.MustCompile(`(?i)^heading ([1-9])$`)

// level gives the 1-based heading level of a paragraph, or 0 for body text.
func (s styleSheet) level(p paraStyle, toc map[string]int) int {
	if p.outline != outlineUnset {
		if p.outline >= outlineBody {
			return 0
		}
		return p.outline + 1
	}
	id := p.style
	for seen := 0; id != "" && seen < 16; seen++ {
		st, ok := s[id]
		if !ok {
			return 0
		}
		if st.outline != outlineUnset {
			if st.outline >= outlineBody {
				return 0
			}
			return st.outline + 1
		}
		if st.heading > 0 {
			return st.heading
		}
		if lvl, ok := toc[strings.ToLower(st.name)]; ok {
			return lvl
		}
		if lvl, ok := toc[strings.ToLower(id)]; ok {
			return lvl
		}
		if m := headingName.FindStringSubmatch(st.name); m != nil {
			n, _ := strconv.Atoi(m[1])
			return n
		}
		id = st.base
	}
	return 0
}

var tocStyles = regexp.MustCompile(`\\t\s+"([^"]*)"`)

// parseTOCStyles reads the style-to-level list of TOC field instructions:
// ` TOC \o "1-3" \h \t "TitluVolum;1;TitluParte;2" ` gives
// {"titluvolum": 1, "titluparte": 2}. Word separates the list with the
// locale's list separator, so both ';' and ',' are accepted.
func parseTOCStyles(instrs []string) map[string]int {
	out := map[string]int{}
	for _, in := range instrs {
		in = strings.TrimSpace(in)
		if !strings.HasPrefix(strings.ToUpper(in), "TOC") {
			continue
		}
		for _, m := range tocStyles.FindAllStringSubmatch(in, -1) {
			parts := strings.FieldsFunc(m[1], func(r rune) bool { return r == ';' || r == ',' })
			for i := 0; i+1 < len(parts); i += 2 {
				name := strings.ToLower(strings.TrimSpace(parts[i]))
				lvl, err := strconv.Atoi(strings.TrimSpace(parts[i+1]))
				if name != "" && err == nil && lvl >= 1 && lvl <= 9 {
					out[name] = lvl
				}
			}
		}
	}
	return out
}

// levelsFor resolves every paragraph's heading level.
func levelsFor(styles styleSheet, paras []paraStyle, instrs []string) []int {
	toc := parseTOCStyles(instrs)
	out := make([]int, len(paras))
	for i, p := range paras {
		out[i] = styles.level(p, toc)
	}
	return out
}
