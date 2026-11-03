package extract

import (
	"archive/zip"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
	"unicode/utf16"
)

var sampleParagraphs = []string{
	"The Dusty Library",
	"It was a “quiet” evening in the café — the lamps were low.",
	"Second line one\nsecond line two",
	"Cell A",
	"Cell B",
	"Ünïcödé ends here.",
}

func TestDetect(t *testing.T) {
	cases := map[string]string{
		"%PDF-1.7\n":                         PDF,
		"PK\x03\x04rest":                     Docx,
		"\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1xx": Doc,
	}
	for head, want := range cases {
		got, ok := Detect([]byte(head))
		if !ok || got != want {
			t.Errorf("Detect(%q) = %q, %v; want %q", head, got, ok, want)
		}
	}
	for _, head := range []string{"", "MZ\x90\x00", "PK\x05\x06", "%PD"} {
		if got, ok := Detect([]byte(head)); ok {
			t.Errorf("Detect(%q) = %q, want no match", head, got)
		}
	}
}

// The fixtures were saved by LibreOffice from the same source text.
func TestSampleFiles(t *testing.T) {
	for _, format := range []string{Docx, Doc} {
		got, err := Paragraphs(filepath.Join("testdata", "sample."+format), format)
		if err != nil {
			t.Fatalf("%s: %v", format, err)
		}
		if !reflect.DeepEqual(got, sampleParagraphs) {
			t.Errorf("%s:\n got  %q\n want %q", format, got, sampleParagraphs)
		}
	}
}

func writeDocx(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "x.docx")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	w, _ := zw.Create("word/document.xml")
	w.Write([]byte(`<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><w:body>` + body + `</w:body></w:document>`))
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
	return path
}

func TestDocxSkipsHiddenContent(t *testing.T) {
	path := writeDocx(t, `
<w:p><w:pPr><w:tabs><w:tab w:val="left" w:pos="720"/></w:tabs></w:pPr>
  <w:r><w:t>Name</w:t></w:r><w:r><w:tab/><w:t xml:space="preserve">value  with   spaces </w:t></w:r></w:p>
<w:p><w:r><w:t>Kept</w:t></w:r><w:del><w:r><w:delText>gone</w:delText></w:r></w:del>
  <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> PAGE </w:instrText></w:r>
  <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t> 7</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
<w:p/>
<w:p><w:r><mc:AlternateContent><mc:Choice><w:txbxContent><w:p><w:r><w:t>Box</w:t></w:r></w:p></w:txbxContent></mc:Choice>
  <mc:Fallback><w:txbxContent><w:p><w:r><w:t>Box</w:t></w:r></w:p></w:txbxContent></mc:Fallback></mc:AlternateContent></w:r>
  <w:r><w:t>Outer</w:t></w:r></w:p>`)
	got, err := Paragraphs(path, Docx)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"Name\tvalue with spaces", "Kept 7", "Box", "Outer"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestDocxErrors(t *testing.T) {
	empty := writeDocx(t, `<w:p/><w:p><w:r><w:t>   </w:t></w:r></w:p>`)
	if _, err := Paragraphs(empty, Docx); !errors.Is(err, ErrNoText) {
		t.Errorf("empty document: err = %v, want ErrNoText", err)
	}

	path := filepath.Join(t.TempDir(), "notword.zip")
	f, _ := os.Create(path)
	zw := zip.NewWriter(f)
	w, _ := zw.Create("hello.txt")
	w.Write([]byte("hi"))
	zw.Close()
	f.Close()
	if _, err := Paragraphs(path, Docx); !errors.Is(err, ErrUnsupported) {
		t.Errorf("plain zip: err = %v, want ErrUnsupported", err)
	}

	garbage := filepath.Join(t.TempDir(), "bad.doc")
	os.WriteFile(garbage, append(append([]byte{}, magicCFB...), make([]byte, 600)...), 0o644)
	if _, err := Paragraphs(garbage, Doc); !errors.Is(err, ErrUnsupported) {
		t.Errorf("garbage doc: err = %v, want ErrUnsupported", err)
	}
}

func TestSplitDocText(t *testing.T) {
	in := "Title\r" +
		"See \x13 HYPERLINK \"x\" \x14the site\x15 now\r" +
		"Page \x13 PAGE \x15here\x0Bnext line\r" +
		"A\x07B\x07\x07" +
		"pic\x01 non\x1Ebreak op\x1Ftional\x0C" +
		"tail"
	st := splitDocText(utf16.Encode([]rune(in)), nil, nil)
	paras, notes := st.paras, st.notes
	got := normalize(paras)
	want := []string{"Title", "See the site now", "Page here\nnext line", "A", "B", "pic non-break optional", "tail"}
	if !reflect.DeepEqual(got, want) || len(notes) != 0 {
		t.Errorf("got %q (notes %q), want %q", got, notes, want)
	}

	// A note reference (0x02) at a listed CP becomes a marker.
	st = splitDocText(utf16.Encode([]rune("Hi\x02 there\x02\r")), map[int]string{2: "salut"}, nil)
	paras, notes = st.paras, st.notes
	if !reflect.DeepEqual(paras, []string{"Hi\uE000 there"}) || !reflect.DeepEqual(notes, []string{"salut"}) {
		t.Errorf("refs: got %q, notes %q", paras, notes)
	}
}

// notes.docx has two footnotes and an endnote (plus Word's separator
// entries); notes.doc is the same document saved by LibreOffice as .doc.
func TestFootnotes(t *testing.T) {
	wantParas := []string{
		"Chapter One",
		"– Eh bien, mon prince, je vous ai fait peur.¹ Ea zâmbi.",
		"– Dieu, quelle sortie!² exclamă prinţul.³",
	}
	wantTexts := []string{"Văd că te-am speriat.", "Dumnezeule!", "Sfârşit."}
	for _, format := range []string{Docx, Doc} {
		b, err := Extract(filepath.Join("testdata", "notes."+format), format)
		if err != nil {
			t.Fatalf("%s: %v", format, err)
		}
		if !reflect.DeepEqual(b.Paragraphs, wantParas) {
			t.Errorf("%s paragraphs:\n got  %q\n want %q", format, b.Paragraphs, wantParas)
		}
		if len(b.Notes) != len(wantTexts) {
			t.Fatalf("%s: notes %+v", format, b.Notes)
		}
		for i, n := range b.Notes {
			if n.Text != wantTexts[i] || n.Label != strconv.Itoa(i+1) {
				t.Errorf("%s note %d: %+v", format, i, n)
			}
			// The offset (in UTF-16 units) points at the superscript label.
			units := utf16.Encode([]rune(b.Paragraphs[n.Paragraph]))
			got := string(utf16.Decode(units[n.Offset : n.Offset+1]))
			if got != superscript(n.Label) {
				t.Errorf("%s note %d: marker at offset is %q", format, i, got)
			}
		}
	}
}

func TestAssembleMarkers(t *testing.T) {
	m := string(noteMark)
	b, at := assemble([]string{"Before", m + m, "x" + m + "y" + m}, []string{"one", "two", "  ", "four"})
	if !reflect.DeepEqual(at, []int{0, -1, 1}) {
		t.Errorf("paragraph map %v", at)
	}
	wantParas := []string{"Before¹²", "xy³"}
	if !reflect.DeepEqual(b.Paragraphs, wantParas) {
		t.Fatalf("paragraphs %q, want %q", b.Paragraphs, wantParas)
	}
	want := []Note{
		{Paragraph: 0, Offset: 6, Label: "1", Text: "one"},
		{Paragraph: 0, Offset: 7, Label: "2", Text: "two"},
		{Paragraph: 1, Offset: 2, Label: "3", Text: "four"},
	}
	if !reflect.DeepEqual(b.Notes, want) {
		t.Errorf("notes %+v, want %+v", b.Notes, want)
	}
}

func TestCP1252(t *testing.T) {
	for b, want := range map[byte]rune{'a': 'a', 0x93: '“', 0x80: '€', 0xE9: 'é', 0x97: '—'} {
		if got := rune(cp1252(b)); got != want {
			t.Errorf("cp1252(%#x) = %q, want %q", b, got, want)
		}
	}
}

// headings.docx marks titles every supported way: an outline level on the
// style (Volume One), inherited from the base style (Part the First), a TOC
// \t style list split across instruction runs (Chapter One), a direct
// outline level, and a built-in "heading 2" name. A style with outline level
// 9 (body text) is not a heading even though its base style is.
func TestHeadings(t *testing.T) {
	b, err := Extract(filepath.Join("testdata", "headings.docx"), Docx)
	if err != nil {
		t.Fatal(err)
	}
	want := []Heading{
		{Paragraph: 1, Level: 1, Title: "Volume One"},
		{Paragraph: 2, Level: 1, Title: "Part the First"},
		{Paragraph: 3, Level: 3, Title: "Chapter One"},
		{Paragraph: 6, Level: 2, Title: "Section by direct outline"},
		{Paragraph: 7, Level: 2, Title: "Second level"},
	}
	if !reflect.DeepEqual(b.Headings, want) {
		t.Errorf("docx headings:\n got  %+v\n want %+v", b.Headings, want)
	}
	if b.Paragraphs[3] != "Chapter\nOne" {
		t.Errorf("heading paragraph %q", b.Paragraphs[3])
	}

	// The same document saved by LibreOffice as .doc keeps the levels in the
	// binary stylesheet and paragraph properties.
	d, err := Extract(filepath.Join("testdata", "headings.doc"), Doc)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(d.Headings, want) {
		t.Errorf("doc headings:\n got  %+v\n want %+v", d.Headings, want)
	}
}

func TestParseTOCStyles(t *testing.T) {
	got := parseTOCStyles([]string{
		` TOC \o "1-3" \h \z \t "TitluVolum;1;TitluParte;2;TutluCapitol;3" `,
		` HYPERLINK \l "x" `,
		` TOC \t "Chapter,2" `,
	})
	want := map[string]int{"titluvolum": 1, "titluparte": 2, "tutlucapitol": 3, "chapter": 2}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}
