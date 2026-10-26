"""The bridge CLI: arguments, the inventory-mode check and the serial loop."""

import json
from pathlib import Path
from types import SimpleNamespace

import pytest
import serial

from bridge import __main__ as cli
from bridge import bambuddy, session

MESSAGES = Path(__file__).resolve().parents[2] / "protocol" / "fixtures" / "messages"


def fixture_line(name: str) -> bytes:
    message = json.loads((MESSAGES / name).read_text(encoding="utf-8"))
    return session.compact(message).encode() + b"\n"


class FakePort:
    """Serial port double: yields queued chunks, then fails like an unplug."""

    def __init__(self, *chunks: bytes):
        self.chunks = list(chunks)
        self.written = bytearray()
        self.in_waiting = 0

    def read(self, size: int) -> bytes:
        if not self.chunks:
            raise serial.SerialException("device disconnected")
        return self.chunks.pop(0)

    def write(self, data: bytes) -> int:
        self.written += data
        return len(data)

    def lines(self) -> list[dict]:
        return [json.loads(line) for line in self.written.decode().splitlines()]


class FakeSettings:
    def __init__(self, result):
        self.result = result

    def spoolman_enabled(self):
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def test_serve_sends_hello_first_then_answers():
    hello = fixture_line("hello_flipper.json")
    scan = fixture_line("scan_ntag.json")
    port = FakePort(hello[:10], hello[10:] + scan[:100], scan[100:])
    logged = []
    cli.serve(port, session.Bridge(None), log=logged.append)
    out = port.lines()
    # The Flipper's hello answers ours, so it gets no second one.
    assert [m["t"] for m in out] == ["hello", "lookup"]
    assert out[1]["scan_id"] == "s-000013"
    assert any("device disconnected" in entry for entry in logged)
    assert port.written.endswith(b"\n")


def test_serve_ignores_garbage():
    port = FakePort(b"garbage\n\xff\xfe\n")
    cli.serve(port, session.Bridge(None), log=lambda _: None)
    assert [m["t"] for m in port.lines()] == ["hello"]


@pytest.mark.parametrize(
    "result, expected",
    [
        (False, None),
        (True, "Spoolman mode"),
        (bambuddy.PermissionMissing("settings:read"), "settings:read"),
        (bambuddy.BambuddyError("connection refused"), "connection refused"),
    ],
)
def test_check_inventory_mode(result, expected):
    refusal = cli.check_inventory_mode(FakeSettings(result))
    if expected is None:
        assert refusal is None
    else:
        assert expected in refusal


def test_parse_args_defaults(monkeypatch):
    monkeypatch.delenv("BAMBUDDY_API_KEY", raising=False)
    args = cli.parse_args([])
    assert args.port is None and args.bambuddy is None
    assert args.core_weight == 325 and args.catalog_id is None and args.dump_dir is None


def test_core_weight_help_names_the_default(capsys):
    with pytest.raises(SystemExit):
        cli.parse_args(["--help"])
    assert "default: 325" in " ".join(capsys.readouterr().out.split())


def test_parse_args_reads_the_key_from_the_environment(monkeypatch):
    monkeypatch.setenv("BAMBUDDY_API_KEY", "bb_env")
    args = cli.parse_args(["--bambuddy", "http://nas:8000"])
    assert args.api_key == "bb_env"


def test_parse_args_requires_a_key_with_bambuddy(monkeypatch):
    monkeypatch.delenv("BAMBUDDY_API_KEY", raising=False)
    with pytest.raises(SystemExit):
        cli.parse_args(["--bambuddy", "http://nas:8000"])


def test_main_refuses_spoolman_mode(monkeypatch, capsys):
    class FakeClient(FakeSettings):
        def color_map(self):
            raise AssertionError("colour map loaded after a refusal")

    monkeypatch.setattr(bambuddy, "BambuddyClient", lambda url, key: FakeClient(True))
    assert cli.main(["--bambuddy", "http://nas:8000", "--api-key", "bb_x"]) == 2
    assert "Spoolman" in capsys.readouterr().err


def test_main_without_a_flipper(monkeypatch, capsys):
    monkeypatch.setattr(cli.list_ports, "comports", lambda: [SimpleNamespace(device="/dev/cu.usbmodem1101")])
    assert cli.main([]) == 1
    assert "no Flipper" in capsys.readouterr().err


def test_main_serves_the_detected_port(monkeypatch):
    port = FakePort(fixture_line("hello_flipper.json"))
    opened = []

    class FakeSerial:
        def __init__(self, device, baud, timeout):
            opened.append((device, baud))

        def __enter__(self):
            return port

        def __exit__(self, *exc):
            return False

    monkeypatch.setattr(cli.list_ports, "comports",
                        lambda: [SimpleNamespace(device="/dev/cu.usbmodemflip_Test1")])
    monkeypatch.setattr(cli.serial, "Serial", FakeSerial)
    assert cli.main([]) == 0
    assert opened == [("/dev/cu.usbmodemflip_Test1", 115200)]
    assert [m["t"] for m in port.lines()] == ["hello"]


def test_main_loads_the_colour_map_after_the_check(monkeypatch):
    class FakeClient(FakeSettings):
        loads = 0

        def color_map(self):
            FakeClient.loads += 1
            return {"colors": {}, "by_material": {}}

    class FakeSerial:
        def __init__(self, device, baud, timeout):
            pass

        def __enter__(self):
            return FakePort()

        def __exit__(self, *exc):
            return False

    monkeypatch.setattr(bambuddy, "BambuddyClient", lambda url, key: FakeClient(False))
    monkeypatch.setattr(cli.list_ports, "comports",
                        lambda: [SimpleNamespace(device="/dev/cu.usbmodemflip_Test1")])
    monkeypatch.setattr(cli.serial, "Serial", FakeSerial)
    assert cli.main(["--bambuddy", "http://nas:8000", "--api-key", "bb_x"]) == 0
    assert FakeClient.loads == 1
