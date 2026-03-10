# frozen_string_literal: true

require 'telemetry/version'
require 'telemetry/config'
require 'telemetry/setup'
require 'telemetry/middleware'
require 'telemetry/trace_formatter'
require 'telemetry/logger'
require 'telemetry/instruments'
require 'telemetry/metering'

# Telemetry — thin, opinionated OpenTelemetry setup for Ruby/Rails.
#
# One call wires traces, metrics, and (optionally) logs over OTLP/HTTP.
# Auto-detects Rails and inserts Rack middleware + at_exit flush. Pass
# integrate_tracing_logger: true to also assign TraceFormatter to Rails.logger.
#
# @example Rails initializer (config/initializers/telemetry.rb)
#   Telemetry.setup(
#     service_name:              Rails.application.class.module_parent_name.underscore,
#     service_namespace:         "my-org",
#     service_version:           ENV.fetch("GIT_COMMIT_SHA", "unknown"),
#     integrate_tracing_logger:  true
#   )
#
# @example Tracing a block
#   Telemetry.trace("orders.process", attrs: { "order.id" => order.id }) do |span|
#     span.set_attribute("order.item_count", items.size)
#   end
#
# @example Timing a block (records duration as a histogram)
#   Telemetry.time("orders.charge_duration") { charge(order) }
#
# @example Metrics — get a reusable handle
#   order_counter = Telemetry.counter("orders.placed", unit: "{order}")
#   order_counter.add(1, "payment.method" => "card")
#
# @example Metrics — fire and forget
#   Telemetry.counter("orders.placed", 1, "payment.method" => "card")
#
# @example Metrics — time a block
#   Telemetry.histogram("orders.charge_duration", unit: "s") { charge(order) }
#
# @example Logging
#   Telemetry.log(:info, "Order placed")
module Telemetry
  # Raised when tracing, metering, or logging is attempted before Telemetry.setup.
  class NotSetupError < StandardError
    def initialize(method_name)
      super("Telemetry.#{method_name} called before Telemetry.setup — call Telemetry.setup first")
    end
  end

  class << self
    include Metering

    attr_reader :tracer
    # Returns the raw OpenTelemetry::Meter for this service.
    # Use this when you need instrument types not covered by the helper methods —
    # e.g. observable (async) instruments.
    # @return [OpenTelemetry::Metrics::Meter, nil]
    attr_reader :meter

    # One-call setup. Accepts keyword arguments forwarded to Config.
    #
    # When called inside a Rails app, always:
    #   - Inserts Telemetry::Middleware into the middleware stack
    #   - Registers at_exit to flush pending telemetry on process exit
    #
    # When integrate_tracing_logger: true, also:
    #   - Assigns TraceFormatter to Rails.logger.formatter
    #
    # @param opts [Hash] forwarded to Telemetry::Config
    # @return [nil]
    def setup(**)
      config  = Config.new(**)
      result  = Setup.call(config)
      @tracer               = result[:tracer]
      @meter                = result[:meter]
      @logger               = Logger.new
      @instruments          = nil
      @rails_middleware_wired = nil

      if defined?(Rails)
        wire_rails_middleware
        wire_tracing_logger if config.integrate_tracing_logger
      end

      unless @test_mode
        shutdown = result[:shutdown]
        at_exit { shutdown&.call }
      end

      nil
    end

    # Returns a cached Counter, or records a value immediately.
    #
    # @overload counter(name, unit: nil, description: nil)
    #   Returns the cached instrument handle.
    #   @return [Instruments::Counter]
    # @overload counter(name, value, attrs = {})
    #   Records +value+ immediately and returns nil.
    #   @param value [Numeric]
    #   @param attrs [Hash]
    def counter(name, *rest, **kwargs)
      value, attrs, unit, description = parse_rest(rest, kwargs)
      dispatch(:counter, name, value, attrs, { unit: unit, description: description })
    end

    # Returns a cached Histogram, records a value, or times a block.
    #
    # @overload histogram(name, unit: nil, description: nil)
    #   Returns the cached instrument handle.
    #   @return [Instruments::Histogram]
    # @overload histogram(name, value, attrs = {})
    #   Records +value+ immediately.
    #   @param value [Numeric]
    #   @param attrs [Hash]
    # @overload histogram(name, attrs = {}) { block }
    #   Times the block, records duration in seconds, returns block value.
    #   @param attrs [Hash]
    #   @yieldreturn block's return value (passed through)
    def histogram(name, *rest, **kwargs, &block)
      value, attrs, unit, description = parse_rest(rest, kwargs)
      if block
        raise ArgumentError, 'pass attrs as a Hash, not a Numeric, when timing a block' \
          if value.is_a?(Numeric)

        fetch_instrument(:histogram, name, { unit: unit, description: description })
          .time(value || {}, &block)
      else
        dispatch(:histogram, name, value, attrs, { unit: unit, description: description })
      end
    end

    # Returns a cached Gauge, or records a value immediately.
    #
    # @overload gauge(name, unit: nil, description: nil)
    #   Returns the cached instrument handle.
    #   @return [Instruments::Gauge]
    # @overload gauge(name, value, attrs = {})
    #   Records +value+ immediately.
    #   @param value [Numeric]
    #   @param attrs [Hash]
    def gauge(name, *rest, **kwargs)
      value, attrs, unit, description = parse_rest(rest, kwargs)
      dispatch(:gauge, name, value, attrs, { unit: unit, description: description })
    end

    # Returns a cached UpDownCounter, or records a value immediately.
    #
    # @overload up_down_counter(name, unit: nil, description: nil)
    #   Returns the cached instrument handle.
    #   @return [Instruments::UpDownCounter]
    # @overload up_down_counter(name, value, attrs = {})
    #   Records +value+ immediately.
    #   @param value [Numeric]
    #   @param attrs [Hash]
    def up_down_counter(name, *rest, **kwargs)
      value, attrs, unit, description = parse_rest(rest, kwargs)
      dispatch(:up_down_counter, name, value, attrs, { unit: unit, description: description })
    end

    # Times a block and records wall-clock duration (seconds) as a histogram.
    # Shorthand for: Telemetry.histogram(name, attrs) { block }
    # Always uses unit: "s".
    #
    # @param name [String] histogram instrument name
    # @param attrs [Hash] metric attributes
    # @yieldreturn the block's return value (passed through)
    def time(name, attrs = {}, &)
      histogram(name, attrs, unit: 's', &)
    end

    # Wraps a block in an OTel span. Nested calls automatically create child
    # spans under the current span (including the Rack middleware's request span).
    #
    # @param name [String] span name
    # @param attrs [Hash] initial span attributes
    # @yieldparam span [OpenTelemetry::Trace::Span]
    def trace(name, attrs: {}, &)
      raise NotSetupError, :trace unless @tracer

      @tracer.in_span(name, attributes: attrs, &)
    end

    # Delegates to Telemetry.logger.<level>.
    #
    # @param level [Symbol] :debug, :info, :warn, :error, or :fatal
    # @param message [String]
    # @param kwargs [Hash] forwarded to the logger (e.g. rails_logger: false)
    def log(level, message, **)
      logger.public_send(level, message, **)
    end

    # OTel log emitter.
    # @return [Telemetry::Logger]
    def logger
      raise NotSetupError, :logger unless @logger

      @logger
    end

    # Enables test mode for the entire process:
    #   1. Suppresses at_exit registration.
    #   2. Suppresses OTLP exporters via OTEL_*_EXPORTER env vars.
    #   3. Installs a Minitest before_setup hook that resets OTel and
    #      re-runs Telemetry.setup before each test.
    #   4. Defines Telemetry.reset! for tests that verify not-setup behavior.
    # Auto-activated via require "telemetry/test" in test_helper.rb.
    # @api private
    def test_mode!
      return if @test_mode

      @test_mode = true

      %w[OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER].each do |var|
        ENV[var] ||= 'none'
      end

      define_singleton_method(:reset!) do
        @tracer               = nil
        @meter                = nil
        @logger               = nil
        @shutdown             = nil
        @instruments          = nil
        @rails_middleware_wired = nil
      end

      Minitest::Test.prepend(Module.new do
        def before_setup
          OpenTelemetry::SDK.configure
          Telemetry.setup
          super
        end
      end)
    end

    private

    def wire_rails_middleware
      return if @rails_middleware_wired

      Rails.application.config.middleware.use(Middleware)
      @rails_middleware_wired = true
    end

    def wire_tracing_logger
      existing = Rails.logger.formatter
      if existing && !existing.is_a?(TraceFormatter)
        warn '[Telemetry] replacing existing logger formatter ' \
             "(#{existing.class}) with Telemetry::TraceFormatter"
      end
      Rails.logger.formatter = TraceFormatter.new
    end
  end
end
