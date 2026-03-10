# otel-rb

Thin, opinionated OpenTelemetry setup for Ruby/Rails. One call wires traces, metrics, and (optionally) logs over OTLP/HTTP.

Mirrors the design of [bitsmithy/go-otel](https://github.com/bitsmithy/go-otel):

- **Single-call setup** — `Telemetry.setup(config)`, no builder pattern
- **All config optional** — sensible defaults from the environment
- **OTLP/HTTP only** — opinionated; no stdout/Zipkin/Jaeger in the setup path
- **Env var fallback** — standard `OTEL_*` env vars apply when `endpoint:` is nil
- **Explicit shutdown** — caller registers `at_exit { result[:shutdown].call }`

## Installation

Add to your `Gemfile`:

```ruby
gem "otel-rb", require: "telemetry"
```

## Configuration

All `Telemetry::Config` fields are optional:

| Field | Default | Description |
|-------|---------|-------------|
| `service_name` | `File.basename($PROGRAM_NAME, ".*")` | Reported service name |
| `service_namespace` | Parent directory name | Reported service namespace |
| `service_version` | `ENV["SERVICE_VERSION"]` or `"unknown"` | Reported service version |
| `endpoint` | `nil` | OTLP endpoint URL; nil uses `OTEL_EXPORTER_OTLP_ENDPOINT` |
| `log_level` | `:info` | Logger level (informational; not yet wired to SDK logger) |

## Setup

### Rails

One call in a single initializer wires everything — traces, metrics, Rack middleware, and log correlation. Nothing in `application.rb` required.

```ruby
# config/initializers/telemetry.rb

TELEMETRY = Telemetry.install(
  Telemetry::Config.new(
    service_name:      Rails.application.class.module_parent_name.underscore,
    service_namespace: "my-org",
    service_version:   ENV.fetch("GIT_COMMIT_SHA", "unknown")
  )
)
```

Or with all defaults (service name inferred from the process name):

```ruby
# config/initializers/telemetry.rb
Telemetry.install
```

`Telemetry.install` handles everything automatically:

- Calls `Telemetry.setup` to configure traces, metrics, and (optionally) logs
- Inserts `Telemetry::Middleware` into the Rails middleware stack
- Assigns `TraceFormatter` to `Rails.logger.formatter` for trace-log correlation (warns if overwriting an existing formatter)
- Registers `at_exit` to flush pending telemetry on process exit
- Returns the result hash so you can access `TELEMETRY[:tracer]` and `TELEMETRY[:meter]` for manual instrumentation

`Telemetry::Middleware` automatically wraps each request with a server span and records:

- `http.server.request.count` (counter)
- `http.server.request.duration` (histogram, seconds)
- `http.server.active_requests` (up-down counter)

Span attributes follow [OpenTelemetry semantic conventions](https://opentelemetry.io/docs/specs/semconv/http/):

- `http.request.method`
- `http.route` (uses `action_dispatch.route_uri_pattern` when available — low cardinality)
- `http.response.status_code`
- `server.address`, `server.port`

5xx responses set span status to `ERROR`. 4xx responses do not.

### Non-Rails / plain Rack

Use `Telemetry.setup` directly and wire the middleware yourself:

```ruby
require "telemetry"

result = Telemetry.setup(
  Telemetry::Config.new(
    service_name: "my-app",
    endpoint:     ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]
  )
)

use Telemetry::Middleware, result[:tracer], result[:meter]

at_exit { result[:shutdown].call }
```

`Telemetry.setup` returns:

```ruby
{
  shutdown: Proc,                      # call at exit to flush pending telemetry
  tracer:   OpenTelemetry::Trace::Tracer,
  meter:    OpenTelemetry::Metrics::Meter  # nil if metrics SDK unavailable
}
```

## Signals

| Signal | Status | Gem |
|--------|--------|-----|
| Traces | Required | `opentelemetry-sdk`, `opentelemetry-exporter-otlp` |
| Metrics | Required (graceful degradation) | `opentelemetry-metrics-sdk`, `opentelemetry-exporter-otlp-metrics` |
| Logs | Optional (silent no-op if absent) | `opentelemetry-logs-sdk`, `opentelemetry-exporter-otlp-logs` |

## Instrumenting your code

### Traces

Use the tracer returned by `setup` to wrap any block of work in a span:

```ruby
result[:tracer].in_span("orders.process", attributes: { "order.id" => order.id }) do |span|
  items = fetch_line_items(order)
  span.set_attribute("order.item_count", items.size)

  charge(order)
rescue => e
  span.record_exception(e)
  span.status = OpenTelemetry::Trace::Status.error(e.message)
  raise
end
```

Child spans are automatically linked to the parent via context propagation — no manual wiring needed.

### Metrics

Use the meter to create instruments once (e.g. in an initializer or class body) and record observations anywhere:

```ruby
# Create instruments once
orders_counter  = result[:meter].create_counter("orders.placed",
                    unit: "{order}", description: "Orders successfully placed")
charge_duration = result[:meter].create_histogram("orders.charge_duration",
                    unit: "s", description: "Time to charge the customer")

# Record in application code
orders_counter.add(1, "payment.method" => order.payment_method)

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
charge(order)
charge_duration.record(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start,
                       "payment.method" => order.payment_method)
```

### Logs

With `TraceFormatter` assigned to `Rails.logger`, every log line is automatically enriched with the active trace and span IDs — no extra calls needed:

```ruby
Rails.logger.info "Order placed: #{order.id}"
# => I, [2026-03-09T12:00:00.000000 #1234]  INFO -- app: Order placed: 8f3a
#    trace_id=4bf92f3577b34da6a3ce929d0e0e4736 span_id=00f067aa0ba902b7
```

The IDs are omitted automatically when no span is active (e.g. background jobs outside a traced context).

`Telemetry::TraceFormatter` is a `Logger::Formatter` subclass — assign it once and it enriches every log line transparently:

```ruby
Rails.logger.formatter = Telemetry::TraceFormatter.new
```

## License

MIT
