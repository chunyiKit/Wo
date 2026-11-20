import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/backup/record_evidence.dart';

RecordEvidenceSchema schema({void Function(EvidenceContentKind)? observed})=>RecordEvidenceSchema(
  fields:{'notes':{'title','amount','body'},'members':{'user_id','status','role'}},
  validateContent:(space,suffix,id,fields,kind){observed?.call(kind);for(final e in fields.entries){
    if(e.key=='amount'){if(e.value is! int||e.value<0||e.value>1000000000)throw const RecordEvidenceException('synthetic_amount_type');}
    else if(e.value is! String){throw const RecordEvidenceException('synthetic_text_type');}
  }});
Future<Uint8List> fixture()=>File('test/local/backup/fixtures/record-v2.json').readAsBytes();
Map<String,dynamic> object(Uint8List bytes)=>jsonDecode(utf8.decode(bytes)) as Map<String,dynamic>;
Uint8List bytes(Map<String,dynamic> value)=>Uint8List.fromList(utf8.encode(jsonEncode(value)));
void main(){
  test('Go KAT decodes only as inert evidence and rebackup keeps artifact/raw bytes/source family',()async{
    final raw=await fixture();var checked=0;final evidence=RecordEvidence.decode(raw,expectedFamily:'family',schema:schema(observed:(_)=>checked++));
    expect(checked,10);expect(evidence.sourceFamilyId,'family');expect(evidence.viewerId,'viewer-a');
    expect(evidence.provenance,'provenance_unverified');expect(evidence.normalImportAllowed,false);expect(evidence.peerExportable,false);
    expect(evidence.identityRestored,false);expect(evidence.recordsApplied,false);expect(evidence.fullDeviceComplete,false);
    expect(evidence.bytes,raw);expect(evidence.sha256,hashing.sha256.convert(raw).toString());
    expect(evidence.documents.singleWhere((d)=>d.id=='viewer-b').data['status'],'inactive');
    for(final op in evidence.operations){expect(op.rawPayload.startsWith(' \n'),true);expect(op.rawPayload.endsWith(' \t'),true);expect(op.payload['actor'],op.actor);}
    final rebuilt=RecordEvidence.build(sourceFamilyId:evidence.sourceFamilyId,viewerId:evidence.viewerId,scopes:evidence.scopes,
      documents:evidence.documents,operations:evidence.operations,schema:schema(),omissions:evidence.omissions);
    expect(rebuilt.bytes,raw);expect(rebuilt.sha256,evidence.sha256);
  });
  test('conflicting historical raw fields are not replaced with final LWW row or restamped',()async{
    final evidence=RecordEvidence.decode(await fixture(),expectedFamily:'family',schema:schema());
    final row=evidence.documents.singleWhere((d)=>d.id=='note-1');expect(row.deleted,true);expect(row.data['title'],'B wins');
    final old=evidence.operations.singleWhere((o)=>o.actor=='viewer-a'&&o.sequence==3);
    expect(old.clock,3);expect(old.payload['fields']['title'],'A version');expect(old.rawPayload,contains('A version'));
    final sameActor=evidence.operations.singleWhere((o)=>o.actor=='viewer-b');expect(sameActor.clock,3);
    expect(row.versions['title'],{'actor':'viewer-b','clock':3});
    expect(evidence.operations.singleWhere((o)=>o.actor=='viewer-a'&&o.sequence==4).payload['kind'],'delete');
  });
  test('closure findings are mandatory and do not turn absence of auth receipts into verified rights',()async{
    final evidence=RecordEvidence.decode(await fixture(),expectedFamily:'family',schema:schema());
    final codes=evidence.closureIssues.map((i)=>i.code).toSet();
    expect(codes,containsAll(['authorization_receipts_unavailable','private_device_revocations_unavailable','missing_version_origin','operation_target_missing','operation_sequence_gap']));
    final gap=evidence.closureIssues.singleWhere((i)=>i.code=='operation_sequence_gap');expect(gap.actor,'viewer-a');expect(gap.fromSequence,5);expect(gap.toSequence,5);
    final root=object(await fixture())..['closure_issues']=<Object>[];
    expect(()=>RecordEvidence.decode(bytes(root),expectedFamily:'family',schema:schema()),throwsA(isA<RecordEvidenceException>()));
  });
  test('claimed active import, identity, peer rights, receipts or foreign family are rejected',()async{
    final raw=await fixture();for(final flag in ['normal_import_allowed','peer_exportable','identity_restored','records_applied']){
      final j=object(raw);j[flag]=true;expect(()=>RecordEvidence.decode(bytes(j),expectedFamily:'family',schema:schema()),throwsA(isA<RecordEvidenceException>()));}
    final j=object(raw)..['authorization_receipts']=['synthetic-not-a-receipt'];
    expect(()=>RecordEvidence.decode(bytes(j),expectedFamily:'family',schema:schema()),throwsA(isA<RecordEvidenceException>()));
    expect(()=>RecordEvidence.decode(raw,expectedFamily:'other-family',schema:schema()),throwsA(isA<RecordEvidenceException>()));
  });
  test('wrong SHA, changed actor/index and dishonest counts cannot be accepted as same evidence',()async{
    final raw=await fixture();var j=object(raw);j['documents'][0]['data_sha256']='0'*64;
    expect(()=>RecordEvidence.decode(bytes(j),expectedFamily:'family',schema:schema()),throwsA(isA<RecordEvidenceException>()));
    j=object(raw);j['operations'][0]['actor']='forged-synthetic';
    expect(()=>RecordEvidence.decode(bytes(j),expectedFamily:'family',schema:schema()),throwsA(isA<RecordEvidenceException>()));
    j=object(raw);j['counts']['tombstones']=0;
    expect(()=>RecordEvidence.decode(bytes(j),expectedFamily:'family',schema:schema()),throwsA(isA<RecordEvidenceException>()));
  });
  test('omitted history remains explicit missing-origin/delete evidence with no normal import',()async{
    final original=RecordEvidence.decode(await fixture(),expectedFamily:'family',schema:schema());
    final inert=RecordEvidence.build(sourceFamilyId:'family',viewerId:'viewer-a',scopes:['family'],documents:original.documents,
      operations:[],schema:schema(),omissions:['historical_selection_incomplete','history_access_unproven','private_registry_not_exported']);
    expect(inert.closureIssues.map((i)=>i.code),contains('missing_delete_operation'));expect(inert.closureIssues.map((i)=>i.code),contains('missing_version_origin'));
    expect(inert.normalImportAllowed,false);expect(inert.documents.singleWhere((d)=>d.id=='note-1').deleted,true);
  });
  test('whitelist and native URI/secret field rejection never redact or rewrite original operation',(){
    RecordEvidenceDocument d(String data)=>RecordEvidenceDocument(space:'family',collection:'/families/family/notes',id:'note',deleted:false,
      revision:1,rawData:data,rawVersions:'{"body":{"actor":"viewer-a","clock":1}}');
    for(final data in ['{"body":"content://synthetic/blocked"}','{"body":"file:///synthetic/blocked"}','{"credential_ref":"synthetic-not-exportable"}']){
      expect(()=>RecordEvidence.build(sourceFamilyId:'family',viewerId:'viewer-a',scopes:['family'],documents:[d(data)],operations:[],schema:schema()),throwsA(isA<RecordEvidenceException>()));
    }
    final op=RecordEvidenceOperation(space:'family',actor:'viewer-a',sequence:1,clock:1,
      rawPayload:'{"space":"family","actor":"viewer-a","sequence":1,"clock":1,"collection":"/families/family/notes","id":"note","kind":"delete","fields":{"body":"synthetic"}}');
    expect(()=>RecordEvidence.build(sourceFamilyId:'family',viewerId:'viewer-a',scopes:['family'],documents:[],operations:[op],schema:schema()),throwsA(isA<RecordEvidenceException>()));
  });
  test('duplicate operation IDs and v1 bytes cannot masquerade as v2 history evidence',()async{
    final original=RecordEvidence.decode(await fixture(),expectedFamily:'family',schema:schema());
    expect(()=>RecordEvidence.build(sourceFamilyId:'family',viewerId:'viewer-a',scopes:['family'],documents:original.documents,
      operations:[original.operations.first,original.operations.first],schema:schema()),throwsA(isA<RecordEvidenceException>()));
    expect(()=>RecordEvidence.decode(Uint8List.fromList(utf8.encode('{"version":1,"family_id":"family","documents":[]}')),
      expectedFamily:'family',schema:schema()),throwsA(isA<RecordEvidenceException>()));
  });
}
