# frozen_string_literal: true

module Telemetry
  # Private dispatch logic for metric instruments.
  # Extended into the Telemetry module's singleton class.
  # @api private
  module Metering
    INSTRUMENT_TYPES = {
      counter: [:create_counter, Instruments::Counter],
      histogram: [:create_histogram, Instruments::Histogram],
      gauge: [:create_gauge, Instruments::Gauge],
      up_down_counter: [:create_up_down_counter, Instruments::UpDownCounter]
    }.freeze

    private

    # Unpacks *rest and **kwargs into [value, attrs, unit, description].
    # rest accepts: (), (value), (value, attrs_hash), or (attrs_hash) for block timing.
    # unit and description are extracted from kwargs; remaining kwargs become attrs.
    def parse_rest(rest, kwargs = {})
      unit        = kwargs.delete(:unit)
      description = kwargs.delete(:description)
      attrs_from_kwargs = kwargs.empty? ? {} : kwargs

      value, attrs =
        case rest
        in []               then [nil, attrs_from_kwargs]
        in [Numeric => v]   then [v,   attrs_from_kwargs]
        in [Numeric => v, Hash => a] then [v, a.merge(attrs_from_kwargs)]
        in [Hash => a] then [a, attrs_from_kwargs] # block-timing path: (attrs_hash)
        else
          raise ArgumentError, "unexpected arguments: #{rest.inspect}"
        end

      [value, attrs, unit, description]
    end

    # Shared dispatch: returns handle when value is nil, records immediately when value is Numeric.
    def dispatch(type, name, value, attrs, opts)
      instrument = fetch_instrument(type, name, opts)
      value.is_a?(Numeric) ? instrument.record_value(value, attrs) : instrument
    end

    def fetch_instrument(type, name, opts)
      raise NotSetupError, type unless @meter

      @instruments ||= {}
      @instruments[[type, name]] ||= build_instrument(type, name, opts)
    end

    def build_instrument(type, name, opts)
      factory_method, wrapper_class = INSTRUMENT_TYPES.fetch(type)
      otel_instrument = @meter.public_send(factory_method, name, **opts)
      if wrapper_class == Instruments::Histogram
        wrapper_class.new(otel_instrument, unit: opts[:unit])
      else
        wrapper_class.new(otel_instrument)
      end
    end
  end
end
