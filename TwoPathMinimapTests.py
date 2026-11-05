"""Two-path maps: the purple path is found as a second route and its meeting
points with the green route are reported; one-path minimaps report none."""
from pathlib import Path
import MinimapVision as mv

ROOT = Path(__file__).resolve().parent
vision = mv.Vision()
vision.load(str(ROOT / "two-path-minimap.jpg"))
reply = vision.scan()
assert "crossings" in reply and "heart" in reply, reply
points = [tuple(map(float, p.split(","))) for p in reply["crossings"].split(";")]
# Supplied Shibuya District minimap: the circled first crossing, the second
# crossing and the merge before the heart (96 x 96 grid units).
expected = [(38.8, 37.2), (56.8, 28.0), (72.5, 34.8)]
assert len(points) == 3, points
for ex, ey in expected:
    assert any((x - ex) ** 2 + (y - ey) ** 2 <= 4 ** 2 for x, y in points), ((ex, ey), points)
image = mv.read_image(str(ROOT / "two-path-minimap.jpg"))
purple = mv.second_route(image)
assert purple.sum() > 1000, "purple path not found"
# A small purple marker on its own (e.g. the boss icon) is not a path.
blob = image.copy()
blob[:] = (30, 30, 30)
blob[100:112, 100:112] = (165, 0, 107)
assert not mv.second_route(blob).any(), "a purple icon was taken for a path"
for name in ["minimap-screenshot.png"]:
    single = mv.Vision()
    single.load(str(ROOT / name))
    assert "crossings" not in single.scan(), name + " is a one-path minimap"
print("PASS: two-path minimap meeting points (first crossing, second crossing, merge); purple icons are not paths; one-path minimaps unchanged.")
