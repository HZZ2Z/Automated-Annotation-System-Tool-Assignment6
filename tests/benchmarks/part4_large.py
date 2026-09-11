"""Run the large UI-queue measurement with an RSS guard, not a virtual-memory cap."""
import json,os,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parents[2]
log=root/'output'/f'part4-large-{time.time_ns()}.log'
log.parent.mkdir(exist_ok=True)
peak=0;guard=None;started=time.monotonic()
with log.open('wb') as stream:
    p=subprocess.Popen([os.environ['GODOT_BIN'],'--headless','--log-file',str(log.with_suffix('.godot.log')),'--path',str(root),'--script','tests/godot/benchmark_part4_io.gd','--','10000','1'],stdout=stream,stderr=subprocess.STDOUT)
    try:
        while p.poll() is None:
            try:
                fields=dict(line.split(':',1) for line in Path(f'/proc/{p.pid}/status').read_text().splitlines() if ':' in line)
                rss=int(fields.get('VmRSS','0 kB').split()[0]);peak=max(peak,rss)
                available=next(int(line.split()[1]) for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemAvailable:'))
                if rss>5*1024*1024 or available<1024*1024:
                    guard={'rss_kib':rss,'available_kib':available};p.terminate();break
            except FileNotFoundError:break
            time.sleep(.25)
        p.wait(timeout=10)
    finally:
        if p.poll() is None:p.kill();p.wait(timeout=10)
result={'returncode':p.returncode,'peak_rss_mib':round(peak/1024,2),'elapsed_s':round(time.monotonic()-started,2),'memory_guard':guard,'log':str(log)}
log.with_suffix('.monitor.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
raise SystemExit(p.returncode or 0)
