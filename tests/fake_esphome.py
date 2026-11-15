"""A stand-in ESPHome device for the QEMU bundle test: the plaintext native API
(hello, connect, device info, entities, states, pings) of a Zuidwijk doorbell.

`FakeDoorbell(port).start()` listens on 0.0.0.0; `ring()` presses the button
(on, then off) on every live connection. Everything a client sent ends up in
`seen` as (type, payload) pairs, for the test to check.
"""
import socket
import struct
import threading


def varint(n):
    out = b''
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def text(num, value):
    raw = value.encode()
    return varint(num << 3 | 2) + varint(len(raw)) + raw


def uint(num, value):
    return varint(num << 3) + varint(value)


def fixed(num, value):
    return varint(num << 3 | 5) + struct.pack('<I', value)


def single(num, value):
    return varint(num << 3 | 5) + struct.pack('<f', value)


def frame(kind, payload=b''):
    return b'\0' + varint(len(payload)) + varint(kind) + payload


BELL, CHIME, SIGNAL = 0x1001, 0x1002, 0x1003

ENTITIES = [
    (12, text(1, 'doorbell') + fixed(2, BELL) + text(3, 'Doorbell') + text(4, 'doorbellbinary_sensordoorbell')),
    (16, text(1, 'doorbell_wifi_signal') + fixed(2, SIGNAL) + text(3, 'Doorbell WiFi Signal')
         + text(4, 'c8c9a36abd17-wifisignal') + text(6, 'dBm') + text(9, 'signal_strength') + uint(10, 1) + uint(13, 2)),
    (17, text(1, 'doorbell_chime_active') + fixed(2, CHIME) + text(3, 'Doorbell Chime Active')
         + text(4, 'doorbellswitchdoorbell_chime_active')),
]
STATES = [
    (21, fixed(1, BELL)),
    (25, fixed(1, SIGNAL) + single(2, -66.0)),
    (26, fixed(1, CHIME) + uint(2, 1)),
]
INFO = (text(2, 'doorbell') + text(3, 'C8:C9:A3:6A:BD:17') + text(4, '2022.6.1')
        + text(6, 'd1_mini') + text(8, 'zuidwijk.doorbell') + text(9, '2.0'))


def read_varint(sock):
    shift = n = 0
    while True:
        b = sock.recv(1)
        if not b:
            raise EOFError
        n |= (b[0] & 0x7F) << shift
        shift += 7
        if not b[0] & 0x80:
            return n


def read_exact(sock, n):
    out = b''
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise EOFError
        out += chunk
    return out


class FakeDoorbell:
    def __init__(self, port=6053):
        self.server = socket.socket()
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(('0.0.0.0', port))
        self.server.listen(8)
        self.seen = []
        self.connections = 0
        self.live = []
        self.lock = threading.Lock()

    def start(self):
        threading.Thread(target=self.accept, daemon=True).start()
        return self

    def close(self):
        self.server.close()

    def accept(self):
        while True:
            try:
                sock, _ = self.server.accept()
            except OSError:
                return
            with self.lock:
                self.connections += 1
            threading.Thread(target=self.serve, args=(sock,), daemon=True).start()

    def ring(self):
        with self.lock:
            for sock in list(self.live):
                try:
                    sock.sendall(frame(21, fixed(1, BELL) + uint(2, 1)) + frame(21, fixed(1, BELL)))
                except OSError:
                    pass

    def serve(self, sock):
        try:
            while True:
                if read_exact(sock, 1) != b'\0':
                    return
                length = read_varint(sock)
                kind = read_varint(sock)
                payload = read_exact(sock, length)
                with self.lock:
                    self.seen.append((kind, payload))
                if kind == 1:
                    sock.sendall(frame(2, uint(1, 1) + uint(2, 6) + text(3, 'doorbell (esphome v2022.6.1)') + text(4, 'doorbell')))
                elif kind == 3:
                    sock.sendall(frame(4))
                elif kind == 9:
                    sock.sendall(frame(10, INFO))
                elif kind == 11:
                    sock.sendall(b''.join(frame(k, p) for k, p in ENTITIES) + frame(19))
                elif kind == 20:
                    sock.sendall(b''.join(frame(k, p) for k, p in STATES))
                    with self.lock:
                        self.live.append(sock)
                elif kind == 7:
                    sock.sendall(frame(8))
                elif kind == 5:
                    sock.sendall(frame(6))
                    return
        except (EOFError, OSError):
            return
        finally:
            with self.lock:
                if sock in self.live:
                    self.live.remove(sock)
            sock.close()


if __name__ == '__main__':
    import time
    bell = FakeDoorbell().start()
    print('fake ESPHome doorbell on :6053', flush=True)
    while True:
        time.sleep(30)
        print('connections', bell.connections, 'messages', [k for k, _ in bell.seen][-12:], flush=True)
