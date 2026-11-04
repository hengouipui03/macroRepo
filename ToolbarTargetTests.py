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

# The grey P fixture is a cropped toolbar; embed it at the real client scale.
bar=mv.read_image(str(root/'path-toggle-off.png'))
scene=np.full((936,1385,3),20,np.uint8)
h,w=bar.shape[:2];scene[:h,1385-w:]=bar
world.static=scene
reply=world.toolbar(0,0,1385,936)
assert reply and reply['on']==0, 'grey P was missed or reported enabled at laptop client size'
x,y=map(int,reply['p'].split(','))
assert abs(x-(1385-w+44))<7, 'grey P target drifted onto the circled i'
print('PASS: grey P detected as disabled at laptop client size, with the click on P rather than i.')

# A remembered position needs only local brightness, even when the P shape is
# partly obscured and the connected-component glyph search would fail.
for name in ['path-world-screenshot.png','path-toggle-split-fx.png']:
    scene=mv.read_image(str(root/name));world.static=scene
    h,w=scene.shape[:2]
    detected=world.toolbar(0,0,w,h);x,y=map(int,detected['p'].split(','))
    fixed=world.toolbar_fixed(0,0,w,h,x,y)
    assert fixed and fixed['on']==detected['on'],(name,fixed,detected)
    assert fixed['p']==detected['p']
print('PASS: saved P coordinates read enabled/disabled state without searching for the glyph.')
