"""在运行的 cinema_preview Dart VM 上逐页渲染，保存 Android 原始截图。"""
import argparse
import json
from pathlib import Path
import subprocess
import time
import urllib.parse
import urllib.request
p=argparse.ArgumentParser()
p.add_argument('vm_url')
p.add_argument('--only', nargs='+')
a=p.parse_args()
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def rpc(method, **params):
    with opener.open(a.vm_url.rstrip('/')+'/'+method+'?'+urllib.parse.urlencode(params),timeout=20) as r:
        data=json.load(r)
    if 'error' in data: raise RuntimeError(data['error'])
    return data['result']
vm=rpc('getVM')
isolate=next(x['id'] for x in vm['isolates'] if x['name']=='main')
shots=[('home',{'route':'/home'}),('messages',{'route':'/messages'}),('profile',{'route':'/me'}),('marketplace',{'route':'/home/marketplace'}),('family',{'route':'/home/family'}),('appearance',{'route':'/me/settings/appearance'})]
shots += [(name,{'plugin':name}) for name in ['accounting','anniversary','chore','stock','recipe','memory','movie','calendar','subscription','plant','retirement','expiry','travel','pet','chat']]
for name,params in shots:
    if a.only and name not in a.only: continue
    rpc('ext.wo.preview',isolateId=isolate,**params)
    time.sleep(2.5)
    target=Path('build/cinema-qa')/('screen-'+name+'.png')
    target.write_bytes(subprocess.check_output(['/Users/chunyi/Library/Android/sdk/platform-tools/adb','exec-out','screencap','-p']))
    print(name,flush=True)
