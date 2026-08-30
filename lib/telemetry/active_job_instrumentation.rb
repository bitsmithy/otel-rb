# frozen_string_literal: true

require 'active_support'
require 'active_support/notifications'

module Telemetry
  class ActiveJobInstrumentation
    EVENT_NAME = 'perform.active_job'
    EXECUTION_COUNT = 'rails.active_job.execution.count'
    EXECUTION_DURATION = 'rails.active_job.execution.duration'
    Operation = Data.define(:span, :context_token, :started_at)

    class << self
      def install
        install_context_propagation
        @instance ||= new.tap { |subscriber| ActiveSupport::Notifications.subscribe(EVENT_NAME, subscriber) }
        @instance.configure(Telemetry.meter)
      end

      private

      def install_context_propagation
        ActiveJob::Base.prepend(ActiveJobContext) unless ActiveJob::Base.ancestors.include?(ActiveJobContext)
      end
    end

    def initialize
      @operations = {}
      @mutex = Mutex.new
    end

    def configure(meter)
      return if @meter.equal?(meter)

      @meter = meter
      @execution_count = meter&.create_counter(
        EXECUTION_COUNT, unit: '{job}', description: 'Active Job executions'
      )
      @execution_duration = meter&.create_histogram(
        EXECUTION_DURATION, unit: 's', description: 'Active Job execution duration'
      )
    end

    def start(_name, transaction_id, payload)
      job = payload.fetch(:job)
      attributes = base_attributes(job)
      span = Telemetry.tracer.start_span(
        span_name(job), attributes:, with_parent: job.telemetry_parent_context
      )
      context_token = OpenTelemetry::Context.attach(OpenTelemetry::Trace.context_with_span(span))
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @mutex.synchronize { @operations[transaction_id] = Operation.new(span:, context_token:, started_at:) }
    rescue StandardError => e
      report_failure(e)
    end

    def finish(_name, transaction_id, payload)
      operation = @mutex.synchronize { @operations.delete(transaction_id) }
      return unless operation

      attributes = base_attributes(payload.fetch(:job)).merge('rails.active_job.outcome' => outcome(payload))
      annotate_span(operation.span, attributes, payload[:exception_object])
      record_metrics(operation.started_at, attributes)
    rescue StandardError => e
      report_failure(e)
    ensure
      finish_operation(operation) if operation
    end

    private

    def span_name(job)
      "#{job.class.name} perform"
    end

    def base_attributes(job)
      {
        'rails.active_job.class' => job.class.name,
        'messaging.destination.name' => job.queue_name
      }
    end

    def outcome(payload)
      return 'error' if payload[:exception_object]
      return 'rejected' if payload[:aborted]

      'success'
    end

    def annotate_span(span, attributes, exception)
      span.add_attributes(attributes)
      return unless exception

      span.set_attribute('error.type', exception.class.name)
      span.record_exception(exception)
      span.status = OpenTelemetry::Trace::Status.error(exception.message)
    end

    def record_metrics(started_at, attributes)
      @execution_count&.add(1, attributes: attributes)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      @execution_duration&.record(duration, attributes: attributes)
    end

    def finish_operation(operation)
      OpenTelemetry::Context.detach(operation.context_token)
      operation.span.finish
    rescue StandardError => e
      report_failure(e)
    end

    def report_failure(error)
      warn "[Telemetry] Active Job instrumentation failed (#{error.class})"
    end
  end
end
