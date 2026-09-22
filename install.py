#!/usr/bin/env python3
"""Install Analog Lens into an existing xschem setup, preserving its PDK config."""
import argparse
import datetime
import os
from pathlib import Path
import re
import shutil
import tempfile

START = '# BEGIN ANALOG LENS'
END = '# END ANALOG LENS'

def tcl_literal(value):
    # Quoted Tcl string with substitutions and control characters disabled.
    return '"' + str(value).replace('\\', '\\\\').replace('$', '\\$').replace('[', '\\[').replace(']', '\\]').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'

def install(source, destination, rc):
    source, destination, rc = map(lambda p: Path(p).expanduser().resolve(), (source, destination, rc))
    if not rc.is_file():
        raise ValueError('Choose an existing xschemrc with your working PDK configuration. No empty replacement will be created.')
    if destination == source or source in destination.parents:
        raise ValueError('Choose an installation directory outside the extracted source folder.')
    text = rc.read_text(encoding='utf-8')
    if (START in text) != (END in text):
        raise ValueError('The existing Analog Lens block is incomplete. Repair it before installing.')
    block = f'{START}\nsource {tcl_literal(destination / "analog_lens.tcl")}\n{END}'
    pattern = re.compile(re.escape(START) + r'.*?' + re.escape(END), re.DOTALL)
    updated = pattern.sub(lambda _: block, text) if START in text else text.rstrip() + '\n\n' + block + '\n'
    for folder in ('lib', 'symbols', 'tools', 'examples', 'docs'):
        shutil.copytree(source / folder, destination / folder, dirs_exist_ok=True)
    for name in ('analog_lens.tcl', 'README.md', 'LICENSE', 'PDK_SUPPORT.md', 'VALIDATION.md'):
        shutil.copy2(source / name, destination / name)
    backup = None
    if updated != text:
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        backup = rc.with_name(rc.name + '.analog-lens-backup-' + stamp)
        shutil.copy2(rc, backup)
        fd, temp = tempfile.mkstemp(prefix='.analog-lens-', dir=rc.parent)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                f.write(updated)
            os.chmod(temp, rc.stat().st_mode & 0o777)
            os.replace(temp, rc)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
    return destination, backup

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--rc', type=Path, help='Existing project or user xschemrc; defaults to project, then user config.')
    p.add_argument('--destination', type=Path, default=Path.home()/'.xschem'/'analog-lens')
    args = p.parse_args()
    rc = args.rc
    if rc is None:
        rc = next((x for x in (Path.cwd()/'xschemrc', Path.home()/'.xschem'/'xschemrc') if x.is_file()), None)
    if rc is None:
        p.error('No existing xschemrc found. Pass --rc /path/to/your/project/xschemrc, or use the console installation in README.md.')
    try:
        destination, backup = install(Path(__file__).parent, args.destination, rc)
    except (OSError, ValueError) as exc:
        p.exit(1, f'Installation stopped: {exc}\n')
    print(f'Installed Analog Lens to {destination}')
    if backup:
        print(f'Original configuration backed up to {backup}')
    print('Restart xschem to open the inspector sidebar. Use Analog Lens → Open analysis window for charts.')
    print('If a project has its own xschemrc, run this installer with --rc pointing to that file.')

if __name__ == '__main__':
    main()
