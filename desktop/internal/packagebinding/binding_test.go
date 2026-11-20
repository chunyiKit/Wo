package packagebinding

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/chunyiKit/Wo/desktop/internal/backup"
	"github.com/chunyiKit/Wo/desktop/internal/portable"
	"github.com/chunyiKit/Wo/desktop/internal/vault"
)

func sha(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func public(id string, kind string, data []byte) backup.Entry {
	return backup.Entry{ID: id, Kind: kind, Size: int64(len(data)), SHA256: sha(data), SourceExact: kind == "photo" || kind == "video"}
}
func restricted(id string, kind portable.Kind, data []byte) portable.Entry {
	return portable.Entry{ID: id, Kind: kind, Size: int64(len(data)), SHA256: sha(data), SourceExact: kind == portable.Photo || kind == portable.Video}
}
func fixture(t *testing.T) ([]byte, backup.Manifest, portable.Manifest, vault.Context) {
	t.Helper()
	ctx := vault.Context{Family: "family_A", Backup: "backup_A", Entry: "sealed_A"}
	p := []backup.Entry{public("public-photo", "photo", []byte("public source bytes")), public("public-thumb", "thumbnail", []byte("public thumbnail"))}
	r := []portable.Entry{restricted("records", "records", []byte(`{"inert":true}`)), restricted("private-photo", "photo", []byte("private source bytes"))}
	raw, err := Build(ctx, p, r)
	if err != nil {
		t.Fatal(err)
	}
	inner := portable.Manifest{Version: 1, FamilyID: ctx.Family, Entries: append(r, restricted(EntryID, portable.Records, raw))}
	outer := backup.Manifest{Version: 1, FamilyID: ctx.Family, BackupID: ctx.Backup, Entries: append(p, backup.Entry{ID: ctx.Entry, Kind: "sealed", Size: 200, SHA256: strings.Repeat("0", 64)})}
	return raw, outer, inner, ctx
}
func clone[T any](value T) T {
	raw, _ := json.Marshal(value)
	var result T
	if err := json.Unmarshal(raw, &result); err != nil {
		panic(err)
	}
	return result
}
func changeRaw(t *testing.T, raw []byte, action func(map[string]any)) []byte {
	t.Helper()
	var object map[string]any
	if err := json.Unmarshal(raw, &object); err != nil {
		t.Fatal(err)
	}
	action(object)
	result, err := json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestBuildDecodeOrderingAndInputImmutability(t *testing.T) {
	raw, outer, inner, ctx := fixture(t)
	index, err := Validate(raw, outer, inner, ctx)
	if err != nil {
		t.Fatal(err)
	}
	if index.Version != 1 || index.Kind != Kind || len(index.PublicEntries) != 2 || len(index.RestrictedEntries) != 2 {
		t.Fatal(index)
	}
	p := append([]backup.Entry{}, index.PublicEntries...)
	p[0], p[1] = p[1], p[0]
	r := append([]portable.Entry{}, index.RestrictedEntries...)
	r[0], r[1] = r[1], r[0]
	beforeP, beforeR := clone(p), clone(r)
	rebuilt, err := Build(ctx, p, r)
	if err != nil {
		t.Fatal(err)
	}
	if !samePublic(beforeP, p) || !sameRestricted(beforeR, r) || p[0] != beforeP[0] || r[0] != beforeR[0] {
		t.Fatal("Build mutated source inventory")
	}
	again, err := Decode(rebuilt)
	if err != nil || !samePublic(index.PublicEntries, again.PublicEntries) || !sameRestricted(index.RestrictedEntries, again.RestrictedEntries) {
		t.Fatal(err)
	}
	outer.Entries[0], outer.Entries[1] = outer.Entries[1], outer.Entries[0]
	inner.Entries[0], inner.Entries[1] = inner.Entries[1], inner.Entries[0]
	if _, err := Validate(raw, outer, inner, ctx); err != nil {
		t.Fatal("inventory ordering must not change metadata", err)
	}
	empty, err := Build(ctx, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Decode(empty); err != nil {
		t.Fatal("empty inventories must be []", err)
	}
}
func TestStrictJSONSchema(t *testing.T) {
	raw, _, _, _ := fixture(t)
	mutations := map[string][]byte{
		"duplicate root":         bytes.Replace(raw, []byte(`"version":1`), []byte(`"version":1,"version":1`), 1),
		"escaped duplicate root": bytes.Replace(raw, []byte(`"version":1`), []byte(`"version":1,"\u0076ersion":1`), 1),
		"duplicate nested":       bytes.Replace(raw, []byte(`"id":"public-photo"`), []byte(`"id":"public-photo","id":"public-photo"`), 1),
		"unknown root":           changeRaw(t, raw, func(o map[string]any) { o["authority"] = true }),
		"missing root":           changeRaw(t, raw, func(o map[string]any) { delete(o, "backup_id") }),
		"null root":              changeRaw(t, raw, func(o map[string]any) { o["family_id"] = nil }),
		"null array":             changeRaw(t, raw, func(o map[string]any) { o["public_entries"] = nil }),
		"array object":           changeRaw(t, raw, func(o map[string]any) { o["restricted_entries"] = map[string]any{} }),
		"null entry":             changeRaw(t, raw, func(o map[string]any) { o["public_entries"].([]any)[0] = nil }),
		"unknown public field":   changeRaw(t, raw, func(o map[string]any) { o["public_entries"].([]any)[0].(map[string]any)["secret"] = true }),
		"null optional":          changeRaw(t, raw, func(o map[string]any) { o["public_entries"].([]any)[0].(map[string]any)["label"] = nil }),
		"empty optional label":   changeRaw(t, raw, func(o map[string]any) { o["public_entries"].([]any)[0].(map[string]any)["label"] = "" }),
		"empty optional missing": changeRaw(t, raw, func(o map[string]any) { o["public_entries"].([]any)[0].(map[string]any)["missing"] = "" }),
		"false optional exact":   changeRaw(t, raw, func(o map[string]any) { o["public_entries"].([]any)[0].(map[string]any)["source_exact"] = false }),
		"empty optional missing sha": changeRaw(t, raw, func(o map[string]any) {
			entry := o["public_entries"].([]any)[0].(map[string]any)
			entry["size"] = 0
			entry["missing"] = "permission_denied"
			entry["sha256"] = ""
			delete(entry, "source_exact")
		}),
		"missing restricted field": changeRaw(t, raw, func(o map[string]any) { delete(o["restricted_entries"].([]any)[0].(map[string]any), "source_exact") }),
		"wrong integer":            bytes.Replace(raw, []byte(`"version":1`), []byte(`"version":1.0`), 1),
		"numeric overflow":         bytes.Replace(raw, []byte(`"version":1`), []byte(`"version":9223372036854775808`), 1),
		"string boolean":           bytes.Replace(raw, []byte(`"source_exact":true`), []byte(`"source_exact":"true"`), 1),
		"trailing document":        append(append([]byte{}, raw...), []byte(`{}`)...),
		"trailing junk":            append(append([]byte{}, raw...), []byte(` X`)...),
		"invalid utf8":             append(append([]byte{}, raw...), 0xff),
		"oversize":                 bytes.Repeat([]byte(" "), MaxBytes+1),
	}
	for name, data := range mutations {
		t.Run(name, func(t *testing.T) {
			if _, err := Decode(data); err == nil {
				t.Fatal("accepted malformed binding")
			}
		})
	}
}
func TestAllInventoryMetadataAndContextMustMatch(t *testing.T) {
	raw, outer, inner, ctx := fixture(t)
	cases := map[string]func(*backup.Manifest, *portable.Manifest, *vault.Context){
		"public sha": func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) {
			o.Entries[0].SHA256 = strings.Repeat("1", 64)
		},
		"public size":         func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) { o.Entries[0].Size++ },
		"public label":        func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) { o.Entries[0].Label = "changed" },
		"public source exact": func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) { o.Entries[0].SourceExact = false },
		"public kind":         func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) { o.Entries[0].Kind = "video" },
		"public missing": func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) {
			o.Entries[0].Missing = "permission_denied"
			o.Entries[0].Size = 0
			o.Entries[0].SHA256 = ""
			o.Entries[0].SourceExact = false
		},
		"public extra": func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) {
			o.Entries = append(o.Entries, public("other-public", "photo", []byte("other")))
		},
		"public omitted": func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) { o.Entries = o.Entries[1:] },
		"private sha": func(_ *backup.Manifest, i *portable.Manifest, _ *vault.Context) {
			i.Entries[0].SHA256 = strings.Repeat("2", 64)
		},
		"private size":  func(_ *backup.Manifest, i *portable.Manifest, _ *vault.Context) { i.Entries[0].Size++ },
		"private exact": func(_ *backup.Manifest, i *portable.Manifest, _ *vault.Context) { i.Entries[1].SourceExact = false },
		"private kind":  func(_ *backup.Manifest, i *portable.Manifest, _ *vault.Context) { i.Entries[1].Kind = portable.Video },
		"private missing": func(_ *backup.Manifest, i *portable.Manifest, _ *vault.Context) {
			i.Entries[1].MissingReason = portable.SourceNotExact
			i.Entries[1].SourceExact = false
			i.Entries[1].Size = 0
			i.Entries[1].SHA256 = ""
		},
		"private extra": func(_ *backup.Manifest, i *portable.Manifest, _ *vault.Context) {
			i.Entries = append(i.Entries, restricted("other-private", portable.Records, []byte("other")))
		},
		"outer family":   func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) { o.FamilyID = "family_B" },
		"outer backup":   func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) { o.BackupID = "backup_B" },
		"inner family":   func(_ *backup.Manifest, i *portable.Manifest, _ *vault.Context) { i.FamilyID = "family_B" },
		"context family": func(_ *backup.Manifest, _ *portable.Manifest, c *vault.Context) { c.Family = "family_B" },
		"context backup": func(_ *backup.Manifest, _ *portable.Manifest, c *vault.Context) { c.Backup = "backup_B" },
		"context sealed": func(_ *backup.Manifest, _ *portable.Manifest, c *vault.Context) { c.Entry = "sealed_B" },
		"sealed id":      func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) { o.Entries[2].ID = "sealed_B" },
		"sealed absent":  func(o *backup.Manifest, _ *portable.Manifest, _ *vault.Context) { o.Entries = o.Entries[:2] },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			o, i, c := clone(outer), clone(inner), ctx
			mutate(&o, &i, &c)
			if _, err := Validate(raw, o, i, c); err == nil {
				t.Fatal("accepted mismatched package")
			}
		})
	}
}
func TestReservedIDsAndCaseConflicts(t *testing.T) {
	_, _, _, ctx := fixture(t)
	validP := public("p", "photo", []byte("p"))
	validR := restricted("r", portable.Photo, []byte("r"))
	cases := []struct {
		name string
		p    []backup.Entry
		r    []portable.Entry
	}{
		{"public duplicate", []backup.Entry{validP, validP}, nil},
		{"public case", []backup.Entry{validP, public("P", "photo", []byte("different"))}, nil},
		{"private case", nil, []portable.Entry{validR, restricted("R", portable.Photo, []byte("different"))}},
		{"cross section", []backup.Entry{validP}, []portable.Entry{restricted("P", portable.Photo, []byte("other"))}},
		{"public records forbidden", []backup.Entry{public("business-records", "records", []byte("private business"))}, nil},
		{"public reserved", []backup.Entry{public(EntryID, "thumbnail", []byte("audit"))}, nil},
		{"private reserved", nil, []portable.Entry{restricted(strings.ToUpper(EntryID), portable.Records, []byte("audit"))}},
		{"sealed conflict", nil, []portable.Entry{restricted(strings.ToUpper(ctx.Entry), portable.Records, []byte("audit"))}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			if _, err := Build(ctx, test.p, test.r); err == nil {
				t.Fatal("accepted ID collision")
			}
		})
	}
	publicTooMany := make([]backup.Entry, MaxPublicEntries+1)
	privateTooMany := make([]portable.Entry, MaxRestrictedEntries+1)
	if _, err := Build(ctx, publicTooMany, nil); err == nil {
		t.Fatal("public count bound")
	}
	if _, err := Build(ctx, nil, privateTooMany); err == nil {
		t.Fatal("private count bound")
	}
}
func TestIndexEntryHashSizeTypeAndLegacyUnbound(t *testing.T) {
	raw, outer, inner, ctx := fixture(t)
	for _, mutate := range []func(*portable.Entry){func(e *portable.Entry) { e.SHA256 = strings.Repeat("9", 64) }, func(e *portable.Entry) { e.Size++ }, func(e *portable.Entry) { e.Kind = portable.Thumbnail }, func(e *portable.Entry) { e.ID = strings.ToUpper(EntryID) }, func(e *portable.Entry) { e.Size = 0; e.SHA256 = ""; e.MissingReason = portable.SourceMissing }} {
		copy := clone(inner)
		mutate(&copy.Entries[2])
		if _, err := Validate(raw, outer, copy, ctx); err == nil {
			t.Fatal("accepted index metadata change")
		}
	}
	legacy := clone(inner)
	legacy.Entries = legacy.Entries[:2]
	if _, err := Validate(nil, outer, legacy, ctx); !errors.Is(err, ErrUnbound) {
		t.Fatalf("legacy must be unbound, got %v", err)
	}
	altered := bytes.Replace(raw, []byte(`"version":1`), []byte(`"version": 1`), 1)
	if _, err := Decode(altered); err != nil {
		t.Fatal(err)
	}
	if _, err := Validate(altered, outer, inner, ctx); err == nil {
		t.Fatal("semantic equivalence must not bypass original index full SHA")
	}
}

type closeError struct{ io.Reader }

func (closeError) Close() error { return errors.New("synthetic close failure") }
func TestPublicByteVerificationRejectsChangesAndPreservesMissing(t *testing.T) {
	raw, _, _, _ := fixture(t)
	index, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	good := map[string][]byte{"public-photo": []byte("public source bytes"), "public-thumb": []byte("public thumbnail")}
	open := func(id string) (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(good[id])), nil }
	if err := VerifyPublic(context.Background(), index, open); err != nil {
		t.Fatal(err)
	}
	for name, changed := range map[string][]byte{"short": []byte("x"), "same size wrong hash": bytes.Repeat([]byte("x"), len(good["public-photo"])), "long": append(append([]byte{}, good["public-photo"]...), 0)} {
		t.Run(name, func(t *testing.T) {
			if err := VerifyPublic(context.Background(), index, func(id string) (io.ReadCloser, error) {
				if id == "public-photo" {
					return io.NopCloser(bytes.NewReader(changed)), nil
				}
				return open(id)
			}); !errors.Is(err, ErrSource) {
				t.Fatal(err)
			}
		})
	}
	if err := VerifyPublic(context.Background(), index, func(string) (io.ReadCloser, error) { return nil, errors.New("synthetic unavailable") }); !errors.Is(err, ErrSource) {
		t.Fatal(err)
	}
	if err := VerifyPublic(context.Background(), index, func(id string) (io.ReadCloser, error) { return closeError{bytes.NewReader(good[id])}, nil }); !errors.Is(err, ErrSource) {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := VerifyPublic(ctx, index, open); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	index.PublicEntries = append(index.PublicEntries, backup.Entry{ID: "missing", Kind: "photo", Missing: "permission_denied"})
	openedMissing := false
	if err := VerifyPublic(context.Background(), index, func(id string) (io.ReadCloser, error) {
		if id == "missing" {
			openedMissing = true
		}
		return open(id)
	}); err != nil || openedMissing {
		t.Fatalf("missing is a declaration, no fabricated bytes: %v", err)
	}
}

func pack(t *testing.T, manifest portable.Manifest, open portable.OpenSource) []byte {
	t.Helper()
	var data bytes.Buffer
	if err := portable.Pack(context.Background(), &data, manifest, open); err != nil {
		t.Fatal(err)
	}
	return data.Bytes()
}
func manifestFromTar(t *testing.T, raw []byte) portable.Manifest {
	t.Helper()
	reader := tar.NewReader(bytes.NewReader(raw))
	header, err := reader.Next()
	if err != nil || header.Name != "manifest.json" {
		t.Fatal(err)
	}
	var manifest portable.Manifest
	if err := json.NewDecoder(reader).Decode(&manifest); err != nil {
		t.Fatal(err)
	}
	return manifest
}
func seal(t *testing.T, raw, key []byte, ctx vault.Context) []byte {
	t.Helper()
	var ciphertext bytes.Buffer
	if _, err := vault.Encrypt(&ciphertext, bytes.NewReader(raw), key, ctx, vault.Limits{}); err != nil {
		t.Fatal(err)
	}
	return ciphertext.Bytes()
}
func decryptRestore(t *testing.T, ciphertext, key []byte, ctx vault.Context) (portable.Result, portable.Manifest) {
	t.Helper()
	private := t.TempDir()
	root, err := os.OpenRoot(private)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if _, err := vault.RestoreFile(root, "authenticated.tar", bytes.NewReader(ciphertext), key, ctx, vault.Limits{}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(private, "authenticated.tar"))
	if err != nil {
		t.Fatal(err)
	}
	result, err := portable.Restore(context.Background(), bytes.NewReader(raw), portable.RestoreOptions{ExpectedFamilyID: ctx.Family, Destination: filepath.Join(t.TempDir(), "restored"), RequirePrivateACL: true})
	if err != nil {
		t.Fatal(err)
	}
	return result, manifestFromTar(t, raw)
}
func upload(t *testing.T, store *backup.Store, outer backup.Manifest, source map[string][]byte) {
	t.Helper()
	if err := store.Create(outer); err != nil {
		t.Fatal(err)
	}
	for _, entry := range outer.Entries {
		if entry.Missing != "" {
			continue
		}
		raw := source[entry.ID]
		if _, err := store.Append(outer.FamilyID, outer.BackupID, entry.ID, 0, int64(len(raw)), sha(raw), bytes.NewReader(raw)); err != nil {
			t.Fatal(err)
		}
	}
	status, err := store.Finalize(outer.FamilyID, outer.BackupID)
	if err != nil {
		t.Fatal(err)
	}
	if status.FullDeviceComplete || status.Complete || status.Scope != "opaque_restricted_unverified" {
		t.Fatalf("computer must not claim decrypt/complete %+v", status)
	}
}
func TestEncryptedPackageRealStoreRestoreAndRebackup(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("restricted plaintext restore correctly fails closed until private Windows ACL verification exists")
	}
	ctx := vault.Context{Family: "family_A", Backup: "backup_A", Entry: "sealed_A"}
	key := bytes.Repeat([]byte{0x57}, 32)
	source := map[string][]byte{"public-photo": []byte("synthetic shared photo original bytes"), "public-thumb": []byte("synthetic shared thumbnail"),
		"records": []byte(`{"version":2,"inert_history":true,"permissions_restored":false}`), "private-photo": []byte("synthetic private photograph bytes"), "private-video": bytes.Repeat([]byte("synthetic-private-video"), 10000), "thumb_private-photo": []byte("synthetic private thumbnail")}
	p := []backup.Entry{public("public-photo", "photo", source["public-photo"]), public("public-thumb", "thumbnail", source["public-thumb"])}
	r := []portable.Entry{restricted("records", portable.Records, source["records"]), restricted("private-photo", portable.Photo, source["private-photo"]), restricted("private-video", portable.Video, source["private-video"]), restricted("thumb_private-photo", portable.Thumbnail, source["thumb_private-photo"]), {ID: "private-missing", Kind: portable.Photo, MissingReason: portable.NotOnDevice}}
	raw, err := Build(ctx, p, r)
	if err != nil {
		t.Fatal(err)
	}
	source[EntryID] = raw
	inner := portable.Manifest{Version: 1, FamilyID: ctx.Family, Entries: append(append([]portable.Entry{}, r...), restricted(EntryID, portable.Records, raw))}
	opener := func(id string) (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(source[id])), nil }
	ciphertext := seal(t, pack(t, inner, opener), key, ctx)
	source[ctx.Entry] = ciphertext
	outer := backup.Manifest{Version: 1, FamilyID: ctx.Family, BackupID: ctx.Backup, Entries: append(append([]backup.Entry{}, p...), public(ctx.Entry, "sealed", ciphertext))}
	computer, err := backup.New(filepath.Join(t.TempDir(), "computer"))
	if err != nil {
		t.Fatal(err)
	}
	defer computer.Close()
	upload(t, computer, outer, source)
	sealedFile, _, err := computer.OpenVerified(ctx.Family, ctx.Backup, ctx.Entry, true)
	if err != nil {
		t.Fatal(err)
	}
	saved, err := io.ReadAll(sealedFile)
	sealedFile.Close()
	if err != nil {
		t.Fatal(err)
	}
	recovered, authenticatedInner := decryptRestore(t, saved, key, ctx)
	marker, err := os.ReadFile(recovered.Files[EntryID].Path)
	if err != nil {
		t.Fatal(err)
	}
	index, err := Validate(marker, outer, authenticatedInner, ctx)
	if err != nil {
		t.Fatal(err)
	}
	publicOpener := func(id string) (io.ReadCloser, error) {
		f, _, err := computer.OpenVerified(ctx.Family, ctx.Backup, id, false)
		return f, err
	}
	if err := VerifyPublic(context.Background(), index, publicOpener); err != nil {
		t.Fatal(err)
	}
	publicInner := portable.Manifest{Version: 1, FamilyID: ctx.Family, Entries: []portable.Entry{restricted(p[0].ID, portable.Photo, source[p[0].ID]), restricted(p[1].ID, portable.Thumbnail, source[p[1].ID])}}
	publicRestore, err := portable.Restore(context.Background(), bytes.NewReader(pack(t, publicInner, portable.OpenSource(publicOpener))), portable.RestoreOptions{ExpectedFamilyID: ctx.Family, Destination: filepath.Join(t.TempDir(), "public-verified"), RequirePrivateACL: true})
	if err != nil {
		t.Fatal(err)
	}
	if recovered.RecordsApplied || recovered.Complete || recovered.Missing["private-missing"] != portable.NotOnDevice || recovered.NewFamilyID == ctx.Family {
		t.Fatal("recovery must remain separate and incomplete", recovered)
	}
	for id, entry := range recovered.Files {
		raw, err := os.ReadFile(entry.Path)
		if err != nil || sha(raw) != entry.SHA256 || entry.NewID == id {
			t.Fatalf("new owned file did not retain SHA: %s %v", id, err)
		}
	}
	// Same source UUIDs, same family/backup/sealed labels, but another package's
	// perfectly valid public SHA: an immutable private index must still reject it.
	swapped := clone(outer)
	swapped.Entries[0] = public(p[0].ID, "photo", []byte("another-package-same-uuid"))
	if _, err := Validate(marker, swapped, authenticatedInner, ctx); !errors.Is(err, ErrMismatch) {
		t.Fatalf("same UUID is not same package: %v", err)
	}
	next := vault.Context{Family: ctx.Family, Backup: "backup_B", Entry: "sealed_B"}
	newIndex, err := Build(next, index.PublicEntries, index.RestrictedEntries)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(newIndex, marker) {
		t.Fatal("new backup must bind new context")
	}
	nextInner := portable.Manifest{Version: 1, FamilyID: next.Family, Entries: append(append([]portable.Entry{}, index.RestrictedEntries...), restricted(EntryID, portable.Records, newIndex))}
	ownedOpen := func(id string) (io.ReadCloser, error) {
		if id == EntryID {
			return io.NopCloser(bytes.NewReader(newIndex)), nil
		}
		return os.Open(recovered.Files[id].Path)
	}
	nextCipher := seal(t, pack(t, nextInner, ownedOpen), key, next)
	nextOuter := backup.Manifest{Version: 1, FamilyID: next.Family, BackupID: next.Backup, Entries: append(append([]backup.Entry{}, index.PublicEntries...), public(next.Entry, "sealed", nextCipher))}
	nextSource := map[string][]byte{next.Entry: nextCipher}
	for id, file := range publicRestore.Files {
		nextSource[id], err = os.ReadFile(file.Path)
		if err != nil {
			t.Fatal(err)
		}
	}
	upload(t, computer, nextOuter, nextSource)
	again, againInner := decryptRestore(t, nextCipher, key, next)
	againMarker, err := os.ReadFile(again.Files[EntryID].Path)
	if err != nil {
		t.Fatal(err)
	}
	againIndex, err := Validate(againMarker, nextOuter, againInner, next)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Validate(marker, nextOuter, againInner, next); err == nil {
		t.Fatal("old index cannot be reused for new backup")
	}
	if !sameRestricted(index.RestrictedEntries, againIndex.RestrictedEntries) {
		t.Fatal("business/media metadata changed during rebackup")
	}
	for _, entry := range r {
		if entry.MissingReason != "" {
			continue
		}
		before, after := recovered.Files[entry.ID], again.Files[entry.ID]
		if before.SHA256 != after.SHA256 || before.NewID == after.NewID {
			t.Fatal("SHA or fresh owned reference mismatch", entry.ID)
		}
	}
	oldAudit, err := os.ReadFile(recovered.Files[EntryID].Path)
	if err != nil || !bytes.Equal(oldAudit, marker) {
		t.Fatal("old index audit bytes must remain private and unchanged", err)
	}
}
func TestActualVaultWrongContextCannotPublishBinding(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("private ACL unsupported")
	}
	raw, _, _, ctx := fixture(t)
	key := bytes.Repeat([]byte{0x23}, 32)
	cipher := seal(t, raw, key, ctx)
	for _, wrong := range []vault.Context{{Family: "family_B", Backup: ctx.Backup, Entry: ctx.Entry}, {Family: ctx.Family, Backup: "backup_B", Entry: ctx.Entry}, {Family: ctx.Family, Backup: ctx.Backup, Entry: "sealed_B"}} {
		root, err := os.OpenRoot(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		_, err = vault.RestoreFile(root, "binding", bytes.NewReader(cipher), key, wrong, vault.Limits{})
		if err == nil {
			t.Fatal("wrong actual AEAD context accepted")
		}
		if _, err := root.Stat("binding"); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("failed authentication published plaintext", err)
		}
		root.Close()
	}
}

func TestCombinedEntryCountAndPublicPortableFileBounds(t *testing.T) {
	ctx := vault.Context{Family: "family_A", Backup: "backup_A", Entry: "sealed_A"}
	atLimit := public("large", "photo", []byte("placeholder"))
	atLimit.Size = 20 << 30
	if _, err := Build(ctx, []backup.Entry{atLimit}, nil); err != nil {
		t.Fatal("20GiB boundary rejected", err)
	}
	tooLarge := atLimit
	tooLarge.Size++
	if _, err := Build(ctx, []backup.Entry{tooLarge}, nil); err == nil {
		t.Fatal("public original above portable/owned 20GiB must fail")
	}
	p := make([]backup.Entry, MaxPublicEntries)
	for i := range p {
		p[i] = public(fmt.Sprintf("p%d", i), "thumbnail", []byte("p"))
	}
	r := make([]portable.Entry, MaxRestrictedEntries-len(p))
	for i := range r {
		r[i] = restricted(fmt.Sprintf("r%d", i), portable.Records, []byte("r"))
	}
	raw, err := Build(ctx, p, r)
	if err != nil {
		t.Fatal("19999 entries plus index must fit", err)
	}
	if _, err := Decode(raw); err != nil {
		t.Fatal(err)
	}
	r = append(r, restricted("one-too-many", portable.Records, []byte("r")))
	if _, err := Build(ctx, p, r); err == nil {
		t.Fatal("combined public+restricted must reserve index slot")
	}
}

func TestCombinedHundredGiBIncludesExactIndexBytes(t *testing.T) {
	ctx := vault.Context{Family: "family_A", Backup: "backup_A", Entry: "sealed_A"}
	p := make([]backup.Entry, 4)
	for i := range p {
		p[i] = public(fmt.Sprintf("large%d", i), "photo", []byte("placeholder"))
		p[i].Size = 20 << 30
	}
	r := []portable.Entry{restricted("large-private", portable.Video, []byte("placeholder"))}
	r[0].Size = (20 << 30) - 10000
	raw, err := Build(ctx, p, r)
	if err != nil {
		t.Fatal(err)
	}
	r[0].Size = (20 << 30) - int64(len(raw))
	atBoundary, err := Build(ctx, p, r)
	if err != nil {
		t.Fatal("combined exact byte boundary rejected", err)
	}
	var total int64 = int64(len(atBoundary))
	for _, entry := range p {
		total += entry.Size
	}
	total += r[0].Size
	if total != MaxCombinedBytes {
		t.Fatalf("test index-size fixed point changed: %d", total)
	}
	if _, err := Decode(atBoundary); err != nil {
		t.Fatal(err)
	}
	// Semantic JSON equivalence does not erase the extra actual index byte.
	if _, err := Decode(append(append([]byte{}, atBoundary...), ' ')); err == nil {
		t.Fatal("actual index byte length must count against combined cap")
	}
	r[0].Size++
	if _, err := Build(ctx, p, r); err == nil {
		t.Fatal("combined >100GiB accepted")
	}
	r[0].Size = 20 << 30
	if _, err := Build(ctx, p, r); err == nil {
		t.Fatal("100GiB inventories plus nonempty index cannot be jointly restored")
	}
}
