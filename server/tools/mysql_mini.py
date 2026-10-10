#!/usr/bin/env python3
"""
Tiny MySQL/MariaDB client using only the Python standard library (for machines without the
`mysql` program, e.g. a Steam Deck). Supports mysql_native_password and caching_sha2_password
(fast path, and full auth over plain TCP using the server's RSA key).

  MYSQL_PWD=secret python3 mysql_mini.py -H 127.0.0.1 -P 3306 -u acore -d acore_world -f file.sql
  MYSQL_PWD=secret python3 mysql_mini.py -H 127.0.0.1 -P 3306 -u acore -d acore_world -e "SELECT 1"
Query results are printed tab-separated, one row per line (like mysql -N -B).
"""
import argparse
import base64
import ssl
import hashlib
import os
import socket
import struct
import sys


class MySQLError(Exception):
    pass


# ----------------------------------------------------------------------------- RSA-OAEP (SHA-1), pure Python
def _der_read(buf, pos):
    tag = buf[pos]; pos += 1
    ln = buf[pos]; pos += 1
    if ln & 0x80:
        n = ln & 0x7F
        ln = int.from_bytes(buf[pos:pos + n], "big"); pos += n
    return tag, buf[pos:pos + ln], pos + ln


def _rsa_from_pem(pem):
    body = b"".join(l.strip() for l in pem.strip().splitlines() if l and not l.startswith(b"-----"))
    der = base64.b64decode(body)
    tag, spki, _ = _der_read(der, 0)                      # SubjectPublicKeyInfo SEQUENCE
    if pem.lstrip().startswith(b"-----BEGIN RSA PUBLIC KEY"):
        rsa = spki                                        # PKCS#1: SEQUENCE { n, e }
    else:
        _, _, p = _der_read(spki, 0)                      # AlgorithmIdentifier
        _, bitstr, _ = _der_read(spki, p)                 # BIT STRING
        _, rsa, _ = _der_read(bitstr[1:], 0)              # skip "unused bits" byte
    _, n, p = _der_read(rsa, 0)
    _, e, _ = _der_read(rsa, p)
    return int.from_bytes(n, "big"), int.from_bytes(e, "big")


def _mgf1(seed, length):
    out = b""; c = 0
    while len(out) < length:
        out += hashlib.sha1(seed + c.to_bytes(4, "big")).digest(); c += 1
    return out[:length]


def rsa_oaep_encrypt(pem, message):
    n, e = _rsa_from_pem(pem)
    k = (n.bit_length() + 7) // 8
    h = hashlib.sha1(b"").digest()
    if len(message) > k - 2 * len(h) - 2:
        raise MySQLError("password too long for the server's RSA key")
    db = h + b"\x00" * (k - len(message) - 2 * len(h) - 2) + b"\x01" + message
    seed = os.urandom(len(h))
    masked_db = bytes(a ^ b for a, b in zip(db, _mgf1(seed, k - len(h) - 1)))
    masked_seed = bytes(a ^ b for a, b in zip(seed, _mgf1(masked_db, len(h))))
    em = b"\x00" + masked_seed + masked_db
    return pow(int.from_bytes(em, "big"), e, n).to_bytes(k, "big")


# ----------------------------------------------------------------------------- auth scrambles
def scramble_native(password, nonce):
    if not password:
        return b""
    a = hashlib.sha1(password).digest()
    c = hashlib.sha1(nonce + hashlib.sha1(a).digest()).digest()
    return bytes(x ^ y for x, y in zip(a, c))


def scramble_sha2(password, nonce):
    if not password:
        return b""
    a = hashlib.sha256(password).digest()
    b = hashlib.sha256(hashlib.sha256(a).digest() + nonce).digest()
    return bytes(x ^ y for x, y in zip(a, b))


# ----------------------------------------------------------------------------- connection
CLIENT_LONG_PASSWORD, CLIENT_CONNECT_WITH_DB, CLIENT_PROTOCOL_41 = 0x1, 0x8, 0x200
CLIENT_TRANSACTIONS, CLIENT_SECURE_CONNECTION, CLIENT_PLUGIN_AUTH = 0x2000, 0x8000, 0x80000
CLIENT_SSL = 0x800


class Conn:
    def __init__(self, host, port, user, password, db):
        if host == "." or str(port).startswith("/"):        # "." = local socket file given in the port field
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(20)
            self.sock.connect(str(port))
        else:
            self.sock = socket.create_connection((host, int(port)), timeout=20)
        self.seq = 0
        self.password = (password or "").encode()
        self._handshake(user, db)

    # packets
    def _recv_exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise MySQLError("server closed the connection")
            data += chunk
        return data

    def read(self):
        payload = b""
        while True:
            hdr = self._recv_exact(4)
            ln = hdr[0] | hdr[1] << 8 | hdr[2] << 16
            self.seq = (hdr[3] + 1) & 0xFF
            payload += self._recv_exact(ln)
            if ln < 0xFFFFFF:
                return payload

    def send(self, payload):
        while True:
            part, payload = payload[:0xFFFFFF], payload[0xFFFFFF:]
            self.sock.sendall(struct.pack("<I", len(part))[:3] + bytes([self.seq]) + part)
            self.seq = (self.seq + 1) & 0xFF
            if len(part) < 0xFFFFFF:
                return

    @staticmethod
    def _err(pkt):
        code = struct.unpack("<H", pkt[1:3])[0]
        msg = pkt[9:] if pkt[3:4] == b"#" else pkt[3:]
        return MySQLError("ERROR %d: %s" % (code, msg.decode("utf-8", "replace")))

    # login
    def _handshake(self, user, db):
        p = self.read()
        if p[0] == 0xFF:
            raise self._err(p)
        if p[0] != 10:
            raise MySQLError("unsupported server protocol %d" % p[0])
        pos = p.index(b"\x00", 1) + 1                       # server version
        pos += 4                                           # connection id
        nonce = p[pos:pos + 8]; pos += 9                   # part 1 + filler
        caps = struct.unpack("<H", p[pos:pos + 2])[0]; pos += 2
        plugin = "mysql_native_password"
        if len(p) > pos:
            pos += 3                                       # charset, status flags
            caps |= struct.unpack("<H", p[pos:pos + 2])[0] << 16; pos += 2
            alen = p[pos]; pos += 11                       # auth data len + 10 reserved
            if caps & CLIENT_SECURE_CONNECTION:
                n2 = max(13, alen - 8)
                nonce += p[pos:pos + n2].rstrip(b"\x00")[:12]; pos += n2
            if caps & CLIENT_PLUGIN_AUTH:
                plugin = p[pos:].split(b"\x00")[0].decode() or plugin
        self.nonce = nonce
        flags = (CLIENT_LONG_PASSWORD | CLIENT_PROTOCOL_41 | CLIENT_TRANSACTIONS | CLIENT_SECURE_CONNECTION
                 | CLIENT_PLUGIN_AUTH | (CLIENT_CONNECT_WITH_DB if db else 0))
        self.tls = False
        if caps & CLIENT_SSL:                              # encrypt when the server offers it (like the mysql program)
            flags |= CLIENT_SSL
            self.send(struct.pack("<IIB", flags, 16 * 1024 * 1024, 45) + b"\x00" * 23)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE                # local server, self-signed certificate
            self.sock = ctx.wrap_socket(self.sock)
            self.tls = True
        auth = self._scramble(plugin)
        resp = struct.pack("<IIB", flags, 16 * 1024 * 1024, 45) + b"\x00" * 23
        resp += user.encode() + b"\x00" + bytes([len(auth)]) + auth
        if db:
            resp += db.encode() + b"\x00"
        resp += plugin.encode() + b"\x00"
        self.send(resp)
        self._auth_loop(plugin)

    def _scramble(self, plugin):
        if plugin == "caching_sha2_password":
            return scramble_sha2(self.password, self.nonce)
        if plugin == "mysql_native_password":
            return scramble_native(self.password, self.nonce)
        if plugin == "mysql_clear_password":
            return self.password + b"\x00"
        raise MySQLError("server wants login method '%s', which this tool does not support" % plugin)

    def _auth_loop(self, plugin):
        while True:
            p = self.read()
            if p[0] == 0x00:
                return
            if p[0] == 0xFF:
                raise self._err(p)
            if p[0] == 0xFE:                               # auth switch request
                rest = p[1:]
                plugin = rest.split(b"\x00")[0].decode()
                self.nonce = rest[len(plugin) + 1:].rstrip(b"\x00")[:20]
                self.send(self._scramble(plugin))
                continue
            if p[0] == 0x01 and plugin == "caching_sha2_password":
                if p[1:2] == b"\x03":                      # fast auth OK, OK packet follows
                    continue
                if p[1:2] == b"\x04" and self.tls:         # full auth over TLS: send the password
                    self.send(self.password + b"\x00")
                    continue
                if p[1:2] == b"\x04":                      # full auth without TLS: ask for the RSA key
                    self.send(b"\x02")
                    pem = self.read()[1:]
                    pw = self.password + b"\x00"
                    xored = bytes(c ^ self.nonce[i % len(self.nonce)] for i, c in enumerate(pw))
                    self.send(rsa_oaep_encrypt(pem, xored))
                    continue
            raise MySQLError("unexpected login reply 0x%02x" % p[0])

    # queries
    @staticmethod
    def _lenenc(p, pos):
        b = p[pos]
        if b < 0xFB:
            return b, pos + 1
        if b == 0xFB:
            return None, pos + 1
        n = {0xFC: 2, 0xFD: 3, 0xFE: 8}[b]
        return int.from_bytes(p[pos + 1:pos + 1 + n], "little"), pos + 1 + n

    def query(self, sql):
        self.seq = 0
        self.send(b"\x03" + sql.encode("utf-8"))
        p = self.read()
        if p[0] == 0xFF:
            raise self._err(p)
        if p[0] == 0x00:
            affected, _ = self._lenenc(p, 1)
            return None, affected
        ncols, _ = self._lenenc(p, 0)
        for _ in range(ncols):
            self.read()                                    # column definitions
        p = self.read()                                    # EOF after columns
        rows = []
        while True:
            p = self.read()
            if p[0] == 0xFE and len(p) < 9:
                break
            if p[0] == 0xFF:
                raise self._err(p)
            row, pos = [], 0
            for _ in range(ncols):
                ln, pos = self._lenenc(p, pos)
                if ln is None:
                    row.append("NULL")
                else:
                    row.append(p[pos:pos + ln].decode("utf-8", "replace")); pos += ln
            rows.append(row)
        return rows, len(rows)

    def close(self):
        try:
            self.seq = 0
            self.send(b"\x01")
        except OSError:
            pass
        self.sock.close()


def split_sql(text):
    """Split a SQL file into statements (handles quotes, -- and # comments)."""
    out, cur, q, i = [], [], None, 0
    while i < len(text):
        ch = text[i]
        if q:
            cur.append(ch)
            if ch == "\\" and q != "`" and i + 1 < len(text):
                cur.append(text[i + 1]); i += 1
            elif ch == q:
                q = None
        elif ch in "'\"`":
            q = ch; cur.append(ch)
        elif ch == "-" and text[i:i + 2] == "--" and (i + 2 >= len(text) or text[i + 2] in " \t\r\n"):
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        elif ch == "#":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        elif ch == ";":
            s = "".join(cur).strip()
            if s:
                out.append(s)
            cur = []
        else:
            cur.append(ch)
        i += 1
    s = "".join(cur).strip()
    if s:
        out.append(s)
    return out


def main():
    ap = argparse.ArgumentParser(description="Tiny MySQL client (password in MYSQL_PWD)")
    ap.add_argument("-H", "--host", default="127.0.0.1")
    ap.add_argument("-P", "--port", default="3306")
    ap.add_argument("-u", "--user", required=True)
    ap.add_argument("-d", "--database", default="")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("-f", "--file")
    g.add_argument("-e", "--execute")
    a = ap.parse_args()
    try:
        c = Conn(a.host, a.port, a.user, os.environ.get("MYSQL_PWD", ""), a.database)
        stmts = split_sql(open(a.file, encoding="utf-8").read()) if a.file else [a.execute]
        for s in stmts:
            rows, _ = c.query(s)
            for r in rows or []:
                print("\t".join(r))
        c.close()
    except (MySQLError, OSError) as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
