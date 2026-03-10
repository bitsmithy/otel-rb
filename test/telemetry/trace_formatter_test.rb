# frozen_string_literal: true

require 'test_helper'
require 'logger'

class TraceFormatterTest < Minitest::Test
  def setup
    @formatter        = Telemetry::TraceFormatter.new
    @tracer_provider  = OpenTelemetry::SDK::Trace::TracerProvider.new
    @tracer           = @tracer_provider.tracer('test')
  end

  def test_no_span_no_suffix
    output = @formatter.call('INFO', Time.now, 'app', 'hello')
    refute_match(/trace_id=/, output)
    refute_match(/span_id=/, output)
  end

  def test_active_span_adds_suffix
    @tracer.in_span('test-span') do
      output = @formatter.call('INFO', Time.now, 'app', 'hello')
      assert_match(/trace_id=[0-9a-f]{32}/, output)
      assert_match(/span_id=[0-9a-f]{16}/, output)
    end
  end

  def test_finished_span_no_suffix
    @tracer.in_span('test-span') {} # span finishes immediately
    output = @formatter.call('INFO', Time.now, 'app', 'hello')
    refute_match(/trace_id=/, output)
  end
end
