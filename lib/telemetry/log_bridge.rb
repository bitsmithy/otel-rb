# frozen_string_literal: true

require 'opentelemetry/trace'
require_relative 'logger'

module Telemetry
  # Intercepts Rails.logger calls and emits OTel log records.
  # Prepended onto Rails.logger's singleton class when
  # integrate_tracing_logger: true. The prepended class must respond to
  # +add+ with the standard Ruby Logger signature.
  module LogBridge
    # Maps Ruby Logger integer severity (0=DEBUG..4=FATAL, 5=UNKNOWN->FATAL)
    # to [severity_number, severity_text] pairs derived from Logger::OTEL_SEVERITY.
    RUBY_TO_OTEL_SEVERITY = {
      0 => Logger::OTEL_SEVERITY[:debug],
      1 => Logger::OTEL_SEVERITY[:info],
      2 => Logger::OTEL_SEVERITY[:warn],
      3 => Logger::OTEL_SEVERITY[:error],
      4 => Logger::OTEL_SEVERITY[:fatal],
      5 => Logger::OTEL_SEVERITY[:fatal]
    }.freeze

    def add(severity, message = nil, progname = nil, &)
      return super if Thread.current[Logger::SKIP_OTEL_BRIDGE_KEY]

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

      @telemetry_bridge_logger ||= OpenTelemetry.logger_provider.logger(
        name: 'telemetry.bridge', version: Telemetry::VERSION
      )

      attrs = { 'level' => otel_severity[1].downcase }
      request_id = Thread.current[Middleware::THREAD_REQUEST_ID_KEY]
      attrs['request.id'] = request_id if request_id

      OtelEmission.call(
        @telemetry_bridge_logger,
        severity_number: otel_severity[0],
        severity_text: otel_severity[1],
        body: message.to_s,
        attributes: attrs
      )
    end
  end
end
