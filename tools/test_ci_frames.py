#!/usr/bin/env python3
"""Unit tests for tools/ci_frames.py. Run: python3 tools/test_ci_frames.py"""
import base64, pathlib, sys, tempfile, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import ci_frames  # noqa: E402

PNG = b'\x89PNG\r\n\x1a\n' + b'fake-body'


def line(name, data=PNG):
    return f'[12:00] SKYFORGE_PNG {name} {base64.b64encode(data).decode()}\n'


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())

    def log(self, text):
        path = self.tmp / 'frames.log'
        path.write_text(text)
        return path

    def test_writes_each_frame_in_log_order(self):
        log = self.log('noise\n' + line('KMRY-final') + line('KBFI-ultra') + 'tail\n')
        out = self.tmp / 'out'
        self.assertEqual(ci_frames.extract(log, out), ['KMRY-final', 'KBFI-ultra'])
        self.assertEqual((out / 'KMRY-final.png').read_bytes(), PNG)
        self.assertEqual(sorted(p.name for p in out.iterdir()), ['KBFI-ultra.png', 'KMRY-final.png'])

    def test_bad_lines_are_skipped_and_good_ones_kept(self):
        bad_payload = 'SKYFORGE_PNG OK-one !!!notbase64\n'
        not_png = line('LSZS-x', b'GIF89a-not-a-png')
        log = self.log(bad_payload + not_png + line('NZQN-ok'))
        out = self.tmp / 'out'
        self.assertEqual(ci_frames.extract(log, out), ['NZQN-ok'])
        self.assertFalse((out / 'LSZS-x.png').exists())

    def test_unsafe_names_are_rejected(self):
        log = self.log(line('../escape') + line('ok'))
        out = self.tmp / 'out'
        self.assertEqual(ci_frames.extract(log, out), ['ok'])
        self.assertFalse((self.tmp / 'escape.png').exists())

    def test_repeated_name_keeps_latest_frame(self):
        newer = b'\x89PNG\r\n\x1a\nnewer'
        log = self.log(line('KASE') + line('KBFI') + line('KASE', newer))
        names = ci_frames.extract(log, self.tmp / 'out')
        self.assertEqual(names, ['KBFI', 'KASE'])
        self.assertEqual((self.tmp / 'out' / 'KASE.png').read_bytes(), newer)

    def test_no_frames_returns_none(self):
        self.assertIsNone(ci_frames.extract(self.log('just swift test output\n'), self.tmp / 'out'))


class CommentTests(unittest.TestCase):
    def test_comment_links_each_frame_and_marks_itself(self):
        frames = pathlib.Path(tempfile.mkdtemp())
        for n in ('KMRY', 'KBFI', 'SKYWORLD'):
            (frames / f'{n}.png').write_bytes(PNG)
        text = ci_frames.comment('microxro/SkyForge-Sim', 'ci-frames', 14, 'a1b2c3d4e5f6', '987',
                                 'https://example.test/run/987', frames)
        self.assertIn(ci_frames.MARKER, text)
        self.assertIn('a1b2c3d', text)
        for n in ('KBFI', 'KMRY', 'SKYWORLD'):
            self.assertIn('https://raw.githubusercontent.com/microxro/SkyForge-Sim/ci-frames/pr-14/'
                          f'{n}.png?run=987', text)
        self.assertEqual(text.count('| --- | --- |'), 1)

    def test_empty_frames_dir_says_so(self):
        frames = pathlib.Path(tempfile.mkdtemp())
        text = ci_frames.comment('o/r', 'ci-frames', 1, 'abcdef0', '1', 'u', frames)
        self.assertIn('No frames were rendered', text)
        self.assertNotIn('<img', text)


if __name__ == '__main__':
    unittest.main()
