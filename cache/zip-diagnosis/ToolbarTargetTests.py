from pathlib import Path
import cv2
import numpy as np
import MinimapVision as mv
root=Path(__file__).resolve().parent
world=mv.World(mv.Vision())
attachment=mv.read_image(str(root/"path-toolbar-p-only.png"))
scene=np.full((900,1379,3),20,np.uint8)
h,w=attachment.shape[:2]
scene[:h,1379-w:]=attachment
world.static=scene
reply=world.toolbar(0,0,1379,900)
x,y=map(int,reply['p'].split(','))
assert abs(x-(1379-w+25))<7 and reply['on']==1,reply
for name in ['path-world-screenshot.png','path-toggle-split-fx.png']:
    scene=mv.read_image(str(root/name));world.static=scene
    reply=world.toolbar(0,0,scene.shape[1],scene.shape[0])
    assert reply, name
    x,y=map(int,reply['p'].split(','))
    scene[max(0,y-12):y+13,x-12:x+13]=(20,20,20)
    assert world.toolbar(0,0,scene.shape[1],scene.shape[0]) is None, 'circled i substituted for missing P'
print('PASS: attached P identified; circled i rejected when P is absent, including split FX.')
