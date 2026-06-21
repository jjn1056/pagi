# PAGI as an AI Agent Harness — Exploration

**Status**: Exploration / *to be explored* — not a commitment, nothing built yet
**Distribution**: would be a separate dist (working name `PAGI::Agent`) built *on*
PAGI; **PAGI core does not change**
**Date**: 2026-06-21

## Why this doc exists

To capture an observation before it evaporates: PAGI's protocol model maps
unusually well onto what an AI agent runtime needs. This is exploratory — it
sketches a direction and the open questions, not a spec to implement. If we ever
build it, this is the starting point; if we don't, it's a record of why we
thought it was a good fit.

## The thesis

An AI agent is a **bidirectional, streaming, long-lived, event-driven** process:
it streams model tokens out while listening for the user to interrupt, it waits
on tool calls and external triggers, it runs for a whole conversation, and its
control flow is "await the next thing, react to what it is."

Most agent frameworks bolt that shape onto an HTTP request/response web stack and
fight the impedance mismatch. PAGI's *native* shape — `async sub ($scope,
$receive, $send)`, streaming-first, full-duplex, event multiplexing, explicit
backpressure — **is** that shape. So PAGI is plausibly a better substrate for
agents than a traditional web framework. And because PAGI is a *spec*, an agent
runtime built on it is portable across PAGI servers (the IO::Async reference
server today, a faster native server later) with no app changes.

## The mapping: agent primitives → existing PAGI mechanics

| Agent need | PAGI mechanic (and where it already lives) |
|---|---|
| **Agent loop** — await the next thing; dispatch on what it is (user message, model token, tool result, interrupt, timer) | `await $receive->()` + switch on `type` — the *receive-delivery* pattern (`PAGI::EventLoops`, `examples/17-event-middleware`). That **is** an agent inbox. |
| **Stream model tokens out while listening for an interrupt** | bidirectional WebSocket: two concurrent branches joined with `wait_any` (`examples/18-bidirectional-websocket`) |
| **Run N tool calls / subagents concurrently, act on whichever returns** | `Future::Selector` / tree-of-futures (`examples/14-periodic-events`, `PAGI::EventLoops`) |
| **Fold tool results + model tokens + external triggers into the agent's stream** | a middleware that wraps `$receive` (the "right way" — `examples/17`'s `wrapped_receive`) |
| **Multi-agent / cross-process / cross-host coordination** | `PAGI::Middleware::Channels` (Redis fan-out) |
| **Stream tokens to a slow client without unbounded memory** | PAGI backpressure (`pagi.transport`, watermarks) |
| **Session setup: warm tool registry, connect model providers** | `lifespan` + shared state |
| **JSON-RPC request/response plumbing (for MCP, below)** | the parked `jsonrpc` work (JSON-RPC 2.0 middleware, future standalone dist) |

## Key insight: the agent loop *is* a PAGI receive loop

An agent's control flow is exactly the "events through `$receive`" pattern we
already settled on. The agent awaits the next event and switches on its type;
the events are a small typed vocabulary:

    while (1) {
        my $event = await $receive->();
        if    ($event->{type} eq 'user.message')   { ... start a turn ... }
        elsif ($event->{type} eq 'tool.result')    { ... feed back to the model ... }
        elsif ($event->{type} eq 'agent.interrupt'){ ... cancel in-flight work ... }
        elsif ($event->{type} eq 'agent.done')     { last }
    }

A **tool result**, a **model token** arriving, a **subagent completing**, a
**human approval**, a **cron tick** — all just become typed events folded into
`$receive` by middleware, the same way `examples/17` folds a `tick` in. The agent
code never reaches into shared state for any of them; it just awaits the next
event. Model tokens go *out* the same way protocol output does: `$send` (or, on
WebSocket, an `outgoing` branch streaming deltas while the loop keeps reading).

That symmetry is the whole point: **the orchestration runtime is almost free,**
because PAGI already provides the await-an-event / stream-output substrate.

## Uniform tool calls

A single tool abstraction (`PAGI::Agent::Tool`-ish): a tool has a **name**, a
**schema**, and an async **invoke**. The agent treats all tools identically — it
emits a `tool.call`, and a `tool.result` arrives later as an event. The *backend*
behind a tool varies and is invisible to the agent:

- **Local** — a Perl coderef / object (in-process).
- **MCP-remote** — a tool exposed by an external MCP server (see below).
- **Subagent** — a tool whose "execution" is *another agent* running its own loop.

A tool-runner middleware owns execution: it picks up `tool.call` events, runs
them (concurrently — `Future::Selector`, with cancellation on `agent.interrupt`),
and folds each `tool.result` back into `$receive`. Concurrency and cancel
semantics are exactly the `wait_any`-cancels-the-loser distinction we documented:
cancelling an in-flight tool branch on interrupt is the *goal*; never cancel the
live `$receive`.

## MCP, both directions

[Model Context Protocol](https://modelcontextprotocol.io) is JSON-RPC 2.0 over a
transport (stdio, or HTTP + SSE / "streamable HTTP"). PAGI is well placed to do
**both** sides, and the JSON-RPC layer is the parked `jsonrpc` dist — MCP is "that
plus the MCP method semantics, over a PAGI transport."

- **PAGI as MCP *server*** — expose tools/resources/prompts to an external agent.
  A PAGI app speaks MCP: it receives JSON-RPC `tools/call` (etc.) over PAGI's SSE
  / HTTP / WebSocket transports (and stdio for local), executes, and replies. This
  is a PAGI app like any other; the MCP method dispatch is a middleware/endpoint
  on top of the JSON-RPC middleware.
- **PAGI as MCP *client*** — consume external MCP servers so their tools become
  agent tools. An async MCP client (Future::IO-based, like any non-blocking PAGI
  client) connects out, lists tools, and each remote tool becomes a uniform tool
  whose `tool.result` folds into the agent's `$receive`. A remote MCP server is
  just another *event source*.

The symmetry is pleasing: PAGI being a transport-agnostic async substrate means an
MCP server and an MCP client are the same machinery pointed in opposite
directions — and an agent can be *both* at once (serve some tools, consume
others).

## Subagents

An agent can invoke a **subagent as a tool**. The subagent runs its own event
loop (its own Future branch, or its own process via Channels), optionally streams
its events up to the parent (surface or summarize), and returns a result that
arrives as a `tool.result`. Orchestration reuses what's here:

- **Concurrent subagents** — `Future::Selector` to run several and act on
  first/all; cancel the losers on interrupt.
- **Cross-process subagents** — `PAGI::Middleware::Channels` to fan work out to
  workers/hosts and collect results, the same way multi-agent coordination works.
- **Supervisor pattern** — a parent agent whose "tools" are subagents, composing
  the same loop recursively.

(This mirrors how multi-agent orchestration tools work in practice: a controller
that dispatches sub-tasks, awaits results, and synthesizes.)

## Proposed shape

A `PAGI::Agent` dist layered on PAGI — **not** changes to PAGI core:

- **Agent session** = a `websocket` (primary) / `sse` / `http` scope wrapped by an
  agent context that provides the typed event loop and `$send`-based token output.
- **Tool runner** = middleware that executes `tool.call`s (local / MCP / subagent)
  and folds `tool.result`s into `$receive`.
- **Model provider** = an async token *source* (the Anthropic/OpenAI streaming
  client as a Future::IO-based source); its deltas become `model.delta` events
  outbound and drive `$send`.
- **MCP** = a JSON-RPC-based server endpoint and client, per above.
- **State** = conversation/turn state in lifespan + per-session state; optional
  persistence for resume-across-reconnect.
- **Cross-cutting** (auth, rate-limit, tracing, tool-injection, human-in-the-loop
  gates) = ordinary PAGI middleware.

Like `examples/mini-framework` or `PAGI::Endpoint`, it's a framework-on-PAGI. The
spec stays the foundation; this is a layer that rides any PAGI server.

## What is *not* free (the actual work)

- A **model-provider adapter**: a non-blocking streaming client for
  Anthropic/OpenAI (Future::IO-based; the EventLoops "who wires the backend" story
  applies). Token streaming must be backpressure-aware.
- **MCP** server method dispatch + an MCP client, on top of the JSON-RPC dist.
- A **tool registry** + schema + the `tool.call`/`tool.result` event contract.
- A **conversation/turn state machine**: multi-turn, interrupts, tool-approval
  gates, resumability.

## Open questions / to explore

- **Event taxonomy** — canonical agent event types (`user.message`,
  `model.delta`, `model.tool_use`, `tool.call`, `tool.result`, `agent.interrupt`,
  `agent.done`, `subagent.*`). A PAGI extension namespace (`PAGI::Spec::Extensions`
  "defining your own events"), or fully app-level?
- **Where the loop lives** — a PAGI app the user writes, vs a
  `PAGI::Endpoint::Agent` driving a user-supplied `step` callback.
- **Interrupt + cancellation** — cancel in-flight tools/model-stream on
  `agent.interrupt` (Future cancel; never cancel the live `$receive`).
- **Human-in-the-loop** — tool-approval as an inbound event the loop awaits.
- **Resumability** — agent/session state outliving a dropped transport
  (reconnect); pairs with Channels for relocation across workers.
- **Backpressure semantics** for token streaming to slow clients.
- **Transport matrix** — WebSocket primary; SSE/HTTP as degraded modes; stdio for
  local MCP.

## Prior art / why this isn't crazy

- ASGI's async receive/send + lifespan model underpins Python agent servers; PAGI
  leans on the same shape (and PAGI is modeled after ASGI).
- "Everything is an awaited typed event" is how robust agent runtimes are
  structured under the hood.
- `PAGI::Middleware::Channels` (Django-Channels-modeled) already gives the
  cross-process fan-out multi-agent needs.
- MCP is JSON-RPC 2.0 over a transport — PAGI already has the JSON-RPC groundwork
  parked and is transport-agnostic.

## A proof-of-shape (optional next step)

A ~60-line runnable example before any framework code: a WebSocket agent that
streams a fake "model" response token-by-token via `$send`, mid-stream emits a
`tool.call`, a middleware runs the tool and folds a `tool.result` back into
`$receive`, and the loop handles a user "stop" interrupt. It would demonstrate the
agent-as-PAGI-event-loop claim end-to-end on existing mechanics — and either click
immediately or expose the first rough edge.

## Non-goals

- Not proposing PAGI **core** changes.
- Not a model-provider SDK or an MCP spec — those are layers/clients on top.
- Not a commitment to build this — capturing the direction.
