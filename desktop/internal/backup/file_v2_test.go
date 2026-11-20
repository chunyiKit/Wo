package backup

import (
	"bytes"
	"io"
	"testing"
)

func TestFileV2StoreRoundTripAndVersionGate(t *testing.T) {
	data := []byte("%PDF-1.7\nsynthetic document, no user data\n%%EOF\n")
	m := Manifest{Version: FileVersion, FamilyID: "family-file", BackupID: "backup-file", Entries: []Entry{{ID: "opaque_file", Kind: "file", Size: int64(len(data)), SHA256: digest(data), Label: "合成文档.pdf"}}}
	if RequiredVersion(m.Entries) != 2 || RequiredVersion(nil) != 1 {
		t.Fatal("writer version gate")
	}
	s, _ := setup(t)
	if err := s.Create(m); err != nil {
		t.Fatal(err)
	}
	appendAll(t, s, m, data)
	st, err := s.Finalize(m.FamilyID, m.BackupID)
	if err != nil || !st.Complete || st.FullDeviceComplete {
		t.Fatal(st, err)
	}
	f, e, err := s.OpenVerified(m.FamilyID, m.BackupID, "opaque_file", false)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(f)
	f.Close()
	if err != nil || !bytes.Equal(got, data) || e.Kind != "file" {
		t.Fatal("file changed", err)
	}
	cases := map[string]func(*Manifest){
		"v1_file":           func(m *Manifest) { m.Version = 1 },
		"unknown_version":   func(m *Manifest) { m.Version = 3 },
		"negative_version":  func(m *Manifest) { m.Version = -1 },
		"file_source_exact": func(m *Manifest) { m.Entries[0].SourceExact = true },
		"oversize":          func(m *Manifest) { m.Entries[0].Size = MaxAttachmentSize + 1 },
		"empty":             func(m *Manifest) { m.Entries[0].Size = 0 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			bad := m
			bad.Entries = append([]Entry{}, m.Entries...)
			mutate(&bad)
			if Validate(bad) == nil {
				t.Fatal("accepted invalid file manifest")
			}
		})
	}
	boundary := m
	boundary.Entries = append([]Entry{}, m.Entries...)
	boundary.Entries[0].Size = MaxAttachmentSize
	if err := Validate(boundary); err != nil {
		t.Fatal("20MiB boundary", err)
	}
}
