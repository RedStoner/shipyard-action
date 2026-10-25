# shellcheck shell=sh
# Shipyard action helpers (POSIX sh). Sourced by shipyard.sh and the tests.
# The slug and name rules mirror core/src/Names.php; tests check both against
# core/tests/fixtures/slugs.tsv.

# Prints the file name without ".disabled" suffixes and without .jar/.zip.
sy_base() {
    sy_b=$1
    while :; do
        case $sy_b in
            ?*.[dD][iI][sS][aA][bB][lL][eE][dD]) sy_b=${sy_b%.*} ;;
            *) break ;;
        esac
    done
    case $sy_b in
        ?*.[jJ][aA][rR] | ?*.[zZ][iI][pP]) sy_b=${sy_b%.*} ;;
    esac
    printf '%s' "$sy_b"
}

# Plugin slug of a file name: version and build classifier stripped.
sy_slug() {
    sy_b=$(sy_base "$1")
    if printf '%s' "$sy_b" | grep -Eq '^[vV]?[0-9]+\.[0-9]'; then
        return 0
    fi
    # shellcheck disable=SC2018,SC2019 # ASCII on purpose, like PHP strtolower
    sy_h=$(printf '%s' "$sy_b" | sed -E 's/[-_ ][vV]?[0-9].*$//' | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    sy_s=$(printf '%s' "$sy_h" | sed -E 's/-(all|shadow|shaded|fat|uber|plain|reobf|remapped)$//')
    if [ -n "$sy_s" ]; then printf '%s' "$sy_s"; else printf '%s' "$sy_h"; fi
}

# Version part of a file name, or nothing for a steady name.
sy_version_text() {
    sy_b=$(sy_base "$1")
    if printf '%s' "$sy_b" | grep -Eq '^[vV]?[0-9]+\.[0-9]'; then
        printf '%s' "$sy_b"
        return 0
    fi
    printf '%s' "$sy_b" | awk '{
        if (match($0, /[-_ ][vV]?[0-9]/)) print substr($0, RSTART + 1)
    }' | tr -d '\n'
}

# Prints why a file name is not acceptable, or nothing.
sy_check_name() {
    sy_n=$1
    if [ -z "$sy_n" ]; then echo 'the file name is empty'; return; fi
    if [ "${#sy_n}" -gt 128 ]; then echo 'the file name is longer than 128 characters'; return; fi
    if printf '%s' "$sy_n" | LC_ALL=C grep -q "[^A-Za-z0-9._+ '!()-]"; then
        echo "the file name has a character other than letters, digits and . _ + - space ' ! ( )"
        return
    fi
    case $sy_n in
        .* | -* | ' '*) echo 'the file name may not start with a dot, a dash or a space'; return ;;
        *' ') echo 'the file name may not end with a space'; return ;;
    esac
    case $sy_n in
        *.[jJ][aA][rR] | *.[zZ][iI][pP]) ;;
        *) echo 'only .jar and .zip files can be sent' ;;
    esac
}

sy_sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -c1-64
    else
        shasum -a 256 "$1" | cut -c1-64
    fi
}

# First 8 hex of sha256(secret); the secret goes through a pipe, never argv.
sy_fingerprint() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$SHIPYARD_SECRET" | sha256sum | cut -c1-8
    else
        printf '%s' "$SHIPYARD_SECRET" | shasum -a 256 | cut -c1-8
    fi
}

# HMAC-SHA256 hex of stdin with $SHIPYARD_SECRET. The key is read from the
# environment by python3 or node, so it never appears in a process list.
sy_hmac() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import hmac, hashlib, os, sys; print(hmac.new(os.environ["SHIPYARD_SECRET"].encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())'
    elif command -v node >/dev/null 2>&1; then
        node -e 'const c=require("crypto");let d=[];process.stdin.on("data",x=>d.push(x)).on("end",()=>console.log(c.createHmac("sha256",process.env.SHIPYARD_SECRET).update(Buffer.concat(d)).digest("hex")))'
    elif sy_java=$(sy_jdk_tool java); then
        # Runners built on the stock Pterodactyl images have a JDK but neither python3 nor node.
        sy_hdir=$(mktemp -d) || return 1
        printf '%s
' 'public class ShipyardHmac { public static void main(String[] a) throws Exception {'             'javax.crypto.Mac m = javax.crypto.Mac.getInstance("HmacSHA256");'             'm.init(new javax.crypto.spec.SecretKeySpec(System.getenv("SHIPYARD_SECRET").getBytes("UTF-8"), "HmacSHA256"));'             'StringBuilder s = new StringBuilder(); for (byte b : m.doFinal(System.in.readAllBytes())) s.append(String.format("%02x", b));'             'System.out.println(s); } }' >"$sy_hdir/ShipyardHmac.java"
        "$sy_java" "$sy_hdir/ShipyardHmac.java"
        sy_hcode=$?
        rm -rf "$sy_hdir"
        return "$sy_hcode"
    else
        echo 'shipyard: needs python3, node or a JDK to sign uploads without exposing the secret' >&2
        return 1
    fi
}

# Path of a JDK tool ($1: java or jar) from PATH or $JAVA_HOME; fails when there is none.
sy_jdk_tool() {
    if command -v "$1" >/dev/null 2>&1; then
        command -v "$1"
    elif [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/$1" ]; then
        printf '%s
' "$JAVA_HOME/bin/$1"
    else
        return 1
    fi
}

# JSON string body (backslash and quote escaped, control bytes dropped).
sy_json() {
    printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Encodes $1 for a header value: "%" and spaces (the server rawurldecodes).
sy_urlencode() {
    printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g'
}

# Writes stamp file $2 into archive $1 as META-INF/shipyard-build.json with
# python3, replacing any stamp already there. zipfile cannot delete, and
# appending would leave two entries of that name (readers take the first),
# so the archive is rewritten without the old one.
sy_stamp_python() {
    python3 - "$1" "$2" <<'PY'
import os, sys, zipfile
path, stamp = sys.argv[1], sys.argv[2]
name = 'META-INF/shipyard-build.json'
tmp = path + '.stamping'
with zipfile.ZipFile(path) as src, zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as out:
    for item in src.infolist():
        if item.filename != name:
            out.writestr(item, src.read(item.filename))
    out.write(stamp, name)
os.replace(tmp, path)
PY
}
