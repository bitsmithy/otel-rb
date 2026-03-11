# frozen_string_literal: true

require 'opentelemetry/trace'

module Telemetry
  # Intercepts Rails.logger calls and emits OTel log records.
  # Prepended onto Rails.logger's singleton class when
  # integrate_tracing_logger: true.
  module LogBridge
    RUBY_TO_OTEL_SEVERITY = {
      0 => [5,  'DEBUG'],
      1 => [9,  'INFO'],
      2 => [13, 'WARN'],
      3 => [17, 'ERROR'],
      4 => [21, 'FATAL'],
      5 => [21, 'FATAL']
    }.freeze

    def add(severity, message = nil, progname = nil, &)
      return super if Thread.current[:telemetry_skip_otel_bridge]

      severity ||= ::Logger::UNKNOWN

      if message.nil?
        if block_given?
          resolved_message = yield
          result = super(severity, resolved_message, progname)
        else
          resolved_message = progname
          result = super(severity, nil, progname)
        end
      else
        resolved_message = message
        result = super
      end

      emit_otel_record(severity, resolved_message) if resolved_message

      result
    end

    private

    def emit_otel_record(severity, message)
      otel_severity = RUBY_TO_OTEL_SEVERITY[severity]
      return unless otel_severity

      span_context = OpenTelemetry::Trace.current_span.context

      @telemetry_bridge_logger ||= OpenTelemetry.logger_provider.logger(
        name: 'telemetry.bridge', version: Telemetry::VERSION
      )

      @telemetry_bridge_logger.on_emit(
        severity_number: otel_severity[0],
        severity_text: otel_severity[1],
        body: message.to_s,
        trace_id: span_context.valid? ? span_context.trace_id : nil,
        span_id: span_context.valid? ? span_context.span_id : nil,
        trace_flags: span_context.valid? ? span_context.trace_flags : nil,
        observed_timestamp: Time.now
      )
    end
  end
end
