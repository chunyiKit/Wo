package packagebinding

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"github.com/chunyiKit/Wo/desktop/internal/portable"
	"github.com/chunyiKit/Wo/desktop/internal/vault"
)

func TestFileV2EncryptedStoreRestoreAndRebackup(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("private ACL unavailable")
	}
	key := bytes.Repeat([]byte{0x34}, 32)
	ctx := vault.Context{Family: "family_file", Backup: "backup_file_A", Entry: "sealed_file_A"}
	doc := []byte("%PDF-1.7\nsynthetic restricted attachment, no personal data\n%%EOF\n")
	r := []portable.Entry{restricted("document_A", portable.File, doc), {ID: "lost_document", Kind: portable.File, MissingReason: portable.PermissionDenied}}
	raw, err := Build(ctx, []backup.Entry{}, r)
	if err != nil {
		t.Fatal(err)
	}
	var index Index
	if err = json.Unmarshal(raw, &index); err != nil || index.Version != 2 {
		t.Fatal("index must be v2", err)
	}
	inner := portable.Manifest{Version: portable.RequiredVersion(r), FamilyID: ctx.Family, Entries: append(append([]portable.Entry{}, r...), restricted(EntryID, portable.Records, raw))}
	source := map[string][]byte{"document_A": doc, EntryID: raw}
	cipher := seal(t, pack(t, inner, func(id string) (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(source[id])), nil }), key, ctx)
	outer := backup.Manifest{Version: backup.RequiredVersion([]backup.Entry{}), FamilyID: ctx.Family, BackupID: ctx.Backup, Entries: []backup.Entry{public(ctx.Entry, "sealed", cipher)}}
	computer, err := backup.New(filepath.Join(t.TempDir(), "computer"))
	if err != nil {
		t.Fatal(err)
	}
	defer computer.Close()
	upload(t, computer, outer, map[string][]byte{ctx.Entry: cipher})
	saved, _, err := computer.OpenVerified(ctx.Family, ctx.Backup, ctx.Entry, true)
	if err != nil {
		t.Fatal(err)
	}
	cipher, err = io.ReadAll(saved)
	saved.Close()
	if err != nil {
		t.Fatal(err)
	}
	recovered, authInner := decryptRestore(t, cipher, key, ctx)
	if _, err := Validate(raw, outer, authInner, ctx); err != nil {
		t.Fatal(err)
	}
	restored := recovered.Files["document_A"]
	got, err := os.ReadFile(restored.Path)
	if err != nil || !bytes.Equal(got, doc) || restored.SHA256 != sha(doc) || restored.NewID == "document_A" || recovered.Complete || recovered.RecordsApplied || recovered.Missing["lost_document"] != portable.PermissionDenied {
		t.Fatal("restricted file roundtrip", err)
	}
	// Re-backup uses new context/index and the recovered private bytes, never an old URI.
	next := vault.Context{Family: ctx.Family, Backup: "backup_file_B", Entry: "sealed_file_B"}
	nextIndex, err := Build(next, []backup.Entry{}, index.RestrictedEntries)
	if err != nil {
		t.Fatal(err)
	}
	nextInner := portable.Manifest{Version: portable.RequiredVersion(r), FamilyID: ctx.Family, Entries: append(append([]portable.Entry{}, r...), restricted(EntryID, portable.Records, nextIndex))}
	nextCipher := seal(t, pack(t, nextInner, func(id string) (io.ReadCloser, error) {
		if id == EntryID {
			return io.NopCloser(bytes.NewReader(nextIndex)), nil
		}
		return os.Open(recovered.Files[id].Path)
	}), key, next)
	nextOuter := backup.Manifest{Version: 1, FamilyID: next.Family, BackupID: next.Backup, Entries: []backup.Entry{public(next.Entry, "sealed", nextCipher)}}
	upload(t, computer, nextOuter, map[string][]byte{next.Entry: nextCipher})
	again, againInner := decryptRestore(t, nextCipher, key, next)
	if _, err := Validate(nextIndex, nextOuter, againInner, next); err != nil {
		t.Fatal(err)
	}
	after := again.Files["document_A"]
	got, err = os.ReadFile(after.Path)
	if err != nil || sha(got) != sha(doc) || after.NewID == restored.NewID {
		t.Fatal("second restored SHA/new ID", err)
	}
	if _, err := Validate(raw, nextOuter, againInner, next); err == nil {
		t.Fatal("old index accepted for new package")
	}
	// Each decoder independently rejects v1 file, unsupported versions and false provenance.
	for name, version := range map[string]int{"v1": 1, "unknown": 3, "zero": 0} {
		t.Run(name, func(t *testing.T) {
			bad := index
			bad.Version = version
			b, _ := json.Marshal(bad)
			if _, err := Decode(b); err == nil {
				t.Fatal("invalid index accepted")
			}
		})
	}
	badInner := authInner
	badInner.Version = 1
	if _, err := Validate(raw, outer, badInner, ctx); err == nil {
		t.Fatal("v1 inner file accepted")
	}
	bad := index
	bad.RestrictedEntries = append([]portable.Entry{}, index.RestrictedEntries...)
	bad.RestrictedEntries[0].SourceExact = true
	b, _ := json.Marshal(bad)
	if _, err := Decode(b); err == nil {
		t.Fatal("file source_exact accepted")
	}
}

func TestFileV2PublicDecoderRetainsExplicitManifestGate(t *testing.T) {
	ctx := vault.Context{Family: "family_public", Backup: "backup_public", Entry: "sealed_public"}
	document := []byte("synthetic document public only with explicit caller authorization")
	p := []backup.Entry{public("document_public", "file", document)}
	raw, err := Build(ctx, p, []portable.Entry{})
	if err != nil {
		t.Fatal(err)
	}
	inner := portable.Manifest{Version: 1, FamilyID: ctx.Family, Entries: []portable.Entry{restricted(EntryID, portable.Records, raw)}}
	outer := backup.Manifest{Version: backup.RequiredVersion(p), FamilyID: ctx.Family, BackupID: ctx.Backup, Entries: append(append([]backup.Entry{}, p...), backup.Entry{ID: ctx.Entry, Kind: "sealed", Size: 200, SHA256: sha(bytes.Repeat([]byte{1}, 200))})}
	if outer.Version != 2 {
		t.Fatal("public file writer version")
	}
	if _, err := Validate(raw, outer, inner, ctx); err != nil {
		t.Fatal(err)
	}
	outer.Version = 1
	if _, err := Validate(raw, outer, inner, ctx); err == nil {
		t.Fatal("v1 outer file accepted")
	}
	oversized := append([]backup.Entry{}, p...)
	oversized[0].Size = backup.MaxAttachmentSize + 1
	if _, err := Build(ctx, oversized, []portable.Entry{}); err == nil {
		t.Fatal("file over 20MiB accepted")
	}
	r := []portable.Entry{{ID: "private_large", Kind: portable.File, Size: portable.MaxAttachmentBytes + 1, SHA256: sha(document)}}
	if _, err := Build(ctx, []backup.Entry{}, r); err == nil {
		t.Fatal("private file over 20MiB accepted")
	}
}
