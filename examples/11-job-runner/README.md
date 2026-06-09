# Async Job Runner - PAGI Demo

A real-time job queue dashboard demonstrating PAGI's async capabilities with HTTP, SSE, and WebSocket protocols working together.

> **Note: this example is IO::Async-specific.** The background worker tick, the
> WebSocket ping, and the per-job countdown timers use `IO::Async::Timer::*` and
> obtain the loop directly via `IO::Async::Loop`, so it runs only under an
> IO::Async-based server such as PAGI::Server. It could be made loop-agnostic by
> replacing those timers with `Future::IO` (e.g. `Future::IO->sleep`), which
> works under any conforming server -- the rest of the app is plain PAGI
> protocol and would not need to change.

## Running

From the PAGI root directory, using `pagi-server` from the `PAGI-Server`
distribution. This example keeps its modules under its own `lib/`, so put that
on the module search path:

```bash
PERL5LIB=examples/11-job-runner/lib pagi-server \
    --app examples/11-job-runner/app.pl --port 5001
```

Then open http://localhost:5001 in your browser.

## Features

- **Real-time job queue** - Create countdown jobs and watch them execute
- **Live progress streaming** - SSE updates show second-by-second progress
- **WebSocket dashboard** - Queue-wide updates pushed to all connected clients
- **Concurrent execution** - Worker processes up to 3 jobs simultaneously

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Browser (app.js)                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │  WebSocket   │  │     SSE      │  │   HTTP (REST)    │  │
│  │ Queue Events │  │ Job Progress │  │   Static Files   │  │
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │
└─────────┼─────────────────┼───────────────────┼────────────┘
          │                 │                   │
          ▼                 ▼                   ▼
┌─────────────────────────────────────────────────────────────┐
│                     PAGI Server                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ WebSocket.pm │  │   SSE.pm     │  │     HTTP.pm      │  │
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘  │
│         │                 │                   │            │
│         └────────────┬────┴───────────────────┘            │
│                      ▼                                     │
│              ┌───────────────┐                             │
│              │   Queue.pm    │ ◄── Job State Management    │
│              └───────┬───────┘                             │
│                      │                                     │
│              ┌───────▼───────┐                             │
│              │  Worker.pm    │ ◄── Async Job Execution     │
│              └───────┬───────┘                             │
│                      │                                     │
│              ┌───────▼───────┐                             │
│              │   Jobs.pm     │ ◄── Job Type Definitions    │
│              └───────────────┘                             │
└─────────────────────────────────────────────────────────────┘
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/stats` | Queue and worker statistics |
| GET | `/api/job-types` | Available job types |
| GET | `/api/jobs` | List all jobs |
| POST | `/api/jobs` | Create a new job |
| GET | `/api/jobs/:id` | Get job details |
| DELETE | `/api/jobs/:id` | Cancel a job |
| GET | `/api/jobs/:id/progress` | SSE progress stream |

## WebSocket Protocol

Connect to `/ws/queue` for real-time updates.

**Server -> Client:**
- `queue_state` - Full state on connect
- `job_created` - New job added
- `job_started` - Job began executing
- `job_progress` - Progress update
- `job_completed` - Job finished successfully
- `job_failed` - Job failed with error
- `job_cancelled` - Job was cancelled

**Client -> Server:**
- `create_job` - Create new job `{ job_type, params }`
- `cancel_job` - Cancel job `{ job_id }`
- `clear_completed` - Remove finished jobs
- `get_state` - Request full state

## Job Types

- **countdown** - Counts down from N seconds with progress updates
- **prime** - Finds all prime numbers up to N (with progress)
- **fibonacci** - Calculates Fibonacci sequence up to N terms
- **echo** - Echoes a message back after a configurable delay

## Testing with curl

```bash
# Create a 5-second countdown job
curl -X POST http://localhost:5001/api/jobs \
    -H "Content-Type: application/json" \
    -d '{"job_type":"countdown","params":{"seconds":5}}'

# Watch job progress (SSE)
curl -N http://localhost:5001/api/jobs/1/progress \
    -H "Accept: text/event-stream"

# Get queue stats
curl http://localhost:5001/api/stats
```
