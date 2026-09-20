"""Android 模拟器本地验收：读取语义节点后点击，并保存原始设备截图。"""
import argparse
import pathlib
import re
import subprocess
import time
import xml.etree.ElementTree as ET
ADB = '/Users/chunyi/Library/Android/sdk/platform-tools/adb'
def adb(*args):
    return subprocess.check_output([ADB, *args])
def nodes():
    adb('shell','uiautomator','dump','/sdcard/wo-window.xml')
    return ET.fromstring(adb('shell','cat','/sdcard/wo-window.xml')).iter('node')
p=argparse.ArgumentParser()
p.add_argument('--tap')
p.add_argument('--shot')
p.add_argument('--back',action='store_true')
p.add_argument('--swipe',action='store_true')
a=p.parse_args()
if a.tap:
    matched=[n for n in nodes() if a.tap == n.get('text') or a.tap in n.get('content-desc','')]
    if not matched:
        raise SystemExit('未找到: '+a.tap)
    n=matched[-1]
    x1,y1,x2,y2=map(int,re.findall(r'\d+',n.get('bounds')))
    adb('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2))
    time.sleep(.8)
if a.back:
    adb('shell','input','keyevent','4');time.sleep(.6)
if a.swipe:
    adb('shell','input','swipe','500','1700','500','750','500');time.sleep(.6)
if a.shot:
    path=pathlib.Path('build/cinema-qa')/a.shot
    path.write_bytes(adb('exec-out','screencap','-p'))
    print(path)
else:
    for n in nodes():
        if n.get('text') or n.get('content-desc'):
            print(n.get('text') or n.get('content-desc'), n.get('bounds'))
