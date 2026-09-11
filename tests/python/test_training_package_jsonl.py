"""Actual Godot package regressions for LF-only JSONL record boundaries."""
import hashlib
import json
from pathlib import Path
import shutil

import pytest
from annotation_data.training_package import package_identity, validate_training_package


@pytest.fixture(params=[(codepoint, field) for codepoint in (133,8232,8233) for field in ('class','image_path','both')])
def unicode_case(request):
    cases = json.loads(Path('/tmp/part4-unicode-jsonl-cases.json').read_text())
    return next(case for case in cases if (case['codepoint'],case['field']) == request.param)


def test_real_godot_unicode_export(unicode_case):
    root = Path(unicode_case['path'])
    character = chr(unicode_case['codepoint']).encode()
    if unicode_case['field'] != 'image_path':
        assert character in (root / 'data/corrected_annotations.jsonl').read_bytes()
    if unicode_case['field'] != 'class':
        assert character in (root / 'data/frame_map.jsonl').read_bytes()
    assert validate_training_package(root) == []


def rewrite_artifact(root, relative, data):
    (root / relative).write_bytes(data)
    manifest_path = root / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    for artifact in manifest['artifacts']:
        raw = (root / artifact['path']).read_bytes()
        artifact.update(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
    manifest['package_id'] = package_identity(manifest)
    manifest_path.write_text(json.dumps(manifest,ensure_ascii=False))


@pytest.mark.parametrize('relative',['data/corrected_annotations.jsonl','data/frame_map.jsonl'])
@pytest.mark.parametrize('ending',['lf','lf_no_terminal','crlf','crlf_no_terminal'])
def test_line_endings_preserve_unicode(tmp_path, relative, ending):
    case = next(c for c in json.loads(Path('/tmp/part4-unicode-jsonl-cases.json').read_text()) if c['field'] == 'both')
    root = tmp_path / 'package'
    shutil.copytree(case['path'],root)
    raw = (root / relative).read_bytes()
    if ending.startswith('crlf'): raw = raw.replace(b'\n',b'\r\n')
    if ending.endswith('no_terminal'): raw = raw.removesuffix(b'\r\n' if ending.startswith('crlf') else b'\n')
    rewrite_artifact(root,relative,raw)
    assert validate_training_package(root) == []


@pytest.mark.parametrize('relative',['data/corrected_annotations.jsonl','data/frame_map.jsonl'])
@pytest.mark.parametrize('case',['empty','single_blank','leading_blank','interior_blank','extra_terminal','bare_cr','malformed','raw_lf_in_string'])
def test_empty_and_malformed_rows_rejected(tmp_path,relative,case):
    original = json.loads(Path('/tmp/part4-unicode-jsonl-cases.json').read_text())[0]['path']
    root = tmp_path / 'package'
    shutil.copytree(original,root)
    raw = (root / relative).read_bytes()
    if case == 'empty': raw = b''
    elif case == 'single_blank': raw = b'\n'
    elif case == 'leading_blank': raw = b'\n' + raw
    elif case == 'interior_blank': raw = raw.replace(b'\n',b'\n\n',1)
    elif case == 'extra_terminal': raw += b'\n'
    elif case == 'bare_cr': raw = raw.replace(b'\n',b'\r')
    elif case == 'malformed': raw = b'{broken}\n'
    else: raw = raw.replace(b'"frame"',b'"fr\name"',1)
    rewrite_artifact(root,relative,raw)
    assert validate_training_package(root)
