# frozen_string_literal: true

require 'test_helper'

class PropagationTest < Minitest::Test
  def setup
    tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    Telemetry.instance_variable_set(:@tracer, tracer_provider.tracer('test'))
  end

  def test_injects_only_w3c_trace_context_into_a_trusted_carrier
    carrier = { 'Authorization' => 'Bearer private-token' }
    Telemetry.tracer.in_span('request') do
      Telemetry.inject_trusted_context(carrier)
    end

    assert_match(/\A00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]\z/, carrier.fetch('traceparent'))
    assert_equal %w[Authorization traceparent], carrier.keys.sort
    assert_equal 'Bearer private-token', carrier.fetch('Authorization')
  end
end
