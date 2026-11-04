"""The supplied blue-region failure must never authorize a ground click."""
from pathlib import Path
import cv2
import numpy as np
import MinimapVision as mv

root = Path(__file__).resolve().parent
world = mv.World(mv.Vision())
world.static = mv.read_image(str(root / 'navy-bay-placement-fixture.png'))
h,w = world.static.shape[:2]
assert world.world(0,0,w,h)['path'] > 0
reply = world.placement_line(48)
assert reply and reply['count'] >= 4

# These points are deep in the red-circled blue area, away from the road.
for x,y in [(470,580),(560,620),(650,690),(710,650),(590,740)]:
    rx,ry = x*800/w,y*600/h
    assert world.placement_valid(rx,ry)['valid'] == 0,(x,y)
    assert world.placement_valid(rx,ry,2,'400,300')['valid'] == 0,(x,y)
    assert not world.area[y//2,x//2]

accepted = []
for value in reply['points'].split(';'):
    x,y = map(int,value.split(','))
    rx,ry = round(x*800/w),round(y*600/h)
    if world.placement_valid(rx,ry)['valid']:
        accepted.append((rx,ry))
assert len(accepted)>=4,'no real road-edge spots survived the live check'

# A once-valid cached coordinate must fail after the path moves away.
old = accepted[0]
world.area[:] = 0
world.area[:,10:25] = 1
assert world.placement_valid(*old)['valid'] == 0

# Cyan range circles by themselves must never establish a road band.
scene = np.full((600,800,3),30,np.uint8)
cv2.circle(scene,(400,300),130,(255,230,110),7)
world.static = scene
assert world.world(0,0,800,600)['path'] == 0

# Second rows need a current first-row anchor, never a third row or an old
# coordinate which no longer touches the path.
world.area = np.zeros((300,400),np.uint8)
world.area[:,180:220] = 1
assert world.placement_valid(348,310)['valid']
assert world.placement_valid(320,310,2,'348,310')['valid']
assert not world.placement_valid(320,310,2,'50,310')['valid']
assert not world.placement_valid(292,310,2,'320,310')['valid']
print('PASS: supplied blue region rejected; actual path edge retained; stale coordinates and cyan-only circles rejected; second rows require live road anchors.')
