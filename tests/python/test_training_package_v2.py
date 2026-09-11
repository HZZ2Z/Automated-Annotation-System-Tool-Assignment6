import importlib
from pathlib import Path

def test_independent_validator_exists():
    assert importlib.util.find_spec('annotation_data.training_package') is not None, 'missing independent package validator'

def test_actual_godot_package():
    module = importlib.import_module('annotation_data.training_package')
    package = Path('/tmp/part4-package-path.txt').read_text()
    assert module.validate_training_package(package) == []

import json
import shutil
import hashlib
import pytest

@pytest.fixture
def copied(tmp_path):
    package = Path('/tmp/part4-package-path.txt').read_text()
    result = tmp_path / 'package'
    shutil.copytree(package, result)
    return result

def rehash(root):
    from annotation_data.training_package import package_identity
    path = root / 'manifest.json'
    manifest = json.loads(path.read_text())
    for item in manifest['artifacts']:
        data = (root / item['path']).read_bytes()
        item.update(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
    manifest['package_id'] = package_identity(manifest)
    path.write_text(json.dumps(manifest))

def change_json(root, relative, mutate):
    path = root / relative
    obj = json.loads(path.read_text())
    mutate(obj)
    path.write_text(json.dumps(obj))
    rehash(root)

def validate(root):
    from annotation_data.training_package import validate_training_package
    return validate_training_package(root)

@pytest.mark.parametrize('case', ['corrupt','path','extra','symlink','sample','source','time','verified','report','class','manifest','duplicate_event','invalid_region','unknown','batch'])
def test_corruption_rejected(copied, case):
    if case == 'corrupt':
        (copied / 'reports/diff.csv').write_text('broken')
    elif case == 'path':
        path = copied / 'manifest.json'
        m = json.loads(path.read_text())
        m['artifacts'][0]['path'] = '../outside'
        path.write_text(json.dumps(m))
    elif case == 'extra':
        (copied / 'extra').write_text('unexpected')
    elif case == 'symlink':
        path = copied / 'reports/diff.csv'
        saved = copied.parent / 'saved.csv'
        shutil.move(path, saved)
        path.symlink_to(saved)
    elif case in {'sample','source','time','verified','invalid_region'}:
        relative = 'data/frame_map.jsonl' if case in {'sample','verified'} else 'data/corrected_annotations.jsonl'
        path = copied / relative
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        if case == 'sample': rows[0]['sample_id'] = 'wrong'
        elif case == 'source': rows[0]['source'] = 'cam'
        elif case == 'time': rows[0]['time_s'] = 0
        elif case == 'verified': rows[0]['verified'] = False
        else: rows[0]['regions'][0]['box'][2] = -1
        path.write_text('\n'.join(json.dumps(r) for r in rows)+'\n')
        rehash(copied)
    elif case == 'report':
        change_json(copied,'reports/diff.json',lambda d:d['summary'].update(changed_regions=99))
    elif case == 'class':
        change_json(copied,'reports/diff.json',lambda d:d['by_class'][0].update(reclassified_in=99))
    elif case == 'manifest':
        change_json(copied,'manifest.json',lambda m:m['coverage'].update(included_frames=99))
    elif case == 'duplicate_event':
        change_json(copied,'reports/diff.json',lambda d:d['frames'][0]['events'].append(d['frames'][0]['events'][0]))
    elif case == 'unknown':
        change_json(copied,'manifest.json',lambda m:m['baseline'].update(kind='unknown',digest=None))
    else:
        change_json(copied,'manifest.json',lambda m:m.update(batch_operations=[{'schema_version':1,'type':'range_propagate','mode':'overwrite','keyframe':99,'start_frame':12,'end_frame':90,'affected_frames':[90]}]))
    assert validate(copied), case

def test_frame_status_rejects_numeric_boolean(copied):
    path = copied / 'data/frame_map.jsonl'
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    rows[0]['verified'] = 1
    path.write_text('\n'.join(json.dumps(r) for r in rows)+'\n')
    rehash(copied)
    assert validate(copied)

def test_nonfinite_source_timestamp(copied):
    change_json(copied,'manifest.json', lambda m: m['source_frame_entries'][0].update(time_s=float('inf')))
    assert validate(copied)

def test_nonfinite_schema_rejected(copied):
    from annotation_data.training_package import _schema_errors
    manifest = json.loads((copied / 'manifest.json').read_text())
    manifest['source_frame_entries'][0]['time_s'] = float('inf')
    assert _schema_errors(manifest,'training-package-v2.schema.json')

def test_godot_exponent_and_full_precision_packages():
    for path in json.loads(Path('/tmp/part4-package-number-paths.json').read_text()):
        assert validate(path) == []

def metric_operation():
    return {'schema_version':1,'type':'range_propagate','mode':'overwrite','keyframe':12,
            'start_frame':12,'end_frame':90,'affected_frames':[90],'metric_id':'normalized_mad',
            'threshold':0.8,'max_frames':2,'keyframe_digest':'a'*64,'created_at':'2026-09-08T01:02:03Z',
            'start_index':0,'end_index':1,'left_stop':'start','right_stop':'end','changed_count':1,'covered_count':2}

def poly_operation():
    return {'schema_version':2,'type':'range_propagate','mode':'merge','keyframe':12,
            'start_frame':12,'end_frame':90,'affected_frames':[90],
            'metric_id':'poly-sim-flow-edge-v1','threshold':0.6,'max_frames':30,
            'frame_step':78,'keyframe_digest':'a'*64,'created_at':'2026-09-10T17:45:15',
            'start_index':0,'end_index':1,'left_stop':'source boundary','right_stop':'source boundary',
            'changed_count':1,'covered_count':2,'edge_refinement':{
                'attempted':1,'accepted':0,'fallback':1,'items':[{
                    'frame_id':90,'region_id':'r1','accepted':False,'reason':'Hausdorff above 6',
                    'raw_edge_score':0.04,'refined_edge_score':0.09}]}}

def test_poly_v2_batch_operation_is_package_compatible(copied):
    change_json(copied,'manifest.json',lambda m:m.update(batch_operations=[poly_operation()]))
    assert validate(copied) == []

@pytest.mark.parametrize('case', ['wrong_step','keyframe_item','legacy_claim','missing_audit'])
def test_poly_v2_batch_operation_semantics(copied, case):
    op = poly_operation()
    if case == 'wrong_step': op['frame_step'] = 77
    elif case == 'keyframe_item': op['edge_refinement']['items'][0]['frame_id'] = 12
    elif case == 'legacy_claim': op['schema_version'] = 1
    else: op.pop('edge_refinement')
    change_json(copied,'manifest.json',lambda m:m.update(batch_operations=[op]))
    assert validate(copied), case

@pytest.mark.parametrize('case', ['changed_count','covered_count','max_frames','range','indices'])
def test_metric_batch_semantics(copied, case):
    op = metric_operation()
    change_json(copied,'manifest.json',lambda m:m.update(batch_operations=[op]))
    assert validate(copied) == []
    if case == 'changed_count': op['changed_count'] = 99
    elif case == 'covered_count': op['covered_count'] = 1
    elif case == 'max_frames': op['max_frames'] = 1
    elif case == 'range': op['start_frame'] = 90
    else: op['start_index'] = 2
    change_json(copied,'manifest.json',lambda m:m.update(batch_operations=[op]))
    assert validate(copied), case

def test_empty_baseline_cannot_have_before_annotations(copied):
    change_json(copied,'manifest.json',lambda m:m['baseline'].update(kind='empty',digest=None))
    assert validate(copied)

@pytest.mark.parametrize('relative',['foreign','data/foreign','reports/foreign'])
def test_foreign_empty_directory_rejected(copied, relative):
    (copied / relative).mkdir()
    assert validate(copied)

def test_valid_empty_baseline_and_omitted_addition(tmp_path):
    original = Path('/tmp/part4-package-empty-path.txt').read_text()
    assert validate(original) == []
    root = tmp_path / 'empty-package'
    shutil.copytree(original,root)
    path = root / 'reports/diff.json'
    diff = json.loads(path.read_text())
    assert diff['summary']['added'] > 0
    for row in diff['frames']:
        row['events'] = []
        row['changed_regions'] = 0
        row['counts'] = dict.fromkeys(row['counts'],0)
    diff['by_class'] = []
    for key in ('added','changed_frames','changed_regions'):
        diff['summary'][key] = 0
    path.write_text(json.dumps(diff))
    (root / 'reports/diff.csv').write_text('frame_id,region_id,type,before,after\n')
    (root / 'reports/summary_by_class.csv').write_text('class,added,deleted,reclassified_in,reclassified_out,geometry_changed,attributes_changed\n')
    change_json(root,'manifest.json',lambda m:m['summary'].update(added=0,changed_frames=0,changed_regions=0))
    assert validate(root)

@pytest.mark.parametrize('field,value', [('threshold',0),('created_at','bad'),('keyframe_digest','bad'),('left_stop',' '),('max_frames',0)])
def test_metric_metadata_rejected(copied,field,value):
    op = metric_operation()
    op[field] = value
    change_json(copied,'manifest.json',lambda m:m.update(batch_operations=[op]))
    assert validate(copied)

def test_optional_corrected_timestamp_absence_preserved(copied):
    from annotation_data.training_package import canonical_digest
    path = copied / 'data/corrected_annotations.jsonl'
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    record = rows[1]
    assert 'time_s' in record
    record.pop('time_s')
    path.write_text('\n'.join(json.dumps(r) for r in rows)+'\n')
    internal = dict(record,source='cam')
    change_json(copied,'manifest.json',lambda m:m['review_state'][str(int(record['frame']))].update(accepted_digest=canonical_digest(internal)))
    assert validate(copied) == []
