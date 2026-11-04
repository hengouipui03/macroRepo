"""Capture fallback, local placement circle and measured camera translation."""
import sys
from types import SimpleNamespace
import cv2
import numpy as np
import MinimapVision as mv

black = np.zeros((600,800,3),np.uint8)
good = np.full_like(black,40)
assert not mv.ScreenSource.usable(black,800,600)
assert not mv.ScreenSource.usable(good,640,480)
assert mv.ScreenSource.usable(good,800,600)

class FakeDX:
    def grab(self, **kwargs): return black

class FakeMSS:
    def __init__(self, image): self.image = image
    def grab(self, rect): return self.image
    def close(self): pass

source = mv.ScreenSource.__new__(mv.ScreenSource)
source.dx,source.dx_w,source.dx_h = FakeDX(),800,600
source.last,source.mss = {},FakeMSS(good)
assert np.array_equal(source.grab(0,0,800,600),good),'blank DX capture did not fall back'
original = sys.modules.get('mss')
sys.modules['mss'] = SimpleNamespace(mss=lambda:FakeMSS(black))
try:
    source.mss = FakeMSS(black)
    try:
        source.grab(0,0,800,600)
        raise AssertionError('blank frames were accepted as a path scan')
    except RuntimeError as err:
        assert 'capture' in str(err)
finally:
    if original is None: del sys.modules['mss']
    else: sys.modules['mss'] = original

world = mv.World(mv.Vision())
world.static = black
try:
    world.world(0,0,800,600)
    raise AssertionError('blank world scan was accepted')
except RuntimeError:
    assert world.area is None

assert world.in_placement_area(560,300)
assert not world.in_placement_area(590,300)
assert not world.in_placement_area(400,300)
world.area = np.zeros((300,400),np.uint8)
world.area[:,180:220] = 1
plan = world.relocation()
assert plan and float(plan['dy'])<0 and 45<=np.hypot(float(plan['dx']),float(plan['dy']))<=75

rng = np.random.default_rng(71)
before = rng.integers(25,220,(600,800,3),dtype=np.uint8)
before = cv2.GaussianBlur(before,(3,3),0)
world.image = before
assert world.remember_view()['saved']
for dx,dy in [(-50,30),(65,-40),(0,0)]:
    world.static = cv2.warpAffine(before,np.float32([[1,0,dx],[0,1,dy]]),(800,600))
    measured = world.view_shift(0,0,800,600)
    assert measured,(dx,dy)
    assert abs(float(measured['dx'])-dx)<1 and abs(float(measured['dy'])-dy)<1,measured
world.static = black
assert world.view_shift(0,0,800,600) is None
world.static = cv2.warpAffine(before,cv2.getRotationMatrix2D((400,300),5,1),(800,600))
assert world.view_shift(0,0,800,600) is None,'camera rotation was mistaken for translation'
print('PASS: black/wrong-size capture rejection; DX-to-MSS fallback; explicit capture failure; circular area; next connected road area; measured camera shifts; rotation/blank-frame rejection.')
