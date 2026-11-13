
"""MIDI bridge protocol tests: no MIDI, serial package, or hardware required."""

import importlib.util
import io
from contextlib import contextmanager, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch


TARGET = Path(__file__).with_name(
    "midi_bridge.py"
)

spec = importlib.util.spec_from_file_location(
    "midi_bridge_test_target", TARGET
)

bridge = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(bridge)


class FakeUart:
    def __init__(self):
        self.frames = []
        self.flushed = False

    def write(self, frame):
        self.frames.append(frame)
        return len(frame)

    def flush(self):
        self.flushed = True


class TestMidiBridge(unittest.TestCase):
    def setUp(self):
        self.stdout = io.StringIO()
        self.redirect = redirect_stdout(self.stdout)
        self.redirect.__enter__()
        self.addCleanup(self.redirect.__exit__, None, None, None)

    def test_note_on(self):
        self.assertEqual(
            bridge.note_on_frame(60, 100),
            bytes.fromhex("90 3C 64"),
        )

    def test_note_off(self):
        self.assertEqual(
            bridge.note_off_frame(60),
            bytes.fromhex("80 3C 00"),
        )

    def test_velocity_zero_becomes_off(self):
        self.assertEqual(
            bridge.note_on_frame(60, 0),
            bytes.fromhex("80 3C 00"),
        )

    def test_note_boundaries(self):
        self.assertEqual(
            bridge.note_on_frame(0, 1),
            bytes.fromhex("90 00 01"),
        )
        self.assertEqual(
            bridge.note_on_frame(127, 127),
            bytes.fromhex("90 7F 7F"),
        )

    def test_out_of_range_rejected(self):
        for note, velocity in [
            (-1, 90),
            (128, 90),
            (60, -1),
            (60, 128),
        ]:
            with self.subTest(note=note, velocity=velocity):
                with self.assertRaises(ValueError):
                    bridge.note_on_frame(note, velocity)

    def test_received_channel_mapped_to_zero(self):
        msg = SimpleNamespace(
            type="note_on",
            channel=9,
            note=60,
            velocity=100,
        )
        self.assertEqual(
            bridge.midi_to_frame(msg),
            bytes.fromhex("90 3C 64"),
        )

    def test_channel_filter(self):
        msg = SimpleNamespace(
            type="note_on",
            channel=1,
            note=60,
            velocity=100,
        )
        self.assertIsNone(
            bridge.midi_to_frame(msg, channel=1)
        )
        self.assertEqual(
            bridge.midi_to_frame(msg, channel=2),
            bytes.fromhex("90 3C 64"),
        )

    def test_midi_note_on_zero(self):
        msg = SimpleNamespace(
            type="note_on",
            channel=0,
            note=60,
            velocity=0,
        )
        self.assertEqual(
            bridge.midi_to_frame(msg),
            bytes.fromhex("80 3C 00"),
        )

    def test_sustain_control_change(self):
        msg = SimpleNamespace(
            type="control_change",
            channel=0,
            control=64,
            value=127,
        )
        self.assertEqual(bridge.midi_to_frame(msg), bytes.fromhex("B0 40 7F"))

    def test_exact_midi_port_required_when_multiple(self):
        with self.assertRaises(ValueError):
            bridge.choose_midi_input(
                ["Piano", "Controller"], None
            )

        self.assertEqual(
            bridge.choose_midi_input(["Piano"], None),
            "Piano",
        )
        self.assertEqual(
            bridge.choose_midi_input(
                ["Piano", "Controller"], "Piano"
            ),
            "Piano",
        )

    def test_panic_clears_sustain_before_legacy_note_cleanup(self):
        uart = FakeUart()
        bridge.send_panic(uart)

        self.assertEqual(len(uart.frames), 130)
        self.assertEqual(
            uart.frames[0],
            bytes.fromhex("B0 40 00"),
        )
        self.assertEqual(uart.frames[1], bytes.fromhex("B0 78 00"))
        self.assertEqual(uart.frames[2], bytes.fromhex("80 00 00"))
        self.assertEqual(
            uart.frames[-1],
            bytes.fromhex("80 7F 00"),
        )
        self.assertTrue(uart.flushed)

    def test_bridge_sends_notes_and_pedal_then_cleanup(self):
        uart = FakeUart()

        messages = [
            SimpleNamespace(
                type="note_on",
                note=60,
                velocity=90,
                channel=0,
            ),
            SimpleNamespace(
                type="control_change",
                control=64,
                value=127,
                channel=0,
            ),
            SimpleNamespace(
                type="note_off",
                note=60,
                velocity=0,
                channel=0,
            ),
        ]

        @contextmanager
        def fake_input(_name):
            yield messages

        @contextmanager
        def fake_serial(_port, _dry_run):
            yield uart

        class FakeMido:
            def get_input_names(self):
                return ["Piano"]

            open_input = staticmethod(fake_input)

        with patch.object(
            bridge, "load_mido", return_value=FakeMido()
        ), patch.object(
            bridge, "open_uart", side_effect=fake_serial
        ):
            bridge.run_bridge(
                "COM5", "Piano", None, False, False
            )

        self.assertEqual(
            uart.frames[0],
            bytes.fromhex("90 3C 5A"),
        )
        self.assertEqual(
            uart.frames[1],
            bytes.fromhex("B0 40 7F"),
        )
        self.assertEqual(
            len(uart.frames),
            133,
        )
        self.assertEqual(uart.frames[2], bytes.fromhex("80 3C 00"))
        self.assertEqual(uart.frames[3], bytes.fromhex("B0 40 00"))
        self.assertEqual(uart.frames[4], bytes.fromhex("B0 78 00"))
        self.assertTrue(uart.flushed)

    def test_controller_filter_and_validation(self):
        for control in (64, 120, 123):
            for value in (0, 63, 64, 127):
                msg = SimpleNamespace(type="control_change", channel=2, control=control, value=value)
                self.assertEqual(bridge.midi_to_frame(msg, 3), bytes((0xB0, control, value)))
                self.assertIsNone(bridge.midi_to_frame(msg, 1))
        msg = SimpleNamespace(type="control_change", channel=0, control=7, value=100)
        self.assertIsNone(bridge.midi_to_frame(msg))
        msg.value = 128
        with self.assertRaises(ValueError):
            bridge.midi_to_frame(msg)

    def test_short_write_is_an_error(self):
        class ShortUart:
            def write(self, frame):
                return len(frame)-1
        with self.assertRaises(OSError):
            bridge.write_frame(ShortUart(), bytes((0x90, 69, 100)))

    def test_dry_run_pedal_and_panic(self):
        self.assertEqual(bridge.main(["pedal", "--value", "127", "--dry-run"]), 0)
        self.assertEqual(bridge.main(["pedal", "--value", "0", "--dry-run"]), 0)
        self.assertEqual(bridge.main(["panic", "--dry-run"]), 0)

    def test_dry_run_demo(self):
        self.assertEqual(
            bridge.main(["demo", "--dry-run"]),
            0,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
