# frozen_string_literal: true

module Telemetry
  module TrustedPropagation
    def inject_trusted_context(carrier)
      OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator.inject(carrier)
      carrier
    rescue StandardError => e
      warn "[Telemetry] trusted trace propagation failed (#{e.class})"
      carrier
    end
  end
end
