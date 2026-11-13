"""Send the explicit three-byte note protocol over USB-UART (115200, 8N1)."""

import argparse
import time
import serial


def seven_bit(value: int, name: str) -> int:
    if not 0 <= value <= 127:
        raise ValueError(f"{name} must be between 0 and 127")
    return value


def command(status: int, note: int, velocity: int) -> bytes:
    return bytes((
        status,
        seven_bit(note, "note"),
        seven_bit(velocity, "velocity"),
    ))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("action", choices=("on", "off", "demo"))
    parser.add_argument("note", type=int, nargs="?")
    parser.add_argument("velocity", type=int, nargs="?", default=100)

    args = parser.parse_args()

    if args.action != "demo" and args.note is None:
        parser.error("'on' and 'off' require a note number")

    with serial.Serial(
        args.port,
        args.baud,
        timeout=1,
        write_timeout=1
    ) as port:

        if args.action == "on":
            payload = command(0x90, args.note, args.velocity)
            port.write(payload)
            print(f"Note On: {list(payload)}")

        elif args.action == "off":
            payload = command(0x80, args.note, 0)
            port.write(payload)
            print(f"Note Off: {list(payload)}")

        else:
            for note in (57, 69, 81, 69):
                port.write(command(0x90, note, 100))
                port.flush()
                print(f"On {note}")
                time.sleep(0.5)

                port.write(command(0x80, note, 0))
                port.flush()
                print(f"Off {note}")
                time.sleep(0.15)

        port.flush()


if __name__ == "__main__":
    main()
