"""Minimap vision service for AAPathMacro.ahk.

AHK keeps all keyboard and mouse input. This process only captures the
bottom-right minimap and answers one request per line on stdin with one
tab-separated reply line on stdout:

    ok<TAB>key=value<TAB>key=value      or      fail<TAB>reason=...

Positions in replies are minimap grid units (0..GRID-1), the same normalized
96 x 96 drawing MapNavigation.ahk stores in learning.ini.

Requests:
    ping
    locate cx cy cw ch hl ht hr hb   client rect (screen) + guessed box (client)
    box cx cy l t w h                client origin (screen) + known box (client)
    load <path>                      read a .png/.bmp/.mapframe instead of the screen
    scan                             route/occlusion bits, heart, static player,
                                     crossings with a second (purple) path
    mark                             remember the current frame for "moved"
    moved                            the white marker that changed since "mark"
    track x y radius                 the player marker nearest a predicted point
    debug <path>                     save the current capture with overlays

World requests read the whole client (positions in client pixels):
    loadworld <path>                 read a client screenshot instead of the screen
    toolbar cx cy cw ch              the top-right P path toggle and whether it is lit
    world cx cy cw ch                capture and keep the illuminated world path
    follow dx dy                     path point ahead of the player in a screen direction
    beside count                     placement points just outside the lit path
    placementline count              adjacent spots along one local path edge
    unitmanager cx cy cw ch           manager rows; entries are column,portrait x,y,row y,
                                     filled,total segments,MAX,Upg x,y,portrait colours
    hillspots count cx cy cw ch       new green hill highlights nearest the path
    onpath x y                       whether a client point lies on the lit path
    worlddebug <path>                save the world capture with path and points
    discord cx cy cw ch <url> <text> post text and a client screenshot to a
                                     Discord webhook (discord.com URLs only)
    quit
"""
import ctypes
import datetime
import json
import struct
import sys
import urllib.request
import uuid

import cv2
import numpy as np

GRID = 96
REF_SIDE = 263.0  # width of the supplied Future City minimap crop

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    pass


class ScreenSource:
    """dxcam (Desktop Duplication) on the primary monitor, mss elsewhere."""

    def __init__(self):
        self.dx = None
        self.mss = None
        try:
            import dxcam
            self.dx = dxcam.create(output_color="BGR")
            self.dx_w, self.dx_h = self.dx.width, self.dx.height
        except Exception:
            self.dx = None
        self.name = "dxcam" if self.dx else "mss"

    def grab(self, left, top, width, height):
        region = (left, top, left + width, top + height)
        if self.dx and left >= 0 and top >= 0 and region[2] <= self.dx_w and region[3] <= self.dx_h:
            try:
                frame = self.dx.grab(region=region)
            except Exception:
                frame = None
            # A missing DX frame uses a fresh MSS grab, never an old cached view.
            if self.usable(frame, width, height):
                return np.ascontiguousarray(frame)
        if self.mss is None:
            import mss
            self.mss = mss.mss()
        for attempt in range(2):
            try:
                shot = self.mss.grab({"left": left, "top": top, "width": width, "height": height})
                frame = np.ascontiguousarray(np.asarray(shot)[:, :, :3])
                if self.usable(frame, width, height):
                    return frame
            except Exception:
                pass
            self.mss.close()
            import mss
            self.mss = mss.mss()
        raise RuntimeError("screen capture is blank/unavailable; no path or placement decision made")

    @staticmethod
    def usable(frame, width, height):
        if frame is None or frame.shape[:2] != (height, width):
            return False
        sample = frame[::8, ::8]
        return bool(sample.size and np.mean(sample.max(axis=2) > 12) >= 0.002)


def read_image(path):
    if path.lower().endswith(".mapframe"):
        raw = open(path, "rb").read()
        width, height = struct.unpack_from("<2I", raw, 0)
        pixels = np.frombuffer(raw, np.uint8, width * height * 4, 24).reshape(height, width, 4)
        return np.ascontiguousarray(pixels[:, :, :3])
    image = cv2.imread(path, cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError("cannot read " + path)
    return image


# --- colour masks ----------------------------------------------------------
# The route is a saturated green whose brightness pulses along its length, so
# hue/saturation are used rather than a fixed brightness. The minimap frame is
# a paler mint green (hue ~77) and stays outside the route range.

def masks(image):
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]
    route = (h >= 38) & (h <= 66) & (s >= 150) & (v >= 70)
    # The translucent minimap can show dim green scenery underneath it.
    # Keep dim route pixels only when their component also contains the
    # brighter line, so scenery cannot become a new walkable branch.
    count, labels = cv2.connectedComponents(route.astype(np.uint8), connectivity=8)
    lit = np.bincount(labels[route & (v >= 120)], minlength=count) > 0
    lit[0] = False
    route = lit[labels]
    white = image.min(axis=2) >= 200
    # Any vivid non-route colour is an icon drawn over the line: red skulls,
    # the purple boss and similar enemy markers.
    icon = (s >= 110) & (v >= 120) & ~route & ~((h >= 68) & (h <= 92))
    return route, white, icon


def second_route(image):
    """A second, purple enemy path (two-path maps). Only long lines count, so
    purple enemy markers such as the boss icon are never taken for a path."""
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]
    purple = ((h >= 125) & (h <= 160) & (s >= 120) & (v >= 90)).astype(np.uint8)
    scale = image.shape[1] / REF_SIDE
    count, labels, stats, _ = cv2.connectedComponentsWithStats(purple, 8)
    path = np.zeros(purple.shape, bool)
    for index in range(1, count):
        if max(stats[index][2], stats[index][3]) >= 60 * scale:
            path |= labels == index
    return path


def three_paths(image):
    """Sky Island has three enemy paths, green, crimson and blue, that all end
    at the base. Returns the crimson and blue lines when BOTH are present,
    else None.

    The other lines are drawn over the crimson one where they cross, cutting
    it into pieces (38, 31, 31 and 24 px on one capture, none 60 px long), so
    a colour counts by the summed length of its line pieces. A piece must be
    at least 20 px long: the red and blue enemy icons and the skull are
    smaller blobs."""
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]
    scale = image.shape[1] / REF_SIDE
    lines = []
    for mask in (((h >= 165) & (s >= 150) & (v >= 120)), ((h >= 100) & (h <= 122) & (s >= 150) & (v >= 120))):
        count, labels, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), 8)
        path = np.zeros(mask.shape, bool)
        length = 0
        for index in range(1, count):
            side = max(stats[index][2], stats[index][3])
            if side >= 20 * scale:
                path |= labels == index
                length += side
        lines.append(path if length >= 60 * scale else None)
    return lines[0] | lines[1] if lines[0] is not None and lines[1] is not None else None


def red_overlay(small, keep):
    """The red no-place overlay shown while a unit is held (P must be off,
    or the lit arrows break it up). Returns (path, blocked) at the size of
    `small`: path is only the road, a long band of constant width; blocked
    is every red area, the road and red Hill ground alike, where nothing can
    be placed.

    Shape, not colour, tells them apart: Hill ground is wider than the road,
    enemy health bars and unit rings are thinner or shorter.
    """
    hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]
    width = small.shape[1]
    red = (((h <= 8) | (h >= 165)) & (s >= 110) & (v >= 150)).astype(np.uint8) & keep
    red = cv2.morphologyEx(red, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    wide_k = max(5, int(width * 0.045)) | 1  # wider than the road: Hill ground
    wide = cv2.morphologyEx(red, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (wide_k, wide_k)))
    wide = cv2.dilate(wide, np.ones((5, 5), np.uint8))
    thin_k = max(3, int(width * 0.012)) | 1  # thinner than the road: health bars, rings
    band = cv2.morphologyEx(red, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (thin_k, thin_k)))
    band &= 1 - wide
    count, labels, stats, _ = cv2.connectedComponentsWithStats(band, 8)
    path = np.zeros_like(band)
    for index in range(1, count):
        if max(stats[index][2], stats[index][3]) >= width * 0.15:
            path[labels == index] = 1
    blocked = cv2.dilate(red, np.ones((3, 3), np.uint8)) > 0
    return path, blocked


def path_crossings(image, route, purple):
    """Grid points where the purple path meets the green route: every crossing
    and the merge before the base, nearby contacts merged into one point."""
    if not purple.any() or not route.any():
        return []
    scale = image.shape[1] / REF_SIDE
    k = max(3, int(round(5 * scale))) | 1
    kernel = np.ones((k, k), np.uint8)
    touch = (cv2.dilate(route.astype(np.uint8), kernel) > 0) & (cv2.dilate(purple.astype(np.uint8), kernel) > 0)
    count, _, stats, centres = cv2.connectedComponentsWithStats(touch.astype(np.uint8), 8)
    points = [tuple(centres[i]) for i in range(1, count) if stats[i][4] >= 3 * scale * scale]
    clusters = []
    for x, y in points:
        for cluster in clusters:
            if any((x - cx) ** 2 + (y - cy) ** 2 <= (28 * scale) ** 2 for cx, cy in cluster):
                cluster.append((x, y))
                break
        else:
            clusters.append([(x, y)])
    return [grid_point(image, float(np.mean([p[0] for p in c])), float(np.mean([p[1] for p in c]))) for c in clusters]


def card_boxes(image):
    """Interiors of the three choice cards as 800-wide reference X spans.

    The cards are dark panels with bright frames between them. The middle card
    is the dark run containing the screen centre, the left card the next run to
    its left. The right card is placed one pitch right of the middle card and
    is never measured, because the Level Modifiers panel can touch it."""
    h, w = image.shape[:2]
    # Lower parts of the cards can fade to red and fail the dark-pixel test.
    y0, y1 = int(h * .36), int(h * .55)
    cols = (image[y0:y1].max(axis=2) < 45).mean(axis=0) > .55
    raw = []
    start = None
    for x, v in enumerate(list(cols) + [False]):
        if v and start is None:
            start = x
        elif not v and start is not None:
            raw.append([start, x])
            start = None
    # Bright text columns split a card interior by a pixel or two.
    merged = []
    for run in raw:
        if merged and run[0] - merged[-1][1] <= max(2, w * .005):
            merged[-1][1] = run[1]
        else:
            merged.append(run)
    runs = [r for r in merged if r[1] - r[0] >= w * .08]
    middle = [r for r in runs if r[0] <= w / 2 <= r[1]]
    if not middle:
        return None
    m = middle[0]
    left = [r for r in runs if r[1] <= m[0] and m[0] - r[1] <= w * .06]
    if not left:
        return None
    l = left[-1]
    if abs((m[1] - m[0]) - (l[1] - l[0])) > w * .03:
        return None
    width = (m[1] - m[0] + l[1] - l[0]) / 2.0
    pitch = (m[0] + m[1]) / 2.0 - (l[0] + l[1]) / 2.0
    centres = [(l[0] + l[1]) / 2.0, (m[0] + m[1]) / 2.0, (m[0] + m[1]) / 2.0 + pitch]
    sx = 800.0 / w
    boxes = [(int(round((c - width / 2) * sx)), int(round((c + width / 2) * sx))) for c in centres]
    # Sanity: three cards of plausible size inside the usual card area.
    if not (100 <= boxes[0][0] and boxes[2][1] <= 720 and 110 <= boxes[1][1] - boxes[1][0] <= 230
            and abs((boxes[1][0] + boxes[1][1]) / 2.0 - 400) <= 40):
        return None
    return boxes


def frame_mask(image):
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]
    return (h >= 68) & (h <= 92) & (s >= 90) & (v >= 190)


def to_grid(mask, fraction=0.06):
    small = cv2.resize(mask.astype(np.float32), (GRID, GRID), interpolation=cv2.INTER_AREA)
    return small > fraction


def bits(grid):
    return "".join("1" if value else "0" for value in grid.ravel())


def grid_point(image, x, y):
    height, width = image.shape[:2]
    return x / (width - 1) * (GRID - 1), y / (height - 1) * (GRID - 1)


def pixel_point(image, gx, gy):
    height, width = image.shape[:2]
    return gx / (GRID - 1) * (width - 1), gy / (GRID - 1) * (height - 1)


# --- white markers ---------------------------------------------------------

def white_blobs(image, white=None):
    if white is None:
        white = masks(image)[1]
    scale = image.shape[1] / REF_SIDE
    count, labels, stats, centres = cv2.connectedComponentsWithStats(white.astype(np.uint8), 8)
    blobs = []
    for index in range(1, count):
        x, y, w, h, area = stats[index]
        if area < max(4, 4 * scale * scale) or max(w, h) > 30 * scale:
            continue
        blobs.append({"index": index, "x": float(centres[index][0]), "y": float(centres[index][1]),
                      "w": int(w), "h": int(h), "area": int(area), "fill": area / float(w * h)})
    return blobs, labels


def is_heart(blob, scale):
    # The filled heart (~190 px at 263 wide) is much larger than the open
    # chevron (~45 px). A heart clipped by an icon still stays above ~110 px.
    return blob["area"] >= 110 * scale * scale and blob["fill"] > 0.42 and 0.6 < blob["w"] / blob["h"] < 1.8


def is_arrow(blob, scale):
    return 12 * scale * scale <= blob["area"] <= 105 * scale * scale and max(blob["w"], blob["h"]) <= 17 * scale


def markers(image, white=None):
    scale = image.shape[1] / REF_SIDE
    blobs, _ = white_blobs(image, white)
    hearts = [blob for blob in blobs if is_heart(blob, scale)]
    heart = max(hearts, key=lambda blob: blob["area"]) if hearts else None
    arrows = [blob for blob in blobs if blob is not heart and is_arrow(blob, scale)]
    return heart, arrows, blobs


# --- requests --------------------------------------------------------------

class Vision:
    def __init__(self):
        self.screen = None
        self.static = None
        self.client = None
        self.box = None
        self.reference = None

    def capture(self):
        if self.static is not None:
            return self.static
        if self.client is None or self.box is None:
            raise ValueError("no minimap box; send locate or box first")
        if self.screen is None:
            self.screen = ScreenSource()
        left, top, width, height = self.box
        return self.screen.grab(self.client[0] + left, self.client[1] + top, width, height)

    def ping(self):
        source = "file" if self.static is not None else (self.screen.name if self.screen else "idle")
        return {"source": source, "cv": cv2.__version__}

    def load(self, *path):
        self.static = read_image(" ".join(path))
        self.box = (0, 0, self.static.shape[1], self.static.shape[0])
        return {"box": "0,0,%d,%d" % (self.static.shape[1], self.static.shape[0])}

    def use_box(self, cx, cy, left, top, width, height):
        self.client = (int(float(cx)), int(float(cy)))
        self.box = tuple(int(float(value)) for value in (left, top, width, height))
        return {"box": ",".join(str(value) for value in self.box)}

    def locate(self, cx, cy, cw, ch, hl, ht, hr, hb):
        """Find the mint frame of the minimap near AHK's proportional guess."""
        self.static = None
        cx, cy, cw, ch = (int(float(value)) for value in (cx, cy, cw, ch))
        hl, ht, hr, hb = (int(float(value)) for value in (hl, ht, hr, hb))
        self.client = (cx, cy)
        side = max(hr - hl, hb - ht)
        # Search a generous bottom-right region so a different UI scale or
        # window size still contains the whole frame.
        left, top = max(0, hl - side), max(0, ht - side)
        width, height = cw - left, ch - top
        if self.screen is None:
            self.screen = ScreenSource()
        image = self.screen.grab(cx + left, cy + top, width, height)
        mint = frame_mask(image).astype(np.uint8)
        mint = cv2.morphologyEx(mint, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
        count, _, stats, _ = cv2.connectedComponentsWithStats(mint, 8)
        best = None
        for index in range(1, count):
            x, y, w, h, area = stats[index]
            if w < side * 0.55 or h < side * 0.55 or w > side * 1.8 or h > side * 1.8:
                continue
            if not 0.8 < w / float(h) < 1.25:
                continue
            # A frame is a thin outline: little of its bounding box is filled.
            if area > 0.45 * w * h:
                continue
            score = w * h
            if best is None or score > best[0]:
                best = (score, x, y, w, h)
        if best:
            _, x, y, w, h = best
            self.box = (left + int(x), top + int(y), int(w), int(h))
            source = "frame"
        else:
            self.box = (hl, ht, hr - hl + 1, hb - ht + 1)
            source = "guess"
        return {"box": ",".join(str(value) for value in self.box), "source": source}

    def scan(self):
        image = self.capture()
        route, white, icon = masks(image)
        scale = image.shape[1] / REF_SIDE
        # Three-path map: all three lines are one walkable route to the base.
        extra = three_paths(image)
        if extra is not None:
            route = route | extra
            icon = icon & ~extra
        # Enemy and player icons interrupt the line; AHK only bridges gaps
        # where this occlusion map shows an icon was in the way.
        occluded = cv2.dilate((icon | white).astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
        heart, arrows, _ = markers(image, white)
        reply = {"route": bits(to_grid(route)), "occluded": bits(to_grid(occluded, 0.02)),
                 "size": "%d,%d" % (image.shape[1], image.shape[0]), "arrows": len(arrows)}
        if heart:
            reply["heart"] = "%.2f,%.2f" % grid_point(image, heart["x"], heart["y"])
        if extra is not None:
            reply["paths"] = 3
        crossings = path_crossings(image, route, second_route(image))
        if crossings:
            reply["crossings"] = ";".join("%.2f,%.2f" % point for point in crossings)
        if len(arrows) == 1:
            reply["player"] = "%.2f,%.2f,%.2f" % (grid_point(image, arrows[0]["x"], arrows[0]["y"]) + (0.8,))
        elif arrows:
            # Several chevron-sized white shapes: report the most compact one
            # with low confidence; AHK resolves it with a movement probe.
            arrow = min(arrows, key=lambda blob: abs(blob["area"] - 45 * scale * scale))
            reply["player"] = "%.2f,%.2f,%.2f" % (grid_point(image, arrow["x"], arrow["y"]) + (0.3,))
        return reply

    def mark(self):
        self.reference = self.capture().copy()
        return {}

    def moved(self):
        """The player is the white shape that changed in response to input.

        The heart and frame are static and enemies are red, so the white
        pixels that differ between the marked frame and now belong to the
        chevron, even when it is clipped by the edge or partly covered.
        """
        if self.reference is None:
            raise ValueError("send mark first")
        before, after = self.reference, self.capture()
        if before.shape != after.shape:
            raise ValueError("capture size changed since mark")
        scale = after.shape[1] / REF_SIDE
        white_before, white_after = masks(before)[1], masks(after)[1]
        changed = white_before ^ white_after
        blobs_before, labels_before = white_blobs(before, white_before)
        blobs_after, labels_after = white_blobs(after, white_after)

        def moving(blobs, labels):
            result = []
            for blob in blobs:
                if is_heart(blob, scale):
                    continue
                part = labels == blob["index"]
                fraction = changed[part].sum() / float(blob["area"])
                if fraction >= 0.25:
                    blob["changed"] = fraction
                    result.append(blob)
            return result

        now = moving(blobs_after, labels_after)
        then = moving(blobs_before, labels_before)
        if not now:
            return None
        reach = 34 * scale
        best = None
        for blob in now:
            partner = None
            for old in then:
                distance = np.hypot(blob["x"] - old["x"], blob["y"] - old["y"])
                similar = 0.4 < blob["area"] / float(old["area"]) < 2.5
                if distance <= reach and similar and (partner is None or distance < partner[0]):
                    partner = (distance, old)
            # Paired shapes are the strongest evidence; an unpaired one can be
            # an arrow emerging from under an icon or the frame edge.
            score = blob["changed"] + (1.0 if partner else 0.0) - abs(blob["area"] - 45 * scale * scale) / (200 * scale * scale)
            if best is None or score > best[0]:
                best = (score, blob, partner)
        _, blob, partner = best
        gx, gy = grid_point(after, blob["x"], blob["y"])
        reply = {"player": "%.2f,%.2f" % (gx, gy), "paired": 1 if partner else 0}
        if partner:
            ox, oy = grid_point(after, partner[1]["x"], partner[1]["y"])
            reply["delta"] = "%.3f,%.3f" % (gx - ox, gy - oy)
        return reply

    def track(self, x, y, radius):
        """Nearest chevron-sized white shape to a predicted grid point.

        Clipped or partly covered chevrons are accepted here because the
        prediction, not the shape, establishes which marker is the player.
        """
        image = self.capture()
        scale = image.shape[1] / REF_SIDE
        px, py = pixel_point(image, float(x), float(y))
        reach = float(radius) / (GRID - 1) * (image.shape[1] - 1)
        best = None
        for blob in white_blobs(image)[0]:
            if is_heart(blob, scale) or blob["area"] > 105 * scale * scale:
                continue
            distance = np.hypot(blob["x"] - px, blob["y"] - py)
            if distance <= reach and (best is None or distance < best[0]):
                best = (distance, blob)
        if best is None:
            return None
        blob = best[1]
        gx, gy = grid_point(image, blob["x"], blob["y"])
        return {"player": "%.2f,%.2f" % (gx, gy), "area": blob["area"]}

    def debug(self, *path):
        image = self.capture().copy()
        route, white, _ = masks(image)
        image[route] = (image[route] * 0.4 + np.array([255, 0, 255]) * 0.6).astype(np.uint8)
        heart, arrows, _ = markers(image, white)
        if heart:
            cv2.circle(image, (int(heart["x"]), int(heart["y"])), 12, (0, 0, 255), 2)
        for arrow in arrows:
            cv2.circle(image, (int(arrow["x"]), int(arrow["y"])), 9, (255, 160, 0), 2)
        cv2.imwrite(" ".join(path), image)
        return {"saved": " ".join(path)}


class World:
    """The illuminated in-game path (toggled with the top-right P button).

    It is a band of lime chevrons and rails with cyan flow arrows. Following it
    keeps the player on ground that is clear of obstacles, and units are
    placed just outside it. The player is at the centre of the overhead view.
    Work is done at half resolution; replies are full client pixels.
    """

    def __init__(self, vision):
        self.vision = vision
        self.static = None
        self.image = None
        self.area = None
        self.saved_view = None
        self.yellow_path = False
        # The path view read from the red overlay (pathview) and every red
        # no-place area in it; kept until the next read or match.
        self.view_area = None
        self.blocked = None

    def reset(self):
        """New match or a moved camera: forget the path view and colour."""
        self.yellow_path = False
        self.view_area = self.blocked = None
        return {"reset": 1}

    def hud_keep(self, height, width):
        """Play-area mask at (height, width): HUD and minimap excluded."""
        keep = np.ones((height, width), np.uint8)
        keep[: int(height * 0.23)] = 0  # Vote controls and top HUD.
        keep[int(height * 0.81):] = 0  # Bottom unit bar.
        keep[int(height * 0.73):, int(width * 0.78):] = 0  # Minimap.
        keep[:int(height * 0.73), int(width * 0.80):] = 0  # Party/modifier HUD.
        if self.vision.box is not None and self.vision.static is None:
            left, top, box_w, box_h = self.vision.box
            keep[max(0, top // 2 - 4):(top + box_h) // 2 + 4, max(0, left // 2 - 4):(left + box_w) // 2 + 4] = 0
        return keep

    def path_view(self, cx, cy, cw, ch):
        """Read the road from the red overlay while a unit is held.

        Stores the road band as the path for every later placement command
        and the red areas as places never to click. The unselected baseline
        image (self.image, used by hillspots and camera shifts) is unchanged.
        """
        image = self.grab(cx, cy, cw, ch)
        if not ScreenSource.usable(image, image.shape[1], image.shape[0]):
            raise RuntimeError("path view capture is blank")
        small = cv2.resize(image, (image.shape[1] // 2, image.shape[0] // 2), interpolation=cv2.INTER_AREA)
        path, blocked = red_overlay(small, self.hud_keep(*small.shape[:2]))
        self.failed_image = None
        if not path.any():
            self.failed_image = image
            return {"path": 0, "on": 0}
        self.view_area, self.blocked, self.view_image = path, blocked, image
        self.area = path
        centre = self.centre()
        return {"path": int(path.sum() * 4), "on": int(self.near_path(*centre, radius=path.shape[1] * 0.02))}

    def path_debug(self, *path):
        """Save the last path view: road magenta, other red no-place blue,
        player centre white."""
        if self.view_area is None or getattr(self, "view_image", None) is None:
            return {"saved": 0}
        image = self.view_image
        small = cv2.resize(image, (image.shape[1] // 2, image.shape[0] // 2), interpolation=cv2.INTER_AREA)
        other = self.blocked & (self.view_area == 0)
        small[other] = (small[other] * 0.4 + np.array([255, 0, 0]) * 0.6).astype(np.uint8)
        road = self.view_area > 0
        small[road] = (small[road] * 0.2 + np.array([255, 0, 255]) * 0.8).astype(np.uint8)
        cv2.circle(small, tuple(int(v) for v in self.centre()), 5, (255, 255, 255), 2)
        cv2.imwrite(" ".join(path), small)
        return {"saved": 1}

    def clear_view(self):
        """Forget the red path view so the next world read is the lit path
        (P path first; the red overlay is only the fallback)."""
        self.view_area = self.blocked = None
        return {"cleared": 1}

    def path_fail_debug(self, *path):
        """Save the raw frame of the last red read that found no road."""
        if getattr(self, "failed_image", None) is None:
            return {"saved": 0}
        cv2.imwrite(" ".join(path), self.failed_image)
        return {"saved": 1}

    def on_red(self, x, y):
        """True where the last path view showed red (half-size coordinates)."""
        return (self.blocked is not None and 0 <= y < self.blocked.shape[0]
                and 0 <= x < self.blocked.shape[1] and bool(self.blocked[y, x]))

    def grab(self, cx, cy, cw, ch):
        if self.static is not None:
            return self.static
        if self.vision.screen is None:
            self.vision.screen = ScreenSource()
        return self.vision.screen.grab(int(float(cx)), int(float(cy)), int(float(cw)), int(float(ch)))

    def load(self, *path):
        self.static = read_image(" ".join(path))
        return {"size": "%d,%d" % (self.static.shape[1], self.static.shape[0])}

    def toolbar_fixed(self, cx, cy, cw, ch, px, py):
        """Read the saved P coordinate's brightness; never search for a glyph."""
        image = self.grab(cx, cy, cw, ch)
        height, width = image.shape[:2]
        scale = width / 1379.0
        px, py = float(px), float(py)

        def ink_level(x):
            x0, x1 = max(0, int(x-9*scale)), min(width, int(x+9*scale)+1)
            y0, y1 = max(0, int(py-12*scale)), min(height, int(py+12*scale)+1)
            patch = image[y0:y1, x0:x1].astype(np.int16)
            if not patch.size:
                return None
            bright, dull = patch.max(axis=2), patch.min(axis=2)
            pixels = bright[(bright >= 60) & (bright-dull < 45)]
            return float(np.median(pixels)) if len(pixels) >= 4 else None

        toggle, info = ink_level(px), ink_level(px+38*scale)
        if toggle is None or info is None:
            return None
        return {"p": "%d,%d" % (px, py), "on": int(toggle > info+50),
                "levels": "%d,%d" % (toggle, info)}

    def toolbar(self, cx, cy, cw, ch):
        """P, i, FX and heart sit in one pill at the top right. The i and FX
        glyphs are always grey, so P is lit when clearly brighter than i."""
        image = self.grab(cx, cy, cw, ch)
        height, width = image.shape[:2]
        left, bottom = int(width * 0.75), max(20, int(height * 0.08))
        region = image[:bottom, left:].astype(np.int16)
        bright, dull = region.max(axis=2), region.min(axis=2)
        glyph = (bright >= 60) & (bright - dull < 45)
        count, labels, stats, centres = cv2.connectedComponentsWithStats(glyph.astype(np.uint8), 8)
        scale = width / 1379.0
        glyphs = []
        for index in range(1, count):
            x, y, w, h, area = stats[index]
            if area >= 40 * scale * scale and 6 * scale <= h <= 30 * scale and w <= 32 * scale:
                component = (labels[y:y+h, x:x+w] == index).astype(np.uint8)
                contours, hierarchy = cv2.findContours(component, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE)
                # P has an upper bowl/hole and an empty lower-right corner.
                # The circled information i has a filled lower-right arc.
                upper_hole = False
                if hierarchy is not None:
                    for ci, contour in enumerate(contours):
                        if hierarchy[0, ci, 3] < 0:
                            continue
                        moments = cv2.moments(contour)
                        if moments["m00"] >= 2 * scale * scale and moments["m01"] / moments["m00"] < h * 0.6:
                            upper_hole = True
                is_p = upper_hole and component[int(h * 0.7):, int(w * 0.6):].mean() < 0.2
                glyphs.append({"x": float(centres[index][0]) + left, "y": float(centres[index][1]),
                               "level": float(bright[labels == index].mean()), "is_p": is_p})
        # The pill's glyphs share a row; take the rightmost row of four or
        # more (FX can split into separate F and X pieces).
        rows = []
        for item in sorted(glyphs, key=lambda glyph: -glyph["x"]):
            for row in rows:
                if abs(row[0]["y"] - item["y"]) <= 8 * scale:
                    row.append(item)
                    break
            else:
                rows.append([item])
        rows = [row for row in rows if len(row) >= 4]
        if not rows:
            return None
        row = max(rows, key=lambda row: row[0]["x"])
        # The heart is rightmost and P is the leftmost glyph of the pill, about
        # 120 px left of the heart at 1379 wide; i is the next glyph after P.
        pill = sorted((item for item in row if item["x"] >= row[0]["x"] - width * 0.11), key=lambda item: item["x"])
        if len(pill) < 4:
            return None
        toggle, info = pill[0], pill[1]
        if not toggle["is_p"] or not (25 * scale <= info["x"] - toggle["x"] <= 52 * scale):
            return None  # Never substitute the circled i if P is missing.
        lit = toggle["level"] > info["level"] + 50
        return {"p": "%d,%d" % (toggle["x"], toggle["y"]), "on": 1 if lit else 0,
                "levels": "%d,%d" % (toggle["level"], info["level"])}

    def world(self, cx, cy, cw, ch):
        image = self.grab(cx, cy, cw, ch)
        if not ScreenSource.usable(image, image.shape[1], image.shape[0]):
            self.image = self.area = None
            raise RuntimeError("world capture is blank; recover capture before placing or moving")
        self.image = image
        small = cv2.resize(image, (image.shape[1] // 2, image.shape[0] // 2), interpolation=cv2.INTER_AREA)
        hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
        h, s, v = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]
        # World lighting can make the route fully saturated yellow-green.
        # Exclude HUD locations spatially instead of excluding those path hues.
        lime = (h >= 32) & (h <= 76) & (s >= 90) & (v >= 170)
        arrow = (h >= 84) & (h <= 96) & (s >= 90) & (s <= 160) & (v >= 225)
        height, width = h.shape
        keep = np.ones((height, width), np.uint8)
        keep[: int(height * 0.23)] = 0  # Vote controls and top HUD.
        keep[int(height * 0.81):] = 0  # Bottom unit bar.
        keep[int(height * 0.73):, int(width * 0.78):] = 0  # Minimap.
        keep[:int(height * 0.73), int(width * 0.80):] = 0  # Party/modifier HUD.
        if self.vision.box is not None and self.vision.static is None:
            left, top, box_w, box_h = self.vision.box
            keep[max(0, top // 2 - 4):(top + box_h) // 2 + 4, max(0, left // 2 - 4):(left + box_w) // 2 + 4] = 0
        # Sand-tinted maps (Sand Village) light the path pure yellow, hue
        # 28-31, instead of lime; the sand stays at hue 17-23. Yellow counts
        # only when it outweighs lime in the play area, so yellow HUD text and
        # unit effects never add to a lime path on other maps.
        yellow = (h >= 27) & (h < 32) & (s >= 100) & (v >= 220) & (keep > 0)
        # The yellow Weather Alert banner sits just above the unit bar; units
        # are never placed that low, so yellow there is never path.
        yellow[int(height * 0.74):] = False
        lime_n, yellow_n = np.count_nonzero(lime & (keep > 0)), np.count_nonzero(yellow)
        # Once a frame clearly shows a yellow path, the rest of the match keeps
        # yellow only: green Hill highlights (shown while a Hill/Hybrid unit is
        # selected), green crate lids and unit effects then never become path.
        # "worldreset" clears this at each match start.
        if not self.yellow_path and yellow_n >= height * width * 0.008 and yellow_n > 3 * lime_n:
            self.yellow_path = True
        if self.yellow_path:
            lime = yellow
        elif yellow_n > 2 * lime_n:
            lime = lime | yellow
        mask = (lime | arrow).astype(np.uint8) & keep
        # Cyan alone (unit rings, scenery) cannot establish a road. Preserve
        # the visible lime evidence before closing/filling gaps in the band.
        evidence = (lime & (mask > 0)).astype(np.uint8)
        # Chevrons and rails close into one solid band.
        size = max(5, int(width * 0.025)) | 1
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (size, size)))
        count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
        area = np.zeros_like(mask)
        minimum = (width * 0.04) ** 2
        for index in range(1, count):
            if stats[index][4] >= minimum:
                area[labels == index] = 1
        # Dark gaps between chevrons and the player's own body are enclosed
        # by the band: anything not reachable from the screen edge is path.
        outside = np.pad(1 - area, 1, constant_values=1).astype(np.uint8)
        cv2.floodFill(outside, None, (0, 0), 2)
        area[outside[1:-1, 1:-1] == 1] = 1
        support_distance = cv2.distanceTransform(1-evidence, cv2.DIST_L2, 5)
        area[support_distance > width*0.025] = 0
        # A path view from the red overlay is the path: an unselected frame
        # only refreshes the baseline image.
        if self.view_area is not None:
            area = self.view_area
        self.area = area
        centre = self.centre()
        return {"path": int(area.sum() * 4), "on": int(self.near_path(*centre, radius=width * 0.02))}

    def centre(self):
        height, width = self.area.shape
        return width / 2.0, height / 2.0

    @staticmethod
    def in_placement_area(x, y):
        distance = (x-400)**2+(y-300)**2
        return (x>=70)&(x<=730)&(y>=145)&(y<=475)&(distance>=28**2)&(distance<=180**2)

    def remember_view(self):
        self.saved_view = None if self.image is None else self.image.copy()
        return {"saved": int(self.saved_view is not None)}

    def view_shift(self, cx, cy, cw, ch):
        """Measure camera translation using stationary scenery, excluding HUD."""
        before, after = self.saved_view, self.grab(cx, cy, cw, ch)
        if before is None or before.shape != after.shape or not ScreenSource.usable(after,after.shape[1],after.shape[0]):
            return None
        h,w = before.shape[:2]
        size = (w//2,h//2)
        a = cv2.cvtColor(cv2.resize(before,size),cv2.COLOR_BGR2GRAY)
        b = cv2.cvtColor(cv2.resize(after,size),cv2.COLOR_BGR2GRAY)
        mask = np.zeros_like(a)
        mask[int(h*.24/2):int(h*.73/2),int(w*.05/2):int(w*.78/2)] = 255
        points = cv2.goodFeaturesToTrack(a,250,0.02,8,mask=mask)
        if points is None or len(points)<15:
            return None
        top,bottom,left,right = int(h*.24/2),int(h*.73/2),int(w*.05/2),int(w*.78/2)
        crop_a,crop_b = a[top:bottom,left:right],b[top:bottom,left:right]
        offset,response = cv2.phaseCorrelate(crop_a.astype(np.float32),crop_b.astype(np.float32))
        initial = points+np.float32(offset) if response>.2 else None
        tracked,status,_ = cv2.calcOpticalFlowPyrLK(a,b,points,initial,winSize=(31,31),maxLevel=4,
                            flags=cv2.OPTFLOW_USE_INITIAL_FLOW if initial is not None else 0)
        if tracked is None or status is None:
            return None
        good = status.ravel()>0
        if good.sum()<15:
            return None
        transform,inliers = cv2.estimateAffinePartial2D(points[good],tracked[good],method=cv2.RANSAC,ransacReprojThreshold=2)
        if transform is None or inliers.sum()<15 or inliers.mean()<0.6:
            return None
        if abs(np.hypot(transform[0,0],transform[1,0])-1)>.015 or abs(transform[1,0])>.015:
            return None
        dx,dy = transform[0,2]*2*800/w,transform[1,2]*2*600/h
        return {"dx":"%.3f"%dx,"dy":"%.3f"%dy}

    def card_boxes(self, cx, cy, cw, ch):
        """X spans of the three card interiors (800x600 reference)."""
        boxes = card_boxes(self.grab(cx, cy, cw, ch))
        if not boxes:
            return {"found": 0}
        return {"found": 1, "boxes": ";".join("%d,%d" % b for b in boxes)}

    def unit_manager(self, cx, cy, cw, ch):
        """Locate manager portraits, avoiding sell X and upgrade/target buttons."""
        image = self.grab(cx,cy,cw,ch)
        h,w = image.shape[:2]
        b,g,r = cv2.split(image.astype(np.int16))
        title = ((r>160)&(g>125)&(b<110)).astype(np.uint8)
        title[:int(h*.065)]=0;title[int(h*.17):]=0;title[:,:int(w*.66)]=0
        title=cv2.morphologyEx(title,cv2.MORPH_CLOSE,np.ones((3,max(3,int(w*.025))),np.uint8))
        _,_,stats,_=cv2.connectedComponentsWithStats(title,8)
        # The "Unit Overview" heading is a thin line of text on the manager's
        # dark panel. Bright yellow scenery in the same corner (Sand Village's
        # path) is a tall blob on a bright background and is not a heading.
        def on_dark_panel(s):
            box=image[max(0,s[1]-int(h*.01)):s[1]+s[3]+int(h*.01),s[0]:s[0]+s[2]]
            return box.size>0 and (np.max(box,axis=2)<85).mean()>=.35
        headings=[s for s in stats[1:] if s[2]>w*.18 and h*.015<s[3]<h*.07 and on_dark_panel(s)]
        if not headings:return {"open":0}
        heading=max(headings,key=lambda s:s[1])
        top=int(heading[1]+heading[3]+h*.02);bottom=int(h*.735)
        # Sell-X backgrounds anchor every cell even if Upgrade is disabled/MAX.
        # These controls are detected only; the returned click is in the portrait.
        icons=((r>140)&(r-g>45)&(r-b>30)).astype(np.uint8)
        icons[:top]=0;icons[bottom:]=0;icons[:,:int(w*.66)]=0
        kernel=max(3,int(round(h*.005)))|1
        icons=cv2.morphologyEx(icons,cv2.MORPH_OPEN,np.ones((kernel,kernel),np.uint8))
        icons=cv2.morphologyEx(icons,cv2.MORPH_CLOSE,np.ones((3,3),np.uint8))
        _,_,stats,_=cv2.connectedComponentsWithStats(icons,8)
        buttons=[s for s in stats[1:] if w*.012<s[2]<w*.05 and h*.016<s[3]<h*.065 and .6<s[2]/s[3]<1.7 and s[4]/(s[2]*s[3])>.4]
        dark=np.max(image[top:bottom,int(w*.66):],axis=2)<85
        if not buttons or not dark.size or dark.mean()<.35:return {"open":1,"ready":0}
        bw=float(np.median([s[2] for s in buttons]));bh=float(np.median([s[3] for s in buttons]))
        rows=[]
        for s in sorted(buttons,key=lambda s:s[1]):
            if not rows or abs(s[1]-np.mean([b[1] for b in rows[-1]]))>bh*.6:rows.append([])
            rows[-1].append(s)
        row_y=[float(np.median([s[1] for s in row])) for row in rows]
        pitch=float(np.median(np.diff(row_y))) if len(row_y)>1 else h*.158
        hsv=cv2.cvtColor(image,cv2.COLOR_BGR2HSV)
        entries=[]
        for ry,row in zip(row_y,rows):
            for x,y,bwidth,bheight,_ in sorted(row,key=lambda s:s[0]):
                px=float(x)+bw*1.4;py=float(y)+bh*2.3
                if py-bh*.6<top or py+bh*.6>bottom:continue
                column=int(x+bwidth/2>w*.76)
                tile=self.manager_tile(hsv,float(x),float(y),bw,bh,pitch,top,bottom)
                entries.append((column,px,py,ry)+tile)
        signature="empty"
        if entries:
            col,px,py=entries[0][:3]
            patch=image[max(top,int(py-bh*.6)):min(bottom,int(py+bh*.6)),int(px-bw*.2):int(px+bw*.2)]
            if patch.size:signature=str(hash((cv2.resize(patch,(12,12))//32).tobytes()))
        # The newest unit is top-left and #1 is in the bottom row; with an odd
        # unit count that bottom row holds one tile, on the LEFT.
        lastcount=sum(1 for e in entries if abs(e[3]-row_y[-1])<1)
        return {"open":1,"ready":1,"top":top,"bottom":bottom,"pitch":"%.3f"%pitch,
                "first":"%.3f"%row_y[0],"last":"%.3f"%row_y[-1],"lastcount":lastcount,"signature":signature,
                "entries":";".join("%d,%.2f,%.2f,%.2f,%d,%d,%d,%.2f,%.2f,%s"%e for e in entries)}

    @staticmethod
    def manager_tile(hsv, x, y, bw, bh, pitch, top, bottom):
        """Upgrade segments, MAX button, Upg click point and portrait colours of
        the manager cell whose sell X is at (x, y). Unreadable bars give -1.

        Every segment has a saturated green/yellow body. Done segments are
        bright (V about 230); not-done segments are dark (V about 80), with or
        without a white outline. Colour (green vs yellow) means nothing."""
        h,w=hsv.shape[:2]
        hue,sat,val=hsv[:,:,0].astype(np.int16),hsv[:,:,1].astype(np.int16),hsv[:,:,2].astype(np.int16)
        filled=total=-1
        # Below the First button, above the next row's sell X.
        y0,y1=int(y+bh*3.3),min(h,int(y+pitch*.95))
        x0,x1=int(x+bw*.3),min(w,int(x+bw*5.4))
        if y1>y0 and x1-x0>bw*3:
            xs=slice(x0,x1)
            body=(sat[y0:y1,xs]>=100)&(val[y0:y1,xs]>=50)&(hue[y0:y1,xs]>=15)&(hue[y0:y1,xs]<=85)
            counts=body.sum(axis=1)
            if counts.max()>=(x1-x0)*.5:
                # The bar is the contiguous band of rows around the strongest one.
                peak=int(np.argmax(counts));a=b=peak
                while a>0 and counts[a-1]>=counts[peak]*.5:a-=1
                while b<len(counts)-1 and counts[b+1]>=counts[peak]*.5:b+=1
                if y0+b<bottom and b-a+1<=bh*.6:
                    band=body[a:b+1];bright=val[y0+a:y0+b+1,xs]
                    cols=band.mean(axis=0)
                    runs=[];start=None
                    for i,v in enumerate(list(cols)+[0]):
                        if v>.5 and start is None:start=i
                        elif v<=.5 and start is not None:
                            if i-start>=bw*.15:runs.append((start,i))
                            start=None
                    if runs:
                        width=float(np.median([e-s for s,e in runs]))
                        segments=[]
                        for s,e in runs:
                            parts=max(1,int(round((e-s)/width))) if e-s>width*1.6 else 1
                            for k in range(parts):
                                ps=s+(e-s)*k//parts;pe=s+(e-s)*(k+1)//parts
                                v=bright[:,ps:pe][band[:,ps:pe]]
                                segments.append(bool(v.size) and float(np.median(v))>=150)
                        if 1<=len(segments)<=20:
                            total=len(segments);filled=sum(segments)
        # MAX is the word on the button: a grey button whose text is short
        # ("Max", about 0.56 of the button) rather than "Upg: 7500" (0.9-1.0,
        # even when dimmed because the next upgrade is unaffordable).
        bx0,bx1=int(x+bw*2.95),min(w,int(x+bw*4.75));by0,by1=int(y+bh*1.25),int(y+bh*1.85)
        maxed=0
        if by0>=top and by1<=bottom and bx1>bx0:
            ys,xs=slice(by0,by1),slice(bx0,bx1)
            colour=((sat[ys,xs]>=110)&(val[ys,xs]>=90)&(hue[ys,xs]>=15)&(hue[ys,xs]<=85)).mean()
            v=val[ys,xs];text=v>np.median(v)+35
            cols=np.nonzero(text.sum(axis=0)>=2)[0]
            span=(cols[-1]-cols[0]+1)/float(bx1-bx0) if cols.size>=10 else 1.0
            maxed=int(colour<.10 and span<.75)
        ux,uy=x+bw*3.85,y+bh*1.55
        # Portrait colours below the Lv label and above the name label:
        # 12 hue bins of coloured pixels, then dark and neutral-light shares.
        sig="-"
        px0,px1,py0,py1=int(x+bw*.55),int(x+bw*2.05),int(y+bh*1.6),int(y+bh*3.0)
        if py0>=top and py1<=bottom:
            ph,ps,pv=hue[py0:py1,px0:px1],sat[py0:py1,px0:px1],val[py0:py1,px0:px1]
            n=float(ph.size) or 1.0
            coloured=(ps>=70)&(pv>=60)
            bins=np.bincount((ph[coloured]*12//180).ravel(),minlength=12)[:12]
            parts=[int(round(100*v/n)) for v in bins]
            parts.append(int(round(100*(pv<60).sum()/n)))
            parts.append(int(round(100*((ps<70)&(pv>=60)).sum()/n)))
            sig=".".join(str(v) for v in parts)
        return (filled,total,maxed,ux,uy,sig)

    def relocation(self, hint_x=0, hint_y=1):
        """A connected road waypoint downstream; AHK repeats it until relocated."""
        if self.area is None or not self.area.any():
            return None
        h,w = self.area.shape
        road = cv2.resize(self.area.astype(np.uint8),(100,75),interpolation=cv2.INTER_NEAREST)
        ys,xs = np.nonzero(road)
        if not len(xs):
            return None
        nearest = int(np.argmin((xs*8-400)**2+(ys*8-300)**2))
        start = (int(xs[nearest]),int(ys[nearest]))
        direction = np.asarray([float(hint_x),float(hint_y)],float)
        norm = np.linalg.norm(direction)
        direction = direction/norm if norm else np.array([0.,1.])
        clearance = cv2.distanceTransform(road,cv2.DIST_L2,5)
        queue,parents,steps = [start],{start:None},{start:0}
        head,best,best_score = 0,None,-float('inf')
        while head<len(queue):
            point=queue[head];head+=1
            x,y=point;offset=np.array([x*8-400,y*8-300],float)
            distance=float(np.linalg.norm(offset));progress=float(offset@direction)
            if 65<=distance<=110 and progress>10 and 150<=y*8<=460:
                score=progress-abs(distance-85)*.6+float(clearance[y,x])*2
                if score>best_score:best,best_score=point,score
            if steps[point]>=20:continue
            for dx,dy in [(0,1),(1,0),(-1,0),(0,-1)]:
                nxt=(x+dx,y+dy)
                if (0<=nxt[0]<100 and 0<=nxt[1]<75 and road[nxt[1],nxt[0]] and nxt not in parents):
                    parents[nxt]=point;steps[nxt]=steps[point]+1;queue.append(nxt)
        if best is None:return None
        route=[];point=best
        while point is not None:
            route.append(point);point=parents[point]
        route.reverse()
        # Aim only at a nearby waypoint on this connected route, never across a bend.
        waypoint=route[min(4,len(route)-1)]
        return {"dx":"%.2f"%(waypoint[0]*8-400),"dy":"%.2f"%(waypoint[1]*8-300),
                "destination":"%d,%d"%(best[0]*8,best[1]*8)}

    def near_path(self, x, y, radius=0.0):
        height, width = self.area.shape
        x0, x1 = int(max(0, x - radius)), int(min(width, x + radius + 1))
        y0, y1 = int(max(0, y - radius)), int(min(height, y + radius + 1))
        return bool(self.area[y0:y1, x0:x1].any()) if x1 > x0 and y1 > y0 else False

    def follow(self, dx, dy):
        """Where the band crosses a circle around the player, in the crossing
        best aligned with the wanted direction: walking there stays on the
        lit path, and leads back onto it when the player is beside it."""
        if self.area is None:
            raise ValueError("send world first")
        dx, dy = float(dx), float(dy)
        length = np.hypot(dx, dy)
        if length < 1e-6:
            return None
        dx, dy = dx / length, dy / length
        height, width = self.area.shape
        cx, cy = self.centre()
        for radius in (width * 0.08, width * 0.05, width * 0.13):
            angles = np.linspace(0, 2 * np.pi, 180, endpoint=False)
            xs = np.clip((cx + np.cos(angles) * radius).astype(int), 0, width - 1)
            ys = np.clip((cy + np.sin(angles) * radius).astype(int), 0, height - 1)
            inside = self.area[ys, xs] > 0
            if not inside.any() or inside.all():
                continue
            # Rotate so index 0 is outside; then crossings are plain runs.
            shift = int(np.argmin(inside))
            inside, angles = np.roll(inside, -shift), np.roll(angles, -shift)
            best = None
            start = None
            for index in range(len(inside) + 1):
                if index < len(inside) and inside[index]:
                    start = index if start is None else start
                elif start is not None:
                    middle = np.angle(np.exp(1j * angles[start:index]).mean())
                    score = np.cos(middle) * dx + np.sin(middle) * dy
                    if best is None or score > best[0]:
                        best = (score, middle)
                    start = None
            if best and best[0] > 0.2:
                x, y = cx + np.cos(best[1]) * radius, cy + np.sin(best[1]) * radius
                return {"point": "%d,%d" % (x * 2, y * 2), "on": int(self.near_path(cx, cy, width * 0.02)),
                        "near": int(self.near_path(cx, cy, width * 0.06)), "align": "%.2f" % best[0]}
        return None

    def beside(self, count=12):
        """Points 1.2-4% of the width outside the band, near the player and
        clear of the screen-edge UI, nearest first and spread apart."""
        if self.area is None:
            raise ValueError("send world first")
        height, width = self.area.shape
        distance = cv2.distanceTransform((1 - self.area).astype(np.uint8), cv2.DIST_L2, 5)
        band = (distance >= width * 0.012) & (distance <= width * 0.04)
        cx, cy = self.centre()
        ys, xs = np.mgrid[0:height, 0:width]
        reach = ((xs - cx) / (width * 0.22)) ** 2 + ((ys - cy) / (height * 0.24)) ** 2 <= 1
        # The player's body hides the path under it; never place on the player.
        reach &= (xs - cx) ** 2 + (ys - cy) ** 2 >= (width * 0.045) ** 2
        ys, xs = np.nonzero(band & reach)
        order = np.argsort((xs - cx) ** 2 + (ys - cy) ** 2)
        chosen, spacing = [], (width * 0.03) ** 2
        for index in order:
            x, y = xs[index], ys[index]
            if all((x - ox) ** 2 + (y - oy) ** 2 >= spacing for ox, oy in chosen):
                chosen.append((x, y))
                if len(chosen) >= int(count):
                    break
        return {"count": len(chosen), "points": ";".join("%d,%d" % (x * 2, y * 2) for x, y in chosen)}

    def placement_geometry(self, chosen, valid_mask=None):
        """Outward normals and verified points across the same visible road."""
        height,width = self.area.shape
        sx,sy = 800.0/width,600.0/height
        distance,labels = cv2.distanceTransformWithLabels((1-self.area).astype(np.uint8),cv2.DIST_L2,5,labelType=cv2.DIST_LABEL_PIXEL)
        ys,xs = np.nonzero(self.area)
        if not len(xs):
            return {"normals":"","opposites":""}
        lookup_x=np.zeros(int(labels.max())+1,np.int32);lookup_y=lookup_x.copy()
        lookup_x[labels[ys,xs]]=xs;lookup_y[labels[ys,xs]]=ys
        normals,opposites=[],[]
        for px,py in chosen:
            x,y=int(px),int(py);label=labels[y,x]
            bx,by=int(lookup_x[label]),int(lookup_y[label])
            nx,ny=(x-bx)*sx,(y-by)*sy;length=float(np.hypot(nx,ny))
            if length<1:
                normals.append("0,0");opposites.append("-");continue
            nx,ny=nx/length,ny/length
            normals.append("%.4f,%.4f"%(nx,ny))
            last=(bx,by);crossed=False;opposite=None
            # Trace inward across the road. Use its opposite boundary, never
            # a reflected unit coordinate or unrelated distant terrain.
            for step in range(2,162,2):
                ox=int(round(bx-nx*step/sx));oy=int(round(by-ny*step/sy))
                if not (0<=ox<width and 0<=oy<height):break
                if self.area[oy,ox]:
                    crossed=True;last=(ox,oy);continue
                if crossed and step>=8:
                    tx=int(round(last[0]-nx*12/sx));ty=int(round(last[1]-ny*12/sy))
                    if not (0<=tx<width and 0<=ty<height):break
                    rx,ry=tx*sx,ty*sy;dx,dy=rx-400,ry-300
                    if (self.in_placement_area(rx,ry)
                            and 8<=distance[ty,tx]*sx<=18
                            and (valid_mask is None or valid_mask[ty,tx])):
                        opposite=(tx,ty)
                break
            opposites.append("%d,%d"%(opposite[0]*2,opposite[1]*2) if opposite else "-")
        return {"normals":";".join(normals),"opposites":";".join(opposites)}

    def placement_line(self, count=48, rejected="-", occupied="-", blocked_edges="-", ux="0", uy="0"):
        """One continuous lane outside the path, beginning near the player.

        Follow one boundary in one direction; never sort unrelated ground
        points together or jump between the two sides of the road.
        """
        if self.area is None:
            raise ValueError("send world first")
        height, width = self.area.shape
        if not self.area.any():
            return None
        sx, sy = 800.0 / width, 600.0 / height
        cx, cy = self.centre()
        gap = max(2, int(round(12.0 / sx)))
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (gap * 2 + 1, gap * 2 + 1))
        outside_edge = cv2.dilate(self.area.astype(np.uint8), kernel)
        contours, _ = cv2.findContours(outside_edge, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        distance = cv2.distanceTransform((1 - self.area).astype(np.uint8), cv2.DIST_L2, 5)

        excluded = np.zeros_like(self.area,np.uint8)
        for text,radius in [(rejected,28.0),(occupied,24.0)]:
            if not text or text=="-":continue
            for item in text.split(";"):
                rx,ry=map(float,item.split(","))
                cv2.ellipse(excluded,(int(round(rx/sx)),int(round(ry/sy))),
                    (max(1,int(np.ceil(radius/sx))),max(1,int(np.ceil(radius/sy)))),0,0,360,1,-1)

        if blocked_edges and blocked_edges!="-":
            for item in blocked_edges.split(";"):
                rx,ry,nx,ny=map(float,item.split(","))
                corners=[]
                for normal,along in [(-80,-48),(-80,48),(80,48),(80,-48)]:
                    corners.append((int(round((rx+normal*nx-along*ny)/sx)),int(round((ry+normal*ny+along*nx)/sy))))
                # Mask only points with the same outward-facing edge normal.
                # The opposite edge stays available even in this rectangle.
                road_y,road_x=np.nonzero(self.area)
                if len(road_x):
                    _,labels=cv2.distanceTransformWithLabels((1-self.area).astype(np.uint8),cv2.DIST_L2,5,labelType=cv2.DIST_LABEL_PIXEL)
                    lx=np.zeros(int(labels.max())+1,np.int32);ly=lx.copy()
                    lx[labels[road_y,road_x]]=road_x;ly[labels[road_y,road_x]]=road_y
                    yy,xx=np.indices(self.area.shape)
                    dx=(xx-lx[labels])*sx;dy=(yy-ly[labels])*sy
                    lengths=np.hypot(dx,dy)
                    same=(dx*nx+dy*ny)>0.3*np.maximum(lengths,1)
                    section=np.zeros_like(excluded)
                    cv2.fillConvexPoly(section,np.array(corners,np.int32),1)
                    excluded[(section>0)&same]=1

        def allowed(point):
            x, y = (int(value) for value in point)
            rx, ry = x * sx, y * sy
            dx, dy = (x - cx) * sx, (y - cy) * sy
            return (not excluded[y,x] and self.in_placement_area(rx,ry) and not self.on_red(x, y)
                    and 8 <= float(distance[y, x]) * sx <= 18)

        candidates = []
        for contour in contours:
            points = contour[:, 0, :]
            for index in range(0, len(points), 3):
                point = points[index]
                if not allowed(point):
                    continue
                dx, dy = (point[0] - cx) * sx, (point[1] - cy) * sy
                score = float(dx * dx + dy * dy)
                candidates.append((score, points, index))
        candidates.sort(key=lambda item: item[0])
        if not candidates:
            return None
        limit = max(1, min(96, int(count)))

        def walk(contour, start, direction):
            result = [contour[start].astype(float)]
            arc = 0.0
            previous = contour[start]
            for offset in range(1, len(contour)):
                point = contour[(start + direction * offset) % len(contour)]
                if not allowed(point):
                    break  # Keep the local line continuous; no skipping gaps.
                arc += float(np.hypot((point[0] - previous[0]) * sx,
                                      (point[1] - previous[1]) * sy))
                previous = point
                if arc >= 12.0:
                    result.append(point.astype(float))
                    arc = 0.0
                    if len(result) >= limit:
                        break
            return result

        ux, uy = float(ux), float(uy)

        def along(line):
            ahead = line[min(3, len(line) - 1)] - line[0]
            return float(ahead[0] * sx * ux + ahead[1] * sy * uy)

        def direction_score(line):
            ahead = line[min(3, len(line) - 1)] - line[0]
            return (len(line) >= 8, float(ahead[1] * sy + ahead[0] * sx * 0.15), len(line))

        if ux or uy:
            # Front and behind lanes from ONE start, the free edge spot nearest
            # the player, running both ways along the same side of the road
            # (front = toward where the enemies come from). Separate starts
            # could sit on opposite sides of the road, and alternating between
            # them stacked edge + partner units on both sides in one place.
            # AHK starts with the emptier lane and then alternates.
            chosen = None
            for score, contour, start in candidates[:240]:
                ways = [walk(contour, start, 1), walk(contour, start, -1)]
                if chosen is None:
                    chosen = ways
                if len(ways[0]) + len(ways[1]) - 1 >= 3:
                    chosen = ways
                    break
            first, second = chosen
            if along(second) > along(first):
                first, second = second, first
            front, behind = first, second[1:]
            # From the end of a visible stretch the second walk wraps around
            # the road's end to its OTHER side and heads the same way as the
            # front lane: that is not a behind lane. The other side of the
            # road stays for when this side is used up.
            if along(second) >= 0:
                behind = []
            line = front + behind
            if not line:
                return None
            reply = {"count": len(line), "front": len(front), "points": ";".join("%d,%d" % (x * 2, y * 2) for x, y in line),
                     "player": "%d,%d" % (cx * 2, cy * 2)}
            reply.update(self.placement_geometry(line))
            return reply

        best = None
        for score, contour, start in candidates[:240]:
            line = max([walk(contour, start, 1), walk(contour, start, -1)], key=direction_score)
            # A short visible edge is usable too. Start with the nearest
            # continuous local edge instead of refusing to attempt placement.
            rank = (len(line) >= 3, -score, direction_score(line)[1], len(line))
            if best is None or rank > best[0]:
                best = (rank, line)
            if best[1] is line and len(line) >= 6:
                break
        if best is None:
            return None
        line = best[1]
        reply = {"count": len(line), "points": ";".join("%d,%d" % (x * 2, y * 2) for x, y in line),
                 "player": "%d,%d" % (cx * 2, cy * 2)}
        reply.update(self.placement_geometry(line))
        return reply

    def placement_neighbours(self, seeds, rejected="-", occupied="-", blocked_edges="-"):
        """One partner spot straight behind each confirmed first-row ground unit.

        All request coordinates are 800x600 reference coordinates. Replies
        use native client coordinates like placement_line. Never root another
        row in an outer-row seed or invent a spot without the visible road.
        """
        empty={"count":0,"points":""}
        if self.area is None or not self.area.any():return empty
        height,width=self.area.shape;sx,sy=800.0/width,600.0/height
        distance,labels=cv2.distanceTransformWithLabels((1-self.area).astype(np.uint8),cv2.DIST_L2,5,labelType=cv2.DIST_LABEL_PIXEL)
        ys,xs=np.nonzero(self.area)
        lx=np.zeros(int(labels.max())+1,np.int32);ly=lx.copy()
        lx[labels[ys,xs]]=xs;ly[labels[ys,xs]]=ys
        def pairs(text):
            return [] if not text or text=="-" else [tuple(map(float,p.split(","))) for p in text.split(";")]
        rejected_points=pairs(rejected);units=pairs(occupied);edges=pairs(blocked_edges)
        chosen=[]
        for rx,ry in pairs(seeds):
            x,y=int(round(rx/sx)),int(round(ry/sy))
            if not(0<=x<width and 0<=y<height) or not 8<=distance[y,x]*sx<=18:continue
            label=labels[y,x];nx,ny=(x-lx[label])*sx,(y-ly[label])*sy
            norm=float(np.hypot(nx,ny))
            if norm<1:continue
            nx,ny=nx/norm,ny/norm
            # One partner spot per edge unit: straight behind it, never beside.
            for along in [0]:
                qx,qy=rx+nx*28-ny*along,ry+ny*28+nx*along
                ix,iy=int(round(qx/sx)),int(round(qy/sy))
                if not(0<=ix<width and 0<=iy<height):continue
                qx,qy=ix*sx,iy*sy;dx,dy=qx-400,qy-300
                if not self.in_placement_area(qx,qy) or self.on_red(ix,iy):continue
                if not 22<=distance[iy,ix]*sx<=48:continue
                nearest=labels[iy,ix];ox,oy=(ix-lx[nearest])*sx,(iy-ly[nearest])*sy
                length=float(np.hypot(ox,oy))
                if length<1 or (ox*nx+oy*ny)/length<0.7:continue
                if any((qx-ax)**2+(qy-ay)**2<=28**2 for ax,ay in rejected_points):continue
                if any((qx-ax)**2+(qy-ay)**2<24**2 for ax,ay in units):continue
                if any((qx-ax)**2+(qy-ay)**2<20**2 for ax,ay in chosen):continue
                blocked=False
                for ax,ay,ex,ey in edges:
                    if (ox*ex+oy*ey)/length>0.3 and abs((qx-ax)*(-ey)+(qy-ay)*ex)<48 and abs((qx-ax)*ex+(qy-ay)*ey)<80:
                        blocked=True;break
                if not blocked:chosen.append((qx,qy))
        if not chosen:return empty
        native=[(int(round(x/sx)),int(round(y/sy))) for x,y in chosen]
        reply={"count":len(native),"points":";".join("%d,%d"%(x*2,y*2) for x,y in native)}
        reply.update(self.placement_geometry(native))
        return reply

    def hill_spots(self, count, cx, cy, cw, ch):
        """Prefer newly green terrain after selecting a Hill-marked slot.

        Keep the unselected world/path capture as the baseline: natural grass,
        the illuminated road and existing green UI do not count as highlights.
        """
        empty = {"count": 0, "points": ""}
        if self.area is None or self.image is None or not self.area.any():
            return empty
        height, width = self.area.shape
        current = self.grab(cx, cy, cw, ch)
        size = (width, height)
        before = cv2.resize(self.image, size, interpolation=cv2.INTER_AREA).astype(np.int16)
        after = cv2.resize(current, size, interpolation=cv2.INTER_AREA)
        hsv = cv2.cvtColor(after, cv2.COLOR_BGR2HSV)
        b, g, r = [after[:, :, i].astype(np.int16) for i in range(3)]
        fresh = ((g - before[:, :, 1] >= 22)
                 & ((g-r) - (before[:, :, 1]-before[:, :, 2]) >= 18))
        green = ((hsv[:, :, 0] >= 45) & (hsv[:, :, 0] <= 85)
                 & (hsv[:, :, 1] >= 100) & (hsv[:, :, 2] >= 170)
                 & (g-r >= 45) & (g-b >= 25) & fresh).astype(np.uint8)
        sx, sy = 800.0 / width, 600.0 / height
        green[:int(height*0.23)] = 0
        green[int(height*0.80):] = 0
        green[int(height*0.73):, int(width*0.78):] = 0
        green = cv2.morphologyEx(green, cv2.MORPH_CLOSE, np.ones((3,3),np.uint8))
        n, labels, stats, _ = cv2.connectedComponentsWithStats(green, 8)
        terrain = np.zeros_like(green)
        for label in range(1,n):
            if (stats[label,cv2.CC_STAT_AREA]*sx*sy >= 400
                    and stats[label,cv2.CC_STAT_WIDTH]*sx >= 16
                    and stats[label,cv2.CC_STAT_HEIGHT]*sy >= 16):
                terrain[labels==label] = 1
        # Stay inside the valid hill surface, away from its uncertain outline.
        inset = max(1, int(round(6.0/sx)))
        terrain = cv2.erode(terrain,cv2.getStructuringElement(cv2.MORPH_ELLIPSE,(2*inset+1,2*inset+1)))
        distance = cv2.distanceTransform((1-self.area).astype(np.uint8),cv2.DIST_L2,5)*sx
        ys,xs = np.nonzero(terrain)
        if not len(xs):
            return empty
        dx,dy = xs*sx-400,ys*sy-300
        valid = (self.in_placement_area(xs*sx,ys*sy)
                 & (distance[ys,xs]>=10))
        xs,ys,dx,dy = xs[valid],ys[valid],dx[valid],dy[valid]
        # Road proximity is primary; player proximity breaks ties.
        order = np.lexsort((dx*dx+dy*dy,distance[ys,xs]))
        chosen = []
        for i in order:
            x,y = int(xs[i]),int(ys[i])
            if all(((x-ox)*sx)**2+((y-oy)*sy)**2>=20**2 for ox,oy in chosen):
                chosen.append((x,y))
                if len(chosen)>=max(1,min(32,int(count))):
                    break
        reply={"count":len(chosen),"points":";".join("%d,%d"%(x*2,y*2) for x,y in chosen)}
        reply.update(self.placement_geometry(chosen,terrain))
        return reply

    def validate_placements(self, text):
        if self.area is None or not self.area.any():return {"match":0}
        height,width=self.area.shape
        distance=cv2.distanceTransform((1-self.area).astype(np.uint8),cv2.DIST_L2,5)
        records=[]
        for pair in text.split(";"):
            if not pair:continue
            rx,ry=map(float,pair.split(","));valid=bool(self.in_placement_area(rx,ry))
            x=min(width-1,max(0,int(rx*width/800)));y=min(height-1,max(0,int(ry*height/600)))
            gap=float(distance[y,x])*800/width
            records.append((rx,ry,gap,valid))
        anchors=[(x,y) for x,y,gap,valid in records if valid and 8<=gap<=18]
        valid_count=0
        for x,y,gap,valid in records:
            if valid and (8<=gap<=18 or (22<=gap<=48 and any(24**2<=(x-ax)**2+(y-ay)**2<=46**2 for ax,ay in anchors))):valid_count+=1
        return {"match":int(bool(records) and valid_count==len(records)),"valid":valid_count,"total":len(records)}

    def placement_valid(self, rx, ry, row=1, seeds="-"):
        """Recheck a pending click against the current unselected road view."""
        if self.area is None or not self.area.any():
            return {"valid": 0}
        height, width = self.area.shape
        rx, ry, row = float(rx), float(ry), int(row)
        if not self.in_placement_area(rx,ry):
            return {"valid": 0}
        distance = cv2.distanceTransform(1-self.area, cv2.DIST_L2, 5)*800/width

        def gap(x, y):
            ix, iy = int(x*width/800), int(y*height/600)
            return float(distance[iy, ix]) if 0 <= ix < width and 0 <= iy < height else float("inf")

        road_gap = gap(rx, ry)
        if self.on_red(int(rx*width/800), int(ry*height/600)):
            return {"valid": 0, "gap": "%.1f" % road_gap}
        valid = 8 <= road_gap <= 18
        if row == 2:
            anchors = [] if seeds == "-" else [tuple(map(float,p.split(","))) for p in seeds.split(";")]
            valid = (22 <= road_gap <= 48 and any(8 <= gap(x,y) <= 18
                     and 24**2 <= (rx-x)**2+(ry-y)**2 <= 46**2 for x,y in anchors))
        return {"valid": int(valid), "gap": "%.1f" % road_gap}

    def onpath(self, x, y):
        if self.area is None:
            raise ValueError("send world first")
        return {"on": int(self.near_path(float(x) / 2, float(y) / 2, self.area.shape[1] * 0.008))}

    def debug(self, *path):
        if self.image is None:
            raise ValueError("send world first")
        image = self.image.copy()
        area = cv2.resize(self.area, (image.shape[1], image.shape[0]), interpolation=cv2.INTER_NEAREST) > 0
        image[area] = (image[area] * 0.5 + np.array([255, 0, 255]) * 0.5).astype(np.uint8)
        cv2.ellipse(image,(image.shape[1]//2,image.shape[0]//2),
                    (int(180*image.shape[1]/800),int(180*image.shape[0]/600)),0,0,360,(0,200,255),2)
        for point in self.beside()["points"].split(";"):
            if point:
                x, y = (int(value) for value in point.split(","))
                cv2.circle(image, (x, y), 8, (0, 200, 255), 2)
        cv2.imwrite(" ".join(path), image)
        return {"saved": " ".join(path)}


WEBHOOK_PREFIXES = ("https://discord.com/api/webhooks/", "https://discordapp.com/api/webhooks/",
                    "https://ptb.discord.com/api/webhooks/", "https://canary.discord.com/api/webhooks/")


def send_discord(url, text, png, opener=urllib.request.urlopen):
    """One message with the screenshot attached, as multipart/form-data."""
    if not url.startswith(WEBHOOK_PREFIXES):
        raise ValueError("not a Discord webhook URL")
    boundary = "aapath" + uuid.uuid4().hex
    payload = json.dumps({"content": text, "attachments": [{"id": 0, "filename": "result.png"}]})
    body = b"".join([
        ("--%s\r\nContent-Disposition: form-data; name=\"payload_json\"\r\n"
         "Content-Type: application/json\r\n\r\n%s\r\n" % (boundary, payload)).encode("utf-8"),
        ("--%s\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"result.png\"\r\n"
         "Content-Type: image/png\r\n\r\n" % boundary).encode("utf-8"),
        png, ("\r\n--%s--\r\n" % boundary).encode("utf-8")])
    request = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "multipart/form-data; boundary=" + boundary,
        # Discord rejects requests without a descriptive User-Agent.
        "User-Agent": "DiscordBot (https://github.com/aapathmacro, 1.0)"})
    with opener(request, timeout=15) as response:
        return response.status


def discord(world, cx, cy, cw, ch, url, *words):
    image = world.grab(cx, cy, cw, ch)
    ok, png = cv2.imencode(".png", image)
    if not ok:
        raise ValueError("screenshot could not be encoded")
    text = "%s  (%s)" % (" ".join(words), datetime.datetime.now().strftime("%Y-%m-%d %H:%M"))
    # Not "status": that key is the reply's ok/fail field, and "status=200"
    # overwrote it, so AHK logged every successful post as a failure.
    return {"http": send_discord(url, text, png.tobytes())}


def format_reply(result):
    if result is None:
        return "none"
    return "\t".join(["ok"] + ["%s=%s" % (key, value) for key, value in result.items()])


def main():
    vision = Vision()
    world = World(vision)
    commands = {"ping": vision.ping, "load": vision.load, "box": vision.use_box, "locate": vision.locate,
                "scan": vision.scan, "mark": vision.mark, "moved": vision.moved, "track": vision.track,
                "debug": vision.debug, "loadworld": world.load, "worldreset": world.reset, "pathview": world.path_view, "pathdebug": world.path_debug, "pathviewclear": world.clear_view, "pathfaildebug": world.path_fail_debug, "toolbar": world.toolbar, "toolbarfixed": world.toolbar_fixed, "world": world.world,
                "follow": world.follow, "beside": world.beside, "placementline": world.placement_line, "placementneighbours": world.placement_neighbours, "hillspots": world.hill_spots, "validateplacements": world.validate_placements, "placementvalid": world.placement_valid, "onpath": world.onpath, "worlddebug": world.debug,
                "relocation": world.relocation, "rememberview": world.remember_view, "viewshift": world.view_shift,
                "unitmanager": world.unit_manager, "cardboxes": world.card_boxes,
                "discord": lambda *args: discord(world, *args)}
    for line in sys.stdin:
        parts = line.strip().split(" ")
        if not parts[0]:
            continue
        if parts[0] == "quit":
            break
        try:
            reply = format_reply(commands[parts[0]](*parts[1:]))
        except Exception as error:
            reply = "fail\treason=" + (type(error).__name__ + ": " + str(error)).replace("\t", " ").replace("\n", " ")
        sys.stdout.write(reply + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
