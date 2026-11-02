#!/usr/bin/env python3
"""Create an isolated build project; never modify either frozen source copy.
Use app dependency versions where present (same host baseline environment), then
fill missing AMAP dependencies from its frozen manifest. JuliaC performs ordinary
Pkg.instantiate/precompile in a further private copy of this project.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def blocks(text):
    return {m.group(1): m.group(0) for m in re.finditer(
        r'^\[\[deps\.(\w+)\]\].*?(?=^\[\[deps\.|\Z)', text, re.M | re.S)}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--pse-root', type=Path, required=True)
    p.add_argument('--source-root', type=Path, required=True)
    p.add_argument('--destination', type=Path, required=True)
    args = p.parse_args()
    pse = args.pse_root.resolve()
    source = args.source_root.resolve()
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=False)
    app = (pse / 'benchmark/juliac_program/app/Manifest.toml').read_text()
    amap = (source / 'AMAPSim/Manifest.toml').read_text()
    merged = blocks(amap)
    merged.update(blocks(app))
    merged['AMAPSim'] = re.sub(r'^path = .*$', f'path = "{source / "AMAPSim"}"',
                              merged['AMAPSim'], flags=re.M)
    merged['PlantSimEngine'] = re.sub(r'^path = .*$', f'path = "{pse}"',
                                    merged['PlantSimEngine'], flags=re.M)
    manifest = app[:app.index('[[deps.')] + ''.join(merged[k] for k in sorted(merged))
    manifest = manifest.replace('/private/tmp/pse-ecosystem-source-freeze-20261101/', str(source) + '/')
    (destination / 'Manifest.toml').write_text(manifest)
    (destination / 'Project.toml').write_text(f'''[deps]
AMAPSim = "976a412c-0a3f-5fcc-b76f-370f5516f661"
PlantSimEngine = "9a576370-710b-4269-adf9-4f603a9c6423"
[sources]
AMAPSim = {{path = "{source / 'AMAPSim'}"}}
PlantSimEngine = {{path = "{pse}"}}
''')
    report = {'pse_root': str(pse), 'source_root': str(source),
              'sha256': {name: hashlib.sha256((destination / name).read_bytes()).hexdigest()
                         for name in ('Project.toml', 'Manifest.toml')}}
    (destination / 'provenance.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
