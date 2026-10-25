#!/bin/sh
# Shipyard GitHub Action: stamp, sign and send build artifacts to a panel.
# POSIX sh. Inputs arrive as INPUT_* environment variables (see action.yml);
# the secret only ever comes from SHIPYARD_SECRET in the environment.

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

fail() {
    printf '::error::%s\n' "$*"
    exit 1
}

PANEL_URL=${INPUT_PANEL_URL:-}
PANEL_URL=${PANEL_URL%/}
MAX_MB=${INPUT_MAX_MB:-95}
RETRIES=${INPUT_RETRIES:-3}
REPO=${GITHUB_REPOSITORY:-}
RUN_ID=${GITHUB_RUN_ID:-}
COMMIT=${SHIPYARD_COMMIT:-${GITHUB_SHA:-}}
BRANCH=${SHIPYARD_BRANCH:-${GITHUB_REF_NAME:-}}
WORK=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/shipyard-$$
# upload: false only stamps the files in place (for workflows that keep their own handover).
UPLOAD=${INPUT_UPLOAD:-true}
case $UPLOAD in true | false) ;; *) fail 'upload must be true or false.' ;; esac

# GitHub vouches for an upload through the webhook of the run that sent it, so
# the run id, commit and branch must all be the build's own. A workflow_run
# trigger is a different run (on the default branch) than the build it follows.
if [ "${GITHUB_EVENT_NAME:-}" = workflow_run ]; then
    fail 'Shipyard must run in the workflow that builds the files, not in a workflow triggered by workflow_run: the panel checks the upload against the run that sent it. Add the Shipyard step to the build job (or a later job of the same workflow).'
fi
if [ "$UPLOAD" = true ]; then
    [ -n "$PANEL_URL" ] || fail 'panel-url is not set.'
    case $PANEL_URL in
        https://* | http://localhost* | http://127.0.0.1*) ;;
        *) fail 'panel-url must start with https:// (the build and its signature travel over it).' ;;
    esac
fi
# shellcheck disable=SC2016 # the ${{ }} is literal text for the user
[ "$UPLOAD" = false ] || [ -n "${SHIPYARD_SECRET:-}" ] || fail 'SHIPYARD_SECRET is empty. Add it as a repository secret and pass it with env: SHIPYARD_SECRET: ${{ secrets.SHIPYARD_SECRET }}. On GitHub Free, organisation secrets do not reach private repositories; add it to the repository itself.'
if [ -z "$REPO" ] || [ -z "$RUN_ID" ] || [ -z "$COMMIT" ] || [ -z "$BRANCH" ]; then
    fail 'GITHUB_REPOSITORY, GITHUB_RUN_ID, the commit and the branch must be set (run this inside GitHub Actions).'
fi
case $MAX_MB in '' | *[!0-9]*) fail 'max-mb must be a whole number.' ;; esac
case $RETRIES in '' | *[!0-9]*) fail 'retries must be a whole number.' ;; esac

# Show length and fingerprint so a mismatch can be diagnosed without leaking it.
[ "$UPLOAD" = false ] || printf 'Shipyard secret: length %d, fingerprint %s (compare with the Shipyard admin page)\n' "${#SHIPYARD_SECRET}" "$(sy_fingerprint)"

# Expand the globs. Patterns are split on whitespace with globbing off, then
# each one is globbed on its own, so matched names may contain spaces.
patterns=$(printf '%s' "${INPUT_FILES:-}" | tr '\n' ' ')
mkdir -p "$WORK" || fail "cannot create $WORK"
: >"$WORK/files"
set -f
for pattern in $patterns; do
    set +f
    matched=''
    # shellcheck disable=SC2086 # the pattern is meant to glob
    for f in $pattern; do
        [ -f "$f" ] || continue
        matched=1
        printf '%s\n' "$f" >>"$WORK/files"
    done
    [ -n "$matched" ] || printf '::warning::No file matches %s\n' "$pattern"
    set -f
done
set +f
[ -s "$WORK/files" ] || fail "No files matched: ${INPUT_FILES:-}"

# Check every file before sending any, so a refused one means nothing is uploaded.
: >"$WORK/slugs"
problems=0
while IFS= read -r f; do
    name=$(basename "$f")
    why=$(sy_check_name "$name")
    if [ -n "$why" ]; then
        printf '::error file=%s::%s: %s\n' "$f" "$name" "$why"
        problems=$((problems + 1))
        continue
    fi
    slug=$(sy_slug "$name")
    if [ -z "$slug" ]; then
        printf '::error file=%s::%s: the name has no plugin name before the version\n' "$f" "$name"
        problems=$((problems + 1))
        continue
    fi
    other=$(awk -F '\t' -v s="$slug" '$1 == s { print $2; exit }' "$WORK/slugs")
    if [ -n "$other" ] && [ "$UPLOAD" = true ]; then
        printf '::error::%s and %s are the same plugin (%s). The build makes two jars of one plugin, often a shadow jar and a plain jar; list only the one servers should run in "files".\n' "$other" "$name" "$slug"
        problems=$((problems + 1))
        continue
    fi
    printf '%s\t%s\n' "$slug" "$name" >>"$WORK/slugs"
    size=$(wc -c <"$f" | tr -d ' ')
    if [ "$size" -gt $((MAX_MB * 1024 * 1024)) ]; then
        printf '::error file=%s::%s is %s bytes, above max-mb (%s MB)\n' "$f" "$name" "$size" "$MAX_MB"
        problems=$((problems + 1))
    fi
done <"$WORK/files"
[ "$problems" -eq 0 ] || fail "$problems file(s) cannot be sent; nothing was uploaded."

# Writes META-INF/shipyard-build.json into a copy of the archive.
stamp() {
    src=$1
    out=$2
    version=${INPUT_VERSION:-$(sy_version_text "$(basename "$src")")}
    mkdir -p "$WORK/stamp/META-INF"
    printf '{"repo":"%s","version":"%s","build":%s,"runId":"%s","commit":"%s","branch":"%s","builtAt":"%s"}\n' \
        "$(sy_json "$REPO")" "$(sy_json "$version")" "${GITHUB_RUN_NUMBER:-null}" "$RUN_ID" "$COMMIT" \
        "$(sy_json "$BRANCH")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$WORK/stamp/META-INF/shipyard-build.json"
    cp "$src" "$out" || return 1
    if command -v zip >/dev/null 2>&1; then
        (cd "$WORK/stamp" && zip -q "$out" META-INF/shipyard-build.json)
    elif command -v python3 >/dev/null 2>&1; then
        sy_stamp_python "$out" "$WORK/stamp/META-INF/shipyard-build.json"
    elif jar=$(sy_jdk_tool jar); then
        # The stock Pterodactyl images (managed runners) have a JDK but neither zip nor python3.
        # jar u replaces an entry of the same name.
        "$jar" uf "$out" -C "$WORK/stamp" META-INF/shipyard-build.json
    else
        echo 'shipyard: needs zip, python3 or a JDK (jar) to stamp archives (or set stamp: false)' >&2
        return 1
    fi
}

if [ "$UPLOAD" = false ]; then
    stamped=0
    while IFS= read -r f; do
        name=$(basename "$f")
        if stamp "$f" "$WORK/$name" && mv "$WORK/$name" "$f"; then
            printf 'Stamped %s\n' "$f"
            stamped=$((stamped + 1))
        else
            fail "Could not stamp $f"
        fi
    done <"$WORK/files"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '### Shipyard\nStamped %d file(s) in place.\n' "$stamped" >>"$GITHUB_STEP_SUMMARY"
    rm -rf "$WORK"
    exit 0
fi

sent=0
failed=0
while IFS= read -r f; do
    name=$(basename "$f")
    body="$WORK/$name"
    if [ "${INPUT_STAMP:-true}" = true ]; then
        stamp "$f" "$body" || { failed=$((failed + 1)); printf '::error::Could not stamp %s\n' "$name"; continue; }
    else
        cp "$f" "$body"
    fi
    digest=$(sy_sha256_file "$body")
    signature=$(printf 'shipyard-v1\n%s\n%s\n%s\n%s\n%s\n%s' "$digest" "$REPO" "$RUN_ID" "$name" "$BRANCH" "$COMMIT" | sy_hmac) || fail 'signing failed'

    attempt=0
    while :; do
        attempt=$((attempt + 1))
        code=$(curl -sS -o "$WORK/response" -w '%{http_code}' -X POST \
            -H 'Content-Type: application/octet-stream' \
            -H 'Expect:' \
            -H "X-Shipyard-Repo: $REPO" \
            -H "X-Shipyard-Run: $RUN_ID" \
            -H "X-Shipyard-File: $(sy_urlencode "$name")" \
            -H "X-Shipyard-Branch: $(sy_urlencode "$BRANCH")" \
            -H "X-Shipyard-Commit: $COMMIT" \
            -H "X-Shipyard-Digest: $digest" \
            -H "X-Shipyard-Signature: sha256=$signature" \
            --data-binary "@$body" \
            "$PANEL_URL/extensions/shipyard/ingest") || code=000
        case $code in
            2??)
                printf 'Sent %s: %s\n' "$name" "$(cat "$WORK/response")"
                sent=$((sent + 1))
                break
                ;;
            000 | 429 | 5??)
                if [ "$attempt" -gt "$RETRIES" ]; then
                    printf '::error::%s: the panel answered %s after %d attempts: %s\n' "$name" "$code" "$attempt" "$(head -c 500 "$WORK/response" 2>/dev/null)"
                    failed=$((failed + 1))
                    break
                fi
                wait=$((1 << attempt))
                printf 'Upload of %s got %s; retrying in %ds\n' "$name" "$code" "$wait"
                sleep "$wait"
                ;;
            *)
                printf '::error::%s was refused (%s): %s\n' "$name" "$code" "$(head -c 500 "$WORK/response")"
                failed=$((failed + 1))
                break
                ;;
        esac
    done
done <"$WORK/files"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Shipyard\nSent %d file(s) to %s; %d failed.\n' "$sent" "$PANEL_URL" "$failed" >>"$GITHUB_STEP_SUMMARY"
fi
rm -rf "$WORK"
[ "$failed" -eq 0 ] || exit 1
