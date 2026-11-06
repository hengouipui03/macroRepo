"""Card interiors are found from the dark card panels, so the Level Modifiers
panel beside the right card never enters its colour or OCR bounds."""
import cv2
import numpy as np
import MinimapVision as mv

def scene(w=1280, h=893, panel_gap=3, seed=1, lower_panel_colour=(22, 18, 26)):
    rng = np.random.default_rng(seed)
    img = rng.integers(60, 255, (h, w, 3), dtype=np.uint8)  # bright, busy world
    s = w / 800.0
    y1, y2 = int(188 * h / 600), int(425 * h / 600)
    for x1, x2 in [(149, 299), (325, 476), (502, 652)]:
        a, b = int(x1 * s), int(x2 * s)
        img[y1 - 8:y2 + 8, a - 8:b + 8] = (200, 60, 170)   # card frame
        img[y1:y2, a:b] = (22, 18, 26)                      # dark interior
        img[int(h * .5):y2, a:b] = lower_panel_colour       # tinted lower interior
        img[y1 + 40:y1 + 52, a + 30:b - 30] = (40, 220, 60)  # green effect words
        img[int(h * .5):int(h * .5) + 10, a + 20:b - 20] = (240, 240, 240)  # white text line
    # Level Modifiers panel: dark, starting just right of the third card.
    pa = int(652 * s) + panel_gap
    img[int(150 * h / 600):int(470 * h / 600), pa:int(780 * s)] = (20, 20, 24)
    return img

expected = [(149, 299), (325, 476), (502, 652)]
for w, h, gap in [(1280, 893, 3), (1385, 936, 3), (1280, 893, 1), (800, 600, 2)]:
    for colour in [(22, 18, 26), (32, 25, 60)]:
        boxes = mv.card_boxes(scene(w, h, gap, lower_panel_colour=colour))
        assert boxes, (w, h, gap, colour)
        for (a, b), (ea, eb) in zip(boxes, expected):
            assert abs(a - ea) <= 4 and abs(b - eb) <= 4, ((w, h, gap), boxes)
world = np.random.default_rng(5).integers(60, 255, (893, 1280, 3), dtype=np.uint8)
assert mv.card_boxes(world) is None, "a world without cards produced card boxes"
w = mv.World(mv.Vision())
w.static = scene()
reply = w.card_boxes(0, 0, 1280, 893)
assert reply["found"] == 1 and len(reply["boxes"].split(";")) == 3, reply
w.static = world
assert w.card_boxes(0, 0, 1280, 893) == {"found": 0}
print("PASS: dark and red-tinted card interiors found at 800x600, 1280x893 and 1385x936; modifier panel excluded; no cards in a plain world.")
