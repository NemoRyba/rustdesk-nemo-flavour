#!/usr/bin/env python3
"""Check a TBFDesk direct endpoint from OUTSIDE, the way a controller will see it.

    probe-direct-endpoint.py <host:port> [expected-peer-id]
    probe-direct-endpoint.py 85.126.226.2:21666 352069946

Run it from a machine that is on neither network (a phone hotspot will do). From inside,
a router without NAT reflection gives a different answer that proves nothing.

What it tells apart (this is the whole point; "port closed" alone is not enough):
  refused   something answered and rejected the port: no forward rule (on a router that
            rejects), a forward to the router itself, or nothing listening behind it
  timeout   nothing answered: a router or firewall dropping the SYN
  closed    the forward reached something that accepted and hung up without speaking
  foreign   the forward reached a service that is not a TBFDesk peer
  PEER      a TBFDesk peer answered. With an expected id, it also says whether it is the
            RIGHT peer: the first frame is the peer's signed id, and the signed message
            carries the id in plain text next to the signature

Exit code 0 only for PEER (and, given an id, the right one).
"""
import socket
import sys
import time


def main() -> int:
    if len(sys.argv) < 2 or ":" not in sys.argv[1]:
        print(__doc__)
        return 2
    host, port = sys.argv[1].rsplit(":", 1)
    want = sys.argv[2].replace(" ", "") if len(sys.argv) > 2 else ""
    t0 = time.time()
    s = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET)
    s.settimeout(5)
    try:
        s.connect((host.strip("[]"), int(port)))
    except socket.timeout:
        print(f"timeout after {(time.time() - t0) * 1000:.0f} ms: nothing answered (dropped by a router or firewall)")
        return 1
    except ConnectionRefusedError:
        print(f"refused in {(time.time() - t0) * 1000:.0f} ms: something rejected the port "
              "(no forward, a forward to the router itself, or nothing listening behind it)")
        return 1
    except OSError as e:
        print(f"error: {e}")
        return 1
    rtt = (time.time() - t0) * 1000
    s.settimeout(4)
    data = b""
    try:
        while len(data) < 4096:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
            if len(data) >= 64:
                break
    except socket.timeout:
        pass
    finally:
        s.close()
    if not data:
        print(f"closed: connected in {rtt:.0f} ms, but the far end sent nothing and hung up "
              "(a forward to something that accepts but does not serve TBFDesk)")
        return 1
    # A TBFDesk peer speaks first: one length-prefixed frame holding Message{signed_id}.
    # The signed blob is signature || IdPk{id, pk}, so the id is readable in it.
    if b"\x00" not in data[:8] and data[:4] in (b"HTTP", b"SSH-"):
        print(f"foreign: connected in {rtt:.0f} ms, but a {data[:4].decode()} service answered, not a TBFDesk peer")
        return 1
    if want:
        if want.encode() in data:
            print(f"PEER {want}: connected in {rtt:.0f} ms and the right workstation answered "
                  f"with its signed id ({len(data)} bytes). The direct path is ready.")
            return 0
        print(f"foreign: connected in {rtt:.0f} ms, {len(data)} bytes, but they do not carry id "
              f"{want}: the forward reaches a different service or a different peer")
        return 1
    print(f"PEER?: connected in {rtt:.0f} ms and got {len(data)} bytes; pass the expected peer id "
          "to check that it is the right workstation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
