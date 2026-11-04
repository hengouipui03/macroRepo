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
    entries=[tuple(map(float,e.split(','))) for e in state['entries'].split(';')]
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
print('PASS: bottom-row portrait click patches remain clear; physical left/right columns; reference/client-crop/resize; disabled buttons and closed-manager rejection.')
