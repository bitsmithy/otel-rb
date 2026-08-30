# frozen_string_literal: true

require 'active_record'
require 'opentelemetry-metrics-sdk'
require 'test_helper'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Base.connection.create_table(:telemetry_records) do |table|
  table.string :name, null: false
end

class ActiveRecordInstrumentationTest < Minitest::Test
  class TelemetryRecord < ActiveRecord::Base
    self.table_name = 'telemetry_records'
  end

  def setup
    TelemetryRecord.delete_all
    @span_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@span_exporter)
    tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    tracer_provider.add_span_processor(processor)
    @meter_provider = OpenTelemetry::SDK::Metrics::MeterProvider.new
    @meter_provider.add_metric_reader(OpenTelemetry::SDK::Metrics::Export::InMemoryMetricPullExporter.new)

    Telemetry.instance_variable_set(:@tracer, tracer_provider.tracer('test'))
    Telemetry.instance_variable_set(:@meter, @meter_provider.meter('test'))
    Telemetry::ActiveRecordInstrumentation.install
  end

  def test_traces_an_executed_database_write_without_its_values
    TelemetryRecord.create!(name: 'private@example.com')
    span = @span_exporter.finished_spans.find { |candidate| candidate.name == 'INSERT' }

    assert_equal({ 'db.system.name' => 'sqlite', 'db.operation.name' => 'INSERT' }, span.attributes)
  end

  def test_records_database_count_and_seconds_duration
    TelemetryRecord.create!(name: 'Recipe')
    names_and_units = metric_streams.to_h do |stream|
      [stream.instance_variable_get(:@name), stream.instance_variable_get(:@unit)]
    end

    expected = {
      'db.client.operation.count' => '{operation}',
      'db.client.operation.duration' => 's'
    }

    assert_equal expected, names_and_units
  end

  def test_excludes_transaction_control_around_a_write
    TelemetryRecord.create!(name: 'Recipe')

    assert_equal ['INSERT'], @span_exporter.finished_spans.map(&:name)
  end

  def test_excludes_an_active_record_query_cache_hit
    TelemetryRecord.create!(name: 'Recipe')
    ActiveRecord::Base.cache do
      TelemetryRecord.first
      @span_exporter.reset
      TelemetryRecord.first
    end

    assert_empty @span_exporter.finished_spans
  end

  def test_excludes_schema_inspection
    ActiveRecord::Base.connection.schema_cache.clear!
    ActiveRecord::Base.connection.columns(:telemetry_records)

    assert_empty @span_exporter.finished_spans
  end

  def test_records_and_preserves_a_database_error
    raised = assert_raises(ActiveRecord::NotNullViolation) { TelemetryRecord.create! }
    span = @span_exporter.finished_spans.find { |candidate| candidate.name == 'INSERT' }

    assert_equal [raised.class.name, OpenTelemetry::Trace::Status::ERROR],
                 [span.attributes.fetch('error.type'), span.status.code]
  end

  def test_database_span_is_a_child_of_the_current_operation
    Telemetry.trace('controller action') { TelemetryRecord.first }
    database_span, operation_span = @span_exporter.finished_spans

    assert_equal operation_span.span_id, database_span.parent_span_id
  end

  def test_instrumentation_failure_does_not_replace_the_query_result
    TelemetryRecord.create!(name: 'Recipe')
    failing_start = ->(*) { raise 'telemetry failed' }
    record = Telemetry.tracer.stub(:start_span, failing_start) { TelemetryRecord.first }

    assert_equal 'Recipe', record.name
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
