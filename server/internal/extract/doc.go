package extract

import (
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"

	"github.com/richardlehane/mscfb"
)

// Legacy Word 97-2003 (.doc) text extraction, following [MS-DOC]:
//
//  1. The WordDocument stream starts with the FIB, which says which table
//     stream (0Table or 1Table) is in use, how many characters each story
//     has (main text, footnotes, headers, comments, endnotes) and where the
//     piece table (Clx) and the note tables live.
//  2. The piece table maps character positions (CPs) to byte ranges in the
//     WordDocument stream, each either 8-bit cp1252 or UTF-16LE. All stories
//     share one CP space, one after another.
//  3. The main document is CPs [0, ccpText). Footnote references sit at the
//     CPs listed in PlcffndRef, and the text of note i is the range
//     [aCP[i], aCP[i+1]) of PlcffndTxt within the footnote story; endnotes
//     work the same way.

const (
	maxStreamBytes = 256 << 20
	wIdentWord     = 0xA5EC
	nFibWord97     = 0x00C1

	fibFlagWhichTable = 0x0200
	fibFlagEncrypted  = 0x0100

	// Indexes into FibRgLw97.
	fibRgLwCcpText = 3
	fibRgLwCcpFtn  = 4
	fibRgLwCcpHdd  = 5
	fibRgLwCcpMcr  = 6
	fibRgLwCcpAtn  = 7
	fibRgLwCcpEdn  = 8

	// Indexes of fc/lcb pairs in FibRgFcLcb97.
	fibRgFcLcbStshf   = 1
	fibRgFcLcbFndRef  = 2
	fibRgFcLcbFndTxt  = 3
	fibRgFcLcbBtePapx = 13
	fibRgFcLcbClx     = 33
	fibRgFcLcbEndRef  = 46
	fibRgFcLcbEndTxt  = 47

	sprmPOutLvl   = 0x2640
	sprmTDefTable = 0xD608
	istdNil       = 0x0FFF
)

func docBook(path string) (*rawBook, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	cfb, err := mscfb.New(f)
	if err != nil {
		return nil, fmt.Errorf("%w: not a valid .doc (%v)", ErrUnsupported, err)
	}
	streams := map[string][]byte{}
	for entry, err := cfb.Next(); err == nil; entry, err = cfb.Next() {
		if len(entry.Path) != 0 {
			continue // only root-level streams
		}
		switch entry.Name {
		case "WordDocument", "0Table", "1Table":
			if entry.Size > maxStreamBytes {
				return nil, fmt.Errorf("%w: %v", ErrUnsupported, errTooLarge)
			}
			buf, err := io.ReadAll(io.LimitReader(entry, entry.Size))
			if err != nil {
				return nil, fmt.Errorf("%w: reading %s (%v)", ErrUnsupported, entry.Name, err)
			}
			streams[entry.Name] = buf
		}
	}
	word, ok := streams["WordDocument"]
	if !ok {
		return nil, fmt.Errorf("%w: file is not a Word document", ErrUnsupported)
	}
	d, err := parseDoc(word, streams)
	if err != nil {
		return nil, err
	}
	st := splitDocText(d.main(), d.refs(), d.styleAt)
	return &rawBook{
		paras:  st.paras,
		levels: levelsFor(d.styles, st.styles, st.instrs),
		notes:  st.notes,
	}, nil
}

// docFile is a parsed .doc: all story text plus the note tables.
type docFile struct {
	text                      []uint16 // every story, in CP order
	ccpText, ccpFtn, ftnStart int
	ednStart, ccpEdn          int
	fndRef, fndTxt            []int // CPs from PlcffndRef / PlcffndTxt
	endRef, endTxt            []int

	pieces []piece    // CP → byte position in WordDocument
	runs   []papRun   // paragraph properties by byte position, sorted
	styles styleSheet // keyed by style index (istd) as a string
}

type piece struct {
	cpStart, cpEnd int
	fc             int // byte position of cpStart
	compressed     bool
}

// papRun is one paragraph's properties from a PAPX FKP: the paragraph's
// bytes [fcStart, fcEnd) in the WordDocument stream.
type papRun struct {
	fcStart, fcEnd int
	style          paraStyle
}

// styleAt gives the style of the paragraph whose mark is at [cp].
func (d *docFile) styleAt(cp int) paraStyle {
	none := paraStyle{outline: outlineUnset}
	fc := -1
	for _, p := range d.pieces {
		if cp >= p.cpStart && cp < p.cpEnd {
			if p.compressed {
				fc = p.fc + (cp - p.cpStart)
			} else {
				fc = p.fc + 2*(cp-p.cpStart)
			}
			break
		}
	}
	if fc < 0 {
		return none
	}
	i := sort.Search(len(d.runs), func(i int) bool { return d.runs[i].fcEnd > fc })
	if i < len(d.runs) && d.runs[i].fcStart <= fc {
		return d.runs[i].style
	}
	return none
}

func (d *docFile) main() []uint16 { return d.story(0, d.ccpText) }

func (d *docFile) story(start, length int) []uint16 {
	end := start + length
	if start < 0 || start > len(d.text) {
		return nil
	}
	if end > len(d.text) {
		end = len(d.text)
	}
	return d.text[start:end]
}

// refs maps the main-text CP of each note reference to that note's text.
func (d *docFile) refs() map[int]string {
	out := map[int]string{}
	add := func(refCPs, txtCPs []int, storyStart, storyLen int) {
		for i, cp := range refCPs {
			if i+1 >= len(txtCPs) || cp < 0 || cp >= d.ccpText {
				continue
			}
			from, to := txtCPs[i], txtCPs[i+1]
			if from < 0 || to <= from || to > storyLen {
				continue
			}
			st := splitDocText(d.story(storyStart+from, to-from), nil, nil)
			out[cp] = strings.Join(st.paras, "\n")
		}
	}
	add(d.fndRef, d.fndTxt, d.ftnStart, d.ccpFtn)
	add(d.endRef, d.endTxt, d.ednStart, d.ccpEdn)
	return out
}

func parseDoc(word []byte, streams map[string][]byte) (*docFile, error) {
	bad := func(what string) error {
		return fmt.Errorf("%w: damaged .doc (%s)", ErrUnsupported, what)
	}
	if len(word) < 34 {
		return nil, bad("short header")
	}
	if binary.LittleEndian.Uint16(word[0:]) != wIdentWord {
		return nil, bad("bad signature")
	}
	if binary.LittleEndian.Uint16(word[2:]) < nFibWord97 {
		return nil, fmt.Errorf("%w: documents from Word 95 or older are not supported; save it as .docx", ErrUnsupported)
	}
	flags := binary.LittleEndian.Uint16(word[0x0A:])
	if flags&fibFlagEncrypted != 0 {
		return nil, fmt.Errorf("%w: password-protected documents are not supported", ErrUnsupported)
	}
	tableName := "0Table"
	if flags&fibFlagWhichTable != 0 {
		tableName = "1Table"
	}
	table, ok := streams[tableName]
	if !ok {
		return nil, bad("missing " + tableName)
	}

	// FibBase is 32 bytes, then three variable-length arrays each preceded
	// by its element count.
	off := 32
	csw := int(binary.LittleEndian.Uint16(word[off:]))
	off += 2 + csw*2
	if off+2 > len(word) {
		return nil, bad("short FIB")
	}
	cslw := int(binary.LittleEndian.Uint16(word[off:]))
	off += 2
	lw := off
	off += cslw * 4
	if cslw <= fibRgLwCcpEdn || off+2 > len(word) {
		return nil, bad("short FIB")
	}
	ccp := func(i int) int {
		v := int(int32(binary.LittleEndian.Uint32(word[lw+i*4:])))
		if v < 0 {
			return 0
		}
		return v
	}
	d := &docFile{ccpText: ccp(fibRgLwCcpText), ccpFtn: ccp(fibRgLwCcpFtn), ccpEdn: ccp(fibRgLwCcpEdn)}
	d.ftnStart = d.ccpText
	d.ednStart = d.ccpText + d.ccpFtn + ccp(fibRgLwCcpHdd) + ccp(fibRgLwCcpMcr) + ccp(fibRgLwCcpAtn)
	total := d.ednStart + d.ccpEdn

	cbRgFcLcb := int(binary.LittleEndian.Uint16(word[off:]))
	off += 2
	if cbRgFcLcb <= fibRgFcLcbClx || off+(fibRgFcLcbClx+1)*8 > len(word) {
		return nil, bad("short FIB")
	}
	fcLcb := func(i int) (int, int, bool) {
		if i >= cbRgFcLcb || off+(i+1)*8 > len(word) {
			return 0, 0, false
		}
		fc := int(binary.LittleEndian.Uint32(word[off+i*8:]))
		lcb := int(binary.LittleEndian.Uint32(word[off+i*8+4:]))
		if lcb <= 0 || fc < 0 || fc+lcb > len(table) {
			return 0, 0, false
		}
		return fc, lcb, true
	}

	fcClx, lcbClx, ok := fcLcb(fibRgFcLcbClx)
	if !ok {
		return nil, bad("piece table out of range")
	}
	text, pieces, err := pieceText(word, table[fcClx:fcClx+lcbClx], total, bad)
	if err != nil {
		return nil, err
	}
	d.text = text
	d.pieces = pieces

	// Styles and paragraph properties, for headings. Damaged tables just
	// mean no headings.
	if fc, lcb, ok := fcLcb(fibRgFcLcbStshf); ok {
		d.styles = parseStylesheet(table[fc : fc+lcb])
	}
	if fc, lcb, ok := fcLcb(fibRgFcLcbBtePapx); ok {
		d.runs = parsePapx(word, table[fc:fc+lcb])
	}

	// Note tables. A damaged or missing table just means no notes.
	plcCPs := func(i, dataSize int) []int {
		fc, lcb, ok := fcLcb(i)
		if !ok || lcb < 4 || (lcb-4)%(4+dataSize) != 0 {
			return nil
		}
		n := (lcb - 4) / (4 + dataSize)
		cps := make([]int, n+1)
		for k := range cps {
			cps[k] = int(binary.LittleEndian.Uint32(table[fc+k*4:]))
		}
		return cps
	}
	if d.ccpFtn > 0 {
		if refs := plcCPs(fibRgFcLcbFndRef, 2); len(refs) > 0 {
			d.fndRef = refs[:len(refs)-1] // the last CP ends the array
		}
		d.fndTxt = plcCPs(fibRgFcLcbFndTxt, 0)
	}
	if d.ccpEdn > 0 {
		if refs := plcCPs(fibRgFcLcbEndRef, 2); len(refs) > 0 {
			d.endRef = refs[:len(refs)-1]
		}
		d.endTxt = plcCPs(fibRgFcLcbEndTxt, 0)
	}
	return d, nil
}

// pieceText decodes the first [total] characters described by the Clx, and
// returns the pieces for mapping characters back to bytes.
func pieceText(word, clx []byte, total int, bad func(string) error) ([]uint16, []piece, error) {
	// Skip Prc entries (property modifiers) to reach the Pcdt.
	i := 0
	for i < len(clx) && clx[i] == 0x01 {
		if i+3 > len(clx) {
			return nil, nil, bad("short Clx")
		}
		cb := int(int16(binary.LittleEndian.Uint16(clx[i+1:])))
		if cb < 0 {
			return nil, nil, bad("bad Prc")
		}
		i += 3 + cb
	}
	if i+5 > len(clx) || clx[i] != 0x02 {
		return nil, nil, bad("missing Pcdt")
	}
	lcb := int(binary.LittleEndian.Uint32(clx[i+1:]))
	plc := clx[i+5:]
	if lcb < 4 || lcb > len(plc) || (lcb-4)%12 != 0 {
		return nil, nil, bad("bad PlcPcd")
	}
	n := (lcb - 4) / 12
	cps := plc[:(n+1)*4]
	pcds := plc[(n+1)*4 : lcb]

	text := make([]uint16, 0, total)
	var pieces []piece
	for k := 0; k < n && len(text) < total; k++ {
		cpStart := int(binary.LittleEndian.Uint32(cps[k*4:]))
		cpEnd := int(binary.LittleEndian.Uint32(cps[(k+1)*4:]))
		if cpEnd <= cpStart {
			continue
		}
		count := cpEnd - cpStart
		if rem := total - len(text); count > rem {
			count = rem
		}
		fc := binary.LittleEndian.Uint32(pcds[k*8+2:])
		compressed := fc&0x40000000 != 0
		start := int(fc)
		if compressed {
			start = int(fc&0x3FFFFFFF) / 2
		}
		pieces = append(pieces, piece{cpStart: len(text), cpEnd: len(text) + count, fc: start, compressed: compressed})
		if compressed { // 8-bit cp1252
			if start+count > len(word) {
				return nil, nil, bad("piece out of range")
			}
			for _, c := range word[start : start+count] {
				text = append(text, cp1252(c))
			}
		} else {
			if start+count*2 > len(word) {
				return nil, nil, bad("piece out of range")
			}
			for j := 0; j < count; j++ {
				text = append(text, binary.LittleEndian.Uint16(word[start+j*2:]))
			}
		}
	}
	return text, pieces, nil
}

// parseStylesheet reads the STSH: for each style its name, base style,
// built-in identifier (sti 1-9 are Heading 1-9) and the outline level in its
// paragraph properties.
func parseStylesheet(stsh []byte) styleSheet {
	out := styleSheet{}
	u16 := func(b []byte, at int) (int, bool) {
		if at < 0 || at+2 > len(b) {
			return 0, false
		}
		return int(binary.LittleEndian.Uint16(b[at:])), true
	}
	cbStshi, ok := u16(stsh, 0)
	if !ok || 2+cbStshi > len(stsh) || cbStshi < 4 {
		return out
	}
	cstd, _ := u16(stsh, 2)
	cbBase, _ := u16(stsh, 4)
	if cbBase < 10 {
		return out
	}
	pos := 2 + cbStshi
	for istd := 0; istd < cstd; istd++ {
		cbStd, ok := u16(stsh, pos)
		if !ok {
			break
		}
		pos += 2
		if cbStd == 0 {
			continue
		}
		if pos+cbStd > len(stsh) {
			break
		}
		std := stsh[pos : pos+cbStd]
		pos += cbStd
		if len(std) < cbBase+2 {
			continue
		}
		w0, _ := u16(std, 0)
		w1, _ := u16(std, 2)
		w2, _ := u16(std, 4)
		sti, stk, base, cupx := w0&0x0FFF, w1&0x000F, w1>>4, w2&0x000F
		st := &styleInfo{outline: outlineUnset}
		if sti >= 1 && sti <= 9 {
			st.heading = sti
		}
		if base != istdNil {
			st.base = strconv.Itoa(base)
		}
		// Name: a length-prefixed UTF-16 string ending in a null.
		p := cbBase
		cch, _ := u16(std, p)
		if p+2+cch*2 <= len(std) {
			units := make([]uint16, cch)
			for i := range units {
				units[i] = binary.LittleEndian.Uint16(std[p+2+i*2:])
			}
			st.name = string(utf16.Decode(units))
		}
		p += 2 + cch*2 + 2
		// Paragraph styles carry paragraph properties in their first UPX.
		if stk == 1 && cupx >= 1 {
			if p%2 == 1 {
				p++
			}
			if cb, ok := u16(std, p); ok && p+2+cb <= len(std) && cb >= 2 {
				if v, ok := sprmByte(std[p+4:p+2+cb], sprmPOutLvl); ok {
					st.outline = outlineValue(strconv.Itoa(int(v)))
				}
			}
		}
		out[strconv.Itoa(istd)] = st
	}
	return out
}

// parsePapx reads the paragraph properties of every paragraph: PlcBtePapx
// lists the 512-byte FKP pages, each mapping byte ranges of text to a style
// index and direct properties.
func parsePapx(word, plc []byte) []papRun {
	if len(plc) < 4 || (len(plc)-4)%8 != 0 {
		return nil
	}
	n := (len(plc) - 4) / 8
	var runs []papRun
	for k := 0; k < n; k++ {
		pn := int(binary.LittleEndian.Uint32(plc[(n+1)*4+k*4:]) & 0x3FFFFF)
		if pn*512+512 > len(word) {
			continue
		}
		page := word[pn*512 : pn*512+512]
		crun := int(page[511])
		if 4*(crun+1)+13*crun > 511 {
			continue
		}
		for i := 0; i < crun; i++ {
			run := papRun{
				fcStart: int(binary.LittleEndian.Uint32(page[i*4:])),
				fcEnd:   int(binary.LittleEndian.Uint32(page[(i+1)*4:])),
				style:   paraStyle{style: "0", outline: outlineUnset},
			}
			if off := int(page[4*(crun+1)+13*i]) * 2; off > 0 && off < 511 {
				start, size := off+1, 2*int(page[off])-1
				if page[off] == 0 && off+1 < 511 {
					start, size = off+2, 2*int(page[off+1])
				}
				if size >= 2 && start+size <= 511 {
					gpi := page[start : start+size]
					run.style.style = strconv.Itoa(int(binary.LittleEndian.Uint16(gpi)))
					if v, ok := sprmByte(gpi[2:], sprmPOutLvl); ok {
						run.style.outline = outlineValue(strconv.Itoa(int(v)))
					}
				}
			}
			runs = append(runs, run)
		}
	}
	sort.Slice(runs, func(i, j int) bool { return runs[i].fcStart < runs[j].fcStart })
	return runs
}

// sprmByte finds property [want] in a list of property modifiers and returns
// the first byte of its operand.
func sprmByte(grpprl []byte, want uint16) (byte, bool) {
	for i := 0; i+2 <= len(grpprl); {
		sprm := binary.LittleEndian.Uint16(grpprl[i:])
		i += 2
		size := 0
		switch sprm >> 13 { // spra: operand size
		case 0, 1:
			size = 1
		case 2, 4, 5:
			size = 2
		case 3:
			size = 4
		case 7:
			size = 3
		case 6:
			if sprm == sprmTDefTable {
				if i+2 > len(grpprl) {
					return 0, false
				}
				size = int(binary.LittleEndian.Uint16(grpprl[i:])) + 1
			} else {
				if i >= len(grpprl) {
					return 0, false
				}
				size = int(grpprl[i]) + 1
			}
		}
		if sprm == want && i < len(grpprl) {
			return grpprl[i], true
		}
		i += size
	}
	return 0, false
}

// docStory is a story split into paragraphs.
type docStory struct {
	paras  []string
	styles []paraStyle // parallel to paras
	notes  []string    // note texts, in marker order
	instrs []string    // field instructions
}

// splitDocText turns story characters into paragraphs. [refs] maps the CP
// of a note reference to the note's text: a note marker is written there and
// the text appended to the notes, in order. [styleAt] (optional) gives the
// style of the paragraph whose mark is at a CP.
func splitDocText(text []uint16, refs map[int]string, styleAt func(int) paraStyle) docStory {
	var (
		st  docStory
		cur []uint16
		// Field nesting: for each open field, whether we have passed its
		// separator (and are therefore in the displayed result).
		fields []bool
	)
	flush := func(cp int) {
		st.paras = append(st.paras, string(utf16.Decode(cur)))
		style := paraStyle{outline: outlineUnset}
		if styleAt != nil {
			style = styleAt(cp)
		}
		st.styles = append(st.styles, style)
		cur = cur[:0]
	}
	inCode := func() bool {
		for _, inResult := range fields {
			if !inResult {
				return true
			}
		}
		return false
	}
	for cp, c := range text {
		switch c {
		case 0x13: // field begin
			if len(fields) == 0 {
				st.instrs = append(st.instrs, "")
			}
			fields = append(fields, false)
			continue
		case 0x14: // field separator
			if n := len(fields); n > 0 {
				fields[n-1] = true
			}
			continue
		case 0x15: // field end
			if n := len(fields); n > 0 {
				fields = fields[:n-1]
			}
			continue
		}
		if inCode() {
			if n := len(st.instrs); n > 0 {
				st.instrs[n-1] += string(rune(c))
			}
			continue
		}
		if note, ok := refs[cp]; ok {
			cur = append(cur, uint16(noteMark))
			st.notes = append(st.notes, note)
			continue
		}
		switch c {
		case 0x0D, 0x07, 0x0C: // paragraph, cell/row end, page/section break
			flush(cp)
		case 0x0B: // manual line break
			cur = append(cur, '\n')
		case 0x09:
			cur = append(cur, '\t')
		case 0x1E: // non-breaking hyphen
			cur = append(cur, '-')
		case 0x1F: // optional hyphen
		case 0x01, 0x02, 0x03, 0x04, 0x05, 0x08: // pictures, note numbers, separators, drawn objects
		default:
			cur = append(cur, c)
		}
	}
	if len(cur) > 0 {
		flush(len(text) - 1)
	}
	return st
}

// cp1252 maps a Windows-1252 byte to UTF-16. Only 0x80-0x9F differ from
// Latin-1.
func cp1252(b byte) uint16 {
	if b < 0x80 || b > 0x9F {
		return uint16(b)
	}
	return cp1252High[b-0x80]
}

var cp1252High = [32]uint16{
	0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
	0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
	0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
	0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
}
