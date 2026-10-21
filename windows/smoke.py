"""Run source/frozen GUI against generated photos. Timeout and nonzero exit fail CI."""
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw
from hej_pets.data import Store

p=argparse.ArgumentParser();p.add_argument('executable',nargs='?');args=p.parse_args()
with tempfile.TemporaryDirectory(prefix='hej-pets-smoke-') as folder:
    root=Path(folder);im=Image.new('RGB',(240,320),'#BAD8CD');draw=ImageDraw.Draw(im)
    draw.ellipse((65,20,175,160),fill='#F1C8AB');draw.rectangle((70,160,170,300),fill='#538C82')
    photo=root/'test.png';im.save(photo);store=Store(root/'data');store.add(photo)
    command=[str(Path(args.executable).resolve())] if args.executable else [sys.executable,str(Path(__file__).with_name('run.py').resolve())]
    result=subprocess.run(command+['--smoke-test','--data-dir',str(root/'data')],timeout=45)
    if result.returncode:raise SystemExit(result.returncode)
    print('GUI smoke passed: isolated photo import, pet window, perimeter, drag/fall, pause and clean exit.')
