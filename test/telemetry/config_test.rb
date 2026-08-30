# frozen_string_literal: true

require 'test_helper'

class ConfigTest < Minitest::Test
  def test_default_service_name
    refute_nil Telemetry::Config.new.service_name
  end

  def test_default_service_namespace
    refute_nil Telemetry::Config.new.service_namespace
  end

  def test_default_service_version
    refute_nil Telemetry::Config.new.service_version
  end

  def test_integrate_tracing_logger_default_false
    assert_equal false, Telemetry::Config.new.integrate_tracing_logger
  end

  def test_correlate_logs_default_false
    assert_equal false, Telemetry::Config.new.correlate_logs
  end

  def test_explicit_values
    config = Telemetry::Config.new(
      service_name: 'my-app',
      service_namespace: 'my-org',
      service_version: 'abc123',
      deployment_environment: 'production',
      endpoint: 'http://localhost:4318',
      correlate_logs: true,
      integrate_tracing_logger: true
    )
    assert_equal 'my-app',               config.service_name
    assert_equal 'my-org',               config.service_namespace
    assert_equal 'abc123',               config.service_version
    assert_equal 'production',           config.deployment_environment
    assert_equal 'http://localhost:4318', config.endpoint
    assert_equal true, config.correlate_logs
    assert_equal true, config.integrate_tracing_logger
  end

  def test_requires_an_endpoint_when_requested
    previous = ENV.delete('OTEL_EXPORTER_OTLP_ENDPOINT')

    assert_raises(Telemetry::ConfigurationError) do
      Telemetry::Config.new(require_endpoint: true)
    end
  ensure
    ENV['OTEL_EXPORTER_OTLP_ENDPOINT'] = previous if previous
  end

  def test_rejects_a_malformed_endpoint
    assert_raises(Telemetry::ConfigurationError) do
      Telemetry::Config.new(endpoint: 'not a URL')
    end
  end

  def test_no_log_level
    refute_respond_to Telemetry::Config.new, :log_level
  end

  def test_no_rails_logger
    refute_respond_to Telemetry::Config.new, :rails_logger
  end
end
