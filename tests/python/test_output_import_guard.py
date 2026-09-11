import json
import os
from pathlib import Path
import subprocess

import pytest

REPO = Path(__file__).resolve().parents[2]

@pytest.mark.parametrize('case', ['default','nested_default','existing_marker','marker_directory','marker_symlink','output_symlink','asset_path','output_prefix','ignored_asset','asset_marker_symlink','external'])
def test_output_import_guard(tmp_path,case):
    project = tmp_path / 'project'
    project.mkdir()
    (project / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="Package guard test"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    for name in ('client','core','tests'):
        (project / name).symlink_to(REPO / name,target_is_directory=True)
    output = project / 'output'
    parent = output
    expected = True
    sentinel_bytes = b''
    if case == 'nested_default': parent = output / 'nested' / 'exports'
    elif case == 'existing_marker':
        output.mkdir()
        sentinel_bytes = b'user-owned marker retained\n'
        (output / '.gdignore').write_bytes(sentinel_bytes)
    elif case == 'marker_directory':
        (output / '.gdignore').mkdir(parents=True)
        expected = False
    elif case == 'marker_symlink':
        output.mkdir()
        target = tmp_path / 'marker-target'
        target.write_bytes(b'keep target')
        (output / '.gdignore').symlink_to(target)
        expected = False
    elif case == 'output_symlink':
        target = tmp_path / 'linked-output'
        target.mkdir()
        output.symlink_to(target,target_is_directory=True)
        expected = False
    elif case in ('asset_path','output_prefix','ignored_asset','asset_marker_symlink'):
        ancestor = project / ('output_other' if case == 'output_prefix' else 'assets')
        ancestor.mkdir()
        parent = ancestor / 'new_exports'
        if case == 'ignored_asset': (ancestor / '.gdignore').write_bytes(b'preexisting')
        elif case == 'asset_marker_symlink':
            target = tmp_path / 'asset-marker-target'
            target.write_bytes(b'keep asset target')
            (ancestor / '.gdignore').symlink_to(target)
        expected = case == 'ignored_asset'
    elif case == 'external': parent = tmp_path / 'external-output'
    result_path = tmp_path / 'result.json'
    run = subprocess.run([os.environ['GODOT_BIN'],'--headless','--log-file',str(tmp_path/'godot.log'),'--path',str(project),'--script','tests/godot/test_part4_output_import_guard.gd','--',str(parent),str(result_path)],text=True,capture_output=True,timeout=30,env=dict(os.environ,XDG_DATA_HOME=str(tmp_path/"userdata")))
    assert run.returncode == 0, run.stdout + run.stderr
    result = json.loads(result_path.read_text())
    assert result['success'] == expected, result
    if expected:
        package = Path(result['output_path'])
        files = {p.relative_to(package).as_posix() for p in package.rglob('*') if p.is_file()}
        assert files == {'manifest.json','data/corrected_annotations.jsonl','data/frame_map.jsonl','reports/diff.json','reports/diff.csv','reports/summary_by_class.csv'}
        assert result['source_png_readable']
        if case in ('default','nested_default','existing_marker'):
            assert (output / '.gdignore').read_bytes() == sentinel_bytes
        else:
            assert not (project / '.gdignore').exists()
            assert not (parent / '.gdignore').exists()
    else:
        assert result['errors']
        assert not result['output_path']
        if case in ('asset_path','output_prefix','asset_marker_symlink'):
            assert not parent.exists()
            assert not (project / '.gdignore').exists()
        if case in ('marker_symlink','asset_marker_symlink'):
            assert target.read_bytes().startswith(b'keep')
        if case == 'marker_directory': assert (output / '.gdignore').is_dir()

def test_round_archival_in_project_source(tmp_path):
    project = tmp_path / 'project'
    project.mkdir()
    (project / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="Round archive test"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    for name in ('client','core','tests'):
        (project / name).symlink_to(REPO / name,target_is_directory=True)
    run = subprocess.run([os.environ['GODOT_BIN'],'--headless','--log-file',str(tmp_path/'round.log'),'--path',str(project),'--script','tests/godot/test_part4_project_round_archive.gd','--',str(tmp_path/'external')],text=True,capture_output=True,timeout=30,env=dict(os.environ,XDG_DATA_HOME=str(tmp_path/"userdata")))
    assert run.returncode == 0, run.stdout + run.stderr
    assert 'PASS: in-project JSON round archive' in run.stdout
    assert not list((project/'Dataset_test').rglob('.gdignore'))
