# Plan: Rails.logger → OTel Log Forwarding

## Goal

When `integrate_tracing_logger: true`, make every `Rails.logger` call also emit an OTel log record — so all application logs are visible in the OTel backend with trace context. When `false` (the default), `Rails.logger` is untouched.

## Research Reference

`docs/claude/20260310-2317-rails-logger-otel-forwarding/research.md`

## Approach

**Prepend a module onto `Rails.logger`'s singleton class** that overrides `add` — the single method all `::Logger` level methods (`debug`, `info`, `warn`, `error`, `fatal`) funnel through. The module:

1. Resolves the message (handling string, progname-as-message, and block forms)
2. Calls `super` so the original logger behavior is preserved
3. Emits an OTel `LogRecord` with severity mapping and trace context

This is installed inside `wire_tracing_logger` alongside the existing `TraceFormatter` assignment, so both are gated behind `integrate_tracing_logger: true` and both respect the existing test-mode skip logic.

**Deduplication**: `Telemetry::Logger#emit` already mirrors to `Rails.logger`. With the bridge active, that mirror call would re-emit to OTel. A thread-local flag (`Thread.current[:telemetry_skip_otel_bridge]`) is set before the mirror call and checked in the bridge to prevent double emission.

## Considerations & Trade-offs

**Why `add` override, not formatter-level?** The formatter is a pure function (string in, string out). Adding OTel emission as a side effect of formatting would be surprising and fragile. `add` is the natural interception point — it's where level filtering happens and where the message is resolved.

**Why prepend on singleton class, not a wrapper logger?** Prepending preserves the existing logger identity. `Rails.logger` remains the same object, so any code that holds a reference to it (gems, middleware, controllers) continues to work. A wrapper would break `Rails.logger.is_a?(ActiveSupport::Logger)` checks and tagged logging.

**Why not `ActiveSupport::BroadcastLogger`?** Rails 7.1+ only. The prepend approach works across all Rails versions and also works WITH BroadcastLogger (the prepend intercepts before broadcast dispatch).

**Option name**: `integrate_tracing_logger` still fits — "integrate the logger with telemetry" now means both trace correlation (formatter) and OTel log emission (bridge). No rename needed.

## Detailed Changes

### `lib/telemetry/log_bridge.rb` (new file)

Module prepended onto `Rails.logger.singleton_class` to intercept `add` and emit OTel log records.

```ruby
# frozen_string_literal: true

require 'opentelemetry/trace'

module Telemetry
  # Intercepts Rails.logger calls and emits OTel log records.
  # Prepended onto Rails.logger's singleton class when
  # integrate_tracing_logger: true.
  module LogBridge
    RUBY_TO_OTEL_SEVERITY = {
      0 => [5,  'DEBUG'],
      1 => [9,  'INFO'],
      2 => [13, 'WARN'],
      3 => [17, 'ERROR'],
      4 => [21, 'FATAL'],
      5 => [21, 'FATAL']
    }.freeze

    def add(severity, message = nil, progname = nil, &)
      return super if Thread.current[:telemetry_skip_otel_bridge]

      severity ||= ::Logger::UNKNOWN

      if message.nil?
        if block_given?
          resolved_message = yield
          result = super(severity, resolved_message, progname)
        else
          resolved_message = progname
          result = super(severity, nil, progname)
        end
      else
        resolved_message = message
        result = super
      end

      emit_otel_record(severity, resolved_message) if resolved_message

      result
    end

    private

    def emit_otel_record(severity, message)
      otel_severity = RUBY_TO_OTEL_SEVERITY[severity]
      return unless otel_severity

      span_context = OpenTelemetry::Trace.current_span.context

      @telemetry_bridge_logger ||= OpenTelemetry.logger_provider.logger(
        name: 'telemetry.bridge', version: Telemetry::VERSION
      )

      @telemetry_bridge_logger.on_emit(
        severity_number: otel_severity[0],
        severity_text: otel_severity[1],
        body: message.to_s,
        trace_id: span_context.valid? ? span_context.trace_id : nil,
        span_id: span_context.valid? ? span_context.span_id : nil,
        trace_flags: span_context.valid? ? span_context.trace_flags : nil,
        observed_timestamp: Time.now
      )
    end
  end
end
```

### `lib/telemetry/logger.rb`

Add deduplication guard in `emit` so that when `Telemetry.log` mirrors to `Rails.logger`, the bridge does not re-emit to OTel.

```ruby
# Change the emit method from:
def emit(level, message, rails_logger:)
  emit_otel(level, message)
  ::Rails.logger.public_send(level, message) if rails_logger && defined?(::Rails)
end

# To:
def emit(level, message, rails_logger:)
  emit_otel(level, message)
  return unless rails_logger && defined?(::Rails)

  prior = Thread.current[:telemetry_skip_otel_bridge]
  begin
    Thread.current[:telemetry_skip_otel_bridge] = true
    ::Rails.logger.public_send(level, message)
  ensure
    Thread.current[:telemetry_skip_otel_bridge] = prior
  end
end
```

### `lib/telemetry.rb`

1. Add `require 'telemetry/log_bridge'`
2. Update `wire_tracing_logger` to also install the bridge

```ruby
# After the existing formatter assignment:
def wire_tracing_logger
  existing = Rails.logger.formatter
  if existing && !existing.is_a?(TraceFormatter)
    return if skip_formatter_replacement?(existing)

    warn '[Telemetry] replacing existing logger formatter ' \
         "(#{existing.class}) with Telemetry::TraceFormatter"
  end
  Rails.logger.formatter = TraceFormatter.new
  Rails.logger.singleton_class.prepend(LogBridge)
  Rails.logger.instance_variable_set(
    :@telemetry_bridge_logger,
    OpenTelemetry.logger_provider.logger(name: 'telemetry.bridge', version: VERSION)
  )
end
```

### `README.md`

**Configuration table** — update the `integrate_tracing_logger` description:

```markdown
| `integrate_tracing_logger` | `false` | When `true`, replaces `Rails.logger.formatter` with `TraceFormatter` and forwards all `Rails.logger` calls to OTel as log records |
```

**Setup → Rails section** — update the "With `integrate_tracing_logger: true`" bullet list:

```markdown
With `integrate_tracing_logger: true`, setup also:

- Assigns `Telemetry::TraceFormatter` to `Rails.logger.formatter` for trace/span ID correlation in text output
- Bridges `Rails.logger` to OTel — every `Rails.logger` call also emits an OTel log record with trace context
```

**Logging section** — rewrite to reflect the new behavior:

```markdown
## Logging

### Via Rails.logger (recommended with `integrate_tracing_logger: true`)

When `integrate_tracing_logger: true`, every `Rails.logger` call automatically emits an OTel log record with trace context. No code changes needed — existing `Rails.logger.info("...")` calls just start appearing in your OTel backend.

### Via Telemetry.log / Telemetry.logger

`Telemetry.log` emits directly to OTel and optionally mirrors to `Rails.logger`:

​```ruby
Telemetry.log(:info,  "Order placed")                     # OTel + Rails.logger
Telemetry.log(:error, "Charge failed", rails_logger: false)  # OTel only
​```

`Telemetry.logger` returns the `Telemetry::Logger` instance:

​```ruby
Telemetry.logger.warn("Low balance", rails_logger: true)
​```

Available levels: `debug`, `info`, `warn`, `error`, `fatal`.

When `integrate_tracing_logger: true`, you only need `Telemetry.log` for OTel-only logs that should NOT appear in `Rails.logger` output:

​```ruby
Telemetry.log(:debug, "internal detail", rails_logger: false)
​```
```

**TraceFormatter section** — update to reflect the combined behavior:

```markdown
## TraceFormatter

With `integrate_tracing_logger: true`, `TraceFormatter` is assigned to `Rails.logger.formatter` automatically. Every log line is enriched with the active trace and span IDs (IDs are omitted when no span is active):

​```text
I, [2026-03-10T12:00:00.000000 #1234]  INFO -- app: Order placed
  trace_id=4bf92f3577b34da6a3ce929d0e0e4736 span_id=00f067aa0ba902b7
​```

This means `Rails.logger` calls get trace correlation in TWO places:
1. **Text output** — trace/span IDs appended to the log line (for log files, STDOUT)
2. **OTel backend** — structured `LogRecord` with trace context (for your observability platform)

If you prefer not to replace `Rails.logger.formatter`, use `Telemetry.log` / `Telemetry.logger` directly — these always emit OTel log records with trace context, regardless of the `integrate_tracing_logger` setting.
```

## New Files

| File | Purpose |
|------|---------|
| `lib/telemetry/log_bridge.rb` | `LogBridge` module — prepended onto `Rails.logger` to intercept `add` and emit OTel log records |

## Dependencies

None — all required OTel gems are already hard dependencies.

## Migration / Data Changes

None.

## Testing Strategy

### `test/telemetry/log_bridge_test.rb` (new file)

Tests for the `LogBridge` module in isolation.

1. **`test_bridge_emits_otel_log_record`** — Prepend `LogBridge` onto a `::Logger` instance, call `logger.info("hello")`, verify `on_emit` was called on the OTel logger with severity_number=9, severity_text="INFO", body="hello".

2. **`test_bridge_maps_all_severity_levels`** — For each level (debug/info/warn/error/fatal), call the corresponding method, verify the OTel severity number matches (5/9/13/17/21).

3. **`test_bridge_attaches_trace_context`** — Inside a span, call `logger.info("traced")`, verify the OTel log record includes the span's trace_id and span_id.

4. **`test_bridge_omits_trace_context_without_span`** — Outside any span, call `logger.info("no trace")`, verify trace_id and span_id are nil.

5. **`test_bridge_handles_block_form`** — Call `logger.info { "from block" }`, verify OTel log record body is "from block" and the block is only evaluated once.

6. **`test_bridge_skips_when_thread_local_set`** — Set `Thread.current[:telemetry_skip_otel_bridge] = true`, call `logger.info("skipped")`, verify no OTel emission.

7. **`test_bridge_preserves_original_logger_output`** — Call `logger.info("hello")` with bridge prepended, verify the message still appears in the logger's IO output.

### `test/telemetry/logger_test.rb` (existing file)

8. **`test_telemetry_log_does_not_double_emit_with_bridge`** — With a fake `Rails.logger` that has `LogBridge` prepended, call `Telemetry.log(:info, "msg")`. Verify OTel `on_emit` is called exactly once (from `Telemetry::Logger#emit_otel`), not twice.

### `test/telemetry/setup_test.rb` (existing file)

9. **`test_bridge_installed_when_integrate_tracing_logger_true`** — With fake Rails, call `Telemetry.setup(integrate_tracing_logger: true)`. Verify `LogBridge` is in `Rails.logger.singleton_class.ancestors`.

10. **`test_bridge_not_installed_by_default`** — With fake Rails, call `Telemetry.setup`. Verify `LogBridge` is NOT in `Rails.logger.singleton_class.ancestors`.

11. **`test_bridge_skipped_in_test_mode_with_simple_formatter`** — In test mode with `SimpleFormatter`, call `Telemetry.setup(integrate_tracing_logger: true)`. Verify `LogBridge` is NOT in `Rails.logger.singleton_class.ancestors` (matches the existing SimpleFormatter skip behavior).

## Todo List

### Phase 1: LogBridge module + tests (TDD)
- [x] Write `test/telemetry/log_bridge_test.rb` with tests 1-7
- [x] Create `lib/telemetry/log_bridge.rb` with the `LogBridge` module
- [x] Run tests, verify all pass

### Phase 2: Deduplication in Telemetry::Logger + test (TDD)
- [x] Write test 8 (`test_telemetry_log_does_not_double_emit_with_bridge`) in `logger_test.rb`
- [x] Update `Telemetry::Logger#emit` with thread-local dedup guard
- [x] Run tests, verify all pass

### Phase 3: Wire into Telemetry.setup + tests (TDD)
- [x] Write tests 9-11 in `setup_test.rb`
- [x] Add `require 'telemetry/log_bridge'` to `lib/telemetry.rb`
- [x] Update `wire_tracing_logger` to prepend `LogBridge`
- [x] Run full test suite, verify all pass

### Phase 4: README documentation
- [x] Update configuration table description for `integrate_tracing_logger`
- [x] Update "With `integrate_tracing_logger: true`" bullet list in Setup section
- [x] Rewrite Logging section
- [x] Update TraceFormatter section
- [x] Review README for consistency

## Verification Summary

Fact-checked on 2026-03-11 against the implemented codebase.

**Total claims checked**: 32
**Confirmed**: 25
**Corrected**: 7

Corrections made:
1. `LogBridge#add` signature: added anonymous block parameter `&` to match rubocop `Style/ExplicitBlockArgument`
2. `LogBridge#add` skip guard: changed `block_given? ? super { yield } : super` to simplified `return super` (bare `super` forwards block automatically)
3. `LogBridge#add` OTel emission: extracted to private `emit_otel_record` method to satisfy rubocop `Metrics/MethodLength` and `Metrics/CyclomaticComplexity`
4. `LogBridge#add` else branch: changed `super(severity, message, progname)` to bare `super` per rubocop `Style/SuperArguments`
5. `Logger#emit` ensure block: changed `= false` to save/restore pattern (`prior = Thread.current[...]` / `= prior`) per code review finding (preserves pre-existing flag value)
6. `Logger#emit` conditional style: changed `if/begin/ensure/end` to guard clause (`return unless`) per rubocop `Style/GuardClause`
7. `wire_tracing_logger`: added eager initialization of `@telemetry_bridge_logger` via `instance_variable_set` to eliminate thread-safety race on lazy `||=`

**Unverifiable**: 0
