# frozen_string_literal: true

require 'active_support/notifications'
require 'opentelemetry-metrics-sdk'
require 'test_helper'

class ControllerInstrumentationTest < Minitest::Test
  def setup
    @span_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@span_exporter)
    tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    tracer_provider.add_span_processor(processor)
    @metric_exporter = OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new
    @meter_provider = OpenTelemetry::SDK::Metrics::MeterProvider.new
    @meter_provider.add_metric_reader(@metric_exporter)

    Telemetry.instance_variable_set(:@tracer, tracer_provider.tracer('test'))
    Telemetry.instance_variable_set(:@meter, @meter_provider.meter('test'))
    Telemetry::ControllerInstrumentation.install
  end

  def test_traces_a_controller_action
    instrument_action

    assert_equal ['RecipesController#create'], @span_exporter.finished_spans.map(&:name)
  end

  def test_controller_action_is_a_child_of_the_current_request_span
    Telemetry.tracer.in_span('POST /recipes') { instrument_action }
    action_span, request_span = @span_exporter.finished_spans

    assert_equal request_span.span_id, action_span.parent_span_id
  end

  def test_controller_span_has_bounded_action_attributes
    instrument_action

    expected = {
      'rails.controller' => 'RecipesController',
      'rails.action' => 'create',
      'http.response.status_code' => 201,
      'rails.action.outcome' => 'success'
    }

    assert_equal expected, @span_exporter.finished_spans.first.attributes
  end

  def test_records_controller_count_and_duration_metrics
    instrument_action

    names = metric_streams.map { |stream| stream.instance_variable_get(:@name) }.sort

    assert_equal %w[rails.controller.action.count rails.controller.action.duration], names
  end

  def test_controller_metrics_use_bounded_action_attributes
    instrument_action
    count_stream = metric_streams.find do |stream|
      stream.instance_variable_get(:@name) == 'rails.controller.action.count'
    end
    attributes = count_stream.instance_variable_get(:@data_points).keys.first

    expected = {
      'rails.controller' => 'RecipesController',
      'rails.action' => 'create',
      'http.response.status_code' => 201,
      'rails.action.outcome' => 'success'
    }

    assert_equal expected, attributes
  end

  def test_classifies_an_exception_as_error_without_replacing_it
    error = RuntimeError.new('controller failed')
    raised = assert_raises(RuntimeError) do
      ActiveSupport::Notifications.instrument(
        'process_action.action_controller', controller: 'RecipesController', action: 'create'
      ) { raise error }
    end
    span = @span_exporter.finished_spans.first

    assert_equal [error, 'error', OpenTelemetry::Trace::Status::ERROR],
                 [raised, span.attributes['rails.action.outcome'], span.status.code]
  end

  def test_classifies_a_client_error_as_rejected
    instrument_action(status: 422)

    assert_equal 'rejected', @span_exporter.finished_spans.first.attributes['rails.action.outcome']
  end

  def test_instrumentation_failure_does_not_replace_the_controller_result
    failing_start = ->(*) { raise 'telemetry failed' }
    result = Telemetry.tracer.stub(:start_span, failing_start) do
      ActiveSupport::Notifications.instrument(
        'process_action.action_controller', controller: 'RecipesController', action: 'create', status: 200
      ) { :application_result }
    end

    assert_equal :application_result, result
  end

  private

  def instrument_action(payload = {})
    ActiveSupport::Notifications.instrument(
      'process_action.action_controller',
      { controller: 'RecipesController', action: 'create', status: 201 }.merge(payload)
    ) { nil }
  end

  def metric_streams
    @meter_provider
      .instance_variable_get(:@meter_registry)
      .values
      .flat_map { |meter| meter.instance_variable_get(:@instrument_registry).values }
      .flat_map { |instrument| instrument.instance_variable_get(:@metric_streams) }
  end
end
