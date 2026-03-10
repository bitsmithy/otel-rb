# frozen_string_literal: true

require 'test_helper'

class TraceTest < Minitest::Test
  # Use an in-memory exporter so we can inspect finished spans.
  # We configure OTel directly here (not via Telemetry.setup) so that
  # the custom processor is not replaced by Setup.call's provider.
  # before_setup resets OTel; our setup then configures it with the exporter.
  def setup
    @exporter  = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    @processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter)

    OpenTelemetry::SDK.configure do |c|
      c.add_span_processor(@processor)
    end

    # Point Telemetry's @tracer at the configured provider — skip Setup.call
    # so the custom processor is not replaced.
    Telemetry.reset!
    tracer = OpenTelemetry.tracer_provider.tracer('test-service')
    # Inject the tracer directly via the module's class-level ivar
    Telemetry.instance_variable_set(:@tracer, tracer)
    # Set up a minimal logger_provider so Logger.new can build its OTel logger
    OpenTelemetry.logger_provider = OpenTelemetry::SDK::Logs::LoggerProvider.new
    Telemetry.instance_variable_set(:@logger, Telemetry::Logger.new)
  end

  def test_trace_yields_span
    yielded = nil
    Telemetry.trace('test.op') { |span| yielded = span }
    refute_nil yielded
    assert_respond_to yielded, :set_attribute
  end

  def test_trace_attrs
    Telemetry.trace('test.op', attrs: { 'foo' => 'bar' }) { |_span| nil }
    span = @exporter.finished_spans.first
    refute_nil span, 'expected a finished span'
    assert_equal 'bar', span.attributes['foo']
  end

  def test_exception_recorded_on_span
    error = RuntimeError.new('something went wrong')

    assert_raises(RuntimeError) do
      Telemetry.trace('test.op') do |span|
        span.record_exception(error)
        span.status = OpenTelemetry::Trace::Status.error(error.message)
        raise error
      end
    end

    span = @exporter.finished_spans.first
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    assert span.events.any? { |e| e.name == 'exception' }, 'expected an exception event on the span'
  end

  def test_nested_trace_is_child_span
    Telemetry.trace('parent') do |_parent_span|
      Telemetry.trace('child') { |_child_span| nil }
    end

    spans  = @exporter.finished_spans
    parent = spans.find { |s| s.name == 'parent' }
    child  = spans.find { |s| s.name == 'child' }

    refute_nil parent, 'expected parent span'
    refute_nil child,  'expected child span'

    # Child's parent_span_id must equal the outer span's span_id
    assert_equal parent.span_id, child.parent_span_id
  end
end
