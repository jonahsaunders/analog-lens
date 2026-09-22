#!/usr/bin/env python3
"""Read SPICE hierarchy and fingerprint its dependencies without changing xschem.

Input is data: no Tcl, shell or SPICE expressions are evaluated. Unresolved
paths and conditional circuits are reported instead of claiming full coverage.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sys


def tcl(value):
    """Encode nested data as Tcl lists/dictionaries, never executable script."""
    if isinstance(value, dict):
        value = [v for pair in value.items() for v in pair]
    if isinstance(value, (list, tuple)):
        return ' '.join(tcl_quote(tcl(v)) for v in value)
    if value is None:
        return ''
    return str(value)


def tcl_quote(text):
    if not text:
        return '{}'
    escaped = {'\n': r'\n', '\r': r'\r', '\t': r'\t'}
    return ''.join(escaped.get(c, '\\'+c if c in ' {}[]$;\\"' else c) for c in text)


def logical_lines(text):
    lines = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('+') and lines:
            lines[-1] += ' ' + line[1:]
        else:
            lines.append(line)
    return lines


def tokens(line):
    lexer = shlex.shlex(line, posix=True)
    lexer.whitespace_split = True
    lexer.commenters = ';'
    return list(lexer)


def signature(path):
    stat = path.stat()
    return dict(size=stat.st_size, mtime_ns=stat.st_mtime_ns, ctime_ns=stat.st_ctime_ns,
                sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def resolve_path(name, directory):
    name = os.path.expandvars(name)
    if any(c in name for c in '{}$'):
        raise ValueError('Unresolved dependency: '+name)
    path = Path(name).expanduser()
    if not path.is_absolute():
        path = directory/path
    # Keep the logical path: replacing a PDK symlink must invalidate the record.
    return Path(os.path.abspath(path))


def read_graph(deck, with_init=True):
    files, visited, warnings, lines = {}, set(), [], []

    def record(path):
        if str(path) not in files:
            if len(files) >= 12000:
                raise ValueError('Dependency graph exceeds 12000 files.')
            files[str(path)] = signature(path)

    def visit(path, section=None, depth=0, source_only=False):
        key = (str(path), section, source_only)
        if key in visited:
            return
        if depth > 64:
            raise ValueError('Dependency nesting exceeds 64 levels.')
        visited.add(key)
        try:
            record(path)
            if source_only:
                return
            text = path.read_text(errors='replace')
        except OSError as exc:
            warnings.append(str(exc)); return
        active = section is None
        seen_section = section is None
        for line in logical_lines(text):
            source = re.match(r'\*\* (?:sch|sym)_path:\s*(.+)', line)
            if source:
                try:
                    visit(resolve_path(source[1], path.parent), depth=depth+1, source_only=True)
                except ValueError as exc:
                    warnings.append(str(exc))
            if not line or line.startswith('*'):
                continue
            # Model equations are opaque data. Tokenize only dependency/library
            # directives; hashing still covers every byte in each source file.
            directive = re.match(r'(?i)^(\.include|\.inc|\.lib|\.endl|source|osdi|pre_osdi)(?:\s|$)', line)
            if not directive:
                if active:
                    lines.append(line)
                continue
            try:
                parts = tokens(line)
            except ValueError:
                warnings.append('Unparsed line in '+str(path)); continue
            if not parts:
                continue
            cmd = parts[0].lower()
            if cmd == '.lib' and len(parts) == 2:
                active = section is not None and parts[1].lower() == section.lower()
                seen_section |= active
                continue
            if cmd == '.endl':
                active = section is None; continue
            if not active:
                continue
            if cmd in ('.include', '.inc', '.lib', 'source', 'osdi', 'pre_osdi') and len(parts) >= 2:
                try:
                    visit(resolve_path(parts[1], path.parent),
                          parts[2] if cmd == '.lib' and len(parts) > 2 else None,
                          depth+1, cmd in ('osdi', 'pre_osdi'))
                except ValueError as exc:
                    warnings.append(str(exc))
            else:
                lines.append(line)
        if not seen_section:
            warnings.append(f'Missing library section {section} in {path}')

    visit(Path(os.path.abspath(deck)))
    if with_init:
        roots = [deck.parent, Path.home()]
        if os.environ.get('SPICE_USERINIT_DIR'):
            roots.append(Path(os.environ['SPICE_USERINIT_DIR']))
        for directory in dict.fromkeys(roots):
            for name in ('.spiceinit', 'spinit'):
                path = directory/name
                if path.is_file():
                    visit(path)
    return dict(format='analog-lens-dependencies', schema=1, files=files,
                warnings=sorted(set(warnings))), lines


def devices_from_lines(lines, pdk):
    """Expand design subcircuits; stop at known PDK device wrappers."""
    blocks = {'': []}; current = ''; control = False
    for line in lines:
        # Compact-model equations cannot introduce design instances. Avoid
        # tokenizing thousands of long .model/.param lines a second time.
        if not re.match(r'(?i)^(?:[xmnq]|\.(?:subckt|ends|control|endc|if|elseif|else|endif)(?:\s|$))', line):
            continue
        words = tokens(line)
        if not words:
            continue
        cmd = words[0].lower()
        if cmd == '.control':
            control = True; continue
        if cmd == '.endc':
            control = False; continue
        if control:
            continue
        if cmd == '.subckt':
            if current:
                raise ValueError('Nested subcircuit definitions need manual device saves.')
            current = words[1].lower(); blocks.setdefault(current, [])
        elif cmd == '.ends':
            current = ''
        else:
            blocks[current].append(words)
    family = 'sky130' if pdk.startswith('sky') else 'gf180' if pdk.startswith('gf') else 'ihp' if pdk.startswith('ihp') else 'generic'
    result = []

    def walk(block, hierarchy, stack):
        if block in stack or len(stack) > 48:
            raise ValueError('Recursive or excessive circuit hierarchy.')
        conditional_depth = 0
        for words in blocks[block]:
            if words[0].lower() == '.if':
                conditional_depth += 1; continue
            if words[0].lower() == '.endif':
                conditional_depth = max(0, conditional_depth-1); continue
            name = words[0]; kind = name[0].lower()
            if kind not in 'xmnq' or len(words) < 5:
                continue
            if conditional_depth:
                raise ValueError('Conditional design topology needs explicit device saves; no branch is guessed.')
            # The model/subcircuit name precedes the first parameter assignment.
            positional = re.split(r'\s+(?:params:|[\w.]+\s*=)', ' '.join(words), maxsplit=1, flags=re.I)[0].split()
            if len(positional) < 5:
                continue
            model = positional[-1]; lower = model.lower()
            is_mos = bool(re.search(r'(?:[np]fet_|sg13.*[np]mos)', lower))
            is_bjt = bool(re.search(r'(?:npn|pnp)', lower))
            if kind == 'x' and not (is_mos or is_bjt):
                if lower in blocks:
                    walk(lower, hierarchy+name.lower()+'.', stack+[block])
                else:
                    raise ValueError(f'Unresolved subcircuit {model}; provide its .include or device saves.')
                continue
            typ = ('p' if ('pfet' in lower or 'pmos' in lower) else 'n')+'mos'
            if kind == 'q' or is_bjt:
                typ = 'pnp' if 'pnp' in lower else 'npn'
            device_family = 'sky130' if 'sky130' in lower or '01v8' in lower else 'gf180' if '03v3' in lower or 'gf180' in lower else 'ihp' if 'sg13' in lower else family
            result.append(dict(name=name[1:] if kind == 'x' else name, owner=name, prefix='x' if kind == 'x' else '', model=model, family=device_family,
                               type=typ, hierarchy=hierarchy))
            if len(result) > 100000:
                raise ValueError('Circuit exceeds 100000 devices.')
    walk('', '', [])
    return result


def check_manifest(manifest, full=False):
    changed = []
    for name, saved in manifest['files'].items():
        try:
            path = Path(name); stat = path.stat()
            dirty = any(saved[k] != getattr(stat, 'st_'+k) for k in ('size', 'mtime_ns', 'ctime_ns'))
            if (full or dirty) and signature(path)['sha256'] != saved['sha256']:
                changed.append(name)
        except OSError:
            changed.append(name)
    return dict(state='changed' if changed else 'partial' if manifest['warnings'] else 'current',
                changed=changed, warnings=manifest['warnings'])


def deck_conditions(deck):
    text = deck.read_text()
    temps = re.findall(r'(?im)^\s*\.temp\s+([-+\d.eE]+)\s*$', text)
    corners = []
    for line in logical_lines(text):
        try:
            words = tokens(line)
        except ValueError:
            continue
        if len(words) == 3 and words[0].lower() == '.lib':
            corners.append(words[2])
    result = {}
    if len(set(temps)) == 1 and not re.search(r'(?im)^\s*(?:set\s+temp|altermod|alterparam|source|reset)\b', text):
        result['temp_c'] = temps[0]
    if len(set(corners)) == 1 and not re.search(r'(?im)^\s*(?:altermod|source)\b', text):
        result['corner'] = corners[0]
    return result


def installed_corners(base, pdk):
    """List sections in the actual model libraries used by this MOS profile."""
    from check_iic import configuration
    if pdk not in ('sky130A', 'gf180mcuD', 'ihp-sg13g2', 'ihp-sg13cmos5l'):
        raise ValueError('Select a supported installed IIC PDK.')
    includes = configuration(pdk, base, 'n')[0]
    groups = []
    for line in includes.splitlines():
        words = tokens(line)
        if words and words[0].lower() == '.lib' and len(words) == 3:
            library = Path(words[1])
            sections = set()
            for entry in logical_lines(library.read_text()):
                if not re.match(r'(?i)^\.lib\s+', entry):
                    continue
                parts = tokens(entry)
                if len(parts) == 2 and re.fullmatch(r'[A-Za-z0-9_]+', parts[1]):
                    sections.add(parts[1])
            groups.append(sections)
    return sorted(set.intersection(*groups)) if groups else []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('devices', 'snapshot', 'check', 'corners'))
    parser.add_argument('path', type=Path)
    parser.add_argument('--pdk', default=os.environ.get('PDK', ''))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--full', action='store_true')
    args = parser.parse_args()
    if args.action == 'corners':
        result = installed_corners(args.path, args.pdk)
    elif args.action == 'check':
        result = check_manifest(json.loads(args.path.read_text()), args.full)
    else:
        manifest, lines = read_graph(args.path)
        if args.action == 'devices':
            # Missing PDK model files do not prevent identifying their known wrappers.
            result = devices_from_lines(lines, args.pdk)
        else:
            from characterize import atomic_text
            atomic_text(args.output, json.dumps(manifest, indent=2)+'\n')
            result = dict(dependencies=str(args.output), dependency_hash=signature(args.output)['sha256'],
                          observed_conditions=deck_conditions(args.path), dependency_warnings=manifest['warnings'])
    print(tcl(result))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError) as exc:
        print(str(exc), file=sys.stderr); sys.exit(1)
