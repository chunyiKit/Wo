package portable

import (
	"bytes"
	"context"
	"io"
	"os"
	"testing"
)

func TestFileV2PortableRestoreRepackBytesAndVersionGate(t *testing.T) {
	data := []byte("%PDF-1.7\nsynthetic portable PDF\n%%EOF\n")
	e := entry("opaque_document", File, data)
	m := Manifest{Version: RequiredVersion([]Entry{e}), FamilyID: "family_A", Entries: []Entry{e}}
	first, err := restoreBytes(packBytes(t, m, map[string][]byte{e.ID: data}), destination(t))
	if err != nil {
		t.Fatal(err)
	}
	if !first.Complete || first.RecordsApplied || first.Files[e.ID].Kind != File {
		t.Fatal(first)
	}
	owned := first.Files[e.ID]
	raw, err := os.ReadFile(owned.Path)
	if err != nil || !bytes.Equal(raw, data) || owned.NewID == e.ID {
		t.Fatal("new private bytes", err)
	}
	var packed bytes.Buffer
	if err := Pack(context.Background(), &packed, m, func(id string) (io.ReadCloser, error) { return os.Open(first.Files[id].Path) }); err != nil {
		t.Fatal(err)
	}
	second, err := restoreBytes(packed.Bytes(), destination(t))
	if err != nil || second.Files[e.ID].SHA256 != e.SHA256 || second.Files[e.ID].NewID == owned.NewID {
		t.Fatal("repack changed SHA/reference", err)
	}
	cases := map[string]func(*Manifest){
		"v1_file":         func(m *Manifest) { m.Version = Version },
		"unknown_version": func(m *Manifest) { m.Version = 3 },
		"zero_version":    func(m *Manifest) { m.Version = 0 },
		"source_exact":    func(m *Manifest) { m.Entries[0].SourceExact = true },
		"oversize":        func(m *Manifest) { m.Entries[0].Size = MaxAttachmentBytes + 1 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			bad := m
			bad.Entries = append([]Entry{}, m.Entries...)
			mutate(&bad)
			if err := Pack(context.Background(), io.Discard, bad, nil); err == nil {
				t.Fatal("writer accepted invalid manifest")
			}
			target := destination(t)
			if _, err := restoreBytes(rewriteArchive(t, manifestJSON(t, bad), nil), target); err == nil {
				t.Fatal("reader accepted invalid manifest")
			}
			assertNoPublication(t, target)
		})
	}
	missing := Manifest{Version: 2, FamilyID: "family_A", Entries: []Entry{{ID: "lost", Kind: File, MissingReason: PermissionDenied}}}
	r, err := restoreBytes(packBytes(t, missing, nil), destination(t))
	if err != nil || r.Complete || r.Missing["lost"] != PermissionDenied {
		t.Fatal("file missing reason", r, err)
	}
	// v1 no-file output stays v1; v2 is explicit and cannot be guessed by a reader.
	if RequiredVersion([]Entry{entry("record", Records, []byte("x"))}) != Version {
		t.Fatal("legacy writer version changed")
	}
}
