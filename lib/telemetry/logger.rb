# frozen_string_literal: true

require 'opentelemetry/trace'

module Telemetry
  # Shared helper for emitting an OTel log record with trace context.
  # @api private
  module OtelEmission
    # Calls on_emit on the given otel_logger with the current span context
    # automatically attached. Pass attributes: only when extra fields are needed.
    def self.call(otel_logger, severity_number:, severity_text:, body:, attributes: nil)
      span_context = OpenTelemetry::Trace.current_span.context

      emit_args = {
        severity_number: severity_number,
        severity_text: severity_text,
        body: body,
        trace_id: span_context.valid? ? span_context.trace_id : nil,
        span_id: span_context.valid? ? span_context.span_id : nil,
        trace_flags: span_context.valid? ? span_context.trace_flags : nil,
        observed_timestamp: Time.now
      }
      emit_args[:attributes] = attributes if attributes

      otel_logger.on_emit(**emit_args)
    end
  end

  # OTel log emitter. Sends structured log records to the OTLP endpoint via
  # the OTel Logs SDK. When the Logs SDK is not installed, emits a one-time
  # warning then no-ops for OTel output.
  #
  # Each method optionally mirrors the call to Rails.logger (when Rails is
  # present). Pass rails_logger: false to suppress that for a specific call.
  #
  # @example
  #   Telemetry.logger.info("Order placed")
  #   Telemetry.logger.error("Charge failed", rails_logger: false)
  class Logger
    # Thread-local flag set by Logger#emit to prevent LogBridge from
    # re-emitting to OTel when mirroring a call to Rails.logger.
    SKIP_OTEL_BRIDGE_KEY = :telemetry_skip_otel_bridge

    # Canonical OTel severity data per specification:
    # https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
    # Maps symbol level -> [severity_number, severity_text].
    OTEL_SEVERITY = {
      debug: [5, 'DEBUG'],
      info: [9, 'INFO'],
      warn: [13, 'WARN'],
      error: [17, 'ERROR'],
      fatal: [21, 'FATAL']
    }.freeze

    def initialize
      @otel_logger = build_otel_logger
    end

    # @param message [String]
    # @param rails_logger [Boolean] also write to Rails.logger (default: true)
    # (applies to all level methods: +debug+, +info+, +warn+, +error+, +fatal+)
    %i[debug info warn error fatal].each do |level|
      define_method(level) do |message, rails_logger: true|
        emit(level, message, rails_logger: rails_logger)
      end
    end

    private

    def emit(level, message, rails_logger:)
      emit_otel(level, message)
      return unless rails_logger && defined?(::Rails)

      prior = Thread.current[SKIP_OTEL_BRIDGE_KEY]
      begin
        Thread.current[SKIP_OTEL_BRIDGE_KEY] = true
        ::Rails.logger.public_send(level, message)
      ensure
        Thread.current[SKIP_OTEL_BRIDGE_KEY] = prior
      end
    end

    def emit_otel(level, message)
      severity = OTEL_SEVERITY[level]
      OtelEmission.call(@otel_logger, severity_number: severity[0], severity_text: severity[1], body: message)
    end

    def build_otel_logger
      OpenTelemetry.logger_provider.logger(name: 'telemetry', version: Telemetry::VERSION)
    end
  end
end
