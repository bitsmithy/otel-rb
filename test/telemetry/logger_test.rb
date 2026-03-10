# frozen_string_literal: true

require 'test_helper'

class LoggerTest < Minitest::Test
  def setup
    Telemetry.setup(service_name: 'test-service')
    # Exhaust the one-time "OTel Logs SDK not available" warning so individual
    # tests don't observe unexpected stderr output.
    capture_io { Telemetry.log(:info, 'warmup') }
  end

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

  # --- OTel Logs SDK missing (always the case in this test bundle) ---

  def test_otel_missing_warn_emitted_once
    # Fresh logger instance so @otel_warned starts false
    Telemetry.reset!
    Telemetry.setup(service_name: 'test-service')

    _out, err = capture_io { Telemetry.log(:info, 'first') }
    assert_match(/OTel Logs SDK not available/, err)

    # Second call must not warn again
    _out2, err2 = capture_io { Telemetry.log(:info, 'second') }
    assert_empty err2
  end

  # --- rails_logger: delegation ---

  def test_rails_logger_delegation
    received = []
    fake_rails_logger = Object.new
    fake_rails_logger.define_singleton_method(:info) { |msg| received << msg }

    fake_rails = Module.new { def self.logger; end }

    stub_const(:Rails, fake_rails) do
      fake_rails.stub(:logger, fake_rails_logger) do
        Telemetry.log(:info, 'from rails')
      end
    end

    assert_equal ['from rails'], received
  end

  def test_logger_instance_with_rails_logger_true
    received = []
    fake_rails_logger = Object.new
    fake_rails_logger.define_singleton_method(:warn) { |msg| received << msg }

    fake_rails = Module.new { def self.logger; end }

    stub_const(:Rails, fake_rails) do
      fake_rails.stub(:logger, fake_rails_logger) do
        Telemetry.logger.warn('Low balance', rails_logger: true)
      end
    end

    assert_equal ['Low balance'], received
  end

  def test_rails_logger_opt_out
    received = []
    fake_rails_logger = Object.new
    fake_rails_logger.define_singleton_method(:info) { |msg| received << msg }

    fake_rails = Module.new { def self.logger; end }

    stub_const(:Rails, fake_rails) do
      fake_rails.stub(:logger, fake_rails_logger) do
        Telemetry.log(:info, 'silent', rails_logger: false)
      end
    end

    assert_empty received
  end
end
