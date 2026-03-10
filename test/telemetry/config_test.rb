# frozen_string_literal: true

require 'test_helper'

class ConfigTest < Minitest::Test
  def test_defaults
    config = Telemetry::Config.new
    refute_nil config.service_name
    refute_nil config.service_namespace
    refute_nil config.service_version
  end

  def test_integrate_tracing_logger_default_false
    assert_equal false, Telemetry::Config.new.integrate_tracing_logger
  end

  def test_explicit_values
    config = Telemetry::Config.new(
      service_name: 'my-app',
      service_namespace: 'my-org',
      service_version: 'abc123',
      endpoint: 'http://localhost:4318',
      integrate_tracing_logger: true
    )
    assert_equal 'my-app',               config.service_name
    assert_equal 'my-org',               config.service_namespace
    assert_equal 'abc123',               config.service_version
    assert_equal 'http://localhost:4318', config.endpoint
    assert_equal true, config.integrate_tracing_logger
  end

  def test_no_log_level
    refute_respond_to Telemetry::Config.new, :log_level
  end

  def test_no_rails_logger
    refute_respond_to Telemetry::Config.new, :rails_logger
  end
end
