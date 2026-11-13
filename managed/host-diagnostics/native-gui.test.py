import importlib.util
import pathlib
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('native_gui', pathlib.Path(__file__).with_name('native-gui.py'))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativeInput(unittest.TestCase):
    def target(self):
        return {'pid': 91, 'title': 'calendar', 'window': {'id': 7, 'bounds': {'x': 10, 'y': 20, 'width': 300, 'height': 400}}, 'x': 50, 'y': 60}

    def test_mouse_release_is_guaranteed_when_dwell_or_focus_check_fails(self):
        for fail in ('dwell', 'focus'):
            events = []
            user = types.SimpleNamespace(SetCursorPos=lambda *args: True, mouse_event=lambda event, *args: events.append(event))
            with patch.object(native, 'u', user), patch.object(native, 'verified', side_effect=[{}, {}, RuntimeError('lost focus')] if fail == 'focus' else None), patch.object(native.time, 'sleep', side_effect=[None, RuntimeError('interrupted')] if fail == 'dwell' else None):
                with self.assertRaises(RuntimeError):
                    native.click(self.target())
            self.assertEqual(events, [0x0002, 0x0004])

    def test_invalid_point_or_preflight_cannot_send_mouse_down(self):
        events = []
        user = types.SimpleNamespace(mouse_event=lambda *args: events.append(args))
        target = self.target()
        target['x'] = 300
        with patch.object(native, 'u', user), patch.object(native, 'verified', return_value={}):
            with self.assertRaisesRegex(RuntimeError, 'outside'):
                native.click(target)
        with patch.object(native, 'u', user), patch.object(native, 'verified', side_effect=RuntimeError('lost focus')):
            with self.assertRaisesRegex(RuntimeError, 'focus'):
                native.click(self.target())
        self.assertEqual(events, [])

    def test_foreign_window_cannot_reach_screenshot_capture(self):
        with patch.object(native, 'verified', side_effect=RuntimeError('lost focus')):
            with self.assertRaisesRegex(RuntimeError, 'focus'):
                native.capture({'pid': 91, 'title': 'calendar', 'evidenceRoot': 'D:/unused'})


if __name__ == '__main__':
    unittest.main()
