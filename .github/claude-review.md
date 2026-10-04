# Cloud code review brief

What this repository is, and what to watch for in it. Everything else — what PR
context is available, how to post a review, what makes a finding worth raising,
comment hygiene, PR-description shape, the versioning mechanism — comes from the
review workflow's runtime notes. Don't restate it here: this file is read first,
so a stale copy would silently override the current text.

Not loaded by local Claude Code; only the cloud reviewer reads this.

## What this repo is

`ghul-mcp` is an MCP server exposing semantic queries against ghūl projects by
driving the compiler's analysis mode over its IPC protocol. It advertises around
sixteen tools — whole-project (`diagnostics`), file-scoped (`inlays`),
position-based (`hover`, `definition`, `references`, `implementations`), the
name-based `*_of` variants of those, `symbols`, `members`, and the session-management
tools (`sessions`, `release_session`, `heap_check`, `version`). Read
`src/analyser/tools.ghul` for the current set rather than trusting this list.
Written in ghūl, consuming the `ghul.analysis.protocol` client library. It keeps a
pool of analyser sessions keyed by canonical project path, reaping
least-recently-used entries above a cap.

Its consumers are AI coding agents, which cannot tell a wrong answer from a right
one. A silently stale result is worse than an error, because the agent proceeds
confidently on it.

## What to watch for here

- **Silently wrong answers.** Stale results after an edit, an empty result where a
  symbol exists, or results from the wrong project. The server re-reads files whose
  mtime moved before answering - flag anything that could bypass that.
- **Session pool correctness.** Leaks, reaping a session still in use, two projects
  colliding on one key, or a crashed analyser left poisoning later queries rather
  than being respawned.
- **Protocol conformance.** Malformed JSON-RPC, missing error responses, or a tool
  result shape that does not match its declared schema. Coordinates are 1-based,
  matching compiler diagnostics.
- **Blocking and timeouts.** A query that can hang without a timeout stalls the
  calling agent indefinitely.
- **Doc comments on the stable surface.** For the shared doc-comment rule, the stable surface here is the MCP tools, their arguments and result shapes, and the analysis protocol the server speaks.

## Versioning

The consumer-visible contract is wider than the tool list, and this section is the
only place that says so — the runtime notes defer to it for what counts as breaking
here. It covers the tool names and their input schemas, the shape of what they
return, the command-line invocation (`--default-project`, `--query-log` and the
rest), and the MCP handshake itself.

Major means breaking any of those: a removed or renamed tool, an input schema a
caller no longer satisfies, a result shape a caller can no longer parse, or a
changed or removed command-line flag. Minor means additions — new tools, new
optional arguments, new flags.
