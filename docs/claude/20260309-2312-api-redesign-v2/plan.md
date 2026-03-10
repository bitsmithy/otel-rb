# Plan: otel-rb API Redesign v2

## Goal

Apply a second round of API refinements to the otel-rb gem: replace RSpec with Minitest, simplify setup (hash instead of Config object), clean up Config, unify the trace/meter/log public API surface, fix multi-span tracing behaviour, and add a `rails_logger` option to opt into Rails integration.

---

## Approach

Six focused changes, each scoped to a small number of files:

1. **Minitest** — swap RSpec for Minitest; rewrite all test files
2. **`Telemetry.setup(hash)`** — parse the hash into a `Config` internally; remove `Config` from the public API
3. **`rails_logger:` config flag** — `Config` grows one new field; `wire_rails` is gated behind it
4. **Remove `log_level`** — deleted from `Config` and everywhere it's referenced
5. **Multi-span tracing** — `Telemetry.trace` already uses `tracer.in_span`, which inherits context from the OTel context stack automatically. Nested calls → child spans. The Rack middleware sets the root span via `OpenTelemetry::Context.with_current(context)` so controller-level `Telemetry.trace` calls automatically become children. **No code change needed here** — the current implementation is correct. The only change is documentation/tests demonstrating nesting.
6. **Unified entrypoints**:
   - `Telemetry.trace("name", attrs: {}) { |span| }` — unchanged
   - `Telemetry.meter(:counter, "name")` → returns a cached instrument
   - `Telemetry.record(:counter, "name", value, attrs = {})` → one-liner
   - `Telemetry.log(:info, "msg", rails_logger: true)` → delegates to `Telemetry.logger`
   - `Telemetry.logger` → still accessible (returns `Telemetry::Logger` instance)
   - Remove `Telemetry::Meter::Counter` etc. (instrument classes become private)

---

## Detailed Changes

### `lib/telemetry/config.rb`

Remove `log_level`. Add `rails_logger` (default `false`).

```ruby
class Config
  attr_reader :service_name, :service_namespace, :service_version,
              :endpoint, :rails_logger

  def initialize(
    service_name: nil,
    service_namespace: nil,
    service_version: nil,
    endpoint: nil,
    rails_logger: false
  )
    @service_name      = service_name      || default_service_name
    @service_namespace = service_namespace || default_service_namespace
    @service_version   = service_version   || default_service_version
    @endpoint          = endpoint
    @rails_logger      = rails_logger
  end
  # ... defaults unchanged
end
```

### `lib/telemetry.rb`

**`setup`** — accepts a hash and builds a `Config` from it:

```ruby
def setup(**opts)
  config = Config.new(**opts)
  result = Setup.call(config)
  # ... rest unchanged
  wire_rails if config.rails_logger && defined?(Rails)
  # ...
end
```

**New `meter` method** — replaces the old `@meter` attr_reader. Returns a cached instrument by type+name. Both `type` and `name` are required:

```ruby
METER_TYPES = %i[counter histogram gauge up_down_counter].freeze

def meter(type, name, unit: nil, description: nil)
  raise NotSetupError.new(:meter) unless @meter
  raise ArgumentError, "unknown meter type #{type.inspect}; must be one of #{METER_TYPES}" unless METER_TYPES.include?(type)

  @instruments ||= {}
  @instruments[[type, name]] ||= build_instrument(type, name, unit: unit, description: description)
end

def record(type, name, value, attrs = {})
  instrument = meter(type, name)
  case type
  when :counter, :up_down_counter then instrument.add(value, attributes: attrs)
  when :histogram, :gauge         then instrument.record(value, attributes: attrs)
  end
end
```

**New `log` method**:

```ruby
def log(level, message, **kwargs)
  logger.public_send(level, message, **kwargs)
end
```

**`reset!`** — must also clear `@instruments`:

```ruby
def reset!
  @tracer      = nil
  @meter       = nil
  @logger      = nil
  @shutdown    = nil
  @instruments = nil
end
```

**Remove** `attr_reader :meter` (replaced by the method above).

### `lib/telemetry/meter.rb`

**Delete this file entirely.** All instrument classes (`Counter`, `Histogram`, `Gauge`, `UpDownCounter`) and the `Instrument` mixin are removed. Instrument creation is handled by a private `build_instrument` helper on the `Telemetry` module.

Add `build_instrument` as a private class method in `lib/telemetry.rb`:

```ruby
private

def build_instrument(type, name, unit:, description:)
  case type
  when :counter         then @meter.create_counter(name, unit: unit, description: description)
  when :histogram       then @meter.create_histogram(name, unit: unit, description: description)
  when :gauge           then @meter.create_gauge(name, unit: unit, description: description)
  when :up_down_counter then @meter.create_up_down_counter(name, unit: unit, description: description)
  end
end
```

### `lib/telemetry.rb` — require cleanup

Remove `require 'telemetry/meter'`.

### `otel-rb.gemspec`

Remove `rspec` dev dependency, add `minitest` and `minitest-reporters`:

```ruby
spec.add_development_dependency 'minitest',           '~> 5.25'
spec.add_development_dependency 'minitest-reporters', '~> 1.7'
spec.add_development_dependency 'rack',               '~> 3.0'
spec.add_development_dependency 'rack-test',          '~> 2.0'
spec.add_development_dependency 'rubocop',            '~> 1.65'
```

### `Gemfile.lock` / `bundle install`

After editing the gemspec, `bundle install` to refresh the lockfile.

### Test files — full replacement

Delete the entire `spec/` directory tree. Create a `test/` directory.

**`test/test_helper.rb`**:

```ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/reporters'
require 'opentelemetry/sdk'
require 'telemetry'

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

module TelemetryTestHelpers
  def setup
    OpenTelemetry::SDK.configure
    Telemetry.reset!
    stub_at_exit  # suppress network timeouts on process exit
  end

  private

  def stub_at_exit
    Kernel.stub(:at_exit, nil) { yield } if block_given?
    # For setup-phase suppression, patch via define_method later if needed
  end
end
```

`Telemetry.test_mode!` is called once at the top of `test_helper.rb`. It does two things:

1. Disables `at_exit` registration so OTel shutdown procs never fire during the test run.
2. Installs a Minitest `before_setup` hook (via `Minitest::Test.prepend`) that calls `OpenTelemetry::SDK.configure` and `Telemetry.reset!` automatically before every test. Individual tests never need to call either.

```ruby
# In test_helper.rb
Telemetry.test_mode!  # one call handles everything: no at_exit, auto-reset before each test

# In lib/telemetry.rb
def test_mode!
  @test_mode = true

  # Auto-reset OTel and Telemetry state before every Minitest test
  require 'minitest'
  Minitest::Test.prepend(Module.new do
    def before_setup
      OpenTelemetry::SDK.configure
      Telemetry.reset!
      super
    end
  end)
end

def setup(**opts)
  # ...
  at_exit { shutdown&.call } unless @test_mode
end
```

**`test/telemetry/config_test.rb`** — replaces `spec/telemetry/config_spec.rb`

**`test/telemetry/setup_test.rb`** — replaces `spec/telemetry/setup_spec.rb`

**`test/telemetry/meter_test.rb`** — replaces `spec/telemetry/meter_spec.rb` (now tests `Telemetry.meter` / `Telemetry.record`)

**`test/telemetry/logger_test.rb`** — replaces `spec/telemetry/logger_spec.rb`

**`test/telemetry/middleware_test.rb`** — replaces `spec/telemetry/middleware_spec.rb`

**`test/telemetry/trace_formatter_test.rb`** — replaces `spec/telemetry/trace_formatter_spec.rb`

### `.rspec`

Delete this file (RSpec config no longer needed).

---

## Considerations & Trade-offs

### Why `Telemetry.setup(**opts)` not `Telemetry.setup(opts)`?

Keyword args are cleaner at the call site and consistent with Ruby conventions. The Rails initializer becomes:

```ruby
Telemetry.setup(
  service_name:      Rails.application.class.module_parent_name.underscore,
  service_namespace: "ourneatlife",
  service_version:   ENV.fetch("GIT_COMMIT_SHA", "unknown"),
  rails_logger:      true
)
```

### `Telemetry.meter` requires both `type` and `name`

The raw OTel meter is not exposed. `Telemetry.meter(type, name)` requires both arguments and raises `ArgumentError` for unknown types. This enforces the typed API and keeps the surface small. Users who need observable counters or other advanced instrument types not yet wrapped should file an issue to get them added.

### Multi-span tracing — why no code change?

`tracer.in_span` pushes/pops the current span on the OTel context stack. Nested `Telemetry.trace` calls are already child spans. The Rack middleware sets the root context via `Context.with_current`. This works correctly today; tests will demonstrate it.

### Removing `Telemetry::Meter::*` classes

They're now private implementation details. The public API is cleaner: `Telemetry.meter(:counter, "name")` and `Telemetry.record(:counter, "name", 1)`. Advanced users who held references to instrument objects can still hold the return value of `Telemetry.meter(...)`.

---

## Testing Strategy

All tests use Minitest. File layout: `test/telemetry/<subject>_test.rb`.

### `test/telemetry/config_test.rb`

- `test_defaults`: service_name, service_namespace, service_version all have non-nil defaults; rails_logger defaults to false
- `test_explicit_values`: all fields can be overridden
- `test_no_log_level`: Config does not respond to `log_level`
- `test_rails_logger_default_false`: `Config.new.rails_logger == false`

### `test/telemetry/setup_test.rb`

- `test_setup_accepts_hash`: `Telemetry.setup(service_name: "x")` does not raise
- `test_setup_returns_nil`: return value is nil
- `test_tracer_assigned`: after setup, `Telemetry.tracer` responds to `in_span`
- `test_meter_assigned`: after setup, `Telemetry.meter` is non-nil
- `test_not_setup_error_trace`: raises before setup
- `test_not_setup_error_meter`: raises before setup
- `test_not_setup_error_logger`: raises before setup
- `test_not_setup_error_log`: raises before setup
- `test_rails_wiring_disabled_by_default`: when Rails is stubbed but `rails_logger: false`, middleware is NOT inserted
- `test_rails_wiring_enabled_when_opted_in`: when `rails_logger: true` and Rails is present, middleware IS inserted and formatter is assigned
- `test_setup_internal_config`: `Telemetry::Setup` still accepts a `Config` directly (internal contract preserved)

### `test/telemetry/trace_test.rb` (new file — trace behaviour)

- `test_trace_yields_span`: block receives a span
- `test_trace_attrs`: initial attrs are set on span
- `test_nested_trace_is_child_span`: inner `Telemetry.trace` inside outer creates a child span (verified via in-memory exporter: child's `parent_span_id` matches outer span's `span_id`)

### `test/telemetry/meter_test.rb`

- `test_meter_counter_returns_instrument`: `Telemetry.meter(:counter, "x")` returns a non-nil object
- `test_meter_instruments_cached`: calling `Telemetry.meter(:counter, "x")` twice returns the same object
- `test_meter_unknown_type_raises`: `Telemetry.meter(:bogus, "x")` raises `ArgumentError`
- `test_record_counter`: does not raise
- `test_record_histogram`: does not raise
- `test_record_gauge`: does not raise
- `test_record_up_down_counter`: does not raise
- `test_record_with_attrs`: does not raise
- `test_meter_not_setup_error`: raises before setup

### `test/telemetry/logger_test.rb`

- `test_logger_returns_logger_instance`: `Telemetry.logger` is a `Telemetry::Logger`
- `test_log_delegates_to_logger`: `Telemetry.log(:info, "msg")` is equivalent to `Telemetry.logger.info("msg")`
- `test_log_levels`: all five levels work without raising
- `test_not_setup_error`: `Telemetry.logger` raises before setup
- `test_log_not_setup_error`: `Telemetry.log(...)` raises before setup
- `test_otel_missing_warn`: one-time warn when Logs SDK absent
- `test_rails_logger_delegation`: delegates to Rails.logger when present
- `test_rails_logger_opt_out`: rails_logger: false suppresses delegation

### `test/telemetry/middleware_test.rb`

- `test_creates_span`: one span per request
- `test_span_name_method_path`: span named "GET /users"
- `test_span_name_uses_route_template`: action_dispatch key used when present
- `test_response_status_attribute`: http.response.status_code set
- `test_4xx_not_error`: 404 does not set span status to ERROR
- `test_5xx_is_error`: 500 sets span status to ERROR
- `test_w3c_propagation`: incoming traceparent header is honoured

### `test/telemetry/trace_formatter_test.rb`

- `test_no_span_no_suffix`: no trace_id in output
- `test_active_span_adds_suffix`: trace_id and span_id appended
- `test_finished_span_no_suffix`: after span ends, no trace_id

---

## Todo List

### Phase 1: Config + gemspec

- [ ] Remove `log_level` from `Config`; add `rails_logger: false`
- [ ] Update gemspec: remove `rspec`, add `minitest` and `minitest-reporters`
- [ ] Run `bundle install` to refresh lockfile

### Phase 2: `Telemetry` module — setup + unified API

- [ ] Change `Telemetry.setup` to accept `**opts` and build `Config` internally
- [ ] Gate `wire_rails` behind `config.rails_logger`
- [ ] Replace `attr_reader :meter` with a `meter(type, name, ...)` method (both args required, no raw-meter escape hatch)
- [ ] Add `Telemetry.record(type, name, value, attrs = {})`
- [ ] Add `Telemetry.log(level, message, **kwargs)`
- [ ] Add `Telemetry.test_mode!` and gate `at_exit` behind it
- [ ] Add `build_instrument` private method
- [ ] Add `@instruments` to `reset!`
- [ ] Remove `require 'telemetry/meter'` from `lib/telemetry.rb`

### Phase 3: Remove meter classes

- [ ] Delete `lib/telemetry/meter.rb`

### Phase 4: Tests — switch to Minitest

- [ ] Delete `spec/` directory (manual — user to confirm)
- [ ] Delete `.rspec` file
- [ ] Create `test/test_helper.rb`
- [ ] Write `test/telemetry/config_test.rb`
- [ ] Write `test/telemetry/setup_test.rb`
- [ ] Write `test/telemetry/trace_test.rb`
- [ ] Write `test/telemetry/meter_test.rb`
- [ ] Write `test/telemetry/logger_test.rb`
- [ ] Write `test/telemetry/middleware_test.rb`
- [ ] Write `test/telemetry/trace_formatter_test.rb`

### Phase 5: Run tests + fix

- [ ] Run `bundle exec ruby -Itest test/**/*_test.rb` (or `bundle exec rake test`) — all green
- [ ] Fix any failures

### Phase 6: Update Rails app

- [ ] Update `our_neat_link` initializer to `Telemetry.setup(... rails_logger: true)`
- [ ] Update `our_neat_link` README if applicable

### Phase 7: Update gem README

- [ ] Rewrite `README.md` for new API
