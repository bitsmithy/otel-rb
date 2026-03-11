# Research: Rails Logger → OTel Forwarding

## Overview

The `otel-rb` gem provides three logging mechanisms:

1. **`Telemetry.log` / `Telemetry.logger`** — emits OTel log records via the Logs SDK, and optionally mirrors to `Rails.logger`
2. **`TraceFormatter`** — a `Logger::Formatter` that enriches log lines with `trace_id`/`span_id` suffixes for correlation
3. **`integrate_tracing_logger: true`** — assigns `TraceFormatter` to `Rails.logger.formatter`

The user's assumption was that `integrate_tracing_logger: true` would forward all `Rails.logger` calls to OTel as log records. **This is incorrect.** It only replaces the formatter — log output still goes to whatever IO `Rails.logger` is already writing to (typically STDOUT or a file), just with trace/span IDs appended. No OTel log records are emitted.

## The Gap

There are two independent capabilities:

| Capability | Mechanism | Result |
|---|---|---|
| **OTel log emission** | `Telemetry.log` / `Telemetry.logger` | Creates OTel `LogRecord` objects exported via OTLP |
| **Trace-log correlation** | `TraceFormatter` on `Rails.logger` | Appends `trace_id`/`span_id` to text log lines |

**Neither bridges `Rails.logger` → OTel.** If you call `Rails.logger.info("something")`, that log line:
- Gets `trace_id`/`span_id` appended (if `integrate_tracing_logger: true`)
- Goes to STDOUT/file as text
- Is **never** emitted as an OTel log record

To get a log line into OTel, you must explicitly call `Telemetry.log(:info, "something")`.

## What Would Make It True

To forward all `Rails.logger` output to OTel, we need to intercept `Rails.logger` calls at a level deeper than the formatter. Two approaches:

### Approach A: Custom log device (IO-level interception)

Replace or wrap `Rails.logger`'s underlying IO device so that every `write` also emits an OTel log record. This is fragile — severity info is lost at the IO level (everything is just a string), and you'd need to parse it back out.

### Approach B: BroadcastLogger with an OTel log sink

Rails 7.1+ has `ActiveSupport::BroadcastLogger` which broadcasts log calls to multiple loggers. We could:
1. Create a logger backed by `Telemetry::Logger` (OTel emission)
2. Add it to `Rails.logger` as a broadcast target

This preserves severity levels natively. However, `BroadcastLogger` is Rails 7.1+ only.

### Approach C: Subscriber / custom Logger subclass

Create a Ruby `::Logger`-compatible class that emits OTel log records, and add it as a broadcast target (or replace `Rails.logger` entirely with a broadcasting wrapper). This would work across Rails versions.

### Recommended: Approach C — OTel-emitting Logger

Create a `Telemetry::OtelLoggerBroadcast` (or similar) that is a `::Logger` subclass (or duck-types enough for `ActiveSupport::BroadcastLogger`). When `integrate_tracing_logger: true`:

1. Wrap the existing `Rails.logger` so that every `debug`/`info`/`warn`/`error`/`fatal` call also emits an OTel `LogRecord`
2. Still apply `TraceFormatter` for text output correlation

When `integrate_tracing_logger: false` (the default), none of this applies — `Rails.logger` is untouched, and the only way to emit OTel log records is via `Telemetry.log` / `Telemetry.logger`.

The cleanest approach is likely a log subscriber that taps into `Rails.logger.add` and emits to OTel. Since `Rails.logger` is a `::Logger` (or `ActiveSupport::Logger`), we can monkey-patch or decorate `add` to also emit OTel records.

## Key Files

| File | Role |
|---|---|
| `lib/telemetry.rb:76-95` | `Telemetry.setup` — orchestrates setup, calls `wire_tracing_logger` |
| `lib/telemetry.rb:237-252` | `wire_tracing_logger` — replaces `Rails.logger.formatter` with `TraceFormatter` |
| `lib/telemetry/logger.rb` | `Telemetry::Logger` — OTel log emitter with `emit_otel` method |
| `lib/telemetry/logger.rb:63-65` | `emit` — dual-writes to OTel + optionally `Rails.logger` |
| `lib/telemetry/trace_formatter.rb` | `TraceFormatter` — appends trace/span IDs to log lines |
| `lib/telemetry/setup.rb:67-81` | `setup_logs` — configures OTel `LoggerProvider` and `BatchLogRecordProcessor` |
| `lib/telemetry/config.rb` | `Config` — holds `integrate_tracing_logger` flag |

## Data Flow (Current)

```
Telemetry.log(:info, "msg")
  → Telemetry::Logger#emit
    → emit_otel  → OTel LoggerProvider → OTLP export
    → Rails.logger.info("msg")  → TraceFormatter → STDOUT/file (with trace_id/span_id)

Rails.logger.info("msg")
  → TraceFormatter → STDOUT/file (with trace_id/span_id)
  → ❌ NOT sent to OTel
```

## Data Flow (Desired, when `integrate_tracing_logger: true`)

```
Telemetry.log(:info, "msg")
  → Telemetry::Logger#emit
    → emit_otel  → OTel LoggerProvider → OTLP export
    → Rails.logger.info("msg")  → TraceFormatter → STDOUT/file (with trace_id/span_id)
       → (intercepted, but deduplicated — NOT re-emitted to OTel)

Rails.logger.info("msg")
  → TraceFormatter → STDOUT/file (with trace_id/span_id)
  → ✅ ALSO emitted as OTel LogRecord (with trace context)
```

When `integrate_tracing_logger: false` (the default), `Rails.logger` behaves exactly as it does today — no formatter replacement, no OTel bridge. The bridge is gated behind the same opt-in flag.

## Edge Cases & Gotchas

1. **Deduplication**: When `Telemetry.log` calls `Rails.logger.info(msg)`, and `Rails.logger` now also emits to OTel, we'd get double OTel emission. Need to deduplicate — either skip `Rails.logger` forwarding in `Telemetry::Logger#emit` when the bridge is active, or use a thread-local flag to prevent re-entry.

2. **Severity mapping**: Ruby `::Logger` uses numeric constants (0=DEBUG, 1=INFO, etc). OTel uses different severity numbers (5=DEBUG, 9=INFO, 13=WARN, 17=ERROR, 21=FATAL). Need to map correctly — `Telemetry::Logger::SEVERITY` already has this mapping.

3. **Block-form logging**: `Rails.logger.info { expensive_string }` — the block should only be evaluated once if above threshold. The interception must handle this form.

4. **Tagged logging**: `Rails.logger.tagged("tag") { ... }` — tags should carry through to OTel log records if possible.

5. **Log level filtering**: `Rails.logger.level = :warn` suppresses debug/info. The OTel emission should respect the same filtering (or have its own level control).

6. **`rails_logger: false` on `Telemetry.log`**: Currently this suppresses `Rails.logger` forwarding. If Rails.logger now also emits to OTel, `rails_logger: false` should still skip the Rails.logger text output but the OTel emission already happened via `emit_otel`.

7. **Non-Rails usage**: When Rails is not present, none of this applies. `Telemetry.log` already works standalone.

8. **Test mode**: `TraceFormatter` replacement is skipped for `SimpleFormatter` in test mode. Similar care needed for the OTel bridge.

## README Documentation Issues

The README currently says (line 33):
> `integrate_tracing_logger` | `false` | When `true`, assigns `Telemetry::TraceFormatter` to `Rails.logger.formatter` for trace/log correlation

And in the Logging section (lines 253-264), it implies that `integrate_tracing_logger` makes `Telemetry.log`/`Telemetry.logger` unnecessary:
> "If you `integrate_tracing_logger`, there is no reason to use `Telemetry.log` / `Telemetry.logger` unless there's a log line you do NOT want to show up where `Rails.logger` writes to"

This is **misleading**. With `integrate_tracing_logger: true` today:
- `Rails.logger` gets trace/span IDs in text output ✅
- `Rails.logger` calls become OTel log records ❌ — this doesn't happen

The README should be corrected to reflect what actually happens, and then updated to document the new behavior once the feature is built.

## Dependencies

- `opentelemetry-logs-sdk` — already a hard dependency
- `opentelemetry-logs-api` — already a hard dependency
- `opentelemetry-exporter-otlp-logs` — already a hard dependency
- Ruby `::Logger` — standard library (hard dep in gemspec for Ruby 4.0+)
- `ActiveSupport::BroadcastLogger` — Rails 7.1+ (dev dependency only)

## Current State

The gem is well-structured with clean separation. The `Telemetry::Logger` class already knows how to emit OTel log records (`emit_otel` method at `logger.rb:68-79`). The main work is creating a bridge that intercepts `Rails.logger` calls and routes them through `emit_otel` (or equivalent).
