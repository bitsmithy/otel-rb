# frozen_string_literal: true

require 'English'
require 'logger'
require 'opentelemetry/trace'

module Telemetry
  class TraceFormatter < ::Logger::Formatter
    FORMAT = "%s, [%s#%d] %5s -- %s: %s%s\n"

    def call(severity, time, progname, msg)
      format(FORMAT, severity[0..0], format_datetime(time), $PROCESS_ID, severity, progname || 'app', msg2str(msg),
             trace_suffix)
    end

    private

    def trace_suffix
      ctx = OpenTelemetry::Trace.current_span&.context
      return '' unless ctx&.valid?

      " trace_id=#{ctx.hex_trace_id} span_id=#{ctx.hex_span_id}"
    end
  end
end
