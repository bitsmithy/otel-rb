# Research: otel-rb Ruby Gem

## Overview

The goal is to build a Ruby gem that serves the same purpose as [`bitsmithy/go-otel`](https://github.com/bitsmithy/go-otel): a **thin, opinionated OpenTelemetry setup library** that wires up traces, metrics, and logs over OTLP/HTTP in a single call, and provides ergonomic helpers for Rack/Rails HTTP middleware.

---

## What go-otel Does (Deep Analysis)

### Core API Surface

**`otel.go`** — `Setup(ctx, Config) → (shutdown_fn, logger, tracer, meter, error)`

The library's entry point is a single `Setup` function that:
1. Derives `service.name` and `service.namespace` from Go module path if not configured
2. Derives `service.version` from build info
3. Builds a merged OTel `Resource` (default + custom attributes)
4. Creates three OTLP/HTTP exporters: traces, metrics, logs
5. Creates three SDK providers: `TracerProvider`, `MeterProvider`, `LoggerProvider`
6. Sets all three as global providers
7. Sets a `TraceContext+Baggage` composite text map propagator
8. Returns: shutdown function, a `*slog.Logger` fanning out to OTel+stderr, a `trace.Tracer`, and a `metric.Meter`

**`Config` struct** — all fields optional:
- `ServiceName` — defaults to last path segment of module path
- `ServiceNamespace` — defaults to penultimate segment
- `ServiceVersion` — defaults to Go module version from build info
- `Endpoint` — full OTLP URL, falls back to standard env vars
- `LogLevel` — minimum log level for stderr, defaults to INFO

**`NewLogger(serviceName, level)` → `*slog.Logger`**
- Creates an additional logger (for background workers etc.) after `Setup`
- Fans out to OTel log pipeline + stderr JSON handler

**`DetachedContext(ctx) → context.Context`**
- Returns a never-cancelled context carrying the active span from `ctx`
- Critical pattern: when `ctx` is cancelled (timeout), OTel SDK silently drops telemetry on it
- `DetachedContext` lets you emit final metrics/logs after a timed-out operation while preserving trace correlation

---

### `handler.go` — Logging Infrastructure

**`TraceHandler`** — wraps any `slog.Handler`, injects `trace_id` and `span_id` into each record when an active span is in context. Correctly implements `WithAttrs` and `WithGroup` returning wrapped handlers.

**`FanoutHandler`** — implements `slog.Handler` as a slice, dispatches each record to all inner handlers. Correctly clones records before dispatch to prevent data races.

---

### `middleware.go` — HTTP Instrumentation

**`NewMiddleware(tracer, meter) → (*Middleware, error)`**
- Pre-registers three metric instruments once (not per-request):
  - `http.server.request.count` — `Int64Counter`
  - `http.server.request.duration` — `Float64Histogram`
  - `http.server.active_requests` — `Int64UpDownCounter`

**`Middleware.Wrap(handler) → http.Handler`**
- Extracts W3C `traceparent`/`tracestate` from incoming headers (context propagation)
- Starts a server span with a temporary name (method + raw path)
- Wraps the `ResponseWriter` to capture status code
- Increments `active_requests` before handler, decrements after
- Reads `r.Pattern` *after* routing to get the route template (e.g. `/users/{id}` not `/users/42`) — this is a Go 1.22+ feature from `http.ServeMux`
- Records `request.count` and `request.duration` with method/route/status attributes
- Sets span error status for 5xx responses only (4xx is not an error)

---

### Key Design Decisions in go-otel

1. **Single-call setup**: One `Setup()` call wires everything. No builder pattern needed.
2. **Return values, not globals**: Callers receive `tracer` and `meter` directly rather than calling global accessors everywhere — though globals are also set for library code.
3. **Optional config**: All fields have sensible defaults derived from runtime metadata.
4. **Explicit shutdown**: Returns a shutdown function to flush buffered telemetry on graceful exit.
5. **OTLP/HTTP only**: Intentionally opinionated — no support for stdout/Jaeger/Zipkin in the setup function itself.
6. **Env var fallback**: When `Endpoint` is empty, OTEL standard env vars apply automatically.
7. **Log-trace correlation**: Automatic `trace_id`/`span_id` injection via `TraceHandler`.
8. **Route template, not concrete path**: Metrics use pattern (e.g. `/users/{id}`) to avoid high cardinality.
9. **DetachedContext**: Solves a subtle OTel SDK quirk — cancelled contexts cause silent telemetry drops.

---

## Ruby OTel Ecosystem

### Available Gems

The Ruby OTel SDK is split into many gems under the `opentelemetry-ruby` and `opentelemetry-ruby-contrib` orgs:

| Gem | Role |
|-----|------|
| `opentelemetry-api` | API interfaces (no-op implementations) |
| `opentelemetry-sdk` | SDK: TracerProvider, SpanProcessor, Exporter interfaces |
| `opentelemetry-exporter-otlp` | OTLP/HTTP exporter for traces |
| `opentelemetry-exporter-otlp-metrics` | OTLP/HTTP exporter for metrics |
| `opentelemetry-exporter-otlp-logs` | OTLP/HTTP exporter for logs |
| `opentelemetry-metrics-api` | Metrics API |
| `opentelemetry-metrics-sdk` | Metrics SDK |
| `opentelemetry-logs-api` | Logs API |
| `opentelemetry-logs-sdk` | Logs SDK |
| `opentelemetry-semantic_conventions` | Semantic convention constants |

### Key Differences from Go

**Context propagation**: Go uses `context.Context` for explicit propagation. Ruby uses **fiber-local storage** via `OpenTelemetry::Context` — the current span is stored in a thread/fiber-local key. No explicit context passing needed (but possible via `OpenTelemetry::Context.with_value`).

**No equivalent of slog**: Ruby has the standard `Logger` class and Rails uses `ActiveSupport::Logger`. The Ruby OTel ecosystem does not yet have a "LoggerProvider" bridge gem as mature as Go's `otelslog`. The logs signal in Ruby OTel is still evolving. We'll need to handle this differently — likely injecting trace correlation into existing loggers.

**Metrics state**: The Ruby metrics API is stable but the SDK is still maturing (as of early 2026). `opentelemetry-metrics-sdk` exists.

**Rack middleware**: Ruby's web framework uses Rack as the foundation. `opentelemetry-instrumentation-rack` exists in contrib, but it's a full auto-instrumentation library. We want a lightweight, explicit middleware.

**No build info introspection**: Ruby doesn't have Go's `debug.ReadBuildInfo`. We'd use `Gem::Specification` to read gem metadata, or fall back to env vars.

### Rack Middleware Patterns

For HTTP instrumentation in Ruby/Rails:
- A Rack middleware receives `env` (a hash) containing `rack.request.query_string`, `REQUEST_METHOD`, `PATH_INFO`, etc.
- The Rails router sets `action_dispatch.request.path_parameters` and `action_dispatch.request.parameters` after routing
- Route pattern (template) is available as `env["action_dispatch.route_uri_pattern"]` in Rails 7.1+ (with `config.action_dispatch.debug_exception_response_format`)
- Actually, route pattern is available via `request.route_uri_pattern` in Rails (added in Rails 7.1)

### Log Correlation Pattern

Since Ruby doesn't have `slog`, the equivalent approach is:
- Provide a custom `Logger` formatter that appends `trace_id` and `span_id` when a span is active
- Provide a `SemanticLogger` appender or Rails `TaggedLogging` integration
- The simplest approach: provide a log formatter and a helper to configure the Rails logger

---

## Target Integration Context

`otel-rb` is a standalone gem. Any Rails 7.1+ / Ruby 3.2+ application can integrate it.

The integration points in a typical Rails app are:
1. A `config/initializers/telemetry.rb` that calls `Telemetry.setup` and assigns `Rails.logger.formatter`
2. `config.middleware.use Telemetry::Middleware, result[:tracer], result[:meter]` in `config/application.rb`

**Ruby 4.0 note**: `logger` is no longer a default gem in Ruby 4.0+. `otel-rb` declares it as an explicit dependency.

---

## Architecture of the Ruby Gem

The gem should mirror go-otel's design closely, adapted to Ruby idioms:

```
otel-rb (gem)
├── lib/
│   └── telemetry/
│       ├── config.rb          # Config struct (keyword args, all optional)
│       ├── setup.rb           # Telemetry.setup(config) → { shutdown:, tracer:, meter: }
│       ├── middleware.rb      # Rack middleware class
│       ├── trace_formatter.rb # Logger formatter injecting trace_id/span_id
│       └── version.rb
│   └── telemetry.rb          # Main entry point, re-exports key API
├── spec/
│   ├── setup_spec.rb
│   ├── middleware_spec.rb
│   └── trace_formatter_spec.rb
├── otel-rb.gemspec
└── README.md
```

### Core API Translation

| Go | Ruby |
|----|------|
| `telemetry.Setup(ctx, cfg)` | `Telemetry.setup(config)` |
| `shutdown, log, tracer, meter, err` | Returns `{ shutdown:, tracer:, meter: }` (log handled separately) |
| `telemetry.Config{...}` | `Telemetry::Config.new(service_name:, ...)` |
| `NewMiddleware(tracer, meter)` | `Telemetry::Middleware.new(app, tracer, meter)` |
| `TraceHandler` | `Telemetry::TraceFormatter` |
| `FanoutHandler` | Rails/Ruby already supports multiple log devices |
| `DetachedContext(ctx)` | Not needed in v1 — no context cancellation in Ruby OTel |

### Ruby-Specific Considerations

**Service name defaults**: Use `File.basename($PROGRAM_NAME)` or gemspec name as service name default. Namespace defaults to parent directory or organization name from gemspec.

**Rack route pattern**: `env["action_dispatch.route_uri_pattern"]` (Rails) or fall back to `PATH_INFO`. We capture the route after the app calls `call(env)`, similar to how go-otel reads `r.Pattern` after `ServeHTTP`.

**Shutdown**: In Ruby, you'd use `at_exit` hook or a Rack `close` middleware. The gem should return a `shutdown` proc/lambda callable from `at_exit`.

**Metrics SDK maturity**: The Ruby metrics SDK may not yet have feature parity. We should gracefully handle the case where metrics aren't available, or scope to traces+logs first.

---

## Edge Cases & Gotchas

1. **Ruby OTel logs signal**: The logs signal in Ruby OTel is still experimental. `opentelemetry-logs-sdk` exists but the exporter (`opentelemetry-exporter-otlp-logs`) may not be widely available. We should make logs optional/additive.

2. **Thread safety in Rack**: Unlike Go goroutines, Ruby threads share the same global state. The OTel Ruby SDK uses fiber-local context — important to understand for async Rack apps.

3. **Rack env mutation**: Rack middleware should not mutate `env` in ways that affect downstream middleware unless intentional. We write status code capture into a wrapping response.

4. **Rails route pattern availability**: `env["action_dispatch.route_uri_pattern"]` is set by Rails routing *after* the router processes the request — but it's set in `env` before the action runs. So we can read it after `@app.call(env)` returns. However, this is a Rails-specific key. For Sinatra or plain Rack apps, we'd fall back to `PATH_INFO`.

5. **Instrumentation overlap**: If the app also uses `opentelemetry-instrumentation-rack` or `opentelemetry-instrumentation-rails`, there's a risk of double-instrumentation. Our middleware should be positioned to complement, not conflict with, auto-instrumentation.

6. **Metric instrument lifecycle**: Instruments must be created once and reused. In Ruby, this means storing them as instance variables on the middleware object — same as Go's struct fields.

7. **OTLP exporter lazy connection**: Like Go, Ruby's OTLP exporter connects lazily — no network call during `setup`. This makes testing straightforward.

8. **at_exit ordering**: Ruby's `at_exit` hooks run in LIFO order. If setup registers `at_exit { shutdown.call }`, it needs to be registered after the OTel providers are set up.

---

## Current State / What Exists

- No Ruby equivalent of go-otel exists in the Ruby ecosystem (there are full auto-instrumentation distros like `opentelemetry-instrumentation-all`, but no thin opinionated setup gem)
- The `opentelemetry-ruby` SDK itself is the closest analog to raw OTel SDK, but requires 50+ lines of boilerplate to set up all three signals
- The target project has no existing telemetry infrastructure to preserve or work around

---

## Summary

The Ruby gem should:

**Naming**: `Telemetry` module, gem named `otel-rb`. Usage: `Telemetry.setup(...)`, `Telemetry::Config`, `Telemetry::Middleware`.

1. Expose a single `Telemetry.setup(config)` call that wires traces + metrics (+ optionally logs) over OTLP/HTTP
2. Return a shutdown proc + tracer + meter (no logger — Ruby logger integration is a formatter, not a new logger)
3. Provide a `Telemetry::Middleware` Rack middleware for automatic HTTP instrumentation
   - Standard Rack interface: `def initialize(app, tracer, meter)` — fully composable with other Rack middleware
   - Calls `@app.call(env)` around instrumentation — never interferes with the middleware stack
   - Does not mutate `env`; wraps response to capture status code only
   - Can be positioned anywhere in the middleware stack; outer position gives widest span coverage
   - Compatible alongside `opentelemetry-instrumentation-rack` if present (both will run)
4. Provide a `Telemetry::TraceFormatter` (or tagged logging helper) that injects `trace_id`/`span_id`
5. ~~`Telemetry.detach_context`~~ — **Not needed for v1.** Ruby OTel uses fiber-local context which has no cancellation signal; Rails timeouts raise exceptions rather than cancelling a context. Drop from initial implementation; revisit if a concrete use case emerges.
6. Default `service_name` from `$PROGRAM_NAME` or caller gem name
7. All configuration optional with sensible defaults
8. Fall back to standard OTel env vars when `endpoint` is not set
