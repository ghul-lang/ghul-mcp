#!/usr/bin/env bash
# End-to-end smoke test in two parts: the MCP protocol core driven with one
# request per method, then the analyser tools driven against a scratch copy
# of this project - including a mid-session file edit to prove queries see
# what is on disk.
set -euo pipefail

cd "$(dirname "$0")/.."

dotnet build -nologo

server=bin/Debug/net10.0/ghul-mcp.dll

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- part 1: protocol core ----------------------------------------------

qlog_tmp=$(mktemp -d)
qlog="$qlog_tmp/query-log.jsonl"

out=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"ping"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"version","arguments":{}}}' \
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"no-such-tool"}}' \
    '{"jsonrpc":"2.0","id":6,"method":"no/such/method"}' \
    | dotnet "$server" --query-log "$qlog")

echo "$out"

count=$(echo "$out" | wc -l)
[ "$count" -eq 6 ] || fail "expected 6 responses (notification must not get one), got $count"

echo "$out" | sed -n 1p | grep -q '"protocolVersion":"2025-06-18"' || fail "initialize: protocolVersion"
echo "$out" | sed -n 1p | grep -q '"serverInfo":{"name":"ghul-mcp"' || fail "initialize: serverInfo"
echo "$out" | sed -n 2p | grep -q '"id":2,"result":{}' || fail "ping: empty result"
echo "$out" | sed -n 3p | grep -q '"tools":\[{"name":"version"' || fail "tools/list: version tool first"
echo "$out" | sed -n 3p | grep -q '"name":"diagnostics"' || fail "tools/list: diagnostics tool"
echo "$out" | sed -n 3p | grep -q '"name":"symbols"' || fail "tools/list: symbols tool"
echo "$out" | sed -n 4p | grep -q '"text":"ghul-mcp 2.1.0 (no analyser session warm' || fail "tools/call: version text"
echo "$out" | sed -n 4p | grep -q '"isError":false' || fail "tools/call: isError false"
echo "$out" | sed -n 5p | grep -q '"error":{"code":-32602,"message":"unknown tool: no-such-tool"}' || fail "unknown tool error"
echo "$out" | sed -n 6p | grep -q '"error":{"code":-32601' || fail "unknown method error"

# Every tools/call dispatch lands in the query log with a status.
[ -f "$qlog" ] || fail "query log: file not written"
grep -q '"event":"start"' "$qlog" || fail "query log: start entry"
grep -q '"tool":"version"' "$qlog" || fail "query log: version call entry"
grep -q '"status":"ok"' "$qlog" || fail "query log: ok status"
grep -q '"status":"unknown-tool"' "$qlog" || fail "query log: unknown-tool status"
qlog_calls=$(grep -c '"event":"call"' "$qlog")
[ "$qlog_calls" -eq 2 ] || fail "query log: expected 2 call entries, got $qlog_calls"

rm -rf "$qlog_tmp"

# --- part 2: analyser tools ---------------------------------------------

tmp=$(mktemp -d)
fifo="$tmp/requests"
responses="$tmp/responses"

cleanup() {
    exec 3>&- 2>/dev/null || true
    [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null || true
    cleanup_pool_hosts
    rm -rf "$tmp" ${tmp2:-} ${hints_dir:-}
}

# The pool hosts spawned by the front end outlive the server process;
# match them by their unique scratch project paths so a run leaves
# none behind. (Their idle timeout also retires them, eventually.)
cleanup_pool_hosts() {
    for d in "${tmp:-}" "${tmp2:-}" "${hints_dir:-}"; do
        [ -n "$d" ] && pkill -f "ghul-mcp.dll --pool-host .* --project $d" 2>/dev/null || true
    done
}
trap cleanup EXIT

cp -r src ghul-mcp.ghulproj Directory.Build.props Directory.Packages.props .config "$tmp/"
(cd "$tmp" && dotnet tool restore >/dev/null)
cp "$tmp/src/main.ghul" "$tmp/main.pristine"

# A stand-in for the ghul command-line tool, which CI does not have, for
# the manifest project section below. It answers only `ghul project`, so
# having it on the server's PATH changes nothing else.
stub_bin="$tmp/stub-bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/ghul" <<'STUB'
#!/bin/sh
if [ "$1 $2" = "project response-file" ] ; then
    shift 2
    while [ $# -gt 0 ] ; do
        case "$1" in
            --output) : > "$2"; shift 2 ;;
            --source-globs) echo 'src/**/*.ghul' > "$2"; shift 2 ;;
            *) shift ;;
        esac
    done
elif [ "$1 $2" = "project compiler" ] ; then
    echo 'dotnet ghul-compiler'
else
    echo "unexpected: $*" >&2
    exit 1
fi
STUB
chmod +x "$stub_bin/ghul"

mkfifo "$fifo"
PATH="$stub_bin:$PATH" dotnet "$server" --default-project "$tmp" --pool-host-idle-timeout 300 --query-log "$tmp/query-log.jsonl" <"$fifo" >"$responses" &
server_pid=$!
exec 3>"$fifo"

send() { echo "$1" >&3; }

await() {
    for _ in $(seq 1 240); do
        grep -q "\"id\":$1," "$responses" 2>/dev/null && return 0
        sleep 1
    done
    echo "--- responses so far ---" >&2
    cat "$responses" >&2 || true
    fail "timed out waiting for response id $1"
}

response() { grep "\"id\":$1," "$responses"; }

send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
await 1

send '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"diagnostics","arguments":{}}}'
await 2
response 2 | grep -q 'no errors or warnings' || fail "diagnostics: expected clean project"
response 2 | grep -q "\\[$tmp " || fail "diagnostics: expected the project stamp on the result"

# Break a source on disk mid-session: the next query must see it.
echo "this is not ghul" >> "$tmp/src/main.ghul"

send '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"diagnostics","arguments":{}}}'
await 3
response 3 | grep -q 'main.ghul' || fail "diagnostics after edit: expected an error in main.ghul"
response 3 | grep -q 'error' || fail "diagnostics after edit: expected severity error"

# Repair it: the next query must go clean again.
cp "$tmp/main.pristine" "$tmp/src/main.ghul"

send '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"diagnostics","arguments":{}}}'
await 4
response 4 | grep -q 'no errors or warnings' || fail "diagnostics after repair: expected clean again"

line=$(grep -n "class ANALYSER_SESSION" src/analyser/session.ghul | head -1 | cut -d: -f1)
send '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"hover","arguments":{"file":"src/analyser/session.ghul","line":'"$line"',"column":11}}}'
await 5
response 5 | grep -q 'ANALYSER_SESSION' || fail "hover: expected the class signature"

send '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"symbols","arguments":{"query":"ensure_fresh"}}}'
await 6
response 6 | grep -q 'session.ghul' || fail "symbols: expected a match in session.ghul"

send '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"hover_of","arguments":{"name":"ANALYSER_SESSION"}}}'
await 7
response 7 | grep -q 'ANALYSER_SESSION' || fail "hover_of: expected class signature"
response 7 | grep -q '"isError":false' || fail "hover_of: unexpected error"

send '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"references_of","arguments":{"name":"ANALYSER_SESSION"}}}'
await 8
response 8 | grep -q 'tools.ghul' || fail "references_of: expected uses in tools.ghul"

send '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"hover_of","arguments":{"name":"init"}}}'
await 9
response 9 | grep -q 'share the name init' || fail "hover_of ambiguous: expected candidate list"

send '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"hover_of","arguments":{"name":"no_such_symbol_xyz"}}}'
await 10
response 10 | grep -q 'no symbol named' || fail "hover_of unknown: expected miss message"

send '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"members","arguments":{"type":"System.Text.StringBuilder"}}}'
await 11
response 11 | grep -q 'append' || fail "members(StringBuilder): expected append in members"
response 11 | grep -q 'length' || fail "members(StringBuilder): expected length property"

# --- part 3: multi-project routing ----------------------------------------
# Spawn a second scratch project alongside the first and verify a query with
# an explicit `project` argument spawns a separate analyser session, while
# no-arg queries continue to use the default.

tmp2=$(mktemp -d)
trap 'exec 3>&- 2>/dev/null || true; [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null || true; cleanup_pool_hosts; rm -rf "$tmp" "$tmp2"' EXIT

cp -r src ghul-mcp.ghulproj Directory.Build.props Directory.Packages.props .config "$tmp2/"
(cd "$tmp2" && dotnet tool restore >/dev/null)

send '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"sessions","arguments":{}}}'
await 20
response 20 | grep -q "$tmp" || fail "sessions: expected default project warm after diagnostics"
response 20 | grep -q "$tmp2" && fail "sessions: second project should NOT be warm yet"

send "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tools/call\",\"params\":{\"name\":\"diagnostics\",\"arguments\":{\"project\":\"$tmp2\"}}}"
await 21
response 21 | grep -q 'no errors or warnings' || fail "diagnostics: expected clean second project"
response 21 | grep -q "\\[$tmp2 " || fail "diagnostics: stamp should name the project argument, not the default"

send '{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"sessions","arguments":{}}}'
await 22
response 22 | grep -q "$tmp" || fail "sessions after 2nd project: default still warm"
response 22 | grep -q "$tmp2" || fail "sessions after 2nd project: second project should now be warm"

# Break a file in project 2 and verify only that project's diagnostics
# report it — the pool must not have crossed sources between sessions.
echo "this is not ghul" >> "$tmp2/src/main.ghul"

send '{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"diagnostics","arguments":{}}}'
await 23
response 23 | grep -q 'no errors or warnings' || fail "default diagnostics after 2nd broken: still clean"
response 23 | grep -q "\\[$tmp " || fail "default diagnostics after 2nd broken: stamp should still name the default project"

send "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"tools/call\",\"params\":{\"name\":\"diagnostics\",\"arguments\":{\"project\":\"$tmp2\"}}}"
await 24
response 24 | grep -q 'main.ghul' || fail "2nd diagnostics: expected broken main.ghul"

# --- part 3b: an analyser that exits is replaced without the caller knowing --
# The compiler exits on its own once it has been idle for a while, so a warm
# session's process can be gone by the time the next query arrives. Killing it
# is that case, arriving sooner. The pool must notice and respawn rather than
# write to a dead pipe, and the replacement must be told about every source —
# a fresh analyser knows nothing, so a session that only re-sent what had
# changed since the last query would answer against an empty project.

# The machine-wide view: with both scratch projects' hosts running, the
# sweep must find this run's default project and its analyser.
send '{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"pool_status","arguments":{}}}'
await 25
response 25 | grep -q "$tmp" || fail "pool_status: expected the default project in the sweep"
response 25 | grep -q "ghul.compiler " || fail "pool_status: expected a compiler version in the sweep"
response 25 | grep -q "requests" || fail "pool_status: expected request counters"
response 25 | grep -q "analyser:" || fail "pool_status: expected an analyser line"

send '{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"sessions","arguments":{}}}'
await 50
# Two projects are warm by now, so match the default project's own line
# rather than whichever the pool happened to render first.
analyser_pid=$(response 50 | grep -o "$tmp (pid [0-9]*" | grep -o '[0-9]*$')
[ -n "$analyser_pid" ] || fail "sessions: no analyser pid to kill"


kill -9 "$analyser_pid" 2>/dev/null || fail "could not kill analyser pid $analyser_pid"

for _ in $(seq 1 50); do
    kill -0 "$analyser_pid" 2>/dev/null || break
    sleep 0.1
done

kill -0 "$analyser_pid" 2>/dev/null && fail "analyser pid $analyser_pid did not die"

# A question only an analyser that has been given the project can answer. A
# clean diagnostics run would not do: an analyser holding no sources at all
# reports no errors either, so it passes whether or not the respawn re-sent
# anything. Neither would the session's own source count, which is its
# bookkeeping rather than evidence about the process it is talking to.
send '{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"symbols","arguments":{"query":"ensure_fresh"}}}'
await 51
response 51 | grep -q 'session.ghul' \
    || fail "symbols after analyser death: expected a transparent respawn with the whole project re-sent"

send '{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"sessions","arguments":{}}}'
await 52
new_pid=$(response 52 | grep -o "$tmp (pid [0-9]*" | grep -o '[0-9]*$')
[ -n "$new_pid" ] || fail "sessions after respawn: expected a live analyser"

[ "$new_pid" != "$analyser_pid" ] || fail "sessions after respawn: pid unchanged, so nothing respawned"

# --- part 4: inlays -----------------------------------------------------
# The narrowing / flow information the editor shows inline is surfaced by the
# file-scoped `inlays` tool. The fixture narrows a local under a presence
# test and then reassigns it, killing the narrowing - a narrowing-presence
# inlay followed by a narrowing-killed one.

hints_dir=$(mktemp -d)
trap 'exec 3>&- 2>/dev/null || true; [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null || true; cleanup_pool_hosts; rm -rf "$tmp" "$tmp2" "$hints_dir"' EXIT

mkdir -p "$hints_dir/src"
cat > "$hints_dir/src/test.ghul" <<'EOF'
class WIDGET is
    init() is si
    make() -> WIDGET? => WIDGET()
    run() is
        let w mut = make()
        if w? then
            w = make()
        fi
    si
si

entry() is
    WIDGET().run()
si
EOF
cp ghul-mcp.ghulproj "$hints_dir/hints-test.ghulproj"
cp Directory.Build.props Directory.Packages.props "$hints_dir/"
cp -r .config "$hints_dir/"
(cd "$hints_dir" && dotnet tool restore >/dev/null)

# baseline: the project compiles clean (inlays are not diagnostics)
send "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"tools/call\",\"params\":{\"name\":\"diagnostics\",\"arguments\":{\"project\":\"$hints_dir\"}}}"
await 30
response 30 | grep -q 'no errors or warnings' || fail "inlays: baseline diagnostics should be clean"

# the inlays tool surfaces both narrowing sites for the file
send "{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"tools/call\",\"params\":{\"name\":\"inlays\",\"arguments\":{\"project\":\"$hints_dir\",\"file\":\"src/test.ghul\"}}}"
await 31
response 31 | grep -q 'narrowing-presence' || fail "inlays: expected a narrowing-presence inlay"
response 31 | grep -q 'narrowing-killed' || fail "inlays: expected a narrowing-killed inlay"
response 31 | grep -q 'reassigned' || fail "inlays: expected the reassignment detail"

# a code filter narrows to one family
send "{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"tools/call\",\"params\":{\"name\":\"inlays\",\"arguments\":{\"project\":\"$hints_dir\",\"file\":\"src/test.ghul\",\"code\":\"narrowing-killed\"}}}"
await 32
response 32 | grep -q 'narrowing-killed' || fail "inlays: code filter should keep the matching family"
response 32 | grep -q 'narrowing-presence' && fail "inlays: code filter should drop other families"

# a code filter matching nothing returns a clean miss
send "{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"tools/call\",\"params\":{\"name\":\"inlays\",\"arguments\":{\"project\":\"$hints_dir\",\"file\":\"src/test.ghul\",\"code\":\"no-such-code\"}}}"
await 33
response 33 | grep -q 'no inlays in src/test.ghul match' || fail "inlays: expected miss message for an unmatched code"

# --- part 5: pool operations --------------------------------------------
# Verify the pool exposes per-session detail, that heap_check returns
# ok on a fresh session, and that release_session tears one down.

send '{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"sessions","arguments":{}}}'
await 40
response 40 | grep -q "pid " || fail "sessions: expected a pid in the listing"
response 40 | grep -q "sources" || fail "sessions: expected a source count in the listing"
response 40 | grep -q "ghul.compiler " || fail "sessions: expected a compiler version in the listing"

# With the default project's session warm, version reports its compiler.
send '{"jsonrpc":"2.0","id":44,"method":"tools/call","params":{"name":"version","arguments":{}}}'
await 44
response 44 | grep -q '(ghul.compiler ' || fail "version: expected compiler version with a warm default session"

send "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"tools/call\",\"params\":{\"name\":\"heap_check\",\"arguments\":{\"project\":\"$tmp\"}}}"
await 41
response 41 | grep -q "heap check ok" || fail "heap_check: expected ok on a fresh session"

send "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"release_session\",\"arguments\":{\"project\":\"$tmp\"}}}"
await 42
response 42 | grep -q "released session for" || fail "release_session: expected release confirmation"

send "{\"jsonrpc\":\"2.0\",\"id\":43,\"method\":\"tools/call\",\"params\":{\"name\":\"release_session\",\"arguments\":{\"project\":\"$tmp\"}}}"
await 43
response 43 | grep -q "no warm session" || fail "release_session: expected miss after release"

# --- manifest project -----------------------------------------------------

# A ghul-project.json project has no .ghulproj: the ghul tool writes its
# response file and source globs and names its compiler. The stub above
# stands in for it, writing what it writes for a .NET-target project with no
# dependencies.
manifest_project="$tmp/manifest-project"
mkdir -p "$manifest_project/src"
cp -r .config "$manifest_project/"
(cd "$manifest_project" && dotnet tool restore >/dev/null)
echo '{ "name": "manifest-project", "sources": ["src/**/*.ghul"] }' > "$manifest_project/ghul-project.json"
printf 'entry() is\n    IO.Std.write_line(not_declared_anywhere);\nsi\n' > "$manifest_project/src/broken.ghul"

send "{\"jsonrpc\":\"2.0\",\"id\":60,\"method\":\"tools/call\",\"params\":{\"name\":\"diagnostics\",\"arguments\":{\"project\":\"$manifest_project\"}}}"
await 60
response 60 | grep -q 'not_declared_anywhere' || fail "manifest project: expected the source error from diagnostics, got: $(response 60)"

exec 3>&-
wait "$server_pid" 2>/dev/null || true
server_pid=""

# The long-lived server logged every analyser dispatch, and none of the
# calls above should have surfaced as an error status.
qlog2="$tmp/query-log.jsonl"
[ -f "$qlog2" ] || fail "query log: long-lived server wrote no log"
grep -q '"tool":"diagnostics"' "$qlog2" || fail "query log: diagnostics entries"
grep -q '"tool":"hover"' "$qlog2" || fail "query log: hover entry"
grep -q '"tool":"inlays"' "$qlog2" || fail "query log: inlays entries"
grep -q '"status":"error"' "$qlog2" && fail "query log: unexpected error status"

# --- part 6: pool host --------------------------------------------------
# The per-project Unix-socket serve mode: the edit hook feeds edits to it
# and the MCP front end routes tool calls to it, so one warm analyser is
# shared between every client of the project. (The front-end sharing is
# already exercised above - every part-2 call spawned or reused a host.)

host_socket="$tmp/pool.sock"
dotnet "$server" --pool-host "$host_socket" --project "$tmp" >"$tmp/host.log" 2>&1 &
host_pid=$!
trap 'kill "$host_pid" 2>/dev/null || true; cleanup_pool_hosts; rm -rf "$tmp" "$tmp2" "$hints_dir"' EXIT

for _ in $(seq 1 40); do
    [ -S "$host_socket" ] && break
    sleep 0.25
done
[ -S "$host_socket" ] || fail "pool host: socket never appeared"

host_request() {
    # hello handshake plus one request, both lines in one connection; the
    # host replies to each and closes once it sees our half-close.
    printf '{"op":"hello","protocol":1}\n%s\n' "$1" | nc -U -q 15 "$host_socket"
}

resp=$(host_request '{"op":"edit","file":"src/main.ghul"}')
echo "$resp" | grep -q '"ok":true' || fail "pool host: expected ok, got: $resp"
echo "$resp" | grep -q '"diagnostics":\[\]' || fail "pool host: expected empty diagnostics for a clean file, got: $resp"

echo "this is not ghul" >> "$tmp/src/main.ghul"
resp=$(host_request '{"op":"edit","file":"src/main.ghul"}')
echo "$resp" | grep -q '"severity":1' || fail "pool host: expected a severity-1 diagnostic after breaking main.ghul, got: $resp"

# a tool call on the same host sees the state the edits fed it
resp=$(host_request '{"op":"call","tool":"hover_of","arguments":{"name":"no_such_symbol_xyz"}}')
echo "$resp" | grep -q '"ok":true' || fail "pool host: call op failed: $resp"
echo "$resp" | grep -q 'no symbol named' || fail "pool host: call result missing the miss text: $resp"

cp "$tmp/main.pristine" "$tmp/src/main.ghul"
resp=$(host_request '{"op":"edit","file":"src/main.ghul"}')
echo "$resp" | grep -q '"diagnostics":\[\]' || fail "pool host: expected clean again after repair, got: $resp"

resp=$(host_request '{"op":"edit","file":"../../../../../../etc/passwd"}')
echo "$resp" | grep -q 'escapes the project directory' || fail "pool host: expected a path-escape rejection, got: $resp"

resp=$(host_request '{"op":"bogus"}')
echo "$resp" | grep -q 'unknown op' || fail "pool host: expected an unknown-op rejection, got: $resp"

# the CLI sweep sees the same host
status_out=$(dotnet "$server" --pool-status)
echo "$status_out" | grep -q "$tmp" || fail "pool_status CLI: expected the host's project, got: $status_out"
echo "$status_out" | grep -q "connections" || fail "pool_status CLI: expected counters"

kill "$host_pid" 2>/dev/null || true
wait "$host_pid" 2>/dev/null || true

# a host stopped by a signal still removes its socket
for _ in $(seq 20); do
    [ -e "$host_socket" ] || break
    sleep 0.25
done
[ -e "$host_socket" ] && fail "pool host: a host stopped by SIGTERM left its socket behind"

# pool status removes a dead socket old enough to be sure of, counts a new
# one rather than listing it, and leaves the new one alone: a host may have
# bound it and not yet be listening
old_socket="/tmp/ghul-mcp-pool-smoke-old-$$.sock"
new_socket="/tmp/ghul-mcp-pool-smoke-new-$$.sock"
timeout 1 nc -lU "$old_socket" || true
timeout 1 nc -lU "$new_socket" || true
[ -S "$old_socket" ] && [ -S "$new_socket" ] || fail "pool status: could not make dead sockets to sweep"
touch -d '2 minutes ago' "$old_socket"

status_out=$(dotnet "$server" --pool-status)
rm -f "$new_socket"

[ -e "$old_socket" ] && fail "pool status: expected a dead socket to be removed, got: $status_out"
echo "$status_out" | grep -q "removed [0-9]* dead socket" || fail "pool status: expected the removal counted, got: $status_out"
echo "$status_out" | grep -q "too new to remove" || fail "pool status: expected the new dead socket counted, got: $status_out"
echo "$status_out" | grep -q "$new_socket" && fail "pool status: dead sockets should be counted, not listed, got: $status_out"

# --- edit hook ------------------------------------------------------------

# The agent edit hook, fed the PostToolUse payload an Edit produces. It
# reports only what changed since the last edit of the file, keeping that
# state under XDG_CACHE_HOME, so the run gets a cache of its own.
cp "$tmp/main.pristine" "$tmp/src/main.ghul"
hook_cache=$(mktemp -d)

edit_hook() {
    printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" |
        XDG_CACHE_HOME="$hook_cache" dotnet "$server" --edit-hook --pool-host-idle-timeout 300
}

hook_out=$(edit_hook Edit "$tmp/src/main.ghul")
[ -z "$hook_out" ] || fail "edit hook: a clean file should report nothing, got: $hook_out"

echo "this is not ghul" >> "$tmp/src/main.ghul"

hook_out=$(edit_hook Edit "$tmp/src/main.ghul")
echo "$hook_out" | grep -q '"hookEventName":"PostToolUse"' || fail "edit hook: expected PostToolUse output, got: $hook_out"
echo "$hook_out" | grep -q 'diagnostics for src/main.ghul (compiler ' || fail "edit hook: expected the report header, got: $hook_out"
echo "$hook_out" | grep -q 'src/main.ghul:[0-9]*:[0-9]*: error: ' || fail "edit hook: expected an error row, got: $hook_out"

hook_out=$(edit_hook Write "$tmp/src/main.ghul")
echo "$hook_out" | grep -q 'unchanged ([0-9]* known diagnostics' || fail "edit hook: a repeat should be acknowledged as unchanged, got: $hook_out"

hook_out=$(edit_hook Read "$tmp/src/main.ghul")
[ -z "$hook_out" ] || fail "edit hook: a tool other than Edit or Write should report nothing, got: $hook_out"

cp "$tmp/main.pristine" "$tmp/src/main.ghul"

hook_out=$(edit_hook Edit "$tmp/src/main.ghul")
[ -z "$hook_out" ] || fail "edit hook: a repaired file should report nothing, got: $hook_out"

# The repair cleared the recorded state, so the same breakage coming back
# is reported in full rather than as unchanged.
echo "this is not ghul" >> "$tmp/src/main.ghul"

hook_out=$(edit_hook Edit "$tmp/src/main.ghul")
echo "$hook_out" | grep -q 'src/main.ghul:[0-9]*:[0-9]*: error: ' || fail "edit hook: a breakage after a repair should be reported in full, got: $hook_out"

cp "$tmp/main.pristine" "$tmp/src/main.ghul"

# --- manifest project, through the edit hook ------------------------------

# The edit hook finds the project by its manifest when walking up from the
# edited file.
hook_out=$(PATH="$stub_bin:$PATH" edit_hook Edit "$manifest_project/src/broken.ghul")
echo "$hook_out" | grep -q 'not_declared_anywhere' || fail "manifest project: expected the edit hook to report the source error, got: $hook_out"

rm -rf "$hook_cache"

echo "smoke test passed"
