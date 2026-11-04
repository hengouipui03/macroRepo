"""Ordered local path-side placement; no screen capture or game input."""
from pathlib import Path
import subprocess
import sys
import cv2
import numpy as np
import MinimapVision as mv

ROOT = Path(__file__).resolve().parent

def points(reply):
    return np.asarray([tuple(map(int, item.split(','))) for item in reply['points'].split(';')],float)

def check_line(world, reply):
    assert reply and reply['count']>=6, reply
    line=points(reply)
    h,w=world.area.shape
    scale=np.array([800/(w*2),600/(h*2)])
    ref=line*scale
    player=np.array(world.centre())*2*scale
    d=ref-player
    assert np.all((d[:,0]/230)**2+(d[:,1]/185)**2<=1.02), 'a spot is far from the player'
    assert np.all(np.linalg.norm(d,axis=1)>=27), 'a spot overlaps the player'
    assert np.all(np.linalg.norm(np.diff(ref,axis=0),axis=1)<=14), 'adjacent attempts jump apart'
    distance=cv2.distanceTransform((1-world.area).astype(np.uint8),cv2.DIST_L2,5)
    for x,y in line:
        ix,iy=int(x/2),int(y/2)
        assert not world.area[iy,ix], 'a spot is on the road'
        assert 9<=distance[iy,ix]*800/w<=29, 'a spot is not beside the road'
    return ref

world=mv.World(mv.Vision())
world.static=mv.read_image(str(ROOT/'path-world-screenshot.png'))
h,w=world.static.shape[:2]
world.world(0,0,w,h)
reply=world.placement_line(48)
ref=check_line(world,reply)
assert np.linalg.norm(ref[0]-np.array([400,300]))<45, 'line does not begin at the player'
image=world.static.copy()
line=points(reply).astype(int)
cv2.polylines(image,[line.reshape(-1,1,2)],False,(0,210,255),2)
for i,(x,y) in enumerate(line):
    cv2.circle(image,(x,y),5,(0,210,255),-1)
    cv2.putText(image,str(i+1),(x+4,y-6),cv2.FONT_HERSHEY_SIMPLEX,0.35,(255,255,255),1)
cv2.circle(image,(w//2,h//2),12,(255,120,20),2)
cv2.imwrite(str(ROOT/'cache'/'ordered-placement-preview.png'),image)

world.area=np.zeros((300,400),np.uint8)
world.area[:,180:220]=1
ref=check_line(world,world.placement_line(48))
assert np.ptp(ref[:,0])<=2, 'vertical-road spots switch sides'
assert np.all(np.diff(ref[:,1])>0), 'vertical-road attempts do not progress down the road'
# A separate illuminated section cannot join the queue.
world.area[:,30:45]=1
other=points(world.placement_line(48))
assert np.all(other[:,0]>300), 'line jumped to a different path component'

world.area=np.zeros((300,400),np.uint8)
world.area[60:165,180:220]=1
world.area[125:165,180:335]=1
check_line(world,world.placement_line(48))
# A short nearest fragment must not hide a usable adjacent road.
world.area=np.zeros((300,400),np.uint8)
world.area[145:154,197:203]=1
world.area[:,222:240]=1
reply=world.placement_line(48)
assert reply and reply['count']>=6, 'short nearest fragment hid the usable road'
check_line(world,reply)
# A locally visible edge more than 90 reference pixels away still permits input.
world.area=np.zeros((300,400),np.uint8)
world.area[:,265:285]=1
reply=world.placement_line(48)
ref=check_line(world,reply)
assert 90<np.linalg.norm(ref[0]-np.array([400,300]))<230
# A single visible spot is attempted instead of failing the whole build gate.
world.area=np.zeros((300,400),np.uint8)
world.area[145:154,197:203]=1
reply=world.placement_line(48)
assert reply and reply['count']==1, 'short local edge was rejected before the slot-click loop'
world.area=np.zeros((300,400),np.uint8)
world.area[:,15:35]=1
assert world.placement_line(48) is None, 'a far road was used as a fallback'
world.area[:]=0
assert world.placement_line(48) is None, 'spots were invented without a visible path'
# Exercise the real request/reply command used by AutoHotkey.
commands=f'loadworld {ROOT / "path-world-screenshot.png"}\nworld 0 0 {w} {h}\nplacementline 48\nquit\n'
result=subprocess.run([sys.executable,'-I',str(ROOT/'MinimapVision.py')],input=commands,text=True,capture_output=True,check=True)
assert 'ok\tcount=' in result.stdout and 'player=' in result.stdout,result.stdout+result.stderr
print('PASS: real image, vertical/bent paths, adjacent ordered steps, one side, player proximity, no distant/disconnected fallback, vision protocol.')

# Saved-layout validation is a local view check, without generating a new line.
world.area=np.zeros((300,400),np.uint8)
world.area[:,180:220]=1
assert world.validate_placements('456,300;456,324;456,348')['match']==1
world.area[:]=0
world.area[:,15:35]=1
assert world.validate_placements('456,300;456,324;456,348')['match']==0
print('PASS: saved layout accepted in matching local view and rejected after the path moves away.')

# A cache match cannot include ground far from the path or inside it.
world.area=np.zeros((300,400),np.uint8)
world.area[:,180:220]=1
assert world.validate_placements('490,300')['match']==0, 'off-path cached point accepted'
assert world.validate_placements('400,300')['match']==0, 'cached point on the road accepted'
assert world.validate_placements('456,300;490,300')['match']==0, 'one bad cached point was hidden by the layout match'
print('PASS: saved placement validation requires every coordinate directly beside the path.')

# The actual failure capture: sandstorm lighting makes the path hue 35 and
# fully saturated, so the old pale-green-only detector rejected the road.
sand=mv.read_image(str(ROOT/'path-world-sandstorm.png'))
world.static=sand
world.world(0,0,sand.shape[1],sand.shape[0])
assert world.onpath(807,505)['on']==1, 'sandstorm yellow-green path rejected'
assert world.onpath(400,500)['on']==0, 'sand ground mistaken for path'
assert world.onpath(700,65)['on']==0, 'green health bar mistaken for path'
reply=world.placement_line(48)
check_line(world,reply)
print('PASS: actual sandstorm failure image yields adjacent path-side spots and excludes ground/HUD.')
