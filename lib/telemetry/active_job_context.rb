# frozen_string_literal: true

module Telemetry
  module ActiveJobContext
    SERIALIZED_CONTEXT_KEY = '_telemetry_trace_context'

    attr_reader :telemetry_parent_context

    def serialize
      carrier = {}
      OpenTelemetry.propagation.inject(carrier)
      super.merge(SERIALIZED_CONTEXT_KEY => carrier)
    end

    def deserialize(job_data)
      super
      carrier = job_data.fetch(SERIALIZED_CONTEXT_KEY, {})
      @telemetry_parent_context = OpenTelemetry.propagation.extract(carrier)
    end
  end
end
