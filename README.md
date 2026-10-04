# ghul-mcp

[![CI](https://img.shields.io/github/actions/workflow/status/degory/ghul-mcp/ci.yml?branch=main)](https://github.com/degory/ghul-mcp/actions/workflows/ci.yml?query=branch%3Amain)
[![NuGet version (ghul.mcp)](https://img.shields.io/nuget/v/ghul.mcp.svg)](https://www.nuget.org/packages/ghul.mcp/)
[![License](https://img.shields.io/github/license/degory/ghul-mcp)](https://github.com/degory/ghul-mcp/blob/main/LICENSE)
[![ghūl](https://img.shields.io/badge/gh%C5%ABl-100%25!-information)](https://ghul.dev)

MCP (Model Context Protocol) server for the [ghūl programming
language](https://ghul.dev). It drives the ghūl compiler's analysis mode to
answer semantic queries — diagnostics, hover, definition, references, symbol
search — so AI coding agents can query ghūl code by meaning instead of
searching it as text.

Written in ghūl, consuming the `ghul.analysis.protocol` client library.

## Status

Working. Multi-project routing: every semantic tool takes an optional
`project` argument (absolute path to a ghūl project directory). Absent
uses the server's `--default-project`. The server keeps a pool of analyser
sessions (up to 8) keyed by canonical path and reaps least-recently-used
entries above the cap, so multiple git worktrees under one Claude session
can each stay warm.

Tools:

- Whole-project: `diagnostics` (errors and warnings). A large result comes
  back as a summary - counts by severity, a by-code and top-files
  breakdown, every error in full - which you narrow with `file`,
  `severity`, `code`, or `exclude_codes`.
- File-scoped: `inlays` (the narrowing / flow annotations the editor shows
  inline for one file - where a value is narrowed and where a narrowing is
  killed); optional `code` filter.
- Position-based: `hover`, `definition`, `references`, `implementations`.
- Name-based: `symbols` (substring search), `hover_of`, `definition_of`,
  `references_of`, `implementations_of` (resolve a name and return the
  answer, or the candidate list when a name is shared).
- Type-based: `members` (list the members of a type expression - works for
  ghūl-declared and imported types including `System.*`).

All lines and columns are 1-based, matching compiler diagnostics.

Every analyser-backed result starts with a context line naming the project
directory and the `ghul.compiler` version that answered, so a query routed
to the wrong project - or served by a session warmed on a superseded pin -
is visible in the result itself.

The server drives the target project's own pinned `ghul.compiler` tool in
analysis mode, seeds it with the project's assembly references and source
contents, and re-sends any file whose on-disk timestamp moved before
answering each query - results always reflect what is on disk. A locally
packed dev compiler (`0.0.0-*`, from
`dotnet pack -p:Version=0.0.0-local-<slug>.1` installed into the project's
manifest) is accepted regardless of the minimum version - it is built from
current source, so its analysis protocol is current too.

## Install as a .NET tool

Published as `ghul.mcp` on NuGet. Add it to any project's local tool
manifest:

```sh
dotnet new tool-manifest      # if the project has no .config/dotnet-tools.json yet
dotnet tool install --local ghul.mcp
```

## Usage

Point the server at a ghūl project directory (its dotnet tools must be
restored; the assemblies list is generated automatically on first use):

```sh
dotnet ghul-mcp --default-project path/to/project
```

Registering with Claude Code:

```sh
claude mcp add ghul -- dotnet ghul-mcp --default-project <project-dir>
```

## Pool host

One analyser per project, shared by every client. The MCP server holds no
analyser of its own: each tool call routes to the target project's pool
host, a Unix-socket serve mode of this same binary, and the host keeps the
project's analyser warm. A shell script - the Claude Code edit hook, say -
feeds edits to the same host, so the analyser an editor session keeps
current is the one queries are answered from, and the first full compile
is paid once per project rather than once per client session:

```sh
dotnet ghul-mcp --pool-host /tmp/ghul-pool.sock --project path/to/project
```

Callers never launch the host by hand: every client - hook or MCP server -
discovers a running host through the project-keyed socket path
(`/tmp/ghul-mcp-pool-<md5 of the project path>.sock`) and connects to it,
or starts one if nothing is listening. A client meeting a host from an
incompatible ghul-mcp build (the hello handshake carries a protocol
version) shuts it down as best it can and starts a fresh one.

The wire shape is newline-delimited JSON, one request per line: a `hello`
handshake first, then `call` (a tool name and its arguments, answered with
the same rendered, stamped text the MCP tool returns), `edit` (a file
relative to the project, answered with that file's diagnostics), `info`,
`release`, `heap_check` and `shutdown`. Connections are served serially;
warm requests are milliseconds.

The host exits once it has gone `--pool-host-idle-timeout` seconds without
a connection (default 1800; `0` waits indefinitely), unlinking its socket
on the way out. A warm analyser holds the project's sources in memory, so
one left over from an editing session that ended hours ago costs hundreds
of megabytes to answer nothing. The MCP server propagates its own
`--pool-host-idle-timeout` to the hosts it spawns.

A caller decides whether to launch a host by connecting, not by testing
whether the socket file exists. A host killed outright cannot unlink its
socket, and the file it leaves behind is indistinguishable from a live
one; treating existence as proof of life leaves the socket dead until the
file is removed by hand. On a refused connection, unlink the socket and
relaunch.

## Edit hook

`--edit-hook` is a Claude Code `PostToolUse` hook. It reads the hook payload
on standard input, and for an `Edit` or `Write` of a `.ghul` file inside a
project - the nearest directory above the file holding a `.ghulproj` or a
`ghul-project.json` manifest - sends
the edit to that project's pool host and writes the file's diagnostics as
the context the agent is shown:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": "dotnet ghul-mcp --edit-hook" }]
      }
    ]
  }
}
```

Only the edited file is reported. Errors with the same code and message are
grouped at their first position with a count, errors come before
everything else, and the list stops at twelve rows. A file with the same
diagnostics as after its previous edit gets a one-line acknowledgement
instead of the list again; that state is kept per project and file under
`$XDG_CACHE_HOME/ghul-diagnostics-hook/`. A clean file, a file outside any
project, a tool other than `Edit` or `Write`, and a host that does not answer
within twenty seconds all produce no output, so the hook never stands in
the way of an edit.

## Observability

`pool_status` (an MCP tool, or `dotnet ghul-mcp --pool-status` from a shell)
sweeps every `/tmp/ghul-mcp-pool-*.sock`, asks each host for its status, and
reports per project: the host pid, uptime and idle time, connection and
request counters split by op, host and analyser memory, and the analyser's
compiler, pid and source count. Discovery is the directory scan - the
socket per project is the registry - so one call sees hosts used by other
sessions and by the edit hook alike.

A host removes its socket when it exits, including when it is stopped by a
signal. One killed outright, or lost to a reboot, cannot, so `pool_status`
and every starting host remove any socket nothing is listening on, and
`pool_status` reports how many it removed rather than listing them. A socket
under a minute old is left and only counted, since its host may have bound
it and not yet be listening.

The shared query log (`~/.local/state/ghul-mcp/query-log.jsonl`) records the
host side too: every `edit` a hook feeds an analyser, and every failed op,
one JSON line each alongside the MCP tool dispatches, carrying the host's
pid so the two producers can be told apart.

## Query log

The server appends one JSON line per `tools/call` dispatch to a query log:
timestamp, pid, tool name, raw arguments, status (`ok`, `error`,
`unknown-tool`, `invalid-request`), elapsed milliseconds, result size, and
the first 300 characters of the result text. Analyser failures - spawn
failures, timeouts, restart loops - surface as `error` entries carrying the
exception message, so the log answers "is this server actually working
reliably, and are its answers useful?" after the fact.

The log defaults to `$XDG_STATE_HOME/ghul-mcp/query-log.jsonl` (falling
back to `~/.local/state/ghul-mcp/query-log.jsonl`), shared by every server
instance - entries carry the pid to tell sessions apart. `--query-log
<path>` redirects it; `--no-query-log` disables it. At startup a log past
10 MB is rotated to `<path>.prev`. A logging failure never breaks the
server: it disables the log for the rest of the run and reports once on
stderr.

## Build and test

```sh
dotnet tool restore
./tests/smoke.sh
```

## Issues

[View open issues](https://github.com/degory/ghul/issues?q=is%3Aopen+is%3Aissue+label%3Aghul-mcp) or [raise a new one](https://github.com/degory/ghul/issues/new?labels=ghul-mcp).
