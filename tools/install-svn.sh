#!/usr/bin/env bash
# install-svn.sh — install Subversion for CI, retrying the way each platform actually needs.
#
# Called by `tests.yml`'s `Install Subversion` step on BOTH legs. It lives here rather than in the
# workflow's `run:` block because its failure mode is silent: a loop that quietly retries zero
# times looks exactly like a loop that works, and nothing downstream would ever say otherwise.
# `tools/tests/unit/install-svn.test.sh` pins the retry count for that reason.
#
# The two platforms fail in DIFFERENT shapes, and the difference decides the fix:
#
#   * ubuntu — apt HANGS on a wedged mirror. Observed 2026-08-18 (49 minutes, no timeout on the
#     step at the time) and 2026-08-19 (ten minutes of complete silence, then the step timed out).
#     A retry loop on its own is useless against this: the call it is waiting on never returns, so
#     the loop never reaches its second iteration. `Acquire::*::Timeout` is what turns the hang
#     into a quick failure -- only THEN does retrying mean anything.
#
#   * windows — choco fails FAST when the community feed is unwell. Observed 2026-08-21:
#     `503 (Service Unavailable)` from the V2 feed, `Chocolatey installed 0/0 packages`. Nothing to
#     bound here; the answer arrived promptly and was simply wrong. A plain retry is the whole fix.
#
# Both legs keep their `timeout-minutes` and `continue-on-error`, and the `Verify Subversion is
# usable` step after them keeps turning "absent" into a red job. This script only removes the
# "every occurrence costs a manual rerun" part -- it is NOT a replacement for those guards. A
# plugin that declared svn and did not get it must still fail loudly, because its svn cases would
# otherwise self-SKIP into a green job that tested nothing.
set -uo pipefail

# Overridable so the tests can exercise the retry behaviour without sleeping through it. Nothing
# in CI sets these.
ATTEMPTS="${SVN_INSTALL_ATTEMPTS:-3}"
BACKOFF="${SVN_INSTALL_BACKOFF:-15}"

# Platform comes from an explicit argument when given. The tests use that rather than shimming
# `uname`, which is both simpler and harder to get wrong.
platform="${1:-}"
if [ -z "$platform" ]; then
    case "$(uname -s 2>/dev/null || echo unknown)" in
        MINGW*|MSYS*|CYGWIN*|Windows_NT) platform=windows ;;
        *)                               platform=linux   ;;
    esac
fi

case "$platform" in
    linux|windows) ;;
    *)
        printf '::error::install-svn: unknown platform %s\n' "$platform" >&2
        exit 2
        ;;
esac

note() { printf '%s\n' "$*" >&2; }

install_linux() {
    # Acquire::*::Timeout bounds a single unresponsive mirror; Acquire::Retries retries at the
    # fetch level, which is far cheaper than starting the whole run again. Both apply to `install`
    # as well as `update` -- `install` downloads too, and it is not the step that has been observed
    # wedging only because `update` gets there first.
    local opts=(-o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 -o Acquire::Retries=3)
    sudo apt-get "${opts[@]}" update || return 1
    sudo apt-get "${opts[@]}" install -y subversion || return 1
    return 0
}

install_windows() {
    # `sliksvn`, NOT choco's `svn` package -- see the workflow comment for why that distinction is
    # load-bearing (win32svn is pinned at 1.8.15, which predates `svn info --show-item`).
    choco install sliksvn --no-progress -y || return 1
    return 0
}

if ! command -v "$( [ "$platform" = windows ] && echo choco || echo apt-get )" >/dev/null 2>&1; then
    # Worth its own message: without it, a package manager missing from PATH surfaces later as the
    # generic "svn is not installed", which sends the reader looking at the wrong thing.
    note "::error::install-svn: no package manager on PATH for platform '$platform'"
    exit 2
fi

attempt=1
while :; do
    if "install_$platform"; then
        exit 0
    fi
    if [ "$attempt" -ge "$ATTEMPTS" ]; then
        break
    fi
    wait_s=$(( attempt * BACKOFF ))
    note "::warning::install-svn: $platform attempt $attempt/$ATTEMPTS failed; retrying in ${wait_s}s"
    [ "$wait_s" -gt 0 ] && sleep "$wait_s"
    attempt=$(( attempt + 1 ))
done

note "::error::install-svn: could not install subversion on $platform after $ATTEMPTS attempt(s)"
exit 1
