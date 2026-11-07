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

# Puppet Island's translucent minimap showed green scenery below the spawn.
# Preserve the bright road across the top while dropping the off-road branch.
puppet = mv.read_image(os.path.join(HERE, "puppet-island-minimap.png"))
puppet_route = mv.masks(puppet)[0]
check(not puppet_route[98:128, 5:50].any(), "green scenery became a route branch")
check(puppet_route[69:88, 30:76].sum() > 100, "the real Puppet Island route was lost")

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
# Sand Village: the lit path is pure yellow (hue 28-31), not lime, on yellow
# sand. It must still be found, and the wall below the player is not path.
sand = mv.World(mv.Vision())
sand.static = mv.read_image(os.path.join(HERE, "path-world-sand-village.png"))
state = sand.world(0, 0, sand.static.shape[1], sand.static.shape[0])
check(state["on"] == 1 and state["path"] > 20000, "yellow Sand Village path not found: %s" % state)
check(all(sand.onpath(x, y)["on"] == 1 for x, y in [(735, 457), (490, 375), (960, 620)]), "yellow chevrons not counted as path")
check(sand.onpath(605, 590)["on"] == 0 and sand.onpath(200, 350)["on"] == 0, "Sand Village wall or sand counted as path")
check(sand.beside(12)["count"] >= 8, "no path-side spots beside the yellow path")
# Later in the same match a Hybrid unit is selected and the green Hill
# highlight outweighs the paler yellow chevrons. The match already showed a
# yellow path, so the highlight is not path and the road beside the player is.
check(sand.yellow_path, "clear yellow path frame did not mark the match as yellow-path")
sand.static = mv.read_image(os.path.join(HERE, "path-world-sand-village-hill.png"))
sand.world(0, 0, sand.static.shape[1], sand.static.shape[0])
check(sand.onpath(800, 449)["on"] == 1 and sand.onpath(965, 620)["on"] == 1, "pale yellow chevrons beside the player not counted as path")
check(sand.onpath(480, 380)["on"] == 0, "green Hill highlight counted as path on a yellow-path map")
check(sand.reset()["reset"] == 1 and not sand.yellow_path, "worldreset did not clear the path colour")
# With the manager closed, Sand Village's yellow path in the top-right corner
# is not the manager's "Unit Overview" heading (it caused F to be skipped,
# then pressed during cards, which opened the manager over the right card).
for name in ("path-world-sand-village.png", "path-world-sand-village-hill.png"):
    sand.static = mv.read_image(os.path.join(HERE, name))
    check(sand.unit_manager(0, 0, sand.static.shape[1], sand.static.shape[0])["open"] == 0, "closed manager read as open: " + name)
# With the enemy direction from AHK the reply holds a front lane (toward the
# enemies: right, into the open space on Sand Village) and a behind lane
# (toward the base), each starting at the free edge spot nearest the player.
sand.static = mv.read_image(os.path.join(HERE, "path-world-sand-village.png"))
sand.world(0, 0, sand.static.shape[1], sand.static.shape[0])
sand.static = mv.read_image(os.path.join(HERE, "path-world-sand-village-hill.png"))
sand.world(0, 0, sand.static.shape[1], sand.static.shape[0])
lanes = {}
for ux, uy in ((1, 0), (0, 1)):
    lane = [tuple(map(int, p.split(","))) for p in sand.placement_line(48, "-", "-", "-", str(ux), str(uy))["points"].split(";")]
    ahead = lane[min(3, len(lane) - 1)]
    check(len(lane) >= 3 and (ahead[0] - lane[0][0]) * ux + (ahead[1] - lane[0][1]) * uy > 0, "lane did not run upstream for %s: %s" % ((ux, uy), lane[:4]))
    lanes[(ux, uy)] = lane
check(lanes[(1, 0)][1] != lanes[(0, 1)][1], "the upstream direction did not change which way the lane runs")
reply = sand.placement_line(48, "-", "-", "-", "1", "0")
lane = [tuple(map(int, p.split(","))) for p in reply["points"].split(";")]
front = int(reply["front"])
# One start, the free edge spot nearest the player. Here it is the end of the
# visible road: the other walk wraps around that end to the far side of the
# road, so there is no behind lane and nothing is placed across the road.
check(front == len(lane) and front >= 8, "lane crossed to the other side of the road: front %s of %s" % (front, len(lane)))
check(len(reply["normals"].split(";")) == len(lane), "geometry not returned for every lane point")
# Where the road continues both ways the behind lane starts beside the shared
# start (same side of the road) and runs away from the enemies.
city = mv.World(mv.Vision())
city.static = mv.read_image(os.path.join(HERE, "hover-future-city-hill.png"))
city.path_view(0, 0, city.static.shape[1], city.static.shape[0])
reply = city.placement_line(48, "-", "-", "-", "-1", "0")
lane = [tuple(map(int, p.split(","))) for p in reply["points"].split(";")]
front = int(reply["front"])
check(front < len(lane) and (lane[front][0] - lane[0][0]) ** 2 + (lane[front][1] - lane[0][1]) ** 2 <= 30 ** 2
      and lane[min(len(lane) - 1, front + 3)][0] > lane[0][0], "behind lane not beside the start or not running away from the enemies")
sand.reset()

# Sky Island: green, crimson and blue paths form one route; other maps do not.
sky_map = mv.Vision()
sky_map.static = mv.read_image(os.path.join(HERE, "sky-island-minimap.png"))
sky_map.box = (0, 0, sky_map.static.shape[1], sky_map.static.shape[0])
reply = sky_map.scan()
route_cells = reply["route"].count("1")
check(reply.get("paths") == 3 and route_cells > 600, "three-path Sky Island minimap not read: %s cells" % route_cells)
# Same map, but the green and blue lines cut the crimson one into short pieces.
crossed = mv.Vision()
crossed.static = mv.read_image(os.path.join(HERE, "sky-island-crossed-minimap.png"))
crossed.box = (0, 0, crossed.static.shape[1], crossed.static.shape[0])
check(crossed.scan().get("paths") == 3, "Sky Island with its crimson line cut at the crossings not read as three paths")
for name in ("minimap-screenshot.png", "two-path-minimap.jpg", "player-on-heart-minimap.png"):
    other = mv.Vision()
    other.static = mv.read_image(os.path.join(HERE, name))
    other.box = (0, 0, other.static.shape[1], other.static.shape[0])
    check("paths" not in other.scan(), name + " read as a three-path map")

# Red no-place overlay (a unit held, P off): the road is the long band of
# constant width; wider red Hill ground and thin health bars are not road, and
# no placement spot lands on any red.
for name, hill_point in (("hover-future-city-hill.png", (900, 569)), ("hover-planet-greenie-p-off.png", None)):
    hover = mv.World(mv.Vision())
    hover.static = mv.read_image(os.path.join(HERE, name))
    view = hover.path_view(0, 0, hover.static.shape[1], hover.static.shape[0])
    check(view["path"] > 10000, "red road not read from the overlay: %s %s" % (name, view))
    lane = [tuple(map(int, p.split(","))) for p in hover.placement_line(48, "-", "-", "-")["points"].split(";")]
    check(len(lane) >= 8 and not any(hover.on_red(x // 2, y // 2) for x, y in lane), "lane spots missing or on red: " + name)
    if hill_point:
        check(hover.onpath(*hill_point)["on"] == 0 and hover.on_red(hill_point[0] // 2, hill_point[1] // 2), "red Hill ground read as road")
        check(hover.placement_valid(hill_point[0] * 800.0 / hover.static.shape[1], hill_point[1] * 600.0 / hover.static.shape[0])["valid"] == 0, "a spot on red Hill ground passed validation")
    # An unselected frame keeps the path view instead of replacing it.
    before = int(hover.area.sum())
    hover.world(0, 0, hover.static.shape[1], hover.static.shape[0])
    check(int(hover.area.sum()) == before, "an unselected frame replaced the path view")
    check(hover.follow(1, 0) is None and hover.follow(0, 1) is None, "red placement view steered movement")
    hover.clear_view()
    check(hover.area is None and hover.blocked is None, "clearing the red view kept stale coordinates")
    hover.path_view(0, 0, hover.static.shape[1], hover.static.shape[0])
    check(hover.reset()["reset"] == 1 and hover.view_area is None and hover.blocked is None, "worldreset kept the path view")
lit = mv.World(mv.Vision())
lit.static = mv.read_image(os.path.join(HERE, "hover-planet-greenie-p-on.png"))
check(lit.path_view(0, 0, lit.static.shape[1], lit.static.shape[0])["path"] == 0, "lit arrows (P on) read as the red overlay road")

# P off on Sky Island during a Blizzard: the yellow Weather Alert banner is
# not a lit road (it let the macro carry on as if P had lit the path).
sky = mv.World(mv.Vision())
sky.static = mv.read_image(os.path.join(HERE, "path-world-sky-island-p-off.png"))
check(sky.world(0, 0, sky.static.shape[1], sky.static.shape[0])["path"] == 0, "Weather Alert banner read as a lit path")

# Sandstorm on Alien Spaceship, P on, nothing held: the haze shifts the lit
# path toward yellow (and turns the red overlay orange, so pathview fails
# there), but the lit path still reads, well above RefreshPathView's 1% of the
# client (LIT_PATH_MIN_FRACTION), with no sandy wall or floor counted.
storm = mv.World(mv.Vision())
storm.static = mv.read_image(os.path.join(HERE, "path-world-sandstorm-p-on.png"))
storm_h, storm_w = storm.static.shape[:2]
lit_read = storm.world(0, 0, storm_w, storm_h)
check(lit_read["path"] >= storm_w * storm_h * 0.01 and lit_read["on"] == 1, "sandstorm lit path (P on) not read: %s" % lit_read)
check(not storm.yellow_path, "sandstorm lime path latched as a yellow Sand Village path")
check(storm.onpath(1100, 220)["on"] == 0 and storm.onpath(300, 400)["on"] == 0, "sandy wall read as the sandstorm lit path")
# pathviewclear: an earlier red view no longer stands in for a fresh lit read.
storm.view_area = np.zeros_like(storm.area)
storm.view_area[0, 0] = 1
check(storm.world(0, 0, storm_w, storm_h)["path"] == 4, "red view did not replace the lit read")
check(storm.clear_view()["cleared"] == 1 and storm.world(0, 0, storm_w, storm_h)["path"] == lit_read["path"], "pathviewclear kept the old red view")
check(storm.path_fail_debug("unused.png")["saved"] == 0, "a fail frame was saved without a failed red read")

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
# The reply to AHK must stay "ok": a "status=200" field once overwrote it, so
# every successful post was logged as failed.
original_send = mv.send_discord
mv.send_discord = lambda url, text, png: 200
try:
    poster = mv.World(mv.Vision())
    poster.static = shot
    line = mv.format_reply(mv.discord(poster, 0, 0, 10, 10, "https://discord.com/api/webhooks/1/abc", "Result:", "WIN"))
finally:
    mv.send_discord = original_send
fields = dict(part.split("=", 1) for part in line.split("\t")[1:])
check(line.startswith("ok\t") and "status" not in fields and fields.get("http") == "200", "webhook reply read as a failure: " + line)
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
