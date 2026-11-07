"""Verify the stack written by the iOS UI regression test."""
from pathlib import Path
import array
import json
import math
import sys

root = Path(sys.argv[1])
projects = [(p.parent, json.loads(p.read_text())) for p in root.glob('*/project.json')]
results = [(folder, p) for folder, p in projects if p.get('result')]
assert len(results) == 3, f'Expected full, cropped and mixed-exposure sets to stack, got {len(results)}'
folder, project = next((folder, project) for folder, project in results if all(frame["height"] == 256 for frame in project["frames"]))
assert any(any(frame["height"] == 240 for frame in project["frames"]) for _, project in results)
result = project['result']
assert result["bottomFirst"] is True
assert len(project['frames']) == 3 and result['acceptedFrames'] == 3
assert (result['width'], result['height']) == (384, 256)
master = (folder / result['fileName']).read_bytes()
assert len(master) == 384 * 256 * 16
for frame in project['frames']:
    assert (folder / frame["fileName"]).is_file(), "Original must remain available"
assert not (folder / "Cache").exists(), "Decoded frames must be removed after stacking"
rgba = array.array('f')
rgba.frombytes(master)
assert all(math.isfinite(value) for value in rgba)
assert sum(alpha > 0 for alpha in rgba[3::4]) > 384 * 256 * .9
assert max(rgba[0::4]) > .3
# The isolated narrow line must stay single and sharp instead of spreading over
# the three input positions (x=20,22,24).
profile = [sum(rgba[(y * 384 + x) * 4] for y in range(119, 137)) / 18 for x in range(15, 30)]
peak = max(profile)
assert peak > .65, f"Drift blurred the filament: {profile}"
assert sum(v > peak * .5 for v in profile) <= 2, f"Filament became wider or doubled: {profile}"
vertical_profile = [sum(rgba[(y * 384 + x) * 4] for x in range(359, 368)) / 9 for y in range(119, 137)]
vertical_peak = max(vertical_profile)
assert vertical_peak > .65, f"Vertical drift or a cache strip boundary blurred the filament: {vertical_profile}"
assert sum(v > vertical_peak * .5 for v in vertical_profile) <= 2, vertical_profile
measured = [frame["registrationRMS"] for frame in project["frames"]]
assert all(0 <= residual <= .65 for residual in measured), measured
print('Verified output: 3 imported PNGs, 384x256, valid combined pixels, temporary decode files removed')
