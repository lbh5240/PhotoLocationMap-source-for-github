"""Verify the stack written by the iOS UI regression test."""
from pathlib import Path
import array
import json
import math
import sys

root = Path(sys.argv[1])
projects = [(p.parent, json.loads(p.read_text())) for p in root.glob('*/project.json')]
results = [(folder, p) for folder, p in projects if p.get('result')]
assert len(results) == 1, f'Expected one successful project, got {len(results)}'
folder, project = results[0]
result = project['result']
assert len(project['frames']) == 3 and result['acceptedFrames'] == 3
assert (result['width'], result['height']) == (384, 256)
master = (folder / result['fileName']).read_bytes()
assert len(master) == 384 * 256 * 16
for frame in project['frames']:
    source = folder / 'Cache' / (frame['id'] + '.rgba')
    assert source.read_bytes() != master, 'Stack must differ from every input'
rgba = array.array('f')
rgba.frombytes(master)
assert all(math.isfinite(value) for value in rgba)
assert sum(alpha > 0 for alpha in rgba[3::4]) > 384 * 256 * .9
assert max(rgba[0::4]) > .3
print('Verified output: 3 imported PNGs, 384x256, valid combined pixels, different from all inputs')
