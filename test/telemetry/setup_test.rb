# frozen_string_literal: true

require 'test_helper'

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
    assert_raises(Telemetry::NotSetupError) { Telemetry.trace('op') {} }
  end

  def test_not_setup_error_counter
    assert_raises(Telemetry::NotSetupError) { Telemetry.counter('x') }
  end

  def test_not_setup_error_logger
    assert_raises(Telemetry::NotSetupError) { Telemetry.logger }
  end

  def test_not_setup_error_log
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
    rails_app  = Object.new
    rails_app.define_singleton_method(:config) { app_config }

    rails_logger = Object.new
    rails_logger.define_singleton_method(:formatter)  { nil }
    rails_logger.define_singleton_method(:formatter=) { |_f| }

    fake_rails = Module.new { def self.application; end; def self.logger; end }

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
    middleware_stack = Object.new
    middleware_stack.define_singleton_method(:use) { |*_args| }

    app_config = Object.new
    app_config.define_singleton_method(:middleware) { middleware_stack }
    rails_app  = Object.new
    rails_app.define_singleton_method(:config) { app_config }

    rails_logger = Object.new
    rails_logger.define_singleton_method(:formatter)  { nil }
    rails_logger.define_singleton_method(:formatter=) { |f| assigned_formatter = f }

    fake_rails = Module.new { def self.application; end; def self.logger; end }

    stub_const(:Rails, fake_rails) do
      fake_rails.stub(:application, rails_app) do
        fake_rails.stub(:logger, rails_logger) do
          Telemetry.setup(service_name: 'test-service')
        end
      end
    end

    assert_equal :not_called, assigned_formatter
  end

  def test_trace_formatter_assigned_when_integrate_tracing_logger_true
    assigned_formatter = nil
    middleware_stack = Object.new
    middleware_stack.define_singleton_method(:use) { |*_args| }

    app_config = Object.new
    app_config.define_singleton_method(:middleware) { middleware_stack }
    rails_app  = Object.new
    rails_app.define_singleton_method(:config) { app_config }

    rails_logger = Object.new
    rails_logger.define_singleton_method(:formatter)  { nil }
    rails_logger.define_singleton_method(:formatter=) { |f| assigned_formatter = f }

    fake_rails = Module.new { def self.application; end; def self.logger; end }

    stub_const(:Rails, fake_rails) do
      fake_rails.stub(:application, rails_app) do
        fake_rails.stub(:logger, rails_logger) do
          Telemetry.setup(service_name: 'test-service', integrate_tracing_logger: true)
        end
      end
    end

    assert_instance_of Telemetry::TraceFormatter, assigned_formatter
  end

  # --- Telemetry::Setup internal contract ---

  def test_setup_module_returns_tracer_and_shutdown
    config = Telemetry::Config.new(service_name: 'test-service')
    result = Telemetry::Setup.call(config)
    assert_respond_to result[:tracer], :in_span
    assert_kind_of Proc, result[:shutdown]
  end

end
