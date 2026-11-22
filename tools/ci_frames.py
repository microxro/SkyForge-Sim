#!/usr/bin/env python3
"""Turn the review frames from the CI `frames` job into viewable PNG files and a PR comment.

  ci_frames.py extract LOG OUT_DIR
      Decode every `SKYFORGE_PNG <name> <base64>` line in LOG into OUT_DIR/<name>.png.
      Prints the frame names it wrote. Exit 1 if a line is malformed or no frames were found.

  ci_frames.py comment --repo OWNER/REPO --branch ci-frames --pr N --sha SHA --run-id ID --run-url URL FRAMES_DIR
      Print the markdown for the PR comment. Images are served from the `ci-frames` branch
      (written by the publish job in .github/workflows/ci.yml) under pr-N/.

Stdlib only, so it runs on the Linux lint job as well as on the macOS frames runner.
"""
import argparse, base64, pathlib, re, sys

MARKER = '<!-- skyforge-frames -->'
PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
LINE = re.compile(r'SKYFORGE_PNG (\S+) ([A-Za-z0-9+/=]+)\s*$')
NAME = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,80}$')


def extract(log_path, out_dir):
    """Write every well-formed frame in the log to out_dir.

    Returns the frame names written, in log order (a repeated name keeps its latest frame). Malformed
    lines are reported on stderr and skipped, so one bad line does not hide the other frames. Returns
    None when no frame was written."""
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    written = {}
    for number, line in enumerate(pathlib.Path(log_path).read_text(errors='replace').splitlines(), 1):
        if 'SKYFORGE_PNG ' not in line:
            continue
        error = None
        match = LINE.search(line)
        if not match:
            error = 'malformed SKYFORGE_PNG line'
        else:
            name, payload = match.groups()
            try:
                data = base64.b64decode(payload, validate=True)
            except ValueError:
                data = None
            if not NAME.match(name):
                error = f'unsafe frame name {name!r}'
            elif data is None:
                error = f'{name} is not valid base64'
            elif not data.startswith(PNG_SIGNATURE):
                error = f'{name} is not a PNG'
        if error:
            print(f'ci_frames: line {number}: {error}', file=sys.stderr)
            continue
        written.pop(name, None)
        written[name] = data
    if not written:
        print('ci_frames: no SKYFORGE_PNG frames found in', log_path, file=sys.stderr)
        return None
    for name, data in written.items():
        (out / f'{name}.png').write_bytes(data)
    return list(written)


def comment(repo, branch, pr, sha, run_id, run_url, frames_dir):
    """Markdown for the PR comment: one image per frame, two per row, each linking to the full PNG."""
    names = sorted(p.stem for p in pathlib.Path(frames_dir).glob('*.png'))
    base = f'https://raw.githubusercontent.com/{repo}/{branch}/pr-{pr}'
    lines = [
        MARKER,
        f'### Review frames for `{sha[:7]}`',
        '',
        f'Rendered by [CI run {run_id}]({run_url}) on macOS. Click an image for the full 1280×720 frame. '
        'The images are replaced on every push to this PR.',
        '',
    ]
    if not names:
        lines.append('No frames were rendered for this commit. Check the frames job log.')
        return '\n'.join(lines) + '\n'
    lines += ['| | |', '| --- | --- |']
    cells = [f'[<img src="{base}/{n}.png?run={run_id}" width="480" alt="{n}"><br>{n}]({base}/{n}.png?run={run_id})'
             for n in names]
    if len(cells) % 2:
        cells.append('')
    for i in range(0, len(cells), 2):
        lines.append(f'| {cells[i]} | {cells[i + 1]} |')
    return '\n'.join(lines) + '\n'


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='cmd', required=True)
    ex = sub.add_parser('extract')
    ex.add_argument('log')
    ex.add_argument('out_dir')
    cm = sub.add_parser('comment')
    cm.add_argument('--repo', required=True)
    cm.add_argument('--branch', default='ci-frames')
    cm.add_argument('--pr', required=True, type=int)
    cm.add_argument('--sha', required=True)
    cm.add_argument('--run-id', required=True)
    cm.add_argument('--run-url', required=True)
    cm.add_argument('frames_dir')
    args = parser.parse_args(argv)
    if args.cmd == 'extract':
        names = extract(args.log, args.out_dir)
        if names is None:
            return 1
        print('\n'.join(names))
        return 0
    sys.stdout.write(comment(args.repo, args.branch, args.pr, args.sha, args.run_id, args.run_url, args.frames_dir))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
