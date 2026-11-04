"""Hill preference uses newly highlighted terrain and never forces a match."""
from pathlib import Path
import cv2
import numpy as np
import MinimapVision as mv
root=Path(__file__).resolve().parent

def setup(before,after):
    world=mv.World(mv.Vision());world.static=before
    world.world(0,0,before.shape[1],before.shape[0]);world.static=after
    return world

def points(reply):
    return [tuple(map(int,p.split(','))) for p in reply['points'].split(';') if p]

base=np.full((600,800,3),30,np.uint8)
base[:,380:421]=(0,255,210)
after=base.copy();after[240:400,270:350]=(100,250,20)
w=setup(base,after)
r=w.hill_spots(8,0,0,800,600); ps=points(r)
assert len(ps)==8,r
assert 336<=ps[0][0]<=344 and abs(ps[0][1]-300)<8,ps[0]
for x,y in ps:
    assert 270<x<350 and 240<y<400, 'candidate escaped green Hill terrain'
assert all(ps[i][0]>=ps[i+1][0] for i in range(len(ps)-1)), 'hill points were not ranked nearest path first'
# Naturally green terrain and a selection with no green highlighting must fall back.
assert setup(after,after).hill_spots(8,0,0,800,600)['count']==0
assert setup(base,base).hill_spots(8,0,0,800,600)['count']==0
noise=base.copy();noise[:100,:]=(0,255,0);noise[280:288,300:318]=(0,255,0)
cv2.circle(noise,(400,300),150,(255,255,0),4)
assert setup(base,noise).hill_spots(8,0,0,800,600)['count']==0,'HUD/text/cyan range ring mistaken for Hill terrain'
far=base.copy();far[200:400,:100]=(100,250,20)
assert setup(base,far).hill_spots(8,0,0,800,600)['count']==0,'distant Hill surface used'
w=setup(base,after);w.area[:]=0
assert w.hill_spots(8,0,0,800,600)['count']==0,'Hill chosen without a visible path reference'
# Supplied image: preserve the real green shades, annotate the visible road,
# and neutralize the highlight only in the unselected baseline fixture.
im=mv.read_image(str(root/'hill-highlight-fixture.png'))
hsv=cv2.cvtColor(im,cv2.COLOR_BGR2HSV)
green=(hsv[:,:,0]>=45)&(hsv[:,:,0]<=85)&(hsv[:,:,1]>=100)&(hsv[:,:,2]>=170)
before=im.copy();before[green]=(70,70,70)
w=mv.World(mv.Vision());w.image=before;w.static=im
w.area=np.zeros((im.shape[0]//2,im.shape[1]//2),np.uint8)
cv2.line(w.area,(352,60),(392,600),1,17)
r=w.hill_spots(8,0,0,im.shape[1],im.shape[0]);ps=points(r)
assert ps,r
for x,y in ps:
    assert green[y,x], 'provided-image candidate is not inside the green highlight'
print('PASS: green terrain nearest path first; preview-only detection; no-green/natural-green/HUD/range/distant/no-path fallback; supplied highlight shades.')
