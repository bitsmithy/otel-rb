# Plan: otel-rb Ruby Gem

## Goal

Build `otel-rb`, a thin, opinionated Ruby gem that mirrors [`bitsmithy/go-otel`](https://github.com/bitsmithy/go-otel): one call wires traces, metrics, and (optionally) logs over OTLP/HTTP, with a Rack middleware for automatic HTTP instrumentation and a logger formatter for trace-log correlation.

**Gem name**: `otel-rb`. All internals use the `Telemetry` module namespace unchanged.

**Research reference**: `docs/claude/20260309-0007-ruby-otel-gem/research.md`

---

## Approach

The gem lives as a **standalone repository** at `~/Documents/Projects/bitsmithy/otel-rb/`. We build it as a proper Rubygem with a gemspec, RSpec tests, and a README. It can be integrated into any Rails/Rack app as a separate step.

Design principles (mirroring go-otel):
- **Single-call setup** — `Telemetry.setup(config)`, no builder pattern
- **Return values over globals** — returns `{ shutdown:, tracer:, meter: }`; globals also set for library instrumentation
- **All config optional** — sensible defaults from the environment
- **OTLP/HTTP only** — opinionated; no stdout/Zipkin/Jaeger in the setup path
- **Env var fallback** — standard `OTEL_*` env vars apply when `endpoint:` is nil
- **Explicit shutdown** — caller registers `at_exit { result[:shutdown].call }`

Signals supported:
- **Traces** — `opentelemetry-sdk` + `opentelemetry-exporter-otlp` (stable)
- **Metrics** — `opentelemetry-metrics-sdk` + `opentelemetry-exporter-otlp-metrics` (stable API, maturing SDK)
- **Logs** — optional; `opentelemetry-logs-sdk` + `opentelemetry-exporter-otlp-logs` only loaded if gems are present; the `TraceFormatter` provides pragmatic trace-log correlation without depending on the experimental log signal

---

## File Structure

The gem lives at `~/Documents/Projects/bitsmithy/otel-rb/`:

```
otel-rb/
├── lib/
│   ├── telemetry.rb                  # Top-level module, public API
│   └── telemetry/
│       ├── version.rb                # VERSION constant
│       ├── config.rb                 # Config value object
│       ├── setup.rb                  # Core wiring logic
│       ├── middleware.rb             # Rack middleware
│       └── trace_formatter.rb       # Logger::Formatter subclass
├── spec/
│   ├── spec_helper.rb
│   ├── telemetry/
│   │   ├── config_spec.rb
│   │   ├── setup_spec.rb
│   │   ├── middleware_spec.rb
│   │   └── trace_formatter_spec.rb
├── otel-rb.gemspec
├── Gemfile
├── .rspec
└── README.md
```

---

## Detailed Changes

### `otel-rb.gemspec`

Declares the gem metadata and runtime dependencies.

```ruby
require_relative "lib/telemetry/version"

Gem::Specification.new do |spec|
  spec.name          = "otel-rb"
  spec.version       = Telemetry::VERSION
  spec.authors       = ["bitsmithy"]
  spec.summary       = "Thin, opinionated OpenTelemetry setup for Ruby/Rails"
  spec.description   = "One-call OTLP/HTTP wiring for traces, metrics, and logs. " \
                       "Rack middleware for HTTP instrumentation. " \
                       "Logger formatter for trace-log correlation."
  spec.homepage      = "https://github.com/bitsmithy/otel-rb"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files         = Dir["lib/**/*", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  # Ruby 4.0+ no longer bundles logger in default gems
  spec.add_dependency "logger", "~> 1.6"

  # Core OTel API is always required (it's a no-op without SDK)
  spec.add_dependency "opentelemetry-api",          "~> 1.0"
  spec.add_dependency "opentelemetry-sdk",          "~> 1.0"
  spec.add_dependency "opentelemetry-exporter-otlp", "~> 0.28"

  # Metrics — declared as required; guard with rescue LoadError in setup
  spec.add_dependency "opentelemetry-metrics-api",            "~> 0.1"
  spec.add_dependency "opentelemetry-metrics-sdk",            "~> 0.1"
  spec.add_dependency "opentelemetry-exporter-otlp-metrics",  "~> 0.1"

  # Semantic conventions (for attribute names)
  spec.add_dependency "opentelemetry-semantic_conventions", "~> 1.0"

  spec.add_development_dependency "rspec",           "~> 3.13"
  spec.add_development_dependency "rack",            "~> 3.0"
  spec.add_development_dependency "rack-test",       "~> 2.0"
  spec.add_development_dependency "rubocop",         "~> 1.65"
end
```

**Note on logs**: `opentelemetry-logs-sdk` and `opentelemetry-exporter-otlp-logs` are NOT declared as dependencies — they are optional. Setup detects their presence with `defined?` checks.

---

### `lib/telemetry/version.rb`

```ruby
module Telemetry
  VERSION = "0.1.0"
end
```

---

### `lib/telemetry/config.rb`

All fields optional. Defaults are computed lazily so they can reference runtime state.

```ruby
module Telemetry
  class Config
    attr_reader :service_name, :service_namespace, :service_version,
                :endpoint, :log_level

    def initialize(
      service_name: nil,
      service_namespace: nil,
      service_version: nil,
      endpoint: nil,
      log_level: :info
    )
      @service_name      = service_name      || default_service_name
      @service_namespace = service_namespace || default_service_namespace
      @service_version   = service_version   || default_service_version
      @endpoint          = endpoint          # nil → OTEL_EXPORTER_OTLP_ENDPOINT env var
      @log_level         = log_level
    end

    private

    def default_service_name
      # Mirrors go-otel: last meaningful segment of the program name
      File.basename($PROGRAM_NAME, ".*")
    end

    def default_service_namespace
      # Parent directory name as a rough namespace (e.g. "bitsmithy")
      File.basename(File.dirname(File.expand_path($PROGRAM_NAME)))
    end

    def default_service_version
      # Try to find the gemspec version; fall back to env var; then "unknown"
      ENV.fetch("SERVICE_VERSION", "unknown")
    end
  end
end
```

---

### `lib/telemetry/setup.rb`

The core wiring. Creates providers, sets globals, configures propagator, returns result hash.

```ruby
require "opentelemetry-sdk"
require "opentelemetry-exporter-otlp"
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"

module Telemetry
  module Setup
    def self.call(config)
      resource = build_resource(config)

      # --- Traces ---
      trace_exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
        **endpoint_opts(config)
      )
      tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
        resource: resource,
        sampler:  OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON
      )
      tracer_provider.add_span_processor(
        OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(trace_exporter)
      )

      # --- Metrics (guard for SDK maturity) ---
      meter_provider = setup_metrics(config, resource)

      # --- Logs (optional, load only if gems present) ---
      setup_logs(config, resource)

      # --- Globals ---
      OpenTelemetry.tracer_provider = tracer_provider
      OpenTelemetry.meter_provider  = meter_provider if meter_provider
      OpenTelemetry.propagation     = composite_propagator

      tracer = tracer_provider.tracer(config.service_name, config.service_version)
      meter  = meter_provider&.meter(config.service_name, config.service_version)

      shutdown = build_shutdown(tracer_provider, meter_provider)

      { shutdown: shutdown, tracer: tracer, meter: meter }
    end

    private_class_method def self.build_resource(config)
      OpenTelemetry::SDK::Resources::Resource.create(
        OpenTelemetry::SemanticConventions::Resource::SERVICE_NAME      => config.service_name,
        OpenTelemetry::SemanticConventions::Resource::SERVICE_NAMESPACE => config.service_namespace,
        OpenTelemetry::SemanticConventions::Resource::SERVICE_VERSION   => config.service_version
      )
    end

    private_class_method def self.endpoint_opts(config)
      return {} if config.endpoint.nil?
      { endpoint: config.endpoint }
    end

    private_class_method def self.setup_metrics(config, resource)
      require "opentelemetry-metrics-sdk"
      require "opentelemetry-exporter-otlp-metrics"
      require "opentelemetry/metrics"
      require "opentelemetry/exporter/otlp/metrics"

      metric_exporter = OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter.new(
        **endpoint_opts(config)
      )
      reader = OpenTelemetry::SDK::Metrics::Export::PeriodicMetricReader.new(
        exporter: metric_exporter
      )
      OpenTelemetry::SDK::Metrics::MeterProvider.new(resource: resource).tap do |mp|
        mp.add_metric_reader(reader)
      end
    rescue LoadError
      warn "[Telemetry] opentelemetry-metrics-sdk not available; metrics disabled"
      nil
    end

    private_class_method def self.setup_logs(config, resource)
      require "opentelemetry-logs-sdk"
      require "opentelemetry-exporter-otlp-logs"
      require "opentelemetry/logs"
      require "opentelemetry/exporter/otlp/logs"

      log_exporter = OpenTelemetry::Exporter::OTLP::Logs::LogsExporter.new(
        **endpoint_opts(config)
      )
      logger_provider = OpenTelemetry::SDK::Logs::LoggerProvider.new(resource: resource)
      logger_provider.add_log_record_processor(
        OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(log_exporter)
      )
      OpenTelemetry.logger_provider = logger_provider
    rescue LoadError
      nil # Logs are optional; no warning needed
    end

    private_class_method def self.composite_propagator
      OpenTelemetry::Context::Propagation::CompositeTextMapPropagator.new(
        propagators: [
          OpenTelemetry::Trace::Propagation::TraceContext.new,
          OpenTelemetry::Baggage::Propagation::TextMapPropagator.new
        ]
      )
    end

    private_class_method def self.build_shutdown(tracer_provider, meter_provider)
      lambda do
        tracer_provider.shutdown
        meter_provider&.shutdown
        if OpenTelemetry.respond_to?(:logger_provider) && OpenTelemetry.logger_provider
          OpenTelemetry.logger_provider.shutdown
        end
      end
    end
  end
end
```

---

### `lib/telemetry/middleware.rb`

Standard Rack middleware. Pre-registers metric instruments once in `initialize`. Wraps each request with a span, captures status code, records metrics with route template labels.

```ruby
require "rack"

module Telemetry
  class Middleware
    HTTP_SERVER_REQUEST_COUNT    = "http.server.request.count"
    HTTP_SERVER_REQUEST_DURATION = "http.server.request.duration"
    HTTP_SERVER_ACTIVE_REQUESTS  = "http.server.active_requests"

    # env key Rails sets after routing (Rails 7.1+)
    ROUTE_PATTERN_KEY = "action_dispatch.route_uri_pattern"

    def initialize(app, tracer, meter)
      @app    = app
      @tracer = tracer

      # Instruments created once; nil-safe if meter is nil (metrics disabled)
      if meter
        @request_count    = meter.create_counter(HTTP_SERVER_REQUEST_COUNT,
                              unit: "{request}", description: "Total HTTP server requests")
        @request_duration = meter.create_histogram(HTTP_SERVER_REQUEST_DURATION,
                              unit: "s", description: "HTTP server request duration")
        @active_requests  = meter.create_up_down_counter(HTTP_SERVER_ACTIVE_REQUESTS,
                              unit: "{request}", description: "Active HTTP server requests")
      end
    end

    def call(env)
      # Extract W3C trace context from incoming headers
      context = OpenTelemetry.propagation.extract(env, getter: OpenTelemetry::Common::HTTP::HeaderExtractor)
      request = Rack::Request.new(env)

      span_name = "#{request.request_method} #{request.path}"

      OpenTelemetry::Context.with_current(context) do
        @tracer.in_span(span_name, kind: :server) do |span|
          @active_requests&.add(1, method: request.request_method)
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          status, headers, body = @app.call(env)

          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          route    = env[ROUTE_PATTERN_KEY] || request.path

          # Rename span to use route template (low-cardinality)
          span.name = "#{request.request_method} #{route}"

          # Span status: only 5xx counts as error
          if status >= 500
            span.status = OpenTelemetry::Trace::Status.error("HTTP #{status}")
          end

          span.set_attribute("http.request.method",     request.request_method)
          span.set_attribute("http.route",              route)
          span.set_attribute("http.response.status_code", status)
          span.set_attribute("server.address",          request.host)
          span.set_attribute("server.port",             request.port)

          attrs = { "http.request.method" => request.request_method,
                    "http.route"          => route,
                    "http.response.status_code" => status.to_s }

          @request_count&.add(1, **attrs)
          @request_duration&.record(duration, **attrs)
          @active_requests&.add(-1, method: request.request_method)

          [status, headers, body]
        end
      end
    end
  end
end
```

**Rack header extraction note**: The `OpenTelemetry::Common::HTTP::HeaderExtractor` converts `HTTP_*` Rack env keys into normal header names. This is provided by `opentelemetry-common` (a transitive dependency of `opentelemetry-sdk`). No custom getter needed.

---

### `lib/telemetry/trace_formatter.rb`

A `Logger::Formatter` subclass. When an active span is present, appends `trace_id` and `span_id` as structured fields to every log line.

```ruby
module Telemetry
  class TraceFormatter < ::Logger::Formatter
    FORMAT = "%s, [%s#%d] %5s -- %s: %s%s\n"

    def call(severity, time, progname, msg)
      trace_suffix = build_trace_suffix
      FORMAT % [
        severity[0..0],
        format_datetime(time),
        $$,
        severity,
        progname || "app",
        msg2str(msg),
        trace_suffix
      ]
    end

    private

    def build_trace_suffix
      span = OpenTelemetry::Trace.current_span
      ctx  = span&.context
      return "" unless ctx&.valid?

      " trace_id=#{ctx.hex_trace_id} span_id=#{ctx.hex_span_id}"
    end
  end
end
```

**Usage in Rails initializer**:
```ruby
Rails.logger.formatter = Telemetry::TraceFormatter.new
```

---

### `lib/telemetry.rb`

Top-level module. Public API surface.

```ruby
require "telemetry/version"
require "telemetry/config"
require "telemetry/setup"
require "telemetry/middleware"
require "telemetry/trace_formatter"

module Telemetry
  # Primary entry point.
  #
  # @param config [Telemetry::Config] optional; all fields have defaults
  # @return [Hash] { shutdown: Proc, tracer: OpenTelemetry::Trace::Tracer, meter: OpenTelemetry::Metrics::Meter }
  #
  # @example
  #   result = Telemetry.setup
  #   at_exit { result[:shutdown].call }
  #
  # @example with config
  #   result = Telemetry.setup(
  #     Telemetry::Config.new(service_name: "my-app", endpoint: "http://collector:4318")
  #   )
  def self.setup(config = Config.new)
    Setup.call(config)
  end
end
```

---

### `spec/spec_helper.rb`

```ruby
require "opentelemetry/sdk"
require "opentelemetry-exporter-otlp"
require "telemetry"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # Reset OTel global state between tests
  config.before(:each) do
    OpenTelemetry::SDK.configure
  end
end
```

---

### `spec/telemetry/config_spec.rb`

```ruby
RSpec.describe Telemetry::Config do
  describe "defaults" do
    subject(:config) { described_class.new }

    it "sets service_name from $PROGRAM_NAME" do
      expect(config.service_name).to eq(File.basename($PROGRAM_NAME, ".*"))
    end

    it "defaults log_level to :info" do
      expect(config.log_level).to eq(:info)
    end

    it "leaves endpoint nil so OTEL env vars apply" do
      expect(config.endpoint).to be_nil
    end
  end

  describe "explicit values" do
    subject(:config) do
      described_class.new(
        service_name:      "my-service",
        service_namespace: "my-org",
        service_version:   "1.2.3",
        endpoint:          "http://localhost:4318",
        log_level:         :debug
      )
    end

    it "stores all provided values" do
      expect(config.service_name).to      eq("my-service")
      expect(config.service_namespace).to eq("my-org")
      expect(config.service_version).to   eq("1.2.3")
      expect(config.endpoint).to          eq("http://localhost:4318")
      expect(config.log_level).to         eq(:debug)
    end
  end
end
```

---

### `spec/telemetry/setup_spec.rb`

Uses the in-memory span exporter from `opentelemetry-sdk` — no real collector needed.

```ruby
require "opentelemetry/sdk"

RSpec.describe Telemetry::Setup do
  let(:config) { Telemetry::Config.new(service_name: "test-service") }
  subject(:result) { described_class.call(config) }

  it "returns a shutdown proc" do
    expect(result[:shutdown]).to be_a(Proc)
  end

  it "returns a tracer" do
    expect(result[:tracer]).to respond_to(:in_span)
  end

  it "sets the global tracer provider" do
    result
    expect(OpenTelemetry.tracer_provider).not_to be_a(OpenTelemetry::Internal::ProxyTracerProvider)
  end

  it "sets the W3C composite propagator" do
    result
    expect(OpenTelemetry.propagation).to be_a(OpenTelemetry::Context::Propagation::CompositeTextMapPropagator)
  end

  context "with explicit endpoint" do
    let(:config) { Telemetry::Config.new(service_name: "test-service", endpoint: "http://localhost:4318") }

    it "does not raise during setup (exporter is lazy)" do
      expect { result }.not_to raise_error
    end
  end

  context "when metrics SDK is unavailable" do
    before { allow(Kernel).to receive(:require).and_call_original }

    it "returns nil meter gracefully" do
      allow(Kernel).to receive(:require).with("opentelemetry-metrics-sdk").and_raise(LoadError)
      expect(result[:meter]).to be_nil
    end
  end

  describe "shutdown proc" do
    it "calls shutdown on the tracer provider" do
      tracer_provider = instance_double(OpenTelemetry::SDK::Trace::TracerProvider, shutdown: nil, add_span_processor: nil, tracer: double(in_span: nil))
      allow(OpenTelemetry::SDK::Trace::TracerProvider).to receive(:new).and_return(tracer_provider)
      result[:shutdown].call
      expect(tracer_provider).to have_received(:shutdown)
    end
  end
end
```

---

### `spec/telemetry/middleware_spec.rb`

Uses a fake Rack app and `rack-test`.

```ruby
require "rack/test"
require "opentelemetry/sdk"

RSpec.describe Telemetry::Middleware do
  include Rack::Test::Methods

  # Set up in-memory span exporter
  let(:exporter)  { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:processor) { OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter) }

  let(:tracer_provider) do
    OpenTelemetry::SDK::Trace::TracerProvider.new.tap { |tp| tp.add_span_processor(processor) }
  end
  let(:tracer) { tracer_provider.tracer("test") }
  let(:meter)  { nil } # metrics tested separately

  let(:inner_app) { ->(env) { [200, { "content-type" => "text/plain" }, ["OK"]] } }
  let(:app)       { described_class.new(inner_app, tracer, meter) }

  def finished_spans = exporter.finished_spans

  it "creates a span for each request" do
    get "/users"
    expect(finished_spans.length).to eq(1)
  end

  it "names the span METHOD PATH" do
    get "/users"
    expect(finished_spans.first.name).to eq("GET /users")
  end

  it "uses route template when action_dispatch key is present" do
    inner = ->(env) {
      env["action_dispatch.route_uri_pattern"] = "/users/:id"
      [200, {}, ["OK"]]
    }
    app = described_class.new(inner, tracer, meter)
    get "/users/42", {}, { "action_dispatch.route_uri_pattern" => "/users/:id" }
    expect(finished_spans.first.name).to eq("GET /users/:id")
  end

  it "sets http.response.status_code attribute" do
    get "/users"
    expect(finished_spans.first.attributes["http.response.status_code"]).to eq(200)
  end

  it "does not mark 4xx responses as span errors" do
    inner_404 = ->(env) { [404, {}, ["Not Found"]] }
    app = described_class.new(inner_404, tracer, meter)
    get "/missing"
    expect(finished_spans.first.status.code).not_to eq(OpenTelemetry::Trace::Status::ERROR)
  end

  it "marks 5xx responses as span errors" do
    inner_500 = ->(env) { [500, {}, ["Error"]] }
    app = described_class.new(inner_500, tracer, meter)
    get "/boom"
    expect(finished_spans.first.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  end

  it "propagates W3C traceparent header into span context" do
    traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    get "/users", {}, { "HTTP_TRACEPARENT" => traceparent }
    span = finished_spans.first
    expect(span.hex_trace_id).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
  end
end
```

---

### `spec/telemetry/trace_formatter_spec.rb`

```ruby
require "opentelemetry/sdk"
require "logger"

RSpec.describe Telemetry::TraceFormatter do
  let(:formatter) { described_class.new }

  context "when no span is active" do
    it "formats without trace suffix" do
      output = formatter.call("INFO", Time.now, "app", "hello")
      expect(output).not_to include("trace_id=")
      expect(output).not_to include("span_id=")
    end
  end

  context "when a span is active" do
    let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
    let(:tracer)          { tracer_provider.tracer("test") }

    it "appends trace_id and span_id to the log line" do
      tracer.in_span("test-span") do
        output = formatter.call("INFO", Time.now, "app", "hello")
        expect(output).to match(/trace_id=[0-9a-f]{32}/)
        expect(output).to match(/span_id=[0-9a-f]{16}/)
      end
    end

    it "does not append trace info after the span ends" do
      tracer.in_span("test-span") { } # span finished
      output = formatter.call("INFO", Time.now, "app", "hello")
      expect(output).not_to include("trace_id=")
    end
  end
end
```

---

### `README.md` (key sections)

Documents the intended ergonomics:

```ruby
# In a Rails initializer: config/initializers/telemetry.rb
require "telemetry"

result = Telemetry.setup(
  Telemetry::Config.new(
    service_name:      Rails.application.class.module_parent_name.underscore,
    service_namespace: "bitsmithy",
    service_version:   ENV.fetch("GIT_COMMIT_SHA", "unknown"),
    endpoint:          ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] # or nil for env var auto-detect
  )
)

# Wire up the trace formatter for log-trace correlation
Rails.logger.formatter = Telemetry::TraceFormatter.new

# Register shutdown for graceful flush
at_exit { result[:shutdown].call }

# In config/application.rb — insert middleware
config.middleware.use Telemetry::Middleware,
  result[:tracer],
  result[:meter]
```

---

## Dependencies

| Gem | Version | Why |
|-----|---------|-----|
| `opentelemetry-api` | ~> 1.0 | OTel API interfaces |
| `opentelemetry-sdk` | ~> 1.0 | TracerProvider, BatchSpanProcessor |
| `opentelemetry-exporter-otlp` | ~> 0.28 | OTLP/HTTP trace exporter |
| `opentelemetry-metrics-api` | ~> 0.1 | Metrics API |
| `opentelemetry-metrics-sdk` | ~> 0.1 | MeterProvider, PeriodicMetricReader |
| `opentelemetry-exporter-otlp-metrics` | ~> 0.1 | OTLP/HTTP metric exporter |
| `opentelemetry-semantic_conventions` | ~> 1.0 | Standard attribute name constants |
| `opentelemetry-logs-sdk` | optional | Log signal (loaded if present) |
| `opentelemetry-exporter-otlp-logs` | optional | OTLP/HTTP log exporter (loaded if present) |
| `rack` | ~> 3.0 | dev only; middleware interface |
| `rack-test` | ~> 2.0 | dev only; middleware testing |
| `rspec` | ~> 3.13 | dev only; test framework |

---

## Considerations & Trade-offs

**Why `rescue LoadError` for metrics instead of `Gem::Specification.find_by_name`?**
`rescue LoadError` is the idiomatic Ruby pattern and works correctly in all load paths (Bundler, manual `require`, eager loading). `find_by_name` raises `Gem::MissingSpecError` if the gem isn't in the lockfile, which is an unexpected exception surface. `LoadError` is the right level of abstraction.

**Why `Logger::Formatter` subclass instead of a module mixin or standalone proc?**
Subclassing gives access to `msg2str` and `format_datetime` helpers from the stdlib formatter, preserving all existing formatting behavior while adding trace fields. A proc would need to reimplement those. The subclass is also easily replaceable — callers assign it to `logger.formatter`.

**Why not `TaggedLogging`?**
`ActiveSupport::TaggedLogging` prepends tags but requires calling `.tagged(...)` at the call site. `TraceFormatter` is transparent — it enriches every log line automatically with zero call-site changes.

**Why declare metrics gems as hard dependencies if they're `rescue LoadError`?**
The gemspec declares them to ensure they're installed by default for the best out-of-the-box experience. Users who want to exclude metrics can use Bundler's `without` group or override manually. The `rescue LoadError` is a graceful degradation path for constrained environments, not the expected default.

**Why not scope log signal behind a feature flag config option?**
Simpler: just don't install the optional gems. No config knob needed. The `rescue LoadError` path is silent for logs (no warning) because it's truly optional — unlike metrics, which we warn about since they're declared as dependencies.

**Middleware positioning**: We recommend inserting `Telemetry::Middleware` near the top of the stack (in `config/application.rb` via `config.middleware.use`) so the span covers the full request including other middleware latency. But it's fully valid to insert it anywhere.

---

## Testing Strategy

All tests use `opentelemetry-sdk`'s built-in `InMemorySpanExporter` — no running collector or network required.

### Test cases

**`spec/telemetry/config_spec.rb`**
1. `defaults` — `service_name` comes from `$PROGRAM_NAME`, `endpoint` is nil, `log_level` is `:info`
2. `explicit values` — all keyword args stored correctly

**`spec/telemetry/setup_spec.rb`**
3. Returns a `Proc` for `:shutdown`
4. Returns a tracer responding to `#in_span`
5. Sets `OpenTelemetry.tracer_provider` to a real SDK provider (not the no-op proxy)
6. Sets `OpenTelemetry.propagation` to a `CompositeTextMapPropagator`
7. Does not raise with an explicit `endpoint:` (exporter connects lazily)
8. Returns `nil` for `:meter` when metrics SDK is unavailable (`LoadError`)
9. Shutdown proc calls `#shutdown` on the tracer provider

**`spec/telemetry/middleware_spec.rb`**
10. Creates exactly one span per request
11. Names span `"METHOD /path"` using raw path initially, updates to route template
12. Uses `action_dispatch.route_uri_pattern` when available (Rails route template)
13. Records `http.response.status_code` as a span attribute
14. Does NOT set error status for 4xx responses
15. Sets error status (`Status::ERROR`) for 5xx responses
16. Propagates incoming W3C `traceparent` header into the span's trace ID

**`spec/telemetry/trace_formatter_spec.rb`**
17. No active span → output does not include `trace_id=` or `span_id=`
18. Active span → output includes `trace_id=<32-hex-chars>`
19. Active span → output includes `span_id=<16-hex-chars>`
20. After span ends → output does not include trace fields

---

## Todo List

### Phase 1: Gem scaffold
- [ ] Create the `otel-rb/` directory and initialize a git repo
- [ ] Write `otel-rb.gemspec` with all dependencies as specified (including `logger` for Ruby 4.0+)
- [ ] Write `Gemfile` (sources gemspec, adds dev dependencies)
- [ ] Write `.rspec` (`--require spec_helper --format documentation`)
- [ ] Write `lib/telemetry/version.rb` (`VERSION = "0.1.0"`)

### Phase 2: Core library
- [ ] Write `lib/telemetry/config.rb` — `Config` value object with all keyword args and defaults
- [ ] Write `lib/telemetry/setup.rb` — `Setup.call(config)` wiring traces, metrics, logs, propagator
- [ ] Write `lib/telemetry/middleware.rb` — Rack middleware with pre-registered metric instruments
- [ ] Write `lib/telemetry/trace_formatter.rb` — `Logger::Formatter` subclass with trace suffix
- [ ] Write `lib/telemetry.rb` — top-level module requiring all files, exposing `Telemetry.setup`

### Phase 3: Tests — Config
- [ ] Write `spec/spec_helper.rb` with OTel SDK reset in `before(:each)`
- [ ] Write `spec/telemetry/config_spec.rb` — test case 1: defaults (`service_name`, `endpoint`, `log_level`)
- [ ] Write `spec/telemetry/config_spec.rb` — test case 2: explicit keyword args stored correctly

### Phase 4: Tests — Setup
- [ ] Write `spec/telemetry/setup_spec.rb` — test case 3: returns `Proc` for `:shutdown`
- [ ] Write `spec/telemetry/setup_spec.rb` — test case 4: returns tracer responding to `#in_span`
- [ ] Write `spec/telemetry/setup_spec.rb` — test case 5: sets global tracer provider (not proxy)
- [ ] Write `spec/telemetry/setup_spec.rb` — test case 6: sets `CompositeTextMapPropagator`
- [ ] Write `spec/telemetry/setup_spec.rb` — test case 7: no raise with explicit `endpoint:`
- [ ] Write `spec/telemetry/setup_spec.rb` — test case 8: nil meter when metrics SDK unavailable
- [ ] Write `spec/telemetry/setup_spec.rb` — test case 9: shutdown proc calls `#shutdown` on provider

### Phase 5: Tests — Middleware
- [ ] Write `spec/telemetry/middleware_spec.rb` — test case 10: one span created per request
- [ ] Write `spec/telemetry/middleware_spec.rb` — test case 11: span named `"METHOD /path"`
- [ ] Write `spec/telemetry/middleware_spec.rb` — test case 12: uses `action_dispatch.route_uri_pattern` for span name
- [ ] Write `spec/telemetry/middleware_spec.rb` — test case 13: `http.response.status_code` attribute set
- [ ] Write `spec/telemetry/middleware_spec.rb` — test case 14: 4xx does NOT set error status
- [ ] Write `spec/telemetry/middleware_spec.rb` — test case 15: 5xx sets `Status::ERROR`
- [ ] Write `spec/telemetry/middleware_spec.rb` — test case 16: W3C `traceparent` propagated into span trace ID

### Phase 6: Tests — TraceFormatter
- [ ] Write `spec/telemetry/trace_formatter_spec.rb` — test case 17: no span → no `trace_id=` in output
- [ ] Write `spec/telemetry/trace_formatter_spec.rb` — test case 18: active span → `trace_id=<32-hex>`
- [ ] Write `spec/telemetry/trace_formatter_spec.rb` — test case 19: active span → `span_id=<16-hex>`
- [ ] Write `spec/telemetry/trace_formatter_spec.rb` — test case 20: after span ends → no trace fields

### Phase 7: Run tests and fix
- [ ] Run `bundle install` in the gem directory
- [ ] Run `bundle exec rspec` and confirm all 20 tests pass
- [ ] Fix any failures (API mismatches, constant names, require paths)

### Phase 8: Polish
- [ ] Write `README.md` with install instructions, Rails initializer example, middleware registration example
- [ ] Run `bundle exec rubocop --autocorrect` and fix any remaining offences
- [ ] Verify `gem build otel-rb.gemspec` succeeds without warnings
