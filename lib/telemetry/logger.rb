# frozen_string_literal: true

require 'opentelemetry/trace'

module Telemetry
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
    # OTel severity numbers per specification
    # https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
    SEVERITY = {
      debug: 5,
      info:  9,
      warn:  13,
      error: 17,
      fatal: 21
    }.freeze

    def initialize
      @otel_logger  = build_otel_logger
      @otel_warned  = false
    end

    # @param message [String]
    # @param rails_logger [Boolean] also write to Rails.logger (default: true)
    def debug(message, rails_logger: true)
      emit(:debug, message, rails_logger: rails_logger)
    end

    # @param message [String]
    # @param rails_logger [Boolean] also write to Rails.logger (default: true)
    def info(message, rails_logger: true)
      emit(:info, message, rails_logger: rails_logger)
    end

    # @param message [String]
    # @param rails_logger [Boolean] also write to Rails.logger (default: true)
    def warn(message, rails_logger: true)
      emit(:warn, message, rails_logger: rails_logger)
    end

    # @param message [String]
    # @param rails_logger [Boolean] also write to Rails.logger (default: true)
    def error(message, rails_logger: true)
      emit(:error, message, rails_logger: rails_logger)
    end

    # @param message [String]
    # @param rails_logger [Boolean] also write to Rails.logger (default: true)
    def fatal(message, rails_logger: true)
      emit(:fatal, message, rails_logger: rails_logger)
    end

    private

    def emit(level, message, rails_logger:)
      emit_otel(level, message)
      ::Rails.logger.public_send(level, message) if rails_logger && defined?(::Rails)
    end

    def emit_otel(level, message)
      unless @otel_logger
        unless @otel_warned
          Kernel.warn '[Telemetry] OTel Logs SDK not available; Telemetry.logger OTel output is a no-op'
          @otel_warned = true
        end
        return
      end

      span_context = OpenTelemetry::Trace.current_span.context

      @otel_logger.on_emit(
        severity_number: SEVERITY[level],
        severity_text:   level.to_s.upcase,
        body:            message,
        trace_id:        span_context.valid? ? span_context.trace_id : nil,
        span_id:         span_context.valid? ? span_context.span_id  : nil,
        trace_flags:     span_context.valid? ? span_context.trace_flags : nil,
        observed_timestamp: Time.now
      )
    end

    def build_otel_logger
      lp = OpenTelemetry.logger_provider
      return nil if lp.is_a?(OpenTelemetry::Internal::ProxyLoggerProvider)

      lp.logger('telemetry', version: Telemetry::VERSION)
    rescue StandardError
      nil
    end
  end
end
