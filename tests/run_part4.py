"""Run the local Part 4 behavioral gates; retain every process log."""
from pathlib import Path
import json,os,shutil,subprocess,time

ROOT=Path(__file__).resolve().parents[1]
DESTINATION=ROOT/'output'/f'part4-gate-{time.time_ns()}'
NAMES='''store_load_regression store_regression codec_malformed_source optional_timestamps
background_job atomic_document repository autosave save_failures save_deadline save_wait_races
diff_edges package package_numbers package_review_fixes parent_semantics export_text_bytes
exact_json_depth exact_json_integration exact_json_hashes exact_reader_legacy
ui_session export_ui export_cancel lifecycle rounds round_ui'''.split()
DESTINATION.mkdir(parents=True)

# The exact-number integration gate consumes a deliberately simple 30 fps
# source. Build it inside this unique run directory so the gate never depends
# on stale, process-global /tmp state from an earlier audit.
exact_source=DESTINATION/'exact-json-source'
shutil.copytree(ROOT/'sample'/'assignment_v1',exact_source)
manifest=json.loads((exact_source/'manifest.json').read_text(encoding='utf-8'))
manifest['source_name']='numeric30'
records=[]
for frame in range(120):
    timestamp=frame/30.0
    manifest['frames'][frame]['time_s']=timestamp
    records.append({'schema_version':1,'source':'numeric30','frame':frame,'time_s':timestamp,
        'regions':[{'id':f'r{frame}','class':'region','kind':'region','box':[7/30.0,1,2,3]}]})
(exact_source/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(exact_source/'model_output_v1.jsonl').write_text(
    ''.join(json.dumps(record,ensure_ascii=False,separators=(',',':'))+'\n' for record in records),encoding='utf-8')
results=[]
for name in NAMES:
    log=DESTINATION/(name+'.log')
    started=time.monotonic()
    with log.open('w') as stream:
        command=[os.environ['GODOT_BIN'],'--headless','--log-file',str(DESTINATION/(name+'.godot.log')),
            '--path',str(ROOT),'--script',f'tests/godot/test_part4_{name}.gd']
        if name=='exact_json_integration': command.extend(['--','--source',str(exact_source)])
        try:
            completed=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=120)
            exit_code=completed.returncode
        except subprocess.TimeoutExpired:
            stream.write('\nTIMEOUT after 120 seconds\n')
            exit_code=124
    text=log.read_text()
    passed=exit_code==0 and not any(marker in text for marker in ['SCRIPT ERROR:','Stack underflow','Stack overflow'])
    results.append({'test':name,'passed':passed,'exit_code':exit_code,'elapsed_s':round(time.monotonic()-started,3),'log':str(log)})
    print(name+': '+('PASS' if passed else 'FAIL'),flush=True)
report={'passed':all(row['passed'] for row in results),'total':len(results),'results':results}
(DESTINATION/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('EVIDENCE '+str(DESTINATION/'results.json'))
raise SystemExit(0 if report['passed'] else 1)
