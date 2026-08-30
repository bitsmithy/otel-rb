# frozen_string_literal: true

require 'active_job'
require 'opentelemetry-metrics-sdk'
require 'test_helper'

class ActiveJobInstrumentationTest < Minitest::Test
  class TracedJob < ActiveJob::Base
    queue_as :telemetry

    def perform
      Telemetry.trace('job child') { nil }
    end
  end

  class FailingJob < ActiveJob::Base
    queue_as :telemetry

    def perform(_private_argument)
      raise 'job failed'
    end
  end

  class PlainJob < ActiveJob::Base
    def perform
      :application_result
    end
  end

  class AbortedJob < ActiveJob::Base
    before_perform { throw :abort }

    def perform
      raise 'must not run'
    end
  end

  def setup
    @span_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@span_exporter)
    tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    tracer_provider.add_span_processor(processor)
    @meter_provider = OpenTelemetry::SDK::Metrics::MeterProvider.new
    @meter_provider.add_metric_reader(OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new)

    Telemetry.instance_variable_set(:@tracer, tracer_provider.tracer('test'))
    Telemetry.instance_variable_set(:@meter, @meter_provider.meter('test'))
    Telemetry::ActiveJobInstrumentation.install
  end

  def test_traces_every_job_execution
    TracedJob.perform_now

    assert_equal ['job child', 'ActiveJobInstrumentationTest::TracedJob perform'],
                 @span_exporter.finished_spans.map(&:name)
  end

  def test_job_child_spans_use_the_execution_span_as_parent
    TracedJob.perform_now
    child_span, job_span = @span_exporter.finished_spans

    assert_equal job_span.span_id, child_span.parent_span_id
  end

  def test_records_job_count_and_seconds_duration_with_bounded_attributes
    TracedJob.perform_now
    streams = metric_streams.to_h do |stream|
      [stream.instance_variable_get(:@name), stream]
    end
    count_attributes = streams.fetch('rails.active_job.execution.count')
                              .instance_variable_get(:@data_points).keys.first
    expected = {
      'rails.active_job.class' => 'ActiveJobInstrumentationTest::TracedJob',
      'messaging.destination.name' => 'telemetry',
      'rails.active_job.outcome' => 'success'
    }

    assert_equal expected, count_attributes
    assert_equal 's', streams.fetch('rails.active_job.execution.duration').instance_variable_get(:@unit)
  end

  def test_records_and_preserves_job_errors_without_arguments
    error = assert_raises(RuntimeError) { FailingJob.perform_now('private@example.com') }
    span = @span_exporter.finished_spans.first

    assert_equal [error.class.name, 'error', OpenTelemetry::Trace::Status::ERROR], [
      span.attributes.fetch('error.type'),
      span.attributes.fetch('rails.active_job.outcome'),
      span.status.code
    ]
    refute_includes span.attributes.values, 'private@example.com'
  end

  def test_serialized_job_continues_the_enqueue_trace
    serialized_job = nil
    Telemetry.tracer.in_span('request') { serialized_job = TracedJob.new.serialize }
    TracedJob.deserialize(serialized_job).perform_now
    request_span = @span_exporter.finished_spans.find { |span| span.name == 'request' }
    job_span = @span_exporter.finished_spans.find do |span|
      span.name == 'ActiveJobInstrumentationTest::TracedJob perform'
    end

    assert_equal [request_span.trace_id, request_span.span_id], [job_span.trace_id, job_span.parent_span_id]
  end

  def test_instrumentation_failure_does_not_replace_the_job_result
    failing_start = ->(*) { raise 'telemetry failed' }
    result = Telemetry.tracer.stub(:start_span, failing_start) { PlainJob.perform_now }

    assert_equal :application_result, result
  end

  def test_classifies_an_aborted_job_as_rejected
    AbortedJob.perform_now
    span = @span_exporter.finished_spans.first

    assert_equal 'rejected', span.attributes.fetch('rails.active_job.outcome')
  end

  private

  def metric_streams
    @meter_provider
      .instance_variable_get(:@meter_registry)
      .values
      .flat_map { |meter| meter.instance_variable_get(:@instrument_registry).values }
      .flat_map { |instrument| instrument.instance_variable_get(:@metric_streams) }
  end
end
