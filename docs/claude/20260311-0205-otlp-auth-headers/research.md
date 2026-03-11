# Research: OTLP Auth Headers

## Overview

The user added authorization to their OTel endpoint and wants otel-rb to send `OTEL_EXPORTER_OTLP_HEADERS` when posting telemetry data.

## Key Finding: It Already Works

**The OpenTelemetry Ruby SDK already auto-reads `OTEL_EXPORTER_OTLP_HEADERS` from the environment.** No code changes to otel-rb are needed for basic auth header support.

Each OTLP exporter's constructor has a `headers:` parameter that defaults to reading from env vars:

```ruby
# opentelemetry-exporter-otlp/lib/opentelemetry/exporter/otlp/exporter.rb:53
headers: OpenTelemetry::Common::Utilities.config_opt(
  'OTEL_EXPORTER_OTLP_TRACES_HEADERS',
  'OTEL_EXPORTER_OTLP_HEADERS',
  default: {}
)
```

The same pattern exists in the metrics and logs exporters. The lookup order is:
1. Signal-specific env var (e.g., `OTEL_EXPORTER_OTLP_TRACES_HEADERS`)
2. General env var (`OTEL_EXPORTER_OTLP_HEADERS`)
3. Default: `{}`

### Env Var Format

`OTEL_EXPORTER_OTLP_HEADERS` accepts comma-separated `key=value` pairs, URL-encoded:

```bash
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer%20my-token,X-Custom=value"
```

### Why otel-rb Doesn't Interfere

otel-rb's `Setup.endpoint_opts(config)` only passes `endpoint:` when explicitly configured:

```ruby
# lib/telemetry/setup.rb:47-49
def self.endpoint_opts(config)
  config.endpoint ? { endpoint: config.endpoint } : {}
end
```

When `endpoint:` is passed explicitly, the SDK still reads `OTEL_EXPORTER_OTLP_HEADERS` from the environment for the `headers:` parameter (since it wasn't overridden). All other parameters (headers, compression, timeout, certificates) remain at their env-var-backed defaults.

## Current Exporter Configuration

| Signal | Exporter Class | Config Passed | Headers Source |
|--------|---|---|---|
| Traces | `OpenTelemetry::Exporter::OTLP::Exporter` | `endpoint:` only | `OTEL_EXPORTER_OTLP_TRACES_HEADERS` or `OTEL_EXPORTER_OTLP_HEADERS` |
| Metrics | `OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter` | `endpoint:` only | `OTEL_EXPORTER_OTLP_METRICS_HEADERS` or `OTEL_EXPORTER_OTLP_HEADERS` |
| Logs | `OpenTelemetry::Exporter::OTLP::Logs::LogsExporter` | `endpoint:` only | `OTEL_EXPORTER_OTLP_LOGS_HEADERS` or `OTEL_EXPORTER_OTLP_HEADERS` |

## What This Means

Setting `OTEL_EXPORTER_OTLP_HEADERS` in the environment (or in a Rails initializer via `ENV['OTEL_EXPORTER_OTLP_HEADERS'] = ...`) is all that's needed. The SDK handles parsing and attaching headers to every OTLP HTTP request.

## Possible Enhancement (Not Required)

If you wanted to allow programmatic header configuration via `Telemetry.setup(headers: { "Authorization" => "Bearer token" })`, that would require:

1. Adding a `headers` attribute to `Telemetry::Config`
2. Passing `headers:` in `endpoint_opts` alongside `endpoint:`
3. Tests for the new config option

This would follow the same pattern as the existing `endpoint` option. But it's not necessary — the env var approach is the standard OTel way and is already supported.

## Key Files

| File | Role |
|---|---|
| `lib/telemetry/setup.rb:47-49` | `endpoint_opts` — the only exporter config passed to SDK |
| `lib/telemetry/config.rb` | `Config` struct — holds `endpoint` (no `headers` today) |
| `lib/telemetry/setup.rb:16,59,75` | Exporter instantiation — `**endpoint_opts(config)` |
