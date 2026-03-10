# frozen_string_literal: true

# Suppress the "otlp metrics exporter cannot be configured" warning that fires
# when opentelemetry-metrics-sdk tries to auto-configure an OTLP exporter via
# OpenTelemetry::SDK.configure. "none" tells the SDK to skip metric export entirely.
ENV['OTEL_METRICS_EXPORTER'] ||= 'none'

require 'minitest/autorun'
require 'minitest/reporters'
require 'opentelemetry/sdk'
require 'telemetry'

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new

# One call disables at_exit and installs auto-reset before every test.
Telemetry.test_mode!

module Minitest
  class Test
    private

    def stub_const(name, value)
      was_defined = Object.const_defined?(name)
      Object.const_set(name, value)
      yield
    ensure
      Object.send(:remove_const, name) if Object.const_defined?(name) && !was_defined
    end
  end
end
