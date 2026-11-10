#!/usr/bin/env python3
import json, sys, time, threading, os
from pathlib import Path
try:
    delay=float(Path(sys.argv[1]).read_text().strip() or 0)
except (ValueError, OSError, IndexError):
    delay=0
if delay: time.sleep(delay)
print('{"ready":true}',flush=True)
current=None
cancelled=threading.Event()
task=None
def run(r, event):
    if r.get('crash'): os._exit(3)
    if r.get('slow'): event.wait(2)
    result={'id':r['id']}
    if event.is_set(): result['error']='Dictation cancelled.'
    else: result['text']=str(os.getpid()) if r.get('pid') else r.get('text','')
    print(json.dumps(result),flush=True)
for line in sys.stdin:
    r=json.loads(line)
    if 'cancel' in r:
        if r['cancel']==current: cancelled.set()
        continue
    if task: task.join()
    cancelled=threading.Event(); current=r['id']
    task=threading.Thread(target=run,args=(r,cancelled)); task.start()
cancelled.set()
if task: task.join()
