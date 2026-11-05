"""Checks for MinimapVision.py using only the two supplied Future City crops.

    python MinimapVisionTests.py

minimap-fixture.mapframe and minimap-screenshot.png are the same map at two
moments: the arrow moved and the enemies advanced between them.
"""
import os
import sys

import numpy as np

import MinimapVision as mv

HERE = os.path.dirname(os.path.abspath(__file__))
checks = 0


def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1


def pixels(image, reply_value):
    x, y = (float(value) for value in reply_value.split(",")[:2])
    return mv.pixel_point(image, x, y)


def vision_for(image):
    vision = mv.Vision()
    vision.static = image
    vision.box = (0, 0, image.shape[1], image.shape[0])
    return vision


fixture = mv.read_image(os.path.join(HERE, "minimap-fixture.mapframe"))
shot = mv.read_image(os.path.join(HERE, "minimap-screenshot.png"))
# The screenshot crop is two rows shorter; pad the bottom to align the frames.
shot = np.vstack([shot, np.repeat(shot[-1:], fixture.shape[0] - shot.shape[0], axis=0)])

# Static reading: same marker positions the AHK fixture test expects.
scan = vision_for(fixture).scan()
x, y = pixels(fixture, scan["player"])
check(abs(x - 140) < 3 and abs(y - 244) < 3, "fixture chevron at %.1f,%.1f" % (x, y))
x, y = pixels(fixture, scan["heart"])
check(abs(x - 83) < 3 and abs(y - 236) < 3, "fixture heart at %.1f,%.1f" % (x, y))

# Magic Town: the player spawns on the heart and its chevron outline cuts the
# heart into small white pieces, so no heart is reported. The route is still
# read; AHK walks toward the middle checkpoint and reads the heart once uncovered.
onheart = mv.read_image(os.path.join(HERE, "player-on-heart-minimap.png"))
onheart_scan = vision_for(onheart).scan()
check("heart" not in onheart_scan and onheart_scan["route"].count("1") > 100, "player-on-heart frame: %s" % {k: v for k, v in onheart_scan.items() if k not in ("route", "occluded")})

# The screenshot's route is darker along its length and largely covered by
# enemies. Every visible route cell must lie on the clean fixture route, and
# route plus occluded cells must cover the fixture route for AHK to bridge.
def grid(text):
    return np.array([value == "1" for value in text]).reshape(mv.GRID, mv.GRID)


clean = grid(scan["route"])
shot_scan = vision_for(shot).scan()
visible, hidden = grid(shot_scan["route"]), grid(shot_scan["occluded"])
# The fixture has its own skull stack on the upper segment.
near_clean = mv.cv2.dilate((clean | grid(scan["occluded"])).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
check((visible & near_clean).sum() >= 0.97 * visible.sum(), "screenshot route strays from the fixture route")
covered = mv.cv2.dilate((visible | hidden).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
check((clean & covered).sum() >= 0.95 * clean.sum(), "occlusion map leaves route gaps unexplained")

# The minimap frame is mint green, not route green.
frame_only = mv.masks(fixture)[0] & mv.frame_mask(fixture)
check(frame_only.sum() == 0, "frame colour overlaps route colour")

# Movement: arrow moved from the screenshot position to the fixture position
# while enemies moved too. Only the white chevron may be reported.
vision = vision_for(shot)
vision.mark()
vision.static = fixture
moved = vision.moved()
x, y = pixels(fixture, moved["player"])
check(moved["paired"] == 1 and abs(x - 140) < 3 and abs(y - 244) < 3, "moved arrow found at %.1f,%.1f" % (x, y))
dx, dy = (float(value) for value in moved["delta"].split(","))
check(abs(dx - 16.5 * 95 / 262) < 1.2 and abs(dy - 7.4 * 95 / 262) < 1.2, "arrow displacement %s" % moved["delta"])

# Edge: move the chevron so half of it is cut off by the right side of the
# capture. The static reading may miss it; movement and tracking may not.
white = mv.masks(fixture)[1]
ys, xs = np.nonzero(white[236:252, 130:150])
arrow_pixels = fixture[236:252, 130:150].copy()
clipped = fixture.copy()
background = fixture[236:252, 160:180].copy()  # route-free strip of the same row
for yy, xx in zip(ys, xs):
    clipped[236 + yy, 130 + xx] = background[yy, min(xx, 19)]
edge_x = fixture.shape[1] - 6
for yy, xx in zip(ys, xs):
    target = edge_x + xx - 8
    if target < fixture.shape[1]:
        clipped[236 + yy, target] = arrow_pixels[yy, xx]
vision = vision_for(fixture)
vision.mark()
vision.static = clipped
moved = vision.moved()
x, y = pixels(clipped, moved["player"]) if moved else (-1, -1)
check(moved and x > fixture.shape[1] - 12, "edge-clipped arrow not found by movement (%s)" % moved)
tracked = vision_for(clipped).track(*(str(value) for value in mv.grid_point(clipped, edge_x, 244)), "6")
check(tracked is not None, "edge-clipped arrow not found by tracking")

# Occlusion: paint a red enemy icon over half of the chevron; tracking keeps it.
covered = fixture.copy()
covered[236:252, 140:150] = (40, 40, 230)
gx, gy = mv.grid_point(fixture, 140, 244)
tracked = vision_for(covered).track(str(gx), str(gy), "5")
check(tracked is not None, "half-covered arrow lost by tracking")
check(vision_for(covered).track(str(gx), str(gy - 40), "5") is None, "tracking accepted a far-away marker")

# The heart never counts as the player, even when tracking is aimed at it.
hx, hy = mv.grid_point(fixture, 83, 236)
tracked = vision_for(fixture).track(str(hx), str(hy), "4")
check(tracked is None, "heart reported as player")

# Locating: put the crop inside a larger bright scene and find its frame.
scene = np.full((700, 900, 3), (210, 215, 220), np.uint8)
scene[300:500, 100:400] = (40, 180, 60)
scene[420:420 + fixture.shape[0], 600:600 + fixture.shape[1]] = fixture


class SceneSource:
    name = "scene"

    def grab(self, left, top, width, height):
        return scene[top:top + height, left:left + width].copy()


vision = mv.Vision()
vision.screen = SceneSource()
located = vision.locate(0, 0, 900, 700, 650, 470, 860, 680)
left, top, width, height = (int(value) for value in located["box"].split(","))
ys, xs = np.nonzero(mv.frame_mask(fixture))
check(located["source"] == "frame" and abs(left - 600 - xs.min()) <= 2 and abs(top - 420 - ys.min()) <= 2, "frame located at %s" % located)
check(abs(width - (xs.max() - xs.min() + 1)) <= 3 and abs(height - (ys.max() - ys.min() + 1)) <= 3, "frame size %dx%d" % (width, height))
# Without a visible frame the proportional guess is kept.
scene[:] = (30, 30, 30)
check(vision.locate(0, 0, 900, 700, 650, 470, 860, 680)["source"] == "guess", "frame invented in an empty scene")

# --- illuminated world path (path-world-screenshot.png, P lit) -------------
shot = mv.read_image(os.path.join(HERE, "path-world-screenshot.png"))
height, width = shot.shape[:2]
world = mv.World(mv.Vision())
world.static = shot
toggle = world.toolbar(0, 0, width, height)
x, y = (int(value) for value in toggle["p"].split(","))
check(toggle["on"] == 1 and abs(x - 1237) < 6 and abs(y - 24) < 6, "lit P toggle not read: %s" % toggle)
# The P-off crop pasted into an otherwise empty top-right corner.
dark = np.full_like(shot, (120, 70, 20))
crop = mv.read_image(os.path.join(HERE, "path-toggle-off.png"))
dark[:crop.shape[0], width - crop.shape[1]:] = crop
world.static = dark
check(world.toolbar(0, 0, width, height)["on"] == 0, "grey P read as lit")
# Here FX splits into separate F and X glyphs; P must still be the leftmost,
# not the i button next to it.
world.static = mv.read_image(os.path.join(HERE, "path-toggle-split-fx.png"))
toggle = world.toolbar(0, 0, world.static.shape[1], world.static.shape[0])
x, y = (int(value) for value in toggle["p"].split(","))
check(toggle["on"] == 0 and abs(x - 1241) < 6 and abs(y - 32) < 6, "P confused with i when FX splits: %s" % toggle)
world.static = shot

state = world.world(0, 0, width, height)
check(state["on"] == 1 and state["path"] > 40000, "lit path around the player not found: %s" % state)
check(world.onpath(560, 530)["on"] == 1 and world.onpath(690, 800)["on"] == 0, "path/off-path points misread")
check(world.onpath(630, 544)["on"] == 1, "dark gap between chevrons not counted as path")
check(world.onpath(618, 178)["on"] == 0 and world.onpath(1245, 930)["on"] == 0, "Yes button or minimap line counted as path")
east = world.follow(1, 0)
x, y = (int(value) for value in east["point"].split(","))
check(x > width / 2 + 60 and world.onpath(x, y)["on"] == 1, "east follow point %s" % east)
west = world.follow(-1, 0)
x, y = (int(value) for value in west["point"].split(","))
check(x < width / 2 - 60 and world.onpath(x, y)["on"] == 1, "west follow point %s" % west)

beside = world.beside(10)
points = [tuple(int(value) for value in point.split(",")) for point in beside["points"].split(";")]
check(len(points) >= 8, "too few placement points beside the path")
check(all(world.onpath(x, y)["on"] == 0 for x, y in points), "a placement point lies on the lit path")
check(all(np.hypot(x - width / 2, y - height / 2) > width * 0.044 for x, y in points), "a placement point is on the player")
# Each point is close to the band: within 5% of the width of a path pixel.
near = [any(world.onpath(x + dx, y + dy)["on"] for dx in range(-70, 71, 14) for dy in range(-70, 71, 14)) for x, y in points]
check(all(near), "a placement point is far from the path")
check(any(y < 470 for _, y in points) and any(y > 580 for _, y in points), "placement points only on one side of the path")

# --- Discord webhook (no network: the request is captured) -----------------
sent = {}


class Response:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *error):
        return False


def capture(request, timeout):
    sent["request"] = request
    return Response()


png = mv.cv2.imencode(".png", shot)[1].tobytes()
status = mv.send_discord("https://discord.com/api/webhooks/1/abc", "Result: WIN", png, capture)
request = sent["request"]
body = request.data
check(status == 200 and request.get_method() == "POST", "webhook not posted")
check(b'name="payload_json"' in body and b'"content": "Result: WIN"' in body, "webhook text missing")
check(b'filename="result.png"' in body and b"\x89PNG" in body, "webhook screenshot missing")
boundary = request.get_header("Content-type").split("boundary=")[1]
check(body.rstrip().endswith(("--%s--" % boundary).encode()), "multipart body not closed")
check(request.get_header("User-agent").startswith("DiscordBot"), "Discord needs a DiscordBot User-Agent")
try:
    mv.send_discord("https://example.com/hook", "x", png, capture)
    check(False, "non-Discord URL accepted")
except ValueError:
    check(True, "")

print("PASS: %d minimap vision checks" % checks)
