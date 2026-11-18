"""Exercise the built CLI against an independent local WebSocket peer."""
import base64
import hashlib
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager

EXE = str(Path(sys.argv[1]).resolve())


def exact(sock, n):
    data = bytearray()
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise EOFError("peer disconnected")
        data.extend(chunk)
    return bytes(data)


def read_frame(sock):
    flags, size = exact(sock, 2)
    assert flags & 0xf0 == 0x80 and size & 0x80
    size &= 127
    if size == 126:
        size = struct.unpack("!H", exact(sock, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", exact(sock, 8))[0]
    key = exact(sock, 4)
    payload = bytes(c ^ key[i % 4] for i, c in enumerate(exact(sock, size)))
    return flags & 15, payload


def frame(sock, opcode, payload):
    size = len(payload)
    length = bytes([size]) if size < 126 else (
        b"\x7e" + struct.pack("!H", size) if size < 65536
        else b"\x7f" + struct.pack("!Q", size))
    sock.sendall(bytes([0x80 | opcode]) + length + payload)


def finish(sock):
    opcode, payload = read_frame(sock)
    assert opcode == 8 and payload == b"\x03\xe8"
    frame(sock, 8, payload)


@contextmanager
def server(handler, unix=None, bad_accept=False):
    listener = socket.socket(socket.AF_UNIX if unix else socket.AF_INET)
    listener.bind(str(unix) if unix else ("127.0.0.1", 0))
    listener.listen()
    listener.settimeout(5)
    errors = []

    def serve():
        try:
            with listener.accept()[0] as sock:
                sock.settimeout(4)
                headers = bytearray()
                while not headers.endswith(b"\r\n\r\n"):
                    headers.extend(exact(sock, 1))
                    assert len(headers) < 8192
                key = next(h.split(b": ", 1)[1] for h in headers.split(b"\r\n")
                           if h.startswith(b"Sec-WebSocket-Key: "))
                digest = hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest()
                accept = b"invalid" if bad_accept else base64.b64encode(digest)
                sock.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                             b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                handler(sock)
        except BaseException as err:
            errors.append(err)

    thread = threading.Thread(target=serve)
    thread.start()
    try:
        if unix:
            yield ["--unix", str(unix), "--target", "/session", "--host", "fixture"]
        else:
            yield ["ws://127.0.0.1:%d/" % listener.getsockname()[1]]
    finally:
        thread.join(6)
        listener.close()
        assert not thread.is_alive()
        if errors:
            raise errors[0]


def read_line(proc):
    assert select.select([proc.stdout], [], [], 3)[0], "timed out waiting for CLI stdout"
    return proc.stdout.readline()


def interactive(sock):
    frame(sock, 1, b'{\n "id" : 0, "label":"a b" }')
    for value in (1, 2):
        expected = ('{"id":%d}' % value).encode()
        assert read_frame(sock) == (1, expected)
        frame(sock, 1, expected)
    finish(sock)


with server(interactive) as endpoint:
    with subprocess.Popen([EXE, *endpoint, "--jsonl", "--receive", "3"], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0) as proc:
        received = [read_line(proc)]
        assert received[0] == b'{"id":0,"label":"a b"}\n'
        for value in (1, 2):
            proc.stdin.write(('{"id":%d}\n' % value).encode())
            received.append(read_line(proc))
        assert proc.wait(timeout=4) == 0 and proc.stderr.read() == b""
        check = subprocess.run(["jqz", "--ndjson", ".id"], input=b"".join(received),
                               capture_output=True, check=True)
        assert check.stdout == b"0\n1\n2\n" and check.stderr == b""

with tempfile.TemporaryDirectory() as tmp:
    data = bytes(range(256)) * 257
    path = Path(tmp, "payload")
    path.write_bytes(data)

    def binary(sock):
        assert read_frame(sock) == (2, data)
        frame(sock, 2, data)
        finish(sock)

    with server(binary, Path(tmp, "peer.sock")) as endpoint:
        result = subprocess.run([EXE, *endpoint, "--binary", "--input", str(path)],
                                capture_output=True, timeout=5)
        assert (result.returncode, result.stdout, result.stderr) == (0, data, b"")


def early_close(sock):
    frame(sock, 8, b"\x03\xe9away")
    assert read_frame(sock) == (8, b"\x03\xe9away")


def normal_close(sock):
    frame(sock, 8, b"\x03\xe8")
    assert read_frame(sock) == (8, b"\x03\xe8")


for handler, bad, options, status, diagnostic in [
    (lambda s: None, True, [], 1, b"WebSocketUpgradeFailed"),
    (lambda s: time.sleep(.15), False, ["--timeout-ms", "60"], 1, b"Timeout"),
    (early_close, False, ["--receive", "1"], 1, b"peer close 1001 away"),
    (normal_close, False, [], 0, b""),
]:
    with server(handler, bad_accept=bad) as endpoint:
        result = subprocess.run([EXE, *endpoint, *options], input=b"", capture_output=True, timeout=4)
        assert result.returncode == status and result.stdout == b"", result
        assert diagnostic in result.stderr
        if status == 0:
            assert result.stderr == b""

print("CLI fixtures passed")
