package portable

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
	"sync"
	"testing"
)

func entry(id string, kind Kind, data []byte) Entry {
	h := sha256.Sum256(data)
	return Entry{ID: id, Kind: kind, Size: int64(len(data)), SHA256: hex.EncodeToString(h[:]), SourceExact: kind == Photo || kind == Video}
}
func packBytes(t *testing.T, m Manifest, sources map[string][]byte) []byte {
	t.Helper()
	var out bytes.Buffer
	err := Pack(context.Background(), &out, m, func(id string) (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(sources[id])), nil })
	if err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}
func destination(t *testing.T) string { t.Helper(); return filepath.Join(t.TempDir(), "restored") }
func restoreBytes(data []byte, target string) (Result, error) {
	return Restore(context.Background(), bytes.NewReader(data), RestoreOptions{ExpectedFamilyID: "family_A", Destination: target})
}
func assertNoPublication(t *testing.T, target string) {
	t.Helper()
	if _, err := os.Lstat(target); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("invalid input published destination: %v", err)
	}
	children, err := os.ReadDir(filepath.Dir(target))
	if err != nil {
		t.Fatal(err)
	}
	if len(children) != 0 {
		t.Fatalf("staging leaked: %v", children)
	}
}
func manifestJSON(t *testing.T, m Manifest) []byte {
	t.Helper()
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
func rewriteArchive(t *testing.T, manifest []byte, files []struct {
	h    *tar.Header
	data []byte
}) []byte {
	t.Helper()
	var out bytes.Buffer
	tw := tar.NewWriter(&out)
	if err := tw.WriteHeader(header("manifest.json", int64(len(manifest)))); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write(manifest); err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		if err := tw.WriteHeader(f.h); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(f.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

type archiveFile struct {
	h    *tar.Header
	data []byte
}

func TestRoundTripUsesFreshIdentitiesAndOpaquePathsWithoutApplyingRecords(t *testing.T) {
	records := []byte(`{"device_id":"old-device","family_id":"family_A","uri":"content://old-phone/1","bookmark":"old-bookmark"}`)
	photo := []byte("synthetic original photo with EXIF")
	video := []byte("synthetic original video")
	thumb := []byte("thumbnail")
	sources := map[string][]byte{"records": records, "photo": photo, "video": video, "thumb": thumb}
	m := Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{entry("records", Records, records), entry("photo", Photo, photo), entry("video", Video, video), entry("thumb", Thumbnail, thumb)}}
	target := destination(t)
	res, err := restoreBytes(packBytes(t, m, sources), target)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Complete || res.RecordsApplied || res.SourceFamilyID != "family_A" || res.NewFamilyID == "family_A" || res.NewDeviceID == "old-device" || res.NewFamilyID == res.NewDeviceID {
		t.Fatalf("identity/completion semantics wrong: %+v", res)
	}
	for id, expected := range sources {
		f, ok := res.Files[id]
		if !ok {
			t.Fatal("missing", id)
		}
		if !identifier.MatchString(f.NewID) || f.NewID == id || f.Path != filepath.Join(target, "data", f.NewID+".blob") {
			t.Fatalf("unsafe/restored source path %+v", f)
		}
		got, err := os.ReadFile(f.Path)
		if err != nil || !bytes.Equal(got, expected) {
			t.Fatalf("bytes changed: %s %v", id, err)
		}
		info, err := os.Stat(f.Path)
		if err != nil || (runtime.GOOS != "windows" && info.Mode().Perm() != 0600) {
			t.Fatalf("permissions: %v %v", info, err)
		}
	}
	marker, err := os.ReadFile(res.CompletionMarker)
	if err != nil {
		t.Fatal(err)
	}
	var persisted Result
	if json.Unmarshal(marker, &persisted) != nil || persisted.RestoreID != res.RestoreID || persisted.RecordsApplied {
		t.Fatal("completion marker wrong")
	}
	// Repacking verified byte files preserves all media digests, but is still not an app import.
	var again bytes.Buffer
	err = Pack(context.Background(), &again, m, func(id string) (io.ReadCloser, error) { return os.Open(res.Files[id].Path) })
	if err != nil {
		t.Fatal(err)
	}
	second, err := restoreBytes(again.Bytes(), destination(t))
	if err != nil {
		t.Fatal(err)
	}
	for id, first := range res.Files {
		if first.SHA256 != second.Files[id].SHA256 || first.NewID == second.Files[id].NewID {
			t.Fatal("digest or fresh mapping failed")
		}
	}
}
func TestMissingOriginalsRetainThumbnailAndNonExactBytesNeverBecomeComplete(t *testing.T) {
	thumb := []byte("thumbnail remains readable")
	redacted := []byte("GPS-redacted bytes")
	nonexact := entry("redacted", Photo, redacted)
	nonexact.SourceExact = false
	m := Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{{ID: "photo", Kind: Photo, MissingReason: PermissionDenied}, {ID: "video", Kind: Video, MissingReason: NotOnDevice}, entry("thumb", Thumbnail, thumb), nonexact}}
	res, err := restoreBytes(packBytes(t, m, map[string][]byte{"thumb": thumb, "redacted": redacted}), destination(t))
	if err != nil {
		t.Fatal(err)
	}
	if res.Complete || res.Missing["photo"] != PermissionDenied || res.Missing["video"] != NotOnDevice || res.UnverifiedOriginals["redacted"] != SourceNotExact {
		t.Fatalf("incomplete reported incorrectly: %+v", res)
	}
	if len(res.Files) != 2 || res.Files["thumb"].Path == "" {
		t.Fatal("thumbnail lost or phantom original")
	}
}
func TestCrossFamilyAndExistingDestinationRejectedWithoutOverwriting(t *testing.T) {
	m := Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{}}
	data := packBytes(t, m, nil)
	target := destination(t)
	_, err := Restore(context.Background(), bytes.NewReader(data), RestoreOptions{ExpectedFamilyID: "family_B", Destination: target})
	if !errors.Is(err, ErrFamily) {
		t.Fatalf("cross family: %v", err)
	}
	assertNoPublication(t, target)
	for _, populated := range []bool{false, true} {
		target = destination(t)
		if err := os.Mkdir(target, 0700); err != nil {
			t.Fatal(err)
		}
		if populated {
			if err := os.WriteFile(filepath.Join(target, "existing"), []byte("keep"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		_, err = restoreBytes(data, target)
		if !errors.Is(err, ErrDestinationExists) {
			t.Fatal(err)
		}
		files, _ := os.ReadDir(target)
		if len(files) != map[bool]int{false: 0, true: 1}[populated] {
			t.Fatal("existing directory altered")
		}
	}
}
func TestConcurrentRestorationsReserveTargetOnceWithoutUnixRenameOverwrite(t *testing.T) {
	data := packBytes(t, Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{}}, nil)
	target := destination(t)
	const workers = 12
	var wg sync.WaitGroup
	out := make(chan error, workers)
	for range workers {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := restoreBytes(data, target); out <- err }()
	}
	wg.Wait()
	close(out)
	success := 0
	for err := range out {
		if err == nil {
			success++
		} else if !errors.Is(err, ErrDestinationExists) {
			t.Fatal(err)
		}
	}
	if success != 1 {
		t.Fatalf("published %d times", success)
	}
	if _, err := os.Stat(filepath.Join(target, "restore.complete.json")); err != nil {
		t.Fatal(err)
	}
}
func TestDestinationSymlinkRejected(t *testing.T) {
	root := t.TempDir()
	real := filepath.Join(root, "real")
	if err := os.Mkdir(real, 0700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "link")
	if err := os.Symlink(real, target); err != nil {
		t.Skip(err)
	}
	_, err := restoreBytes(packBytes(t, Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{}}, nil), target)
	if !errors.Is(err, ErrDestinationExists) {
		t.Fatal(err)
	}
	files, _ := os.ReadDir(real)
	if len(files) != 0 {
		t.Fatal("followed target symlink")
	}
}
func TestManifestIsStrictAboutDuplicateIDsFieldsTypesAndMissingReasons(t *testing.T) {
	data := []byte("one")
	e := entry("one", Photo, data)
	base := Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{e}}
	raw := string(manifestJSON(t, base))
	cases := map[string]string{
		"duplicate_field": strings.Replace(raw, `"version":1`, `"version":1,"version":1`, 1),
		"case_alias":      strings.Replace(raw, `"family_id"`, `"Family_ID"`, 1),
		"unknown":         strings.Replace(raw, `"version":1`, `"version":1,"extra":true`, 1),
		"null_bool":       strings.Replace(raw, `"source_exact":true`, `"source_exact":null`, 1),
		"string_size":     strings.Replace(raw, `"size":3`, `"size":"3"`, 1),
		"unsafe_id":       strings.Replace(raw, `"id":"one"`, `"id":"../one"`, 1),
		"unsafe_family":   strings.Replace(raw, `"family_A"`, `"../family_A"`, 1),
		"unknown_kind":    strings.Replace(raw, `"kind":"photo"`, `"kind":"device_identity"`, 1),
		"trailing_json":   raw + `{}`, "null_entries": `{"version":1,"family_id":"family_A","entries":null}`,
		"invalid_reason":         `{"version":1,"family_id":"family_A","entries":[{"id":"lost","kind":"photo","size":0,"sha256":"","missing_reason":"whatever","source_exact":false}]}`,
		"missing_required_field": strings.Replace(raw, `,"missing_reason":""`, "", 1),
	}
	dupe := base
	dupe.Entries = []Entry{e, e}
	cases["duplicate_entry"] = string(manifestJSON(t, dupe))
	for name, bad := range cases {
		t.Run(name, func(t *testing.T) {
			target := destination(t)
			_, err := restoreBytes(rewriteArchive(t, []byte(bad), nil), target)
			if err == nil {
				t.Fatal("accepted invalid manifest")
			}
			assertNoPublication(t, target)
		})
	}
	bad := base
	bad.Entries = []Entry{entry("one", Thumbnail, data)}
	bad.Entries[0].SourceExact = true
	if err := Pack(context.Background(), io.Discard, bad, nil); !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
}
func TestTarTraversalLinksDuplicateAndUnexpectedPathsRejected(t *testing.T) {
	payload := []byte("one")
	m := Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{entry("one", Photo, payload)}}
	raw := manifestJSON(t, m)
	for _, name := range []string{"../escape", "/absolute", "entries/../escape", `entries\one`, "entries/different"} {
		t.Run(name, func(t *testing.T) {
			bad := rewriteArchive(t, raw, []struct {
				h    *tar.Header
				data []byte
			}{{header(name, 3), payload}})
			target := destination(t)
			_, err := restoreBytes(bad, target)
			if err == nil {
				t.Fatal("accepted path")
			}
			assertNoPublication(t, target)
		})
	}
	for _, kind := range []byte{tar.TypeSymlink, tar.TypeLink, tar.TypeDir} {
		t.Run(string(kind), func(t *testing.T) {
			h := header("entries/one", 0)
			h.Typeflag = kind
			if kind != tar.TypeDir {
				h.Linkname = "outside"
			}
			bad := rewriteArchive(t, raw, []struct {
				h    *tar.Header
				data []byte
			}{{h, nil}})
			target := destination(t)
			_, err := restoreBytes(bad, target)
			if err == nil {
				t.Fatal("accepted nonregular")
			}
			assertNoPublication(t, target)
		})
	}
	for _, name := range []string{"entries/one", "entries/two", "manifest.json"} {
		t.Run("extra_"+name, func(t *testing.T) {
			bad := rewriteArchive(t, raw, []struct {
				h    *tar.Header
				data []byte
			}{{header("entries/one", 3), payload}, {header(name, 3), payload}})
			target := destination(t)
			_, err := restoreBytes(bad, target)
			if err == nil {
				t.Fatal("accepted extra tar entry")
			}
			assertNoPublication(t, target)
		})
	}
}
func TestTruncationTrailingBytesHashAndSizeErrorsNeverPublish(t *testing.T) {
	payload := []byte("one")
	m := Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{entry("one", Photo, payload)}}
	data := packBytes(t, m, map[string][]byte{"one": payload})
	cases := map[string][]byte{"truncated_data": data[:1537], "missing_terminator": data[:len(data)-1024], "single_terminator": data[:len(data)-512], "partial_terminator": data[:len(data)-1], "trailing_junk": append(append([]byte{}, data...), 1), "trailing_zero": append(append([]byte{}, data...), 0)}
	cases["hash_error"] = rewriteArchive(t, manifestJSON(t, m), []struct {
		h    *tar.Header
		data []byte
	}{{header("entries/one", 3), []byte("two")}})
	cases["header_size_error"] = rewriteArchive(t, manifestJSON(t, m), []struct {
		h    *tar.Header
		data []byte
	}{{header("entries/one", 4), []byte("four")}})
	for name, bad := range cases {
		t.Run(name, func(t *testing.T) {
			target := destination(t)
			_, err := restoreBytes(bad, target)
			if err == nil {
				t.Fatal("accepted invalid archive")
			}
			assertNoPublication(t, target)
		})
	}
}

type trackedReader struct {
	io.Reader
	closed bool
}

func (r *trackedReader) Close() error { r.closed = true; return nil }
func TestPackRejectsAbsentShortLongOrChangedSourcesAndClosesThem(t *testing.T) {
	m := Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{entry("one", Photo, []byte("one"))}}
	for name, data := range map[string][]byte{"short": []byte("on"), "long": []byte("ones"), "changed": []byte("two")} {
		t.Run(name, func(t *testing.T) {
			r := &trackedReader{Reader: bytes.NewReader(data)}
			err := Pack(context.Background(), io.Discard, m, func(string) (io.ReadCloser, error) { return r, nil })
			if !errors.Is(err, ErrSource) || !r.closed {
				t.Fatalf("source not rejected/closed: %v %v", err, r.closed)
			}
		})
	}
	err := Pack(context.Background(), io.Discard, m, func(string) (io.ReadCloser, error) { return nil, os.ErrNotExist })
	if !errors.Is(err, ErrSource) {
		t.Fatal(err)
	}
}
func TestLimitsCancellationAndLargeVideoHeaderRemainBounded(t *testing.T) {
	m := Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{entry("one", Photo, []byte("one"))}}
	if err := PackWithLimits(context.Background(), io.Discard, m, nil, Limits{MaxFileBytes: 2}); !errors.Is(err, ErrLimit) {
		t.Fatal(err)
	}
	data := packBytes(t, m, map[string][]byte{"one": []byte("one")})
	target := destination(t)
	_, err := Restore(context.Background(), bytes.NewReader(data), RestoreOptions{ExpectedFamilyID: "family_A", Destination: target, Limits: Limits{MaxManifestBytes: 8}})
	if !errors.Is(err, ErrLimit) {
		t.Fatal(err)
	}
	assertNoPublication(t, target)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := Pack(ctx, io.Discard, m, nil); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	target = destination(t)
	_, err = Restore(ctx, bytes.NewReader(data), RestoreOptions{ExpectedFamilyID: "family_A", Destination: target})
	if err == nil {
		t.Fatal("cancellation ignored")
	}
	assertNoPublication(t, target)
	// Exercise 10 GiB size encoding without allocating/copying a 10 GiB fixture.
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	h := header("entries/large_video", 10<<30)
	if err := tw.WriteHeader(h); err != nil {
		t.Fatal(err)
	}
	got, err := tar.NewReader(bytes.NewReader(buf.Bytes())).Next()
	if err != nil || got.Size != 10<<30 || got.Format != tar.FormatGNU {
		t.Fatalf("large video header: %v %v", got, err)
	}
}

func TestRestrictedRestoreRequiresEnforceablePrivatePermissions(t *testing.T) {
	data := packBytes(t, Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{}}, nil)
	target := destination(t)
	result, err := Restore(context.Background(), bytes.NewReader(data), RestoreOptions{ExpectedFamilyID: "family_A", Destination: target, RequirePrivateACL: true})
	if runtime.GOOS == "windows" {
		if !errors.Is(err, ErrPrivateACLUnavailable) {
			t.Fatalf("unverified Windows ACL accepted: %v", err)
		}
		assertNoPublication(t, target)
		// Explicit public restore remains available under a caller-controlled parent.
		if _, err = restoreBytes(data, target); err != nil {
			t.Fatal(err)
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(result.Directory)
	if err != nil || info.Mode().Perm() != 0700 {
		t.Fatalf("non-private output: %v %v", info, err)
	}
}

func TestHiddenExtensionAndNonzeroPaddingCannotReplaceTerminator(t *testing.T) {
	payload := []byte("one")
	m := Manifest{Version: Version, FamilyID: "family_A", Entries: []Entry{entry("one", Photo, payload)}}
	raw := manifestJSON(t, m)
	valid := packBytes(t, m, map[string][]byte{"one": payload})
	offset := int(512 + paddingSize(int64(len(raw))))
	// Construct a GNU longname extension with an ordinary short name. The stock
	// tar.Reader would hide this auxiliary header; removing the two end blocks
	// offsets its physical length, so a mere total-length check is insufficient.
	var hbuf bytes.Buffer
	tw := tar.NewWriter(&hbuf)
	name := []byte("entries/one\x00")
	if err := tw.WriteHeader(header("././@LongLink", int64(len(name)))); err != nil {
		t.Fatal(err)
	}
	ext := append([]byte{}, hbuf.Bytes()...)
	ext[156] = tar.TypeGNULongName
	for i := 148; i < 156; i++ {
		ext[i] = ' '
	}
	sum := 0
	for _, b := range ext {
		sum += int(b)
	}
	copy(ext[148:156], []byte(fmt.Sprintf("%06o\x00 ", sum)))
	ext = append(ext, name...)
	ext = append(ext, make([]byte, 512-len(name))...)
	hidden := append([]byte{}, valid[:offset]...)
	hidden = append(hidden, ext...)
	hidden = append(hidden, valid[offset:len(valid)-1024]...)
	if len(hidden) != len(valid) {
		t.Fatal("fixture does not counterbalance terminator")
	}
	manifestPadding := append([]byte{}, valid...)
	manifestPadding[512+len(raw)] = 1
	mediaPadding := append([]byte{}, valid...)
	mediaPadding[offset+512+len(payload)] = 1
	for name, bad := range map[string][]byte{"hidden_extension_without_end": hidden, "manifest_padding": manifestPadding, "media_padding": mediaPadding} {
		t.Run(name, func(t *testing.T) {
			target := destination(t)
			if _, err := restoreBytes(bad, target); err == nil {
				t.Fatal("accepted hidden bytes")
			}
			assertNoPublication(t, target)
		})
	}
}
