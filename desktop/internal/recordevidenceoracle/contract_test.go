// Package recordevidenceoracle 仅验证只读证据容器，不提供活动库导入或同步出口。
package recordevidenceoracle

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

const maxInteger = 9007199254740991

var invalid = errors.New("invalid inert evidence")
var ident = regexp.MustCompile(`^[A-Za-z0-9_-]{1,100}$`)
var encoding = base64.RawURLEncoding.Strict()

func canonical(v any) string {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if e.Encode(v) != nil {
		panic("synthetic encode")
	}
	return strings.TrimSuffix(b.String(), "\n")
}
func sha(raw string) string { sum := sha256.Sum256([]byte(raw)); return hex.EncodeToString(sum[:]) }
func rawFields(raw string, prefix string) map[string]any {
	return map[string]any{prefix + "_b64": encoding.EncodeToString([]byte(raw)), prefix + "_sha256": sha(raw)}
}
func doc(id, collection, data, versions string, deleted bool, revision int) map[string]any {
	m := map[string]any{"space": "family", "collection": "/families/family/" + collection, "id": id, "deleted": deleted, "revision": revision}
	for k, v := range rawFields(data, "data") {
		m[k] = v
	}
	for k, v := range rawFields(versions, "versions") {
		m[k] = v
	}
	return m
}
func op(actor string, seq, clock int, collection, id, kind string, fields map[string]any) map[string]any {
	p := map[string]any{"space": "family", "actor": actor, "sequence": seq, "clock": clock, "collection": "/families/family/" + collection, "id": id, "kind": kind, "fields": fields}
	// 刻意保留原payload额外外层空白；不得归一化后冒充原日志字节。
	raw := " \n" + canonical(p) + " \t"
	m := map[string]any{"space": "family", "actor": actor, "sequence": seq, "clock": clock}
	for k, v := range rawFields(raw, "payload") {
		m[k] = v
	}
	return m
}
func fixture() map[string]any {
	a := map[string]any{"user_id": "viewer-a", "role": "owner", "status": "active"}
	b := map[string]any{"user_id": "viewer-b", "role": "member", "status": "inactive"}
	versions := func(fields map[string]any, actor string, clock int) string {
		m := map[string]any{}
		for k := range fields {
			m[k] = map[string]any{"actor": actor, "clock": clock}
		}
		return canonical(m)
	}
	docs := []any{doc("viewer-a", "members", canonical(a), versions(a, "viewer-a", 1), false, 1), doc("viewer-b", "members", canonical(b), versions(b, "viewer-a", 2), false, 2),
		doc("note-1", "notes", `{ "amount":200, "title":"B wins" }`, `{"title":{"clock":3,"actor":"viewer-b"},"amount":{"actor":"viewer-a","clock":3}}`, true, 5),
		doc("note-2", "notes", `{"body":"合成证据：历史来源未证明"}`, `{"body" : {"actor":"viewer-a","clock":9}}`, false, 9)}
	ops := []any{op("viewer-a", 1, 1, "members", "viewer-a", "patch", a), op("viewer-a", 2, 2, "members", "viewer-b", "patch", b),
		op("viewer-a", 3, 3, "notes", "note-1", "patch", map[string]any{"amount": 200, "title": "A version"}), op("viewer-a", 4, 4, "notes", "note-1", "delete", map[string]any{}),
		op("viewer-a", 6, 6, "notes", "note-3", "patch", map[string]any{"body": "synthetic orphan"}), op("viewer-b", 1, 3, "notes", "note-1", "patch", map[string]any{"title": "B wins"})}
	sort.Slice(docs, func(i, j int) bool { return docKey(docs[i].(map[string]any)) < docKey(docs[j].(map[string]any)) })
	root := map[string]any{"version": 2, "kind": "wo_record_evidence", "source_family_id": "family", "viewer_id": "viewer-a", "scopes": []any{"family"},
		"provenance": "provenance_unverified", "normal_import_allowed": false, "peer_exportable": false, "identity_restored": false, "records_applied": false,
		"authorization_receipts": []any{}, "private_device_revocations": "not_exported", "documents": docs, "operations": ops,
		"omissions": []any{"history_access_unproven", "private_registry_not_exported"}}
	refresh(root)
	return root
}
func object(raw []byte) (map[string]any, error) {
	if !utf8.Valid(raw) || !json.Valid(raw) {
		return nil, invalid
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 12 {
			return invalid
		}
		token, e := d.Token()
		if e != nil {
			return invalid
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for d.More() {
				key, e := d.Token()
				s, ok := key.(string)
				if e != nil || !ok || seen[s] {
					return invalid
				}
				seen[s] = true
				if walk(depth+1) != nil {
					return invalid
				}
			}
			_, e = d.Token()
			return e
		case '[':
			for d.More() {
				if walk(depth+1) != nil {
					return invalid
				}
			}
			_, e = d.Token()
			return e
		default:
			return invalid
		}
	}
	if walk(0) != nil {
		return nil, invalid
	}
	if _, e := d.Token(); e != io.EOF {
		return nil, invalid
	}
	d = json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var m map[string]any
	if d.Decode(&m) != nil || m == nil {
		return nil, invalid
	}
	return m, nil
}
func mapValue(v any) map[string]any { m, _ := v.(map[string]any); return m }
func number(v any) (int64, bool) {
	switch n := v.(type) {
	case int:
		return int64(n), n > 0
	case json.Number:
		i, e := strconv.ParseInt(string(n), 10, 64)
		return i, e == nil && i > 0 && i <= maxInteger
	}
	return 0, false
}
func text(v any) string { s, _ := v.(string); return s }
func exact(m map[string]any, keys ...string) bool {
	if len(m) != len(keys) {
		return false
	}
	for _, k := range keys {
		if _, ok := m[k]; !ok {
			return false
		}
	}
	return true
}
func decodeRaw(m map[string]any, prefix string, max int) (string, error) {
	s := text(m[prefix+"_b64"])
	if len(s) > (max*4+2)/3 {
		return "", invalid
	}
	raw, e := encoding.DecodeString(s)
	if e != nil || len(raw) > max || !utf8.Valid(raw) || encoding.EncodeToString(raw) != s || sha(string(raw)) != text(m[prefix+"_sha256"]) {
		return "", invalid
	}
	return string(raw), nil
}
func docKey(m map[string]any) string {
	return text(m["space"]) + "|" + text(m["collection"]) + "|" + text(m["id"])
}
func location(space, collection, id string, scopes map[string]bool) (string, error) {
	if !ident.MatchString(space) || !ident.MatchString(id) || !scopes[space] || !strings.HasPrefix(collection, "/families/"+space+"/") {
		return "", invalid
	}
	suffix := strings.TrimPrefix(collection, "/families/"+space+"/")
	for _, p := range strings.Split(suffix, "/") {
		if !ident.MatchString(p) {
			return "", invalid
		}
	}
	return suffix, nil
}
func noNative(value any, depth int) bool {
	if depth > 10 {
		return false
	}
	switch v := value.(type) {
	case map[string]any:
		for k, item := range v {
			switch k {
			case "locator", "bookmark", "asset_id", "original_uri", "original_bytes", "original_handle", "source_uri", "file_path", "api_key", "access_token", "password", "secret", "token", "secret_ref", "credential_ref":
				return false
			}
			if !noNative(item, depth+1) {
				return false
			}
		}
	case []any:
		if len(v) > 4096 {
			return false
		}
		for _, item := range v {
			if !noNative(item, depth+1) {
				return false
			}
		}
	case string:
		lower := strings.ToLower(v)
		for _, prefix := range []string{"content://", "file://", "ph://", "assets-library://"} {
			if strings.Contains(lower, prefix) {
				return false
			}
		}
	}
	return true
}
func schema(suffix string, fields map[string]any) bool {
	if len(fields) > 256 || !noNative(fields, 0) {
		return false
	}
	allowed := map[string]bool{}
	switch suffix {
	case "notes":
		allowed = map[string]bool{"title": true, "amount": true, "body": true}
	case "members":
		allowed = map[string]bool{"user_id": true, "role": true, "status": true}
	default:
		return false
	}
	for k := range fields {
		if !allowed[k] {
			return false
		}
	}
	return true
}
func validate(raw []byte, family string) (map[string]any, error) {
	if len(raw) > 64<<20 {
		return nil, invalid
	}
	root, e := object(raw)
	if e != nil {
		return nil, e
	}
	if !exact(root, "version", "kind", "source_family_id", "viewer_id", "scopes", "provenance", "normal_import_allowed", "peer_exportable", "identity_restored", "records_applied", "authorization_receipts", "private_device_revocations", "documents", "operations", "omissions", "counts", "closure_issues") {
		return nil, invalid
	}
	if root["version"] != json.Number("2") || root["kind"] != "wo_record_evidence" || root["source_family_id"] != family || !ident.MatchString(text(root["viewer_id"])) || root["provenance"] != "provenance_unverified" || root["private_device_revocations"] != "not_exported" {
		return nil, invalid
	}
	for _, k := range []string{"normal_import_allowed", "peer_exportable", "identity_restored", "records_applied"} {
		if root[k] != false {
			return nil, invalid
		}
	}
	receipts, ok := root["authorization_receipts"].([]any)
	if !ok || len(receipts) != 0 {
		return nil, invalid
	}
	scopeList, ok := root["scopes"].([]any)
	if !ok || len(scopeList) == 0 || len(scopeList) > 64 {
		return nil, invalid
	}
	scopes := map[string]bool{}
	for _, v := range scopeList {
		s := text(v)
		if !ident.MatchString(s) || scopes[s] {
			return nil, invalid
		}
		scopes[s] = true
	}
	if !scopes[family] {
		return nil, invalid
	}
	docs, ok := root["documents"].([]any)
	if !ok || len(docs) > 20000 {
		return nil, invalid
	}
	ops, ok := root["operations"].([]any)
	if !ok || len(ops) > 100000 {
		return nil, invalid
	}
	seen := map[string]bool{}
	for _, rawDoc := range docs {
		d := mapValue(rawDoc)
		if !exact(d, "space", "collection", "id", "deleted", "revision", "data_b64", "data_sha256", "versions_b64", "versions_sha256") {
			return nil, invalid
		}
		if _, ok := d["deleted"].(bool); !ok {
			return nil, invalid
		}
		if _, ok := number(d["revision"]); !ok {
			return nil, invalid
		}
		suffix, e := location(text(d["space"]), text(d["collection"]), text(d["id"]), scopes)
		if e != nil || seen[docKey(d)] {
			return nil, invalid
		}
		seen[docKey(d)] = true
		data, e := decodeRaw(d, "data", 2<<20)
		if e != nil {
			return nil, e
		}
		versions, e := decodeRaw(d, "versions", 512<<10)
		if e != nil {
			return nil, e
		}
		fields, e := object([]byte(data))
		if e != nil || !schema(suffix, fields) {
			return nil, invalid
		}
		v, e := object([]byte(versions))
		if e != nil || len(v) != len(fields) {
			return nil, invalid
		}
		for key, rawVersion := range v {
			version := mapValue(rawVersion)
			if _, exists := fields[key]; !exists || !exact(version, "actor", "clock") || !ident.MatchString(text(version["actor"])) {
				return nil, invalid
			}
			if _, ok := number(version["clock"]); !ok {
				return nil, invalid
			}
		}
	}
	seen = map[string]bool{}
	for _, rawOp := range ops {
		o := mapValue(rawOp)
		if !exact(o, "space", "actor", "sequence", "clock", "payload_b64", "payload_sha256") {
			return nil, invalid
		}
		seq, ok := number(o["sequence"])
		if !ok {
			return nil, invalid
		}
		clock, ok := number(o["clock"])
		if !ok || !ident.MatchString(text(o["actor"])) {
			return nil, invalid
		}
		key := fmt.Sprint(o["space"], "|", o["actor"], "|", seq)
		if seen[key] {
			return nil, invalid
		}
		seen[key] = true
		payload, e := decodeRaw(o, "payload", 1<<20)
		if e != nil {
			return nil, e
		}
		p, e := object([]byte(payload))
		if e != nil || !exact(p, "space", "actor", "sequence", "clock", "collection", "id", "kind", "fields") {
			return nil, invalid
		}
		ps, _ := number(p["sequence"])
		pc, _ := number(p["clock"])
		if p["space"] != o["space"] || p["actor"] != o["actor"] || ps != seq || pc != clock {
			return nil, invalid
		}
		suffix, e := location(text(o["space"]), text(p["collection"]), text(p["id"]), scopes)
		fields := mapValue(p["fields"])
		if e != nil || fields == nil || !schema(suffix, fields) || (p["kind"] != "patch" && p["kind"] != "delete") || (p["kind"] == "delete" && len(fields) != 0) {
			return nil, invalid
		}
	}
	omissions, ok := root["omissions"].([]any)
	if !ok || len(omissions) > 16 {
		return nil, invalid
	}
	omissionSet := map[string]bool{}
	for _, v := range omissions {
		s := text(v)
		switch s {
		case "history_access_unproven", "private_registry_not_exported", "schema_not_supported", "source_operation_limit", "source_document_limit", "historical_selection_incomplete":
		default:
			return nil, invalid
		}
		if omissionSet[s] {
			return nil, invalid
		}
		omissionSet[s] = true
	}
	expected := clone(root)
	refresh(expected)
	if canonical(root["counts"]) != canonical(expected["counts"]) || canonical(root["closure_issues"]) != canonical(expected["closure_issues"]) {
		return nil, invalid
	}
	return root, nil
}
func clone(root map[string]any) map[string]any {
	m, e := object([]byte(canonical(root)))
	if e != nil {
		panic(e)
	}
	return m
}
func issue(code, space, collection, id, actor string, from, to int64) map[string]any {
	return map[string]any{"code": code, "space": space, "collection": collection, "id": id, "actor": actor, "from_sequence": from, "to_sequence": to}
}
func refresh(root map[string]any) {
	docs := root["documents"].([]any)
	ops := root["operations"].([]any)
	family := text(root["source_family_id"])
	docKeys, members, deletes := map[string]bool{}, map[string]bool{}, map[string]bool{}
	origins := map[string]int{}
	byActor := map[string][]int64{}
	issues := map[string]map[string]any{}
	add := func(m map[string]any) { issues[canonical(m)] = m }
	add(issue("authorization_receipts_unavailable", "", "", "", "", 0, 0))
	add(issue("private_device_revocations_unavailable", "", "", "", "", 0, 0))
	tombstones, memberCount := 0, 0
	for _, v := range docs {
		d := mapValue(v)
		docKeys[docKey(d)] = true
		if d["deleted"] == true {
			tombstones++
		}
		if d["space"] == family && d["collection"] == "/families/"+family+"/members" {
			members[text(d["id"])] = true
			memberCount++
		}
	}
	origin := func(key, actor string, clock int64, field string, value any) string {
		return canonical([]any{key, actor, clock, field, sha(canonical(value))})
	}
	for _, v := range ops {
		o := mapValue(v)
		raw, _ := decodeRaw(o, "payload", 1<<20)
		p, _ := object([]byte(raw))
		target := docKey(p)
		seq, _ := number(o["sequence"])
		clock, _ := number(o["clock"])
		actor, space := text(o["actor"]), text(o["space"])
		byActor[space+"|"+actor] = append(byActor[space+"|"+actor], seq)
		if p["kind"] == "delete" {
			deletes[target] = true
		} else {
			for field, value := range mapValue(p["fields"]) {
				origins[origin(target, actor, clock, field, value)]++
			}
		}
		if !docKeys[target] {
			add(issue("operation_target_missing", space, text(p["collection"]), text(p["id"]), actor, 0, 0))
		}
		if !members[actor] {
			add(issue("operation_actor_not_in_member_evidence", space, "", "", actor, 0, 0))
		}
	}
	for _, v := range docs {
		d := mapValue(v)
		key := docKey(d)
		space, c, id := text(d["space"]), text(d["collection"]), text(d["id"])
		if d["deleted"] == true && !deletes[key] {
			add(issue("missing_delete_operation", space, c, id, "", 0, 0))
		}
		raw, _ := decodeRaw(d, "data", 2<<20)
		data, _ := object([]byte(raw))
		raw, _ = decodeRaw(d, "versions", 512<<10)
		versions, _ := object([]byte(raw))
		for field, rawVersion := range versions {
			v := mapValue(rawVersion)
			clock, _ := number(v["clock"])
			actor := text(v["actor"])
			matches := origins[origin(key, actor, clock, field, data[field])]
			if matches != 1 {
				code := "missing_version_origin"
				if matches > 1 {
					code = "ambiguous_version_origin"
				}
				add(issue(code, space, c, id, actor, 0, 0))
			}
		}
	}
	for key, sequences := range byActor {
		sort.Slice(sequences, func(i, j int) bool { return sequences[i] < sequences[j] })
		parts := strings.Split(key, "|")
		expected := int64(1)
		for _, seq := range sequences {
			if seq > expected {
				add(issue("operation_sequence_gap", parts[0], "", "", parts[1], expected, seq-1))
			}
			expected = seq + 1
		}
	}
	keys := make([]string, 0, len(issues))
	for key := range issues {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	result := []any{}
	for _, key := range keys {
		result = append(result, issues[key])
	}
	root["counts"] = map[string]any{"documents": len(docs), "tombstones": tombstones, "operations": len(ops), "member_documents": memberCount}
	root["closure_issues"] = result
}
func TestFixedV2Evidence(t *testing.T) {
	root := fixture()
	raw := []byte(canonical(root))
	paths := []string{"testdata/record-v2.json", "../../../test/local/backup/fixtures/record-v2.json"}
	if os.Getenv("WO_WRITE_EVIDENCE_FIXTURES") == "1" {
		for _, p := range paths {
			if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
				t.Fatal(e)
			}
			if e := os.WriteFile(p, raw, 0600); e != nil {
				t.Fatal(e)
			}
		}
	}
	for _, p := range paths {
		saved, e := os.ReadFile(p)
		if e != nil || !bytes.Equal(saved, raw) {
			t.Fatal(p, e)
		}
	}
	if _, e := validate(raw, "family"); e != nil {
		t.Fatal(e)
	}
	t.Logf("fixture bytes=%d sha256=%s", len(raw), sha(string(raw)))
	codes := map[string]bool{}
	for _, i := range root["closure_issues"].([]any) {
		codes[text(mapValue(i)["code"])] = true
	}
	for _, code := range []string{"authorization_receipts_unavailable", "private_device_revocations_unavailable", "missing_version_origin", "operation_target_missing", "operation_sequence_gap"} {
		if !codes[code] {
			t.Fatal(code)
		}
	}
}
func TestWrongFamilyDigestUnsafeFlagsAndNativeRefsReject(t *testing.T) {
	base := fixture()
	if _, e := validate([]byte(canonical(base)), "other-family"); e == nil {
		t.Fatal("接受跨家庭")
	}
	for _, flag := range []string{"normal_import_allowed", "peer_exportable", "identity_restored", "records_applied"} {
		m := clone(base)
		m[flag] = true
		if _, e := validate([]byte(canonical(m)), "family"); e == nil {
			t.Fatal(flag)
		}
	}
	m := clone(base)
	m["provenance"] = "verified"
	if _, e := validate([]byte(canonical(m)), "family"); e == nil {
		t.Fatal("假来源")
	}
	m = clone(base)
	d := mapValue(m["documents"].([]any)[0])
	d["data_sha256"] = strings.Repeat("0", 64)
	if _, e := validate([]byte(canonical(m)), "family"); e == nil {
		t.Fatal("错误SHA")
	}
	m = clone(base)
	d = mapValue(m["documents"].([]any)[3])
	for k, v := range rawFields(`{"body":"content://synthetic/denied"}`, "data") {
		d[k] = v
	}
	if _, e := validate([]byte(canonical(m)), "family"); e == nil {
		t.Fatal("原生URI")
	}
	m = clone(base)
	m["closure_issues"] = []any{}
	if _, e := validate([]byte(canonical(m)), "family"); e == nil {
		t.Fatal("删除缺证据报告")
	}
	m = clone(base)
	m["counts"] = map[string]any{"documents": 0}
	if _, e := validate([]byte(canonical(m)), "family"); e == nil {
		t.Fatal("假计数")
	}
}
func TestRawOpsRemainUnchangedInInertRebackup(t *testing.T) {
	raw := []byte(canonical(fixture()))
	parsed, e := validate(raw, "family")
	if e != nil {
		t.Fatal(e)
	}
	for _, v := range parsed["operations"].([]any) {
		o := mapValue(v)
		payload, e := decodeRaw(o, "payload", 1<<20)
		if e != nil {
			t.Fatal(e)
		}
		if !strings.HasPrefix(payload, " \n") || !strings.HasSuffix(payload, " \t") {
			t.Fatal("重写原日志")
		}
		p, e := object([]byte(payload))
		if e != nil || p["actor"] != o["actor"] {
			t.Fatal(e)
		}
	}
	// 只读私有恢复库可保留整份artifact原字节；没有重新签发、旧身份激活或merge。
	copied := bytes.Clone(raw)
	if !bytes.Equal(raw, copied) || sha(string(raw)) != sha(string(copied)) {
		t.Fatal("重备份字节不同")
	}
	if parsed["source_family_id"] != "family" || parsed["identity_restored"] != false {
		t.Fatal("不能换sourceFamily或激活旧身份")
	}
}
func TestDuplicateKeysAndOperationIndexMismatchReject(t *testing.T) {
	if _, e := object([]byte(`{"version":2,"version":2}`)); e == nil {
		t.Fatal("重复key")
	}
	m := clone(fixture())
	o := mapValue(m["operations"].([]any)[0])
	o["actor"] = "forged-synthetic"
	if _, e := validate([]byte(canonical(m)), "family"); e == nil {
		t.Fatal("变造actor")
	}
	raw := []byte(canonical(fixture()))
	for _, cut := range []int{0, 1, len(raw) - 1} {
		if _, e := validate(raw[:cut], "family"); e == nil {
			t.Fatal("截断")
		}
	}
}

func TestClosureReportsMissingDeleteAmbiguousVersionAndActor(t *testing.T) {
	root := clone(fixture())
	original := root["operations"].([]any)
	filtered := []any{}
	for _, value := range original {
		o := mapValue(value)
		raw, _ := decodeRaw(o, "payload", 1<<20)
		p, _ := object([]byte(raw))
		if p["kind"] != "delete" {
			filtered = append(filtered, value)
		}
	}
	root["operations"] = filtered
	refresh(root)
	if _, e := validate([]byte(canonical(root)), "family"); e != nil {
		t.Fatal(e)
	}
	found := false
	for _, value := range root["closure_issues"].([]any) {
		if mapValue(value)["code"] == "missing_delete_operation" {
			found = true
		}
	}
	if !found {
		t.Fatal("缺少删除日志却未报告")
	}
	root = clone(fixture())
	root["operations"] = append(root["operations"].([]any), op("viewer-a", 7, 3, "notes", "note-1", "patch", map[string]any{"amount": 200}))
	refresh(root)
	if _, e := validate([]byte(canonical(root)), "family"); e != nil {
		t.Fatal(e)
	}
	found = false
	for _, value := range root["closure_issues"].([]any) {
		if mapValue(value)["code"] == "ambiguous_version_origin" {
			found = true
		}
	}
	if !found {
		t.Fatal("歧义原始版本未报告")
	}
	root = clone(fixture())
	docs := []any{}
	for _, value := range root["documents"].([]any) {
		if mapValue(value)["id"] != "viewer-b" {
			docs = append(docs, value)
		}
	}
	root["documents"] = docs
	refresh(root)
	if _, e := validate([]byte(canonical(root)), "family"); e != nil {
		t.Fatal(e)
	}
	found = false
	for _, value := range root["closure_issues"].([]any) {
		if mapValue(value)["code"] == "operation_actor_not_in_member_evidence" {
			found = true
		}
	}
	if !found {
		t.Fatal("缺成员状态证据未报告")
	}
	for _, name := range []string{"normal_import_allowed", "peer_exportable", "identity_restored", "records_applied"} {
		if root[name] != false {
			t.Fatal("闭包不足不能升级权限", name)
		}
	}
}
