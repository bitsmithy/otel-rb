# frozen_string_literal: true

require 'opentelemetry/sdk'
require 'opentelemetry-exporter-otlp'
require 'telemetry'

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
