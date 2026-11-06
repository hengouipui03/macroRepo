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
        assert 8<=distance[iy,ix]*800/w<=18, 'a spot is not beside the road'
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
world.area[145:154,220:226]=1
reply=world.placement_line(48)
assert reply and reply['count']>=1, 'short local edge was rejected before the slot-click loop'
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

# Alternate candidates cross this same visible road and remain path-side/local.
world.area=np.zeros((300,400),np.uint8)
world.area[:,180:220]=1
reply=world.placement_line(48)
line=points(reply)
normals=np.array([tuple(map(float,n.split(','))) for n in reply['normals'].split(';')])
assert len(normals)==len(line)
assert np.allclose(np.linalg.norm(normals,axis=1),1,atol=.001)
alternates=reply['opposites'].split(';')
assert len(alternates)==len(line) and any(a!='-' for a in alternates)
for original,other in zip(line,alternates):
    if other=='-':continue
    x,y=map(int,other.split(','))
    assert (original[0]<360 and x>438) or (original[0]>438 and x<360), 'alternate did not cross the road'
    assert abs(y-original[1])<=2, 'alternate moved away along an unrelated path'
    assert world.validate_placements(f'{x},{y}')['match']==1
# Hill alternatives must also be in the current green terrain mask.
chosen=[(228,155)]
mask=np.zeros_like(world.area);mask[:,170:180]=1
reply=world.placement_geometry(chosen,mask)
assert reply['opposites']!='-', 'valid opposite green hill was rejected'
x,y=map(int,reply['opposites'].split(','))
assert mask[y//2,x//2]
mask[:]=0
assert world.placement_geometry(chosen,mask)['opposites']=='-', 'non-green hill alternate was accepted'
# No opposite terrain is invented when the other edge is beyond local range.
world.area[:]=0;world.area[:,50:230]=1
assert world.placement_geometry([(239,155)])['opposites']=='-'
print('PASS: verified opposite road edge, aligned normals, local path-side validation, green-only Hill alternates, no distant fallback.')

world.area=np.zeros((300,400),np.uint8)
world.area[:,180:220]=1
original=world.placement_line(48)
old=points(original)
rejected=';'.join(f'{int(x)},{int(y)}' for x,y in old)
rescan=world.placement_line(48,rejected)
assert rescan, 'Rejected edge hid all other local road edges'
for x,y in points(rescan):
    assert np.min(np.linalg.norm(old-np.array([x,y]),axis=1))>6, 'rescan reused a rejected coordinate'
# Dense masks on one side must leave the opposite side available.
blocked=';'.join(f'342,{y}' for y in range(145,476,8))
rescan=world.placement_line(48,blocked)
assert rescan and np.all(points(rescan)[:,0]>438), 'rescan did not move to the unblocked opposite road edge'
# Completed-unit positions are excluded at their full spacing.
rescan=world.placement_line(48,'-', '342,300;342,324;342,348')
assert rescan
for p in points(rescan):
    assert np.all(np.linalg.norm(np.array([[342,300],[342,324],[342,348]])-p,axis=1)>=24), 'occupied position returned by rescan'
assert np.array_equal(points(world.placement_line(48)),old), 'rejected coordinates leaked into a later unfiltered game'
print('PASS: rescan excludes rejected/occupied spots, chooses other nearby road edges, and retains no rejection data between requests.')

world.area=np.zeros((300,400),np.uint8);world.area[:,180:220]=1
rescan=world.placement_line(48,'-','-', '348,310,-1,0')
assert rescan and np.all(points(rescan)[:,0]>438), 'blocked left edge was selected again instead of the opposite side'
assert world.validate_placements('458,300')['match']==0, 'a cached point beyond the tight edge gap was accepted'
print('PASS: normal candidates stay within 18 reference pixels of the road; blocked edge sections move the search to the opposite side.')

# Second row: one unit spacing outward from a confirmed first-row placement.
world.area=np.zeros((300,400),np.uint8);world.area[:,180:220]=1
reply=world.placement_neighbours('348,310','-','348,310')
assert reply['count']==1 and np.allclose(points(reply)[0],[320,310]), ('exactly one partner spot, straight behind',reply)
for x,y in points(reply):
    assert 22<=cv2.distanceTransform((1-world.area).astype(np.uint8),cv2.DIST_L2,5)[int(y/2),int(x/2)]*2<=48
    assert np.linalg.norm(np.array([x,y])-[348,310])>=24
assert world.placement_neighbours('320,310')['count']==0, 'second-row unit created a third row'
assert world.placement_neighbours('50,310')['count']==0, 'unrelated far unit became a placement origin'
# The single partner spot is never swapped for a diagonal one.
assert world.placement_neighbours('348,310','320,310','348,310')['count']==0, 'failed partner spot replaced by another spot'
assert world.placement_neighbours('348,310','-','348,310;320,310')['count']==0, 'filled partner spot gave a second partner'
line=world.placement_line(48,'348,310')
assert all(np.linalg.norm(p-[348,310])>14 for p in points(line)), 'failed patch reused by edge search'
assert world.validate_placements('348,310;320,310')['match']==1, 'anchored second-row cache rejected'
assert world.validate_placements('320,310')['match']==0, 'unanchored off-edge cache accepted'
assert world.validate_placements('348,310;320,310;292,310')['match']==0, 'third-row cache accepted'
world.area[:]=0
assert world.placement_neighbours('348,310')['count']==0, 'neighbours invented without visible road'
print('PASS: one partner spot straight behind each confirmed edge unit; rejected areas, third rows, distant origins, overlaps and unanchored saved positions excluded.')
