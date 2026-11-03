package extract

import (
	"archive/zip"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"path"
	"strconv"
	"strings"
)

// maxXMLBytes caps how much decompressed XML is read from one part, so a
// small zip cannot expand into an unbounded amount of work.
const maxXMLBytes = 256 << 20

const (
	relOfficeDocument = "/officeDocument"
	relFootnotes      = "/footnotes"
	relEndnotes       = "/endnotes"
	relStyles         = "/styles"
)

// docxBook returns the body paragraphs, with a note marker at each footnote
// or endnote reference, their heading levels, and the text of those notes in
// marker order.
func docxBook(filePath string) (*rawBook, error) {
	zr, err := zip.OpenReader(filePath)
	if err != nil {
		return nil, fmt.Errorf("%w: not a valid .docx (%v)", ErrUnsupported, err)
	}
	defer zr.Close()

	files := make(map[string]*zip.File, len(zr.File))
	for _, f := range zr.File {
		files[strings.TrimPrefix(f.Name, "/")] = f
	}
	main := relTarget(files, "_rels/.rels", "", relOfficeDocument, "word/document.xml")
	if _, ok := files[main]; !ok {
		return nil, fmt.Errorf("%w: zip is not a Word document", ErrUnsupported)
	}

	var body collector
	if err := readPart(files, main, body.feed); err != nil {
		return nil, err
	}

	// Notes live in their own parts, named by the main document's rels.
	dir := path.Dir(main)
	rels := path.Join(dir, "_rels", path.Base(main)+".rels")
	notes := map[string]map[string]string{
		"footnote": readNotes(files, relTarget(files, rels, dir, relFootnotes, path.Join(dir, "footnotes.xml")), "footnote"),
		"endnote":  readNotes(files, relTarget(files, rels, dir, relEndnotes, path.Join(dir, "endnotes.xml")), "endnote"),
	}
	texts := make([]string, len(body.refs))
	for i, r := range body.refs {
		texts[i] = notes[r.kind][r.id] // "" (dropped later) when missing
	}
	styles := readStyles(files, relTarget(files, rels, dir, relStyles, path.Join(dir, "styles.xml")))
	return &rawBook{
		paras:  body.out,
		levels: levelsFor(styles, body.styles, body.instrs),
		notes:  texts,
	}, nil
}

// readStyles parses styles.xml: each paragraph style's name, the style it
// is based on and its outline level. A missing or damaged part gives none.
func readStyles(files map[string]*zip.File, name string) styleSheet {
	out := styleSheet{}
	if _, ok := files[name]; !ok {
		return out
	}
	var cur *styleInfo
	_ = readPart(files, name, func(tok xml.Token) {
		switch t := tok.(type) {
		case xml.StartElement:
			switch t.Name.Local {
			case "style":
				cur = nil
				if typ := attr(t, "type"); typ == "" || typ == "paragraph" {
					cur = &styleInfo{outline: outlineUnset}
					out[attr(t, "styleId")] = cur
				}
			case "name":
				if cur != nil {
					cur.name = attr(t, "val")
				}
			case "basedOn":
				if cur != nil {
					cur.base = attr(t, "val")
				}
			case "outlineLvl":
				if cur != nil {
					cur.outline = outlineValue(attr(t, "val"))
				}
			}
		case xml.EndElement:
			if t.Name.Local == "style" {
				cur = nil
			}
		}
	})
	return out
}

func outlineValue(v string) int {
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 || n > outlineBody {
		return outlineUnset
	}
	return n
}

// readPart streams one XML part through [feed].
func readPart(files map[string]*zip.File, name string, feed func(xml.Token)) error {
	f, ok := files[name]
	if !ok {
		return fmt.Errorf("%w: missing %s", ErrUnsupported, name)
	}
	rc, err := f.Open()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUnsupported, err)
	}
	defer rc.Close()
	dec := xml.NewDecoder(&limitedReader{r: rc, n: maxXMLBytes})
	dec.Strict = false
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			if errors.Is(err, errTooLarge) {
				return fmt.Errorf("%w: %v", ErrUnsupported, err)
			}
			return fmt.Errorf("%w: malformed %s (%v)", ErrUnsupported, name, err)
		}
		feed(tok)
	}
}

// readNotes parses footnotes.xml or endnotes.xml into id → text. The
// separator entries Word keeps there are skipped. A missing or damaged part
// just means there are no notes.
func readNotes(files map[string]*zip.File, name, kind string) map[string]string {
	out := map[string]string{}
	if _, ok := files[name]; !ok {
		return out
	}
	var (
		cur   *collector
		id    string
		depth int
	)
	_ = readPart(files, name, func(tok xml.Token) {
		switch t := tok.(type) {
		case xml.StartElement:
			if cur == nil {
				if t.Name.Local == kind {
					typ := attr(t, "type")
					if typ == "" || typ == "normal" {
						cur, id, depth = &collector{}, attr(t, "id"), 0
					}
				}
				return
			}
			depth++
		case xml.EndElement:
			if cur == nil {
				return
			}
			if depth == 0 && t.Name.Local == kind {
				out[id] = strings.Join(cur.out, "\n")
				cur = nil
				return
			}
			depth--
		}
		if cur != nil {
			cur.feed(tok)
		}
	})
	return out
}

func attr(e xml.StartElement, local string) string {
	for _, a := range e.Attr {
		if a.Name.Local == local {
			return a.Value
		}
	}
	return ""
}

// relTarget looks up the part a relationship of [relType] points to in the
// rels part [rels] (targets are relative to [base]), or returns [fallback].
func relTarget(files map[string]*zip.File, rels, base, relType, fallback string) string {
	f, ok := files[rels]
	if !ok {
		return fallback
	}
	rc, err := f.Open()
	if err != nil {
		return fallback
	}
	defer rc.Close()
	var doc struct {
		Rel []struct {
			Type       string `xml:"Type,attr"`
			Target     string `xml:"Target,attr"`
			TargetMode string `xml:"TargetMode,attr"`
		} `xml:"Relationship"`
	}
	if err := xml.NewDecoder(io.LimitReader(rc, 1<<20)).Decode(&doc); err != nil {
		return fallback
	}
	for _, r := range doc.Rel {
		if strings.HasSuffix(r.Type, relType) && r.Target != "" && r.TargetMode != "External" {
			t := r.Target
			if !strings.HasPrefix(t, "/") {
				t = path.Join("/", base, t)
			}
			return strings.TrimPrefix(path.Clean(t), "/")
		}
	}
	return fallback
}

var errTooLarge = errors.New("document is too large")

type limitedReader struct {
	r io.Reader
	n int64
}

func (l *limitedReader) Read(p []byte) (int, error) {
	if l.n <= 0 {
		return 0, errTooLarge
	}
	if int64(len(p)) > l.n {
		p = p[:l.n]
	}
	n, err := l.r.Read(p)
	l.n -= int64(n)
	return n, err
}

type noteRef struct{ kind, id string }

type openPara struct {
	b     strings.Builder
	style paraStyle
}

// collector walks WordprocessingML and gathers the text of each w:p.
// Paragraphs nested inside another (text boxes) are emitted on their own
// after it. Deleted/moved-away text, field instructions, property blocks and
// the fallback copy of alternate content are skipped. Note references leave
// a [noteMark] in the text and are listed in [refs]. Each paragraph's style
// and outline level go in [styles] (parallel to [out]), and field
// instructions (for the TOC style list) in [instrs].
type collector struct {
	out     []string
	styles  []paraStyle
	refs    []noteRef
	instrs  []string
	stack   []*openPara // open paragraphs, innermost last
	inT     bool
	inInstr bool
	skip    int // depth inside an element whose content is ignored
	pPr     int // depth inside the open paragraph's properties
}

func (c *collector) top() *openPara {
	if len(c.stack) == 0 {
		return nil
	}
	return c.stack[len(c.stack)-1]
}

func (c *collector) cur() *strings.Builder {
	if p := c.top(); p != nil {
		return &p.b
	}
	return nil
}

func (c *collector) feed(tok xml.Token) {
	switch t := tok.(type) {
	case xml.StartElement:
		if c.skip > 0 {
			c.skip++
			return
		}
		if c.pPr > 0 {
			// Only the paragraph's style and outline level matter here.
			c.pPr++
			if p := c.top(); p != nil && c.pPr == 2 {
				switch t.Name.Local {
				case "pStyle":
					p.style.style = attr(t, "val")
				case "outlineLvl":
					p.style.outline = outlineValue(attr(t, "val"))
				}
			}
			return
		}
		switch t.Name.Local {
		case "pPr":
			if c.top() != nil {
				c.pPr = 1
			} else {
				c.skip = 1
			}
		case "rPr", "sectPr", "tblPr", "trPr", "tcPr",
			"del", "moveFrom", "delText", "delInstrText",
			"Fallback", "commentReference":
			c.skip = 1
		case "instrText":
			c.inInstr = true
		case "fldChar":
			if attr(t, "fldCharType") == "begin" {
				c.instrs = append(c.instrs, "")
			}
		case "fldSimple":
			c.instrs = append(c.instrs, attr(t, "instr"))
		case "p":
			c.stack = append(c.stack, &openPara{style: paraStyle{outline: outlineUnset}})
		case "t":
			c.inT = true
		case "tab", "ptab":
			if b := c.cur(); b != nil {
				b.WriteByte('\t')
			}
		case "br", "cr":
			if b := c.cur(); b != nil {
				b.WriteByte('\n')
			}
		case "noBreakHyphen":
			if b := c.cur(); b != nil {
				b.WriteByte('-')
			}
		case "footnoteReference", "endnoteReference":
			if b := c.cur(); b != nil {
				b.WriteRune(noteMark)
				c.refs = append(c.refs, noteRef{
					kind: strings.TrimSuffix(t.Name.Local, "Reference"),
					id:   attr(t, "id"),
				})
			}
		}
	case xml.EndElement:
		if c.skip > 0 {
			c.skip--
			return
		}
		if c.pPr > 0 {
			c.pPr--
			return
		}
		switch t.Name.Local {
		case "p":
			if n := len(c.stack); n > 0 {
				c.out = append(c.out, c.stack[n-1].b.String())
				c.styles = append(c.styles, c.stack[n-1].style)
				c.stack = c.stack[:n-1]
			}
		case "t":
			c.inT = false
		case "instrText":
			c.inInstr = false
		}
	case xml.CharData:
		if c.inInstr && c.skip == 0 && len(c.instrs) > 0 {
			c.instrs[len(c.instrs)-1] += string(t)
			return
		}
		if c.inT && c.skip == 0 {
			if b := c.cur(); b != nil {
				b.Write(t)
			}
		}
	}
}
