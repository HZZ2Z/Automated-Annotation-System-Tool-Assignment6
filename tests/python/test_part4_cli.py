import json
import os
from pathlib import Path
import subprocess
import sys
import shutil

ROOT=Path(__file__).resolve().parents[2]
CLI=ROOT/'python/part4.py'

def run(*args):
    result=subprocess.run([sys.executable,str(CLI),*map(str,args)],cwd=ROOT,capture_output=True,text=True,timeout=90)
    assert result.stdout.strip(), result.stderr
    return result,json.loads(result.stdout)

def test_part4_cli_demo_real_round_trip(tmp_path):
    result,evidence=run('demo','--output',tmp_path/'demo')
    assert result.returncode==0, (result.stderr,evidence)
    assert evidence['success']
    assert evidence['training_simulated']
    assert evidence['summary']['changed_regions']==7
    assert evidence['summary']['changed_frames']==6
    assert evidence['summary']['geometry_changed']==2
    assert evidence['summary']['attributes_changed']==2
    assert evidence['training_coverage']==6 and evidence['training_excluded']==114
    assert evidence['review_coverage']==120
    assert evidence['reopen_stable'] and evidence['new_round_reset']
    assert Path(evidence['archive_path']).is_file()
    for key in ['training_package','review_package']:
        validation,payload=run('validate-package',evidence[key])
        assert validation.returncode==0, payload
    exported,payload=run('export','--session',evidence['archive_path'],'--output',tmp_path/'export')
    assert exported.returncode==0,payload
    assert payload['package_id']==evidence['training_package_id']
    copied=tmp_path/'active-copy.json'
    shutil.copyfile(evidence['archive_path'],copied)
    imported,payload=run('import-round','--session',copied,'--input',evidence['round_manifest'],'--parent-package',evidence['training_package'])
    assert imported.returncode==0,payload
    assert json.loads(copied.read_text())['round_id']=='round2'
    rejected,payload=run('import-round','--session',evidence['active_session'],'--input',evidence['round_manifest'],'--parent-package',evidence['training_package'])
    assert rejected.returncode!=0 and not payload['success']

def test_part4_cli_validation_failure_json(tmp_path):
    result,payload=run('validate-package',tmp_path)
    assert result.returncode==1 and not payload['success'] and payload['errors']
