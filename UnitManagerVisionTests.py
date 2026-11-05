"""Manager geometry on the supplied screenshot and at another client size."""
from pathlib import Path
import cv2
import numpy as np
import MinimapVision as mv

root=Path(__file__).resolve().parent
reference=mv.read_image(str(root/'unit-manager-fixture.png'))
world=mv.World(mv.Vision())
for image in [reference,reference[31:,:],cv2.resize(reference,(1040,726))]:
    world.static=image
    state=world.unit_manager(0,0,image.shape[1],image.shape[0])
    assert state['open']==1,state
    entries=[tuple(map(float,e.split(',')[:4])) for e in state['entries'].split(';')]
    assert len(entries)==8,entries  # bottom row has a fully visible portrait click patch
    assert [int(e[0]) for e in entries]==[0,1,0,1,0,1,0,1],entries
    assert all(entries[i][1]<entries[i+1][1] for i in [0,2,4,6]),entries
    assert all(float(state['top'])<e[2]<float(state['bottom']) for e in entries)
    assert all(e[1]<image.shape[1]*.9 for e in entries),'upgrade button substituted for portrait'
for name in ['path-world-screenshot.png','path-world-sandstorm.png']:
    image=mv.read_image(str(root/name));world.static=image
    assert world.unit_manager(0,0,image.shape[1],image.shape[0])['open']==0,name
single=reference.copy()
single[155:,1140:]=20
single[320:,900:1140]=20
world.static=single
state=world.unit_manager(0,0,single.shape[1],single.shape[0])
assert state['open']==1 and len(state['entries'].split(';'))==1 and state['entries'].startswith('0,'),state
disabled=reference.copy()
disabled[180:711,1030:1135]=30
disabled[180:711,1255:1360]=30
world.static=disabled
state=world.unit_manager(0,0,disabled.shape[1],disabled.shape[0])
assert state['open']==1 and len(state['entries'].split(';'))==8,'disabled/MAX upgrade controls hid unit rows'
world.static=np.zeros_like(reference)
assert world.unit_manager(0,0,reference.shape[1],reference.shape[0])['open']==0

def tiles(image):
    world.static=image
    state=world.unit_manager(0,0,image.shape[1],image.shape[0])
    return state,[e.split(',') for e in state['entries'].split(';')]
state,cells=tiles(reference)
assert state['lastcount']==2,state  # 8 units: #1 bottom-right, #2 bottom-left
assert [c[4:7] for c in cells[:6]]==[['7','7','0']]+[['8','8','0']]*5,cells
assert [c[4] for c in cells[6:]]==['-1','-1'],'clipped bottom-row bars must stay unread'
for c in cells[:6]:
    ux,uy=float(c[7]),float(c[8])
    patch=reference[int(uy)-14:int(uy)+15,int(ux)-30:int(ux)+31].reshape(-1,3).astype(int)
    assert ((patch[:,1]>60)&(patch[:,1]-patch[:,2]>30)).mean()>.4,('Upg click is not on the green button',c)
def cluster(a,b):
    return sum(abs(int(x)-int(y)) for x,y in zip(a.split('.'),b.split('.')))
sig=[c[9] for c in cells[:6]]
assert max(cluster(sig[1],sig[2]),cluster(sig[4],sig[5]))*3<min(cluster(sig[1],sig[4]),cluster(sig[0],sig[4])),sig
segments=[(1167,1189),(1191,1212),(1214,1236),(1238,1260),(1262,1284),(1286,1307),(1309,1331),(1333,1355)]
def empty(image,runs):
    for a,b in runs:
        image[285:294,a:b]=(20,20,20)
        image[285:287,a:b]=image[292:294,a:b]=(230,230,230)
        image[285:294,a:a+2]=image[285:294,b-2:b]=(230,230,230)
partial=reference.copy();empty(partial,segments[5:])
for image in [partial,cv2.resize(partial,(1600,1117))]:
    assert tiles(image)[1][1][4:7]==['5','8','0'],'white-outline segments counted as upgrades'
none=reference.copy();empty(none,segments)
assert tiles(none)[1][1][4:7]==['0','8','0']
bright=reference.copy()
for i,(a,b) in enumerate(segments[:5]):
    bright[285:294,a:b]=(40,220,60) if i%2 else (40,210,250)
empty(bright,segments[5:])
assert tiles(bright)[1][1][4:7]==['5','8','0'],'green and yellow segments must count the same'
grey=reference.copy();grey[198:228,1040:1118]=(90,90,90);grey[208:216,1065:1095]=(200,200,200)
assert tiles(grey)[1][0][6]=='1','grey Max button not recognised'
odd=reference.copy();odd[600:711,1140:]=20
state,cells=tiles(odd)
assert state['lastcount']==1 and cells[-1][0]=='0',('odd unit count: #1 must be the lone bottom-LEFT tile',state)
print('PASS: tile segments (lit green/yellow vs white outline), grey Max, Upg click point, portrait colours, odd-count bottom row.')
print('PASS: bottom-row portrait click patches remain clear; physical left/right columns; reference/client-crop/resize; disabled buttons and closed-manager rejection.')
