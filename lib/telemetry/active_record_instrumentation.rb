# frozen_string_literal: true

require 'active_support'
require 'active_support/notifications'

module Telemetry
  class ActiveRecordInstrumentation
    EVENT_NAME = 'sql.active_record'
    OPERATION_COUNT = 'db.client.operation.count'
    OPERATION_DURATION = 'db.client.operation.duration'
    Operation = Data.define(:span, :context_token, :started_at, :attributes)
    IGNORED_OPERATION = Object.new.freeze

    class << self
      def install
        @instance ||= new.tap { |subscriber| ActiveSupport::Notifications.subscribe(EVENT_NAME, subscriber) }
        @instance.configure(Telemetry.meter)
      end
    end

    def initialize
      @operations = {}
      @mutex = Mutex.new
    end

    def configure(meter)
      return if @meter.equal?(meter)

      @meter = meter
      @operation_count = meter&.create_counter(
        OPERATION_COUNT, unit: '{operation}', description: 'Executed database operations'
      )
      @operation_duration = meter&.create_histogram(
        OPERATION_DURATION, unit: 's', description: 'Database operation duration'
      )
    end

    def start(_name, transaction_id, payload)
      return push_operation(transaction_id, IGNORED_OPERATION) if DatabaseOperation.ignored?(payload)

      attributes = DatabaseOperation.attributes(payload)
      span = Telemetry.tracer.start_span(
        attributes.fetch('db.operation.name'), kind: :client, attributes: attributes
      )
      context_token = OpenTelemetry::Context.attach(OpenTelemetry::Trace.context_with_span(span))
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      operation = Operation.new(span:, context_token:, started_at:, attributes:)
      push_operation(transaction_id, operation)
    rescue StandardError => e
      push_operation(transaction_id, IGNORED_OPERATION)
      report_failure(e)
    end

    def finish(_name, transaction_id, payload)
      operation = pop_operation(transaction_id)
      return if operation.nil? || operation.equal?(IGNORED_OPERATION)

      attributes = operation.attributes.dup
      annotate_error(operation.span, attributes, payload[:exception_object])
      record_metrics(operation.started_at, attributes)
    rescue StandardError => e
      report_failure(e)
    ensure
      finish_operation(operation) if operation && !operation.equal?(IGNORED_OPERATION)
    end

    private

    def operation_key(transaction_id)
      [Thread.current.object_id, transaction_id]
    end

    def push_operation(transaction_id, operation)
      @mutex.synchronize { (@operations[operation_key(transaction_id)] ||= []) << operation }
    end

    def pop_operation(transaction_id)
      @mutex.synchronize do
        key = operation_key(transaction_id)
        operation = @operations[key]&.pop
        @operations.delete(key) if @operations[key] && @operations[key].empty?
        operation
      end
    end

    def annotate_error(span, attributes, exception)
      return unless exception

      attributes['error.type'] = exception.class.name
      span.add_attributes(attributes)
      span.record_exception(exception)
      span.status = OpenTelemetry::Trace::Status.error(exception.message)
    end

    def record_metrics(started_at, attributes)
      @operation_count&.add(1, attributes: attributes)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      @operation_duration&.record(duration, attributes: attributes)
    end

    def finish_operation(operation)
      OpenTelemetry::Context.detach(operation.context_token)
      operation.span.finish
    rescue StandardError => e
      report_failure(e)
    end

    def report_failure(error)
      warn "[Telemetry] Active Record instrumentation failed (#{error.class})"
    end
  end
end
