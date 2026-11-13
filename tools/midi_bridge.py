
"""USB-MIDI keyboard and sustain pedal to Nexys 4 DDR UART bridge.

Explicit three-byte protocol, 115200 8N1:
    Note On:  90 note velocity
    Note Off: 80 note 00
    Sustain:  B0 40 value (>=64 down)
    Panic:    B0 78 00 (CC120), also accepts CC123

No MIDI running status or channel bits are sent to the FPGA.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import sys
import time
from typing import Iterator

BAUD_RATE = 115_200


def validate_midi_byte(value: int, name: str) -> None:
    if not isinstance(value, int) or not 0 <= value <= 127:
        raise ValueError(
            f"{name} must be an integer from 0 to 127 (got {value!r})"
        )


def note_off_frame(note: int) -> bytes:
    validate_midi_byte(note, "note")
    return bytes((0x80, note, 0x00))


def note_on_frame(note: int, velocity: int) -> bytes:
    validate_midi_byte(note, "note")
    validate_midi_byte(velocity, "velocity")

    if velocity == 0:
        return note_off_frame(note)

    return bytes((0x90, note, velocity))


def midi_to_frame(
    message: object,
    channel: int | None = None,
) -> bytes | None:
    """Convert supported MIDI events to complete FPGA packets.

    channel=None accepts all MIDI channels.
    Otherwise, select an input channel from 1 to 16.
    """
    message_type = getattr(message, "type", None)

    if message_type not in ("note_on", "note_off", "control_change"):
        return None

    if channel is not None:
        if not 1 <= channel <= 16:
            raise ValueError("MIDI channel must be 1..16")

        if getattr(message, "channel", None) != channel - 1:
            return None

    if message_type == "control_change":
        control = message.control
        value = message.value
        validate_midi_byte(control, "controller")
        validate_midi_byte(value, "controller value")
        if control in (64, 120, 123):
            return bytes((0xB0, control, value))
        return None

    note = message.note

    if message_type == "note_off":
        return note_off_frame(note)

    return note_on_frame(note, message.velocity)


def all_notes_off_frames() -> Iterator[bytes]:
    """Emulate panic using normal Note Off frames."""
    for note in range(128):
        yield note_off_frame(note)


def choose_midi_input(
    names: list[str],
    requested: str | None,
) -> str:
    if requested is not None:
        if requested not in names:
            raise ValueError(
                f"MIDI input {requested!r} not found; run 'list'"
            )
        return requested

    if len(names) == 1:
        return names[0]

    if not names:
        raise ValueError(
            "No MIDI input found; connect the keyboard and run 'list'"
        )

    raise ValueError(
        "Multiple MIDI inputs found; choose one with --midi (see 'list')"
    )


def load_mido():
    try:
        import mido
    except ImportError as exc:
        raise RuntimeError(
            "Install tools/requirements.txt first"
        ) from exc

    mido.set_backend("mido.backends.rtmidi")
    return mido


@contextmanager
def open_uart(port_name: str | None, dry_run: bool):
    if dry_run:
        yield None
        return

    if not port_name:
        raise ValueError(
            "--port COMx is required unless --dry-run is used"
        )

    try:
        import serial
    except ImportError as exc:
        raise RuntimeError("Install pyserial first") from exc

    with serial.Serial(
        port=port_name,
        baudrate=BAUD_RATE,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=1,
        write_timeout=1,
        xonxoff=False,
        rtscts=False,
        dsrdtr=False,
    ) as uart:
        yield uart


def write_frame(uart, frame: bytes, verbose: bool = False) -> None:
    if uart is not None:
        count = uart.write(frame)

        if count != len(frame):
            raise OSError(
                f"Short UART write: {count}/{len(frame)} bytes"
            )

    if uart is None or verbose:
        print("UART:", frame.hex(" ").upper())


def panic_frames() -> Iterator[bytes]:
    """Clear pedal first, silence the new core, then legacy note-off cleanup."""
    yield bytes((0xB0, 64, 0))
    yield bytes((0xB0, 120, 0))
    yield from all_notes_off_frames()


def send_panic(uart, verbose: bool = False) -> None:
    """Release sustain and stop sound, including after interrupted input."""
    for frame in panic_frames():
        write_frame(uart, frame, verbose=verbose)

    if uart is not None:
        uart.flush()


def run_bridge(
    port: str | None,
    midi_name: str | None,
    channel: int | None,
    verbose: bool,
    dry_run: bool,
) -> None:
    mido = load_mido()
    selected = choose_midi_input(
        mido.get_input_names(),
        midi_name,
    )

    with open_uart(port, dry_run) as uart:
        print(f"MIDI input: {selected}")
        print(
            f"UART output: {'DRY RUN' if dry_run else port} "
            f"({BAUD_RATE} 8N1)"
        )
        print(
            "Press Ctrl+C to stop; sustain and all notes "
            "will be released on exit."
        )

        try:
            with mido.open_input(selected) as midi_input:
                for message in midi_input:
                    frame = midi_to_frame(
                        message,
                        channel=channel,
                    )

                    if frame is not None:
                        write_frame(
                            uart,
                            frame,
                            verbose=verbose,
                        )

        except KeyboardInterrupt:
            print("Stopping MIDI bridge.")

        finally:
            try:
                # Do not print the entire dry-run cleanup sequence.
                for frame in panic_frames():
                    if uart is not None:
                        write_frame(uart, frame)

                if uart is not None:
                    uart.flush()

                print(
                    "Cleanup: sustain off, all-sound-off, and 128 Note Off packets sent."
                    if uart is not None
                    else "Cleanup: dry run (no FPGA packets sent)."
                )

            except OSError as exc:
                print(
                    f"Warning: UART cleanup failed: {exc}",
                    file=sys.stderr,
                )


def list_ports() -> None:
    try:
        from serial.tools import list_ports as serial_list_ports
    except ImportError as exc:
        raise RuntimeError("Install pyserial first") from exc

    mido = load_mido()

    print("MIDI input ports:")
    for name in mido.get_input_names():
        print("  ", name)

    print("USB-UART serial ports:")
    for item in serial_list_ports.comports():
        print(f"   {item.device}  {item.description}")


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(
        dest="action",
        required=True,
    )

    sub.add_parser(
        "list",
        help="List MIDI inputs and serial COM ports",
    )

    def add_uart_args(p):
        p.add_argument(
            "--port",
            help="Nexys USB-UART COM port, e.g. COM5",
        )
        p.add_argument(
            "--dry-run",
            action="store_true",
            help="Print bytes without opening UART",
        )
        p.add_argument(
            "--verbose",
            action="store_true",
            help="Print each UART frame",
        )

    bridge = sub.add_parser(
        "bridge",
        help="Forward keyboard notes, sustain pedal and panic controllers",
    )
    add_uart_args(bridge)
    bridge.add_argument(
        "--midi",
        help="Exact MIDI input name (see 'list')",
    )
    bridge.add_argument(
        "--channel",
        type=int,
        choices=range(1, 17),
        metavar="1..16",
        help="Input channel filter (default: all)",
    )

    on = sub.add_parser(
        "on",
        help="Send one Note On",
    )
    add_uart_args(on)
    on.add_argument(
        "--note",
        type=int,
        required=True,
    )
    on.add_argument(
        "--velocity",
        type=int,
        default=100,
    )

    off = sub.add_parser(
        "off",
        help="Send one Note Off",
    )
    add_uart_args(off)
    off.add_argument(
        "--note",
        type=int,
        required=True,
    )

    pedal = sub.add_parser("pedal", help="Send sustain pedal value (>=64 means down)")
    add_uart_args(pedal)
    pedal.add_argument("--value", type=int, required=True, choices=range(128), metavar="0..127")

    panic = sub.add_parser(
        "panic",
        help="Clear sustain, silence all sound, and release all 128 notes",
    )
    add_uart_args(panic)

    demo = sub.add_parser(
        "demo",
        help="Play a short PC-controlled melody",
    )
    add_uart_args(demo)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = make_parser()
    args = parser.parse_args(argv)

    try:
        if args.action == "list":
            list_ports()

        elif args.action == "bridge":
            run_bridge(
                args.port,
                args.midi,
                args.channel,
                args.verbose,
                args.dry_run,
            )

        else:
            with open_uart(args.port, args.dry_run) as uart:

                if args.action == "on":
                    write_frame(
                        uart,
                        note_on_frame(args.note, args.velocity),
                        args.verbose,
                    )

                elif args.action == "off":
                    write_frame(
                        uart,
                        note_off_frame(args.note),
                        args.verbose,
                    )

                elif args.action == "pedal":
                    write_frame(uart, bytes((0xB0, 64, args.value)), args.verbose)

                elif args.action == "panic":
                    send_panic(uart, args.verbose)
                    print(
                        "Panic: sustain off, all-sound-off and 128 Note Off packets transmitted."
                        if uart is not None
                        else "Panic dry run complete."
                    )

                elif args.action == "demo":
                    for note in (60, 64, 67, 72):
                        write_frame(
                            uart,
                            note_on_frame(note, 100),
                            args.verbose,
                        )

                        if uart is not None:
                            uart.flush()

                        if not args.dry_run:
                            time.sleep(0.35)

                        write_frame(
                            uart,
                            note_off_frame(note),
                            args.verbose,
                        )

                        if uart is not None:
                            uart.flush()

                        if not args.dry_run:
                            time.sleep(0.08)

                if uart is not None:
                    uart.flush()

    except (OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
