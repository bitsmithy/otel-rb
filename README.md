# otel-rb

Thin, opinionated OpenTelemetry setup for Ruby/Rails. One call wires traces, metrics, and (optionally) logs over OTLP/HTTP.

- **Single-call setup** — `Telemetry.setup(...)`, no builder pattern, no config objects
- **All config optional** — sensible defaults from the environment
- **OTLP/HTTP only** — opinionated; no stdout/Zipkin/Jaeger in the setup path
- **Env var fallback** — standard `OTEL_*` env vars apply when `endpoint:` is nil
- **Uniform entrypoints** — `Telemetry.trace`, `Telemetry.counter`/`.histogram`/`.gauge`/`.up_down_counter`, `Telemetry.meter`, `Telemetry.log`

## Installation

```ruby
# Gemfile
gem "otel-rb", require: "telemetry"

# From GitHub
gem "otel-rb", github: "bitsmithy/otel-rb", require: "telemetry"
```

> The `require:` key is needed because the gem name (`otel-rb`) doesn't match its load path (`telemetry`).

## Configuration

All options are optional. Pass them as keywords to `Telemetry.setup`:

| Option | Default | Description |
|--------|---------|-------------|
| `service_name` | `File.basename($PROGRAM_NAME, ".*")` | Reported service name |
| `service_namespace` | Parent directory name | Reported service namespace |
| `service_version` | `ENV["SERVICE_VERSION"]` or `"unknown"` | Reported service version |
| `endpoint` | `nil` | OTLP endpoint URL; nil uses `OTEL_EXPORTER_OTLP_ENDPOINT` |
| `integrate_tracing_logger` | `false` | When `true`, replaces `Rails.logger.formatter` with `TraceFormatter` and forwards all `Rails.logger` calls to OTel as log records |

### Authentication

If your OTLP endpoint requires authentication, set the standard `OTEL_EXPORTER_OTLP_HEADERS` environment variable. The underlying OpenTelemetry SDK reads it automatically and attaches the headers to every OTLP request (traces, metrics, and logs):

```bash
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer%20your-token"
```

Multiple headers are comma-separated, with values URL-encoded:

```bash
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer%20your-token,X-Org-Id=12345"
```

You can also set signal-specific headers (e.g., `OTEL_EXPORTER_OTLP_TRACES_HEADERS`) if different signals need different credentials.

## Setup

### Rails

```ruby
# config/initializers/telemetry.rb

Telemetry.setup(
  service_name:             Rails.application.class.module_parent_name.underscore,
  service_namespace:        "my-org",
  service_version:          ENV.fetch("GIT_COMMIT_SHA", "unknown"),
  integrate_tracing_logger: true
)
```

When Rails is detected, setup always:

- Inserts `Telemetry::Middleware` into the Rails middleware stack (traces every request, records HTTP metrics)
- Registers `at_exit` to flush pending telemetry on process exit

With `integrate_tracing_logger: true`, setup also:

- Assigns `Telemetry::TraceFormatter` to `Rails.logger.formatter` for trace/span ID correlation in text output
- Bridges `Rails.logger` to OTel — every `Rails.logger` call also emits an OTel log record with trace context

`Telemetry::Middleware` traces every request and records metrics for each one.

**Tracing** — one span per request, kind `:server`. Span attributes:

| Attribute | Source |
|-----------|--------|
| `http.request.method` | HTTP verb |
| `http.route` | `action_dispatch.route_uri_pattern` (Rails 7.1+), falls back to raw path |
| `http.response.status_code` | Response status |
| `server.address` | Request host |
| `server.port` | Request port |

5xx responses set span status to `ERROR`. 4xx do not.

**Metrics** — three instruments recorded per request:

| Instrument | Type | Unit | Attributes |
|-----------|------|------|-----------|
| `http.server.request.count` | counter | `{request}` | `http.request.method`, `http.route`, `http.response.status_code`, `rails.controller`*, `rails.action`* |
| `http.server.request.duration` | histogram | `s` | same as above |
| `http.server.active_requests` | up-down counter | `{request}` | `http.request.method` |

\* `rails.controller` and `rails.action` are set from `action_dispatch.request.path_parameters` and are omitted when the middleware is used outside Rails.

### Non-Rails / plain Rack

```ruby
require "telemetry"

Telemetry.setup(service_name: "my-app")

use Telemetry::Middleware # Mount the middleware
```

## Signals

All three signals are included as hard gem dependencies and wired on every `Telemetry.setup` call.

| Signal | Gems |
|--------|------|
| Traces | `opentelemetry-sdk`, `opentelemetry-exporter-otlp` |
| Metrics | `opentelemetry-metrics-sdk`, `opentelemetry-exporter-otlp-metrics` |
| Logs | `opentelemetry-logs-sdk`, `opentelemetry-exporter-otlp-logs` |

## Tracing

`Telemetry.trace` wraps a block in a span and yields it. Nested calls automatically become child spans — no wiring needed.

```ruby
Telemetry.trace("orders.process", attrs: { "order.id" => order.id }) do |span|
  span.set_attribute("order.item_count", items.size)

  # Nested call → child span, automatically linked to the parent
  Telemetry.trace("orders.charge") do |_child|
    charge(order)
  end

rescue => e
  span.record_exception(e)
  span.status = OpenTelemetry::Trace::Status.error(e.message)
  raise
end
```

Inside a Rails controller action, any `Telemetry.trace` call is automatically a child of the request span set by `Telemetry::Middleware`.

## Metrics

Each instrument type has a single method that works in two forms:

| Form | Arguments | Effect |
|------|-----------|--------|
| Handle | `(name)` or `(name, unit: "s", description: "...")` | Returns a cached instrument object for repeated use |
| Fire-and-forget | `(name, value)` or `(name, value, attrs_hash, unit: "s", description: "...")` | Records the value immediately, returns nil |
| Block *(histogram only)* | `(name, unit: "s") { block }` or `(name, attrs_hash, unit: "s") { block }` | Times the block, records duration in seconds, returns block value |

`unit:` and `description:` are always keyword arguments and can be added to either form. The numeric value, when present, is always the second positional argument. The attributes hash, when present, is always the third positional argument — never a keyword. This is why the hash position shifts between the two forms: the handle form has no value, so attributes have nowhere to go as positional args — pass them when you call the method on the handle instead.

`unit:` follows the OTel convention: use SI units (`"s"`, `"By"`, `"ms"`) for standard measurements, or curly-brace notation (`"{order}"`, `"{request}"`) for arbitrary countable things. Your backend uses it as the Y-axis label.

**Metric attributes** (the `attrs` hash) are key/value labels attached to each recorded value. They let you slice the same metric by dimension — e.g. `"payment.method" => "card"` lets you chart orders by payment method without a separate instrument per method. Keep the number of distinct values per key low; each unique combination produces a separate time series in your backend.

---

### Counter

Monotonically increasing. Use for things that only ever go up: requests served, errors raised, emails sent.

```ruby
# Handle form — get a reusable object, then call .add
orders = Telemetry.counter("orders.placed", unit: "{order}")
orders.add(1)
orders.add(1, "payment.method" => "card")   # with attributes
orders.add(3, "payment.method" => "card")   # add more than 1

# Fire-and-forget — record immediately
Telemetry.counter("orders.placed", 1, unit: "{order}", description: "Orders placed")
Telemetry.counter("orders.placed", 1, "payment.method" => "card", unit: "{order}", description: "Orders placed")
```

### Histogram

Distribution of values over time. Use for durations, payload sizes, latencies — anything where you care about percentiles (p50/p95/p99), not just the total.

```ruby
# Handle form
durations = Telemetry.histogram("orders.duration", unit: "s")
durations.record(0.42)
durations.record(0.42, "queue" => "default")  # with attributes
durations.time { charge(order) }              # times block, records seconds
durations.time("queue" => "default") { charge(order) }  # timed with attributes

# Fire-and-forget — record a value immediately
Telemetry.histogram("orders.duration", 0.42, unit: "s", description: "Order processing time")
Telemetry.histogram("orders.duration", 0.42, "queue" => "default", unit: "s", description: "Order processing time")

# Fire-and-forget — block form, unit: "s" must be set explicitly
Telemetry.histogram("orders.charge_duration", unit: "s") { charge(order) }
Telemetry.histogram("orders.charge_duration", "queue" => "default", unit: "s") { charge(order) }

# Timed shorthand — unit: "s" set automatically
result = Telemetry.time("orders.charge_duration") { charge(order) }
result = Telemetry.time("orders.charge_duration", "queue" => "default") { charge(order) }

```

Block return value is always passed through.

### Gauge

Current value at a point in time. Use when you only care about the latest reading: memory usage, CPU %, queue depth, temperature.

```ruby
# Handle form
depth = Telemetry.gauge("queue.depth", unit: "{job}")
depth.record(17)
depth.record(17, "queue" => "default")  # with attributes

# Fire-and-forget
Telemetry.gauge("queue.depth", 17, unit: "{job}", description: "Jobs waiting in queue")
Telemetry.gauge("queue.depth", 17, "queue" => "default", unit: "{job}", description: "Jobs waiting in queue")
```

### UpDownCounter

Value that can increase and decrease. Use for counts of things that go up and down: active connections, items in a queue, concurrent in-flight requests.

```ruby
# Handle form
connections = Telemetry.up_down_counter("db.connections", unit: "{connection}")
connections.increment                           # +1
connections.increment(5)                        # +5
connections.increment(1, "pool" => "primary")   # +1 with attributes
connections.decrement                           # -1
connections.decrement(3)                        # -3
connections.decrement(1, "pool" => "primary")   # -1 with attributes

# Fire-and-forget
Telemetry.up_down_counter("db.connections",  1, unit: "{connection}", description: "Active DB connections")
Telemetry.up_down_counter("db.connections", -1, unit: "{connection}", description: "Active DB connections")
Telemetry.up_down_counter("db.connections",  1, "pool" => "primary", unit: "{connection}", description: "Active DB connections")
```

### Raw meter

`Telemetry.meter` returns the underlying `OpenTelemetry::Meter` for advanced use cases not covered above, such as observable (async) instruments:

```ruby
Telemetry.meter.create_observable_gauge("process.memory.usage", unit: "By") do |observer|
  observer.observe(current_memory_bytes)
end
```

## Logging

### Via Rails.logger (recommended with `integrate_tracing_logger: true`)

When `integrate_tracing_logger: true`, every `Rails.logger` call automatically emits an OTel log record with trace context. No code changes needed — existing `Rails.logger.info("...")` calls just start appearing in your OTel backend.

### Via Telemetry.log / Telemetry.logger

`Telemetry.log` emits directly to OTel and optionally mirrors to `Rails.logger`:

```ruby
Telemetry.log(:info,  "Order placed")                        # OTel + Rails.logger
Telemetry.log(:error, "Charge failed", rails_logger: false)  # OTel only
```

`Telemetry.logger` returns the `Telemetry::Logger` instance:

```ruby
Telemetry.logger.warn("Low balance", rails_logger: true)
```

Available levels: `debug`, `info`, `warn`, `error`, `fatal`.

When `integrate_tracing_logger: true`, you only need `Telemetry.log` for OTel-only logs that should NOT appear in `Rails.logger` output:

```ruby
Telemetry.log(:debug, "internal detail", rails_logger: false)
```

## TraceFormatter

With `integrate_tracing_logger: true`, `TraceFormatter` is assigned to `Rails.logger.formatter` automatically. Every log line is enriched with the active trace and span IDs (IDs are omitted when no span is active):

```text
I, [2026-03-10T12:00:00.000000 #1234]  INFO -- app: Order placed
  trace_id=4bf92f3577b34da6a3ce929d0e0e4736 span_id=00f067aa0ba902b7
```

This means `Rails.logger` calls get trace correlation in two places:

1. **Text output** — trace/span IDs appended to the log line (for log files, STDOUT)
2. **OTel backend** — structured `LogRecord` with trace context (for your observability platform)

If you prefer not to replace `Rails.logger.formatter`, use `Telemetry.log` / `Telemetry.logger` directly — these always emit OTel log records with trace context, regardless of the `integrate_tracing_logger` setting.

## Error handling

All public methods raise `Telemetry::NotSetupError` if called before `Telemetry.setup`:

```ruby
Telemetry.trace("x") { }
# => Telemetry::NotSetupError: Telemetry.trace called before Telemetry.setup
```

## Testing

Call `Telemetry.test_mode!` once in your test helper. It disables the `at_exit` shutdown hook and installs a `before` callback that resets all Telemetry state between tests, so each test starts clean.

```ruby
# test/test_helper.rb
ENV['OTEL_METRICS_EXPORTER'] ||= 'none'  # skip metric export in tests

require 'opentelemetry/sdk'
require 'telemetry'

Telemetry.test_mode!
```

`OTEL_METRICS_EXPORTER=none` tells the OTel metrics SDK to skip exporter configuration entirely, suppressing the connection-refused noise that would otherwise appear when there is no collector running locally.

When `RAILS_ENV=test`, `SimpleFormatter` is not replaced with `TraceFormatter` since Rails' test framework sets `SimpleFormatter` as the default before initializers run. If you want trace/span IDs in your test log output, opt in to the replacement in your test helper:

```ruby
# test/test_helper.rb

Telemetry.replace_simple_formatter = true
```

## License

MIT
