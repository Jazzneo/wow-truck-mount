#!/usr/bin/env bash
# =============================================================================
#  Truck Mount installer for AzerothCore (WoW 3.3.5a) - Linux / macOS / WSL
#  Gives every character two mount buttons: "Truck with Lights" and "Truck with No Lights".
#
#  Usage:   bash install.sh                        (finds worldserver.conf by itself)
#           bash install.sh /path/to/worldserver.conf
#           bash install.sh --uninstall [/path/to/worldserver.conf]
#  Then restart worldserver. Players run the installer in the client folder.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNINSTALL=0
if [[ "${1:-}" == "--uninstall" ]]; then UNINSTALL=1; shift; fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: bash install.sh [--uninstall] [/path/to/worldserver.conf]"; exit 0
fi

builtin_sql() {   # copies of the files in sql/, used when this script is run on its own
  case "$1" in
    install_world) cat <<'SQL_END'
-- Truck Mount: new characters start with both truck buttons.
-- Needs PlayerStart.CustomSpells = 1 in worldserver.conf (the installer turns it on).
--   55531 = Truck with Lights      (Mechano-Hog spell, changed by the client patch)
--   60424 = Truck with No Lights   (Mekgineers Chopper spell, changed by the client patch)
DELETE FROM `playercreateinfo_spell_custom` WHERE `Spell` IN (55531, 60424);
INSERT INTO `playercreateinfo_spell_custom` (`racemask`, `classmask`, `Spell`, `Note`) VALUES
(0, 0, 55531, 'Truck Mount: Truck with Lights'),
(0, 0, 60424, 'Truck Mount: Truck with No Lights');
SQL_END
    ;;
    install_characters) cat <<'SQL_END'
-- Truck Mount: give both truck buttons to every existing character.
-- Characters that get a button from this installer are remembered in `truck_mount_granted`,
-- so uninstalling removes only what the installer added (a crafted Mechano-Hog stays).
CREATE TABLE IF NOT EXISTS `truck_mount_granted` (
  `guid` INT UNSIGNED NOT NULL,
  `spell` INT UNSIGNED NOT NULL,
  PRIMARY KEY (`guid`, `spell`)
);
INSERT IGNORE INTO `truck_mount_granted` (`guid`, `spell`)
SELECT c.`guid`, 55531 FROM `characters` c
LEFT JOIN `character_spell` s ON s.`guid` = c.`guid` AND s.`spell` = 55531 WHERE s.`guid` IS NULL;
INSERT IGNORE INTO `truck_mount_granted` (`guid`, `spell`)
SELECT c.`guid`, 60424 FROM `characters` c
LEFT JOIN `character_spell` s ON s.`guid` = c.`guid` AND s.`spell` = 60424 WHERE s.`guid` IS NULL;
INSERT IGNORE INTO `character_spell` (`guid`, `spell`, `specMask`)
SELECT `guid`, 55531, 255 FROM `characters`;
INSERT IGNORE INTO `character_spell` (`guid`, `spell`, `specMask`)
SELECT `guid`, 60424, 255 FROM `characters`;
SQL_END
    ;;
    uninstall_world) cat <<'SQL_END'
-- Truck Mount uninstall: new characters no longer start with the truck buttons.
DELETE FROM `playercreateinfo_spell_custom` WHERE `Spell` IN (55531, 60424);
SQL_END
    ;;
    uninstall_characters) cat <<'SQL_END'
-- Truck Mount uninstall: remove only the truck buttons this installer gave out.
CREATE TABLE IF NOT EXISTS `truck_mount_granted` (
  `guid` INT UNSIGNED NOT NULL,
  `spell` INT UNSIGNED NOT NULL,
  PRIMARY KEY (`guid`, `spell`)
);
DELETE FROM `character_spell` WHERE (`guid`, `spell`) IN (SELECT `guid`, `spell` FROM `truck_mount_granted`);
DROP TABLE `truck_mount_granted`;
SQL_END
    ;;
  esac
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/truck_mount.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT    # all temp files live here
sql_file() {      # sql_file NAME -> path of sql/NAME.sql, or a temp copy of the built-in one
  if [[ -f "$HERE/sql/$1.sql" ]]; then echo "$HERE/sql/$1.sql"; return; fi
  builtin_sql "$1" > "$WORK/$1.sql"; echo "$WORK/$1.sql"
}
if (( UNINSTALL )); then ACT=uninstall; else ACT=install; fi
SQL_WORLD="$(sql_file ${ACT}_world)"; SQL_CHARS="$(sql_file ${ACT}_characters)"
SPELL=55531

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()   { red "ERROR: $*"; exit 1; }

write_mini() {  # built-in MySQL client (same as tools/mysql_mini.py)
cat <<'PYCLIENT_END'
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
PYCLIENT_END
}

# ----------------------------------------------------------------------------- 1. find worldserver.conf
step "1/4  Finding worldserver.conf"
CONF="${1:-}"
if [[ -z "$CONF" ]]; then
  mapfile -t FOUND < <(
    for root in "$PWD" "$HERE/.." "$HOME" /opt /srv /usr/local /home; do
      [[ -d "$root" ]] && find "$root" -maxdepth 7 -type f -name worldserver.conf 2>/dev/null
    done | while IFS= read -r f; do realpath "$f" 2>/dev/null || echo "$f"; done | awk '!seen[$0]++'
  )
  if (( ${#FOUND[@]} == 0 )); then
    die "worldserver.conf not found. Run again with its path:  ./install.sh /path/to/worldserver.conf
       (if you only have worldserver.conf.dist, copy it to worldserver.conf first)"
  elif (( ${#FOUND[@]} > 1 )); then
    echo "Found more than one:"; i=1; for f in "${FOUND[@]}"; do echo "  $i) $f"; i=$((i+1)); done
    read -rp "Which one does your server use? [1-${#FOUND[@]}] " n
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#FOUND[@]} )) || die "Invalid choice."
    CONF="${FOUND[$((n-1))]}"
  else
    CONF="${FOUND[0]}"
  fi
fi
[[ -f "$CONF" ]] || die "File not found: $CONF"
green "Using $CONF"

# ----------------------------------------------------------------------------- 2. read database logins
step "2/4  Reading database logins"
conf_value() {  # prints the value of KEY from the conf, without quotes or Windows line endings
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONF" | tail -n1 | sed -E 's/^[^=]*=[[:space:]]*//; s/\r$//; s/^"//; s/"[[:space:]]*$//'
}
WORLD_INFO="$(conf_value WorldDatabaseInfo)"
CHAR_INFO="$(conf_value CharacterDatabaseInfo)"
[[ -n "$WORLD_INFO" && -n "$CHAR_INFO" ]] || die "WorldDatabaseInfo / CharacterDatabaseInfo missing in $CONF"
split_info() { IFS=';' read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME <<< "$1"; }
# Docker setups (docker-compose.yml next to the server) ignore the logins in worldserver.conf:
# the real ones are AC_*_DATABASE_INFO in docker-compose.yml, with the password from .env.
DOCKER_ROOT=""; d="$(dirname "$CONF")"
for _ in 1 2 3 4 5; do
  if [[ -f "$d/docker-compose.yml" || -f "$d/docker-compose.override.yml" ]]; then DOCKER_ROOT="$d"; break; fi
  d="$(dirname "$d")"
done
env_value() {   # env_value VAR default  -> value from .env, else default
  local v=""
  [[ -f "$DOCKER_ROOT/.env" ]] && v="$(grep -E "^[[:space:]]*$1=" "$DOCKER_ROOT/.env" | tail -n1 | cut -d= -f2- | sed -E 's/\r$//; s/^["'\'']//; s/["'\'']$//')"
  printf '%s' "${v:-$2}"
}
resolve_vars() { # replace ${VAR:-default} and ${VAR} with values from .env
  local s="$1" m var def
  while [[ "$s" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\} ]]; do
    m="${BASH_REMATCH[0]}"; var="${BASH_REMATCH[1]}"; def="${BASH_REMATCH[3]}"
    s="${s/"$m"/$(env_value "$var" "$def")}"
  done
  printf '%s' "$s"
}
compose_info() { # compose_info AC_WORLD_DATABASE_INFO -> "host;port;user;pass;db" from docker-compose files
  local f line
  for f in "$DOCKER_ROOT/docker-compose.override.yml" "$DOCKER_ROOT/docker-compose.yml"; do
    [[ -f "$f" ]] || continue
    line="$(grep -E "^[[:space:]-]*$1[[:space:]]*[:=]" "$f" | head -n1 | sed -E "s/^[^:=]*[:=][[:space:]]*//; s/^[\"']//; s/[\"'][[:space:]]*$//")"
    [[ -n "$line" ]] && { resolve_vars "$line"; return; }
  done
}
if [[ -n "$DOCKER_ROOT" ]]; then
  echo "Docker setup found in $DOCKER_ROOT - using its database login."
  DB_EXT_PORT="$(env_value DOCKER_DB_EXTERNAL_PORT 3306)"
  for which in WORLD CHARACTER; do
    info="$(compose_info "AC_${which}_DATABASE_INFO")"
    [[ -n "$info" ]] || continue
    IFS=';' read -r _h _p u pw db <<< "$info"
    new="127.0.0.1;$DB_EXT_PORT;$u;$pw;$db"          # from this machine, the container is reached on the published port
    if [[ "$which" == WORLD ]]; then WORLD_INFO="$new"; else CHAR_INFO="$new"; fi
  done
fi
split_info "$WORLD_INFO"; echo "World database:      $DB_NAME on $DB_HOST:$DB_PORT (user $DB_USER)"
split_info "$CHAR_INFO";  echo "Characters database: $DB_NAME on $DB_HOST:$DB_PORT (user $DB_USER)"

# How to reach MySQL, in this order:
#   1. the mysql / mariadb program
#   2. the built-in client (tools/mysql_mini.py, needs only python3 - works on a Steam Deck)
#   3. a Docker / Podman database container
MODE=""; MYSQL_BIN=""; PY_BIN=""; CTR=""; CTR_TOOL=""
MINI="$WORK/mysql_mini.py"
write_mini > "$MINI"                                         # built-in client is stored inside this script
for c in mysql mariadb /usr/bin/mysql /usr/local/bin/mysql /usr/local/mysql/bin/mysql; do
  if command -v "$c" >/dev/null 2>&1; then MYSQL_BIN="$(command -v "$c")"; break; fi
done
for c in python3 python /usr/bin/python3 /usr/local/bin/python3 /bin/python3 "$HOME/.local/bin/python3"; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' 2>/dev/null; then
    PY_BIN="$(command -v "$c")"; break
  fi
done
if [[ -n "$MYSQL_BIN" ]]; then
  MODE=cli; echo "MySQL client: $MYSQL_BIN"
elif [[ -n "$PY_BIN" ]]; then
  MODE=py; echo "No mysql program found - using the built-in client with $PY_BIN"
else
  for t in docker podman; do
    command -v "$t" >/dev/null 2>&1 || continue
    CTR="$($t ps --format '{{.Names}}' 2>/dev/null | grep -E 'database|mysql|mariadb' | head -n1 || true)"
    [[ -n "$CTR" ]] && { CTR_TOOL="$t"; MODE=ctr; echo "Using MySQL inside $t container: $CTR"; break; }
  done
fi
[[ -n "$MODE" ]] || die "Could not reach MySQL: no mysql program, no Python 3 and no database container were found.
       Checked PATH=$PATH"

run_sql_file() {   # run_sql_file "<db info>" file.sql
  split_info "$1"
  case "$MODE" in
    cli) if [[ "$DB_HOST" == "." ]]; then MYSQL_PWD="$DB_PASS" "$MYSQL_BIN" --socket="$DB_PORT" -u"$DB_USER" "$DB_NAME" < "$2"
         else MYSQL_PWD="$DB_PASS" "$MYSQL_BIN" -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" "$DB_NAME" < "$2"; fi ;;
    py)  MYSQL_PWD="$DB_PASS" "$PY_BIN" "$MINI" -H "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -d "$DB_NAME" -f "$2" ;;
    ctr) "$CTR_TOOL" exec -i -e MYSQL_PWD="$DB_PASS" "$CTR" mysql -u"$DB_USER" "$DB_NAME" < "$2" ;;
  esac
}
run_sql_query() {  # run_sql_query "<db info>" "SELECT ..."  -> prints result
  split_info "$1"
  case "$MODE" in
    cli) if [[ "$DB_HOST" == "." ]]; then MYSQL_PWD="$DB_PASS" "$MYSQL_BIN" --socket="$DB_PORT" -u"$DB_USER" "$DB_NAME" -N -B -e "$2"
         else MYSQL_PWD="$DB_PASS" "$MYSQL_BIN" -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" "$DB_NAME" -N -B -e "$2"; fi ;;
    py)  MYSQL_PWD="$DB_PASS" "$PY_BIN" "$MINI" -H "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -d "$DB_NAME" -e "$2" ;;
    ctr) "$CTR_TOOL" exec -i -e MYSQL_PWD="$DB_PASS" "$CTR" mysql -u"$DB_USER" "$DB_NAME" -N -B -e "$2" ;;
  esac
}

# ----------------------------------------------------------------------------- 3. run the SQL
if (( UNINSTALL )); then step "3/4  Removing the truck from the databases"; else step "3/4  Adding the truck to the databases"; fi
split_info "$WORLD_INFO"
if [[ "$DB_HOST" != "." && -n "$PY_BIN" ]] && ! "$PY_BIN" -c "import socket,sys; socket.create_connection(('$DB_HOST', int('$DB_PORT')), 5)" 2>/dev/null; then
  die "MySQL is not running (nothing answers on $DB_HOST:$DB_PORT).
       Start your server the usual way (that starts MySQL too), then run this again."
fi
run_sql_file "$WORLD_INFO" "$SQL_WORLD" || die "Could not update the world database (wrong login or MySQL not running?)."
if (( UNINSTALL )); then green "World database: new characters no longer get the truck."; else green "World database: new characters will start with the truck."; fi
run_sql_file "$CHAR_INFO" "$SQL_CHARS" || die "Could not update the characters database."
COUNT="$(run_sql_query "$CHAR_INFO" "SELECT COUNT(*) FROM character_spell WHERE spell=$SPELL" | tr -d '[:space:]')"
if (( UNINSTALL )); then
  green "Characters database: truck buttons removed (${COUNT:-?} characters still have spell $SPELL, e.g. a crafted Mechano-Hog)."
  printf '\n'; green "UNINSTALLED. Restart worldserver. Players can run client/uninstall-client.sh (or .bat)."
  echo "(PlayerStart.CustomSpells was left on in case other custom spells use it.)"
  exit 0
fi
green "Characters database: ${COUNT:-?} characters now have the truck."

# ----------------------------------------------------------------------------- 4. turn on PlayerStart.CustomSpells
step "4/4  Turning on PlayerStart.CustomSpells"
if grep -qE '^[[:space:]]*PlayerStart\.CustomSpells[[:space:]]*=[[:space:]]*1' "$CONF"; then
  green "Already on."
else
  cp "$CONF" "$CONF.bak-truck"
  if grep -qE '^[[:space:]]*PlayerStart\.CustomSpells[[:space:]]*=' "$CONF"; then
    sed -i.tmp -E 's/^([[:space:]]*PlayerStart\.CustomSpells[[:space:]]*=[[:space:]]*)[0-9]+/\11/' "$CONF" && rm -f "$CONF.tmp"
  else
    printf '\nPlayerStart.CustomSpells = 1\n' >> "$CONF"
  fi
  green "Done (backup saved as $(basename "$CONF").bak-truck)."
fi

printf '\n'; green "ALL DONE. Restart worldserver, then look in Spellbook > Mounts:"
echo "  \"Truck with Lights\" and \"Truck with No Lights\"."
echo "Give players the client folder: they run install-client.sh (Linux/Steam Deck) or install-client.bat (Windows)."
