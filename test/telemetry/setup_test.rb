# frozen_string_literal: true

require 'test_helper'
require 'active_support/logger'

class SetupTest < Minitest::Test
  # --- Telemetry.setup (module-level) ---

  def test_setup_returns_nil
    assert_nil Telemetry.setup(service_name: 'test-service')
  end

  def test_tracer_assigned_after_setup
    assert_respond_to Telemetry.tracer, :in_span
  end

  def test_meter_available_after_setup
    refute_nil Telemetry.meter
  end

  def test_counter_handle_available_after_setup
    refute_nil Telemetry.counter('test.counter')
  end

  def test_logger_available_after_setup
    assert_instance_of Telemetry::Logger, Telemetry.logger
  end

  # --- NotSetupError before setup ---

  def test_not_setup_error_trace
    Telemetry.reset!
    assert_raises(Telemetry::NotSetupError) { Telemetry.trace('op') { nil } }
  end

  def test_not_setup_error_counter
    Telemetry.reset!
    assert_raises(Telemetry::NotSetupError) { Telemetry.counter('x') }
  end

  def test_not_setup_error_logger
    Telemetry.reset!
    assert_raises(Telemetry::NotSetupError) { Telemetry.logger }
  end

  def test_not_setup_error_log
    Telemetry.reset!
    assert_raises(Telemetry::NotSetupError) { Telemetry.log(:info, 'msg') }
  end

  # --- Rails wiring ---
  # Middleware is always inserted when Rails is detected, regardless of
  # integrate_tracing_logger.

  def test_middleware_always_inserted_in_rails
    inserted_args = nil

    # integrate_tracing_logger defaults to false — middleware still inserted
    with_fake_rails(on_middleware_use: ->(args) { inserted_args = args }) do
      Telemetry.setup(service_name: 'test-service')
    end

    assert_equal [Telemetry::Middleware], inserted_args
  end

  def test_trace_formatter_not_assigned_by_default
    assigned_formatter = :not_called
    rails_logger = fake_rails_logger(formatter: nil)
    rails_logger.define_singleton_method(:formatter=) { |f| assigned_formatter = f }

    with_fake_rails(logger: rails_logger) do
      Telemetry.setup(service_name: 'test-service')
    end

    assert_equal :not_called, assigned_formatter
  end

  def test_trace_formatter_assigned_when_integrate_tracing_logger_true
    assigned_formatter = nil
    rails_logger = fake_rails_logger(formatter: nil)
    rails_logger.define_singleton_method(:formatter=) { |f| assigned_formatter = f }

    # Call wire_tracing_logger directly because setup skips it in test mode.
    Telemetry.setup(service_name: 'test-service')
    with_fake_rails(logger: rails_logger) do
      Telemetry.send(:wire_tracing_logger)
    end

    assert_instance_of Telemetry::TraceFormatter, assigned_formatter
  end

  # --- test_mode! skips tracing logger ---

  def test_test_mode_skips_tracing_logger
    assigned_formatter = :not_called
    rails_logger = fake_rails_logger(formatter: ::Logger::Formatter.new)
    rails_logger.define_singleton_method(:formatter=) { |f| assigned_formatter = f }

    with_fake_rails(logger: rails_logger) do
      Telemetry.setup(service_name: 'test-service', integrate_tracing_logger: true)
    end

    assert_equal :not_called, assigned_formatter
  end

  # --- test_mode! auto-setup ---

  def test_auto_setup_provides_tracer
    assert_respond_to Telemetry.tracer, :in_span
  end

  def test_auto_setup_provides_meter
    refute_nil Telemetry.meter
  end

  def test_auto_setup_provides_logger
    assert_instance_of Telemetry::Logger, Telemetry.logger
  end

  # --- test_mode! env vars ---

  def test_test_mode_sets_exporter_env_vars_to_none
    %w[OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER].each do |var|
      assert_equal 'none', ENV.fetch(var, nil), "Expected #{var} to be 'none' in test mode"
    end
  end

  # --- OTLP headers from env ---

  def test_exporter_picks_up_otlp_headers_from_env
    ENV['OTEL_EXPORTER_OTLP_HEADERS'] = 'Authorization=Bearer%20test-token,X-Org-Id=42'

    exporter = OpenTelemetry::Exporter::OTLP::Exporter.new
    headers = exporter.instance_variable_get(:@headers)

    assert_equal 'Bearer test-token', headers['Authorization']
    assert_equal '42', headers['X-Org-Id']
  ensure
    ENV.delete('OTEL_EXPORTER_OTLP_HEADERS')
  end

  def test_exporter_picks_up_headers_even_with_explicit_endpoint
    ENV['OTEL_EXPORTER_OTLP_HEADERS'] = 'Authorization=Bearer%20test-token'

    exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(endpoint: 'http://localhost:4318')
    headers = exporter.instance_variable_get(:@headers)

    assert_equal 'Bearer test-token', headers['Authorization']
  ensure
    ENV.delete('OTEL_EXPORTER_OTLP_HEADERS')
  end

  # --- Telemetry::Setup internal contract ---

  def test_setup_module_returns_tracer
    config = Telemetry::Config.new(service_name: 'test-service')
    result = Telemetry::Setup.call(config)
    assert_respond_to result[:tracer], :in_span
  end

  def test_setup_module_returns_shutdown_proc
    config = Telemetry::Config.new(service_name: 'test-service')
    result = Telemetry::Setup.call(config)
    assert_kind_of Proc, result[:shutdown]
  end

  # --- LogBridge installation ---

  def test_bridge_installed_when_integrate_tracing_logger_true
    require 'telemetry/log_bridge'
    rails_logger = ::Logger.new(StringIO.new)

    # Call wire_tracing_logger directly because setup skips it in test mode.
    Telemetry.setup(service_name: 'test-service')
    with_fake_rails(logger: rails_logger) do
      Telemetry.send(:wire_tracing_logger)
    end

    assert_includes rails_logger.singleton_class.ancestors, Telemetry::LogBridge
  end

  def test_wire_tracing_logger_with_broadcast_logger
    require 'active_support'
    require 'active_support/broadcast_logger'
    require 'telemetry/log_bridge'

    inner = ::Logger.new(StringIO.new)
    broadcast = ActiveSupport::BroadcastLogger.new(inner)
    # Rails sets a formatter in production; we need one here so the
    # wire_tracing_logger code path that replaces the formatter is exercised.
    broadcast.formatter = ::Logger::Formatter.new

    Telemetry.setup(service_name: 'test-service')
    with_fake_rails(logger: broadcast) do
      Telemetry.send(:wire_tracing_logger)
    end

    assert_includes inner.singleton_class.ancestors, Telemetry::LogBridge
  end

  def test_bridge_not_installed_by_default
    require 'telemetry/log_bridge'
    rails_logger = ::Logger.new(StringIO.new)

    with_fake_rails(logger: rails_logger) do
      Telemetry.setup(service_name: 'test-service')
    end

    refute_includes rails_logger.singleton_class.ancestors, Telemetry::LogBridge
  end

  def test_bridge_skipped_in_test_mode
    require 'telemetry/log_bridge'
    rails_logger = ::Logger.new(StringIO.new)

    with_fake_rails(logger: rails_logger) do
      Telemetry.setup(service_name: 'test-service', integrate_tracing_logger: true)
    end

    refute_includes rails_logger.singleton_class.ancestors, Telemetry::LogBridge
  end

  private

  def fake_rails_logger(formatter:)
    logger = Object.new
    logger.define_singleton_method(:formatter)  { formatter }
    logger.define_singleton_method(:formatter=) { |_f| nil }
    logger
  end

  def with_fake_rails(formatter: nil, logger: nil, on_middleware_use: nil, &block)
    middleware_stack = Object.new
    middleware_stack.define_singleton_method(:use) { |*args| on_middleware_use&.call(args) }

    app_config = Object.new
    app_config.define_singleton_method(:middleware) { middleware_stack }
    rails_app = Object.new
    rails_app.define_singleton_method(:config) { app_config }

    rails_logger = logger || fake_rails_logger(formatter: formatter)

    fake_rails = Module.new do
      def self.application; end

      def self.logger; end
    end

    stub_const(:Rails, fake_rails) do
      fake_rails.stub(:application, rails_app) do
        fake_rails.stub(:logger, rails_logger, &block)
      end
    end
  end
end
