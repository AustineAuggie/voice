#!/usr/bin/env python3
"""Process-level speaker failure/recovery fixture; never included in the app."""
import json
from pathlib import Path
import sys
import time

args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
mode = Path(args['--segmentation']).read_text().strip()
if mode == 'slow':
    time.sleep(2)
if mode == 'failure':
    print('speaker-error model-init', file=sys.stderr)
    print('Could not load ' + args['--embedding'], file=sys.stderr)
    print('Input: ' + args['--audio'], file=sys.stderr)
    sys.exit(1)
if mode == 'unknown':
    print('x' * 40000, file=sys.stderr)
    print('Unknown native fault ' + args['--audio'], file=sys.stderr)
    sys.exit(9)
Path(args['--output']).write_text(json.dumps({
    'sample_rate':16000, 'num_speakers':2,
    'segments':[{'start':0, 'end':0.5, 'speaker':0},
                {'start':0.5, 'end':1, 'speaker':1}]
}))
