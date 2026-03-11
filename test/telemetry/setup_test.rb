# frozen_string_literal: true

require 'test_helper'
require 'active_support/logger'

class SetupTest < Minitest::Test
  # --- Telemetry.setup (module-level) ---

  def test_setup_accepts_keyword_args
    assert_nil Telemetry.setup(service_name: 'test-service')
  end

  def test_setup_returns_nil
    assert_nil Telemetry.setup(service_name: 'test-service')
  end

  def test_tracer_assigned_after_setup
    Telemetry.setup(service_name: 'test-service')
    assert_respond_to Telemetry.tracer, :in_span
  end

  def test_meter_available_after_setup
    Telemetry.setup(service_name: 'test-service')
    refute_nil Telemetry.meter
  end

  def test_counter_handle_available_after_setup
    Telemetry.setup(service_name: 'test-service')
    refute_nil Telemetry.counter('test.counter')
  end

  def test_logger_available_after_setup
    Telemetry.setup(service_name: 'test-service')
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
    middleware_stack = Object.new
    middleware_stack.define_singleton_method(:use) { |*args| inserted_args = args }

    app_config = Object.new
    app_config.define_singleton_method(:middleware) { middleware_stack }
    rails_app = Object.new
    rails_app.define_singleton_method(:config) { app_config }

    rails_logger = Object.new
    rails_logger.define_singleton_method(:formatter)  { nil }
    rails_logger.define_singleton_method(:formatter=) { |_f| nil }

    fake_rails = Module.new do
      def self.application; end

      def self.logger; end
    end

    stub_const(:Rails, fake_rails) do
      fake_rails.stub(:application, rails_app) do
        fake_rails.stub(:logger, rails_logger) do
          # integrate_tracing_logger defaults to false — middleware still inserted
          Telemetry.setup(service_name: 'test-service')
        end
      end
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

    with_fake_rails(logger: rails_logger) do
      Telemetry.setup(service_name: 'test-service', integrate_tracing_logger: true)
    end

    assert_instance_of Telemetry::TraceFormatter, assigned_formatter
  end

  # --- test_mode! formatter warning ---

  def test_test_mode_skips_simple_formatter_replacement
    assigned_formatter = :not_called
    rails_logger = fake_rails_logger(formatter: ActiveSupport::Logger::SimpleFormatter.new)
    rails_logger.define_singleton_method(:formatter=) { |f| assigned_formatter = f }

    with_fake_rails(logger: rails_logger) do
      Telemetry.setup(service_name: 'test-service', integrate_tracing_logger: true)
    end

    assert_equal :not_called, assigned_formatter
  end

  def test_test_mode_still_warns_and_replaces_non_simple_formatter
    warnings = capture_warnings do
      with_fake_rails(formatter: ::Logger::Formatter.new) do
        Telemetry.setup(service_name: 'test-service', integrate_tracing_logger: true)
      end
    end

    assert_equal 1, warnings.size
    assert_match(/replacing existing logger formatter/, warnings.first)
  end

  def test_test_mode_replace_simple_formatter_opt_in
    assigned_formatter = nil
    rails_logger = fake_rails_logger(formatter: ActiveSupport::Logger::SimpleFormatter.new)
    rails_logger.define_singleton_method(:formatter=) { |f| assigned_formatter = f }

    Telemetry.replace_simple_formatter = true

    with_fake_rails(logger: rails_logger) do
      Telemetry.setup(service_name: 'test-service', integrate_tracing_logger: true)
    end

    assert_instance_of Telemetry::TraceFormatter, assigned_formatter
  ensure
    Telemetry.replace_simple_formatter = false
  end

  # --- test_mode! auto-setup ---

  def test_before_setup_re_runs_setup_automatically
    # before_setup (from test_mode!) already ran for this test, resetting state.
    # Telemetry should be usable without the consumer calling setup in each test.
    assert_respond_to Telemetry.tracer, :in_span
    refute_nil Telemetry.meter
    assert_instance_of Telemetry::Logger, Telemetry.logger
  end

  # --- test_mode! env vars ---

  def test_test_mode_sets_exporter_env_vars_to_none
    %w[OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER].each do |var|
      assert_equal 'none', ENV.fetch(var, nil), "Expected #{var} to be 'none' in test mode"
    end
  end

  # --- Telemetry::Setup internal contract ---

  def test_setup_module_returns_tracer_and_shutdown
    config = Telemetry::Config.new(service_name: 'test-service')
    result = Telemetry::Setup.call(config)
    assert_respond_to result[:tracer], :in_span
    assert_kind_of Proc, result[:shutdown]
  end

  # --- LogBridge installation ---

  def test_bridge_installed_when_integrate_tracing_logger_true
    require 'telemetry/log_bridge'
    rails_logger = ::Logger.new(StringIO.new)

    with_fake_rails(logger: rails_logger) do
      Telemetry.setup(service_name: 'test-service', integrate_tracing_logger: true)
    end

    assert_includes rails_logger.singleton_class.ancestors, Telemetry::LogBridge
  end

  def test_bridge_not_installed_by_default
    require 'telemetry/log_bridge'
    rails_logger = ::Logger.new(StringIO.new)

    with_fake_rails(logger: rails_logger) do
      Telemetry.setup(service_name: 'test-service')
    end

    refute_includes rails_logger.singleton_class.ancestors, Telemetry::LogBridge
  end

  def test_bridge_skipped_in_test_mode_with_simple_formatter
    require 'telemetry/log_bridge'
    rails_logger = ::Logger.new(StringIO.new)
    rails_logger.formatter = ActiveSupport::Logger::SimpleFormatter.new

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

  def with_fake_rails(formatter: nil, logger: nil, &block)
    middleware_stack = Object.new
    middleware_stack.define_singleton_method(:use) { |*_args| nil }

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

  def capture_warnings(&)
    warnings = []
    Telemetry.stub(:warn, ->(msg) { warnings << msg }, &)
    warnings
  end
end
