# frozen_string_literal: true

require 'active_support'
require 'active_support/notifications'

module Telemetry
  class ControllerInstrumentation
    EVENT_NAME = 'process_action.action_controller'
    ACTION_COUNT = 'rails.controller.action.count'
    ACTION_DURATION = 'rails.controller.action.duration'
    Operation = Data.define(:span, :context_token, :started_at)

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
      @action_count = meter&.create_counter(ACTION_COUNT, unit: '{action}', description: 'Rails controller actions')
      @action_duration = meter&.create_histogram(
        ACTION_DURATION, unit: 's', description: 'Rails controller action duration'
      )
    end

    def start(_name, transaction_id, payload)
      span = Telemetry.tracer.start_span(
        span_name(payload),
        attributes: {
          'rails.controller' => payload.fetch(:controller),
          'rails.action' => payload.fetch(:action)
        }
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

      attributes = action_attributes(payload)
      annotate_span(operation.span, payload, attributes)
      record_metrics(operation.started_at, attributes)
      Telemetry.record_configured_action(payload)
    rescue StandardError => e
      report_failure(e)
    ensure
      finish_operation(operation) if operation
    end

    private

    def action_attributes(payload)
      {
        'rails.controller' => payload.fetch(:controller),
        'rails.action' => payload.fetch(:action),
        'http.response.status_code' => payload[:status],
        'rails.action.outcome' => action_outcome(payload)
      }.compact
    end

    def annotate_span(span, payload, attributes)
      attributes.each { |key, value| span.set_attribute(key, value) }
      exception = payload[:exception_object]
      return unless exception

      span.record_exception(exception)
      span.status = OpenTelemetry::Trace::Status.error(exception.message)
    end

    def record_metrics(started_at, attributes)
      @action_count&.add(1, attributes: attributes)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      @action_duration&.record(duration, attributes: attributes)
    end

    def action_outcome(payload)
      return 'error' if payload[:exception_object] || payload.fetch(:status, 200) >= 500
      return 'rejected' if payload.fetch(:status, 200) >= 400

      'success'
    end

    def span_name(payload)
      "#{payload.fetch(:controller)}##{payload.fetch(:action)}"
    end

    def finish_operation(operation)
      OpenTelemetry::Context.detach(operation.context_token)
      operation.span.finish
    rescue StandardError => e
      report_failure(e)
    end

    def report_failure(error)
      warn "[Telemetry] controller instrumentation failed (#{error.class})"
    end
  end
end
