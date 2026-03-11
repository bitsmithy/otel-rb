# frozen_string_literal: true

require 'test_helper'

class LoggerTest < Minitest::Test
  # --- Telemetry.logger ---

  def test_logger_returns_logger_instance
    assert_instance_of Telemetry::Logger, Telemetry.logger
  end

  def test_not_setup_error
    Telemetry.reset!
    assert_raises(Telemetry::NotSetupError) { Telemetry.logger }
  end

  # --- Telemetry.log ---

  def test_log_not_setup_error
    Telemetry.reset!
    assert_raises(Telemetry::NotSetupError) { Telemetry.log(:info, 'msg') }
  end

  def test_log_delegates_to_logger
    calls = []
    Telemetry.logger.stub(:info, ->(msg, **_kw) { calls << msg }) do
      Telemetry.log(:info, 'hello')
    end
    assert_equal ['hello'], calls
  end

  def test_log_levels
    %i[debug info warn error fatal].each do |level|
      assert_silent { Telemetry.log(level, "test #{level}") }
    end
  end

  # --- OTel emit works (SDK is a hard dependency) ---

  def test_otel_emit_does_not_warn
    _out, err = capture_io { Telemetry.log(:info, 'hello') }
    assert_empty err
  end

  # --- rails_logger: delegation ---

  def test_rails_logger_delegation
    with_fake_rails_logger(:info) do |received|
      Telemetry.log(:info, 'from rails')
      assert_equal ['from rails'], received
    end
  end

  def test_logger_instance_with_rails_logger_true
    with_fake_rails_logger(:warn) do |received|
      Telemetry.logger.warn('Low balance', rails_logger: true)
      assert_equal ['Low balance'], received
    end
  end

  def test_rails_logger_opt_out
    with_fake_rails_logger(:info) do |received|
      Telemetry.log(:info, 'silent', rails_logger: false)
      assert_empty received
    end
  end

  # --- Bridge deduplication ---

  def test_telemetry_log_does_not_double_emit_with_bridge
    require 'telemetry/log_bridge'

    bridge_emissions = []
    mock_otel_logger = Object.new
    mock_otel_logger.define_singleton_method(:on_emit) { |**kwargs| bridge_emissions << kwargs }

    fake_rails_logger = ::Logger.new(StringIO.new)
    fake_rails_logger.singleton_class.prepend(Telemetry::LogBridge)
    fake_rails_logger.instance_variable_set(:@telemetry_bridge_logger, mock_otel_logger)

    fake_rails = Module.new { def self.logger; end }

    stub_const(:Rails, fake_rails) do
      fake_rails.stub(:logger, fake_rails_logger) do
        Telemetry.log(:info, 'msg')
      end
    end

    assert_empty bridge_emissions, 'LogBridge must not re-emit to OTel when Telemetry.log mirrors to Rails.logger'
  end

  def test_emit_restores_prior_skip_flag_value
    require 'telemetry/log_bridge'

    fake_rails_logger = ::Logger.new(StringIO.new)
    fake_rails_logger.singleton_class.prepend(Telemetry::LogBridge)
    fake_rails_logger.instance_variable_set(:@telemetry_bridge_logger,
                                            Object.new.tap { |m| m.define_singleton_method(:on_emit) { |**_| nil } })

    flag_after_inner_call = :not_set
    fake_rails = Module.new { def self.logger; end }

    Thread.current[Telemetry::Logger::SKIP_OTEL_BRIDGE_KEY] = true
    stub_const(:Rails, fake_rails) do
      fake_rails.stub(:logger, fake_rails_logger) do
        Telemetry.log(:info, 'msg')
      end
    end
    flag_after_inner_call = Thread.current[Telemetry::Logger::SKIP_OTEL_BRIDGE_KEY]
  ensure
    Thread.current[Telemetry::Logger::SKIP_OTEL_BRIDGE_KEY] = nil
    assert flag_after_inner_call, 'emit must restore the pre-existing true flag value, not reset it to false'
  end

  private

  def with_fake_rails_logger(level)
    received = []
    fake_rails_logger = Object.new
    fake_rails_logger.define_singleton_method(level) { |msg| received << msg }

    fake_rails = Module.new { def self.logger; end }

    stub_const(:Rails, fake_rails) do
      fake_rails.stub(:logger, fake_rails_logger) do
        yield received
      end
    end
  end
end
