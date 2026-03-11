# frozen_string_literal: true

module Telemetry
  # Instrument wrappers returned by Telemetry.instrument.
  # These are not part of the public API — do not instantiate directly.
  # @api private
  module Instruments
    # Shared base for all instrument wrappers.
    class Base
      def initialize(instrument)
        @instrument = instrument
      end

      private

      attr_reader :instrument
    end

    # Monotonically increasing cumulative count.
    # Use for things that only ever go up: requests served, errors thrown, bytes sent.
    class Counter < Base
      # @param value [Numeric] positive amount to add
      # @param attrs [Hash] metric attributes
      def add(value, attrs = {})
        @instrument.add(value, attributes: attrs)
      end

      alias record_value add
    end

    # Distribution of values over time.
    # Use for durations, payload sizes, latencies — anything where you care
    # about percentiles, not just the sum.
    class Histogram < Base
      ELAPSED_MULTIPLIER = {
        'h' => 1.0 / 3600, 'min' => 1.0 / 60, 's' => 1,
        'ms' => 1_000, 'us' => 1_000_000, 'ns' => 1_000_000_000
      }.freeze

      # @param instrument [OpenTelemetry::Metrics::Histogram] underlying OTel instrument
      # @param unit [String, nil] time unit for `.time` conversion (default "ms")
      def initialize(instrument, unit: nil)
        super(instrument)
        @unit = unit
      end

      # @param value [Numeric] observed value
      # @param attrs [Hash] metric attributes
      def record(value, attrs = {})
        @instrument.record(value, attributes: attrs)
      end

      alias record_value record

      # Times the given block and records wall-clock duration in the histogram's unit.
      # Returns the block's own return value.
      #
      # @param attrs [Hash] metric attributes
      # @yieldreturn the block's return value (passed through unchanged)
      def time(attrs = {})
        multiplier = ELAPSED_MULTIPLIER.fetch(@unit || 'ms') do
          raise ArgumentError,
                "cannot time with unit #{@unit.inspect} — use one of: #{ELAPSED_MULTIPLIER.keys.join(', ')}"
        end
        start  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * multiplier
        record(elapsed, attrs)
        result
      end
    end

    # Current value at a point in time (non-additive snapshot).
    # Use when you only care about the latest reading: memory usage, temperature,
    # CPU %, file descriptor count.
    class Gauge < Base
      # @param value [Numeric] current observed value
      # @param attrs [Hash] metric attributes
      def record(value, attrs = {})
        @instrument.record(value, attributes: attrs)
      end

      alias record_value record
    end

    # Value that can increment and decrement.
    # Use for counts of things that go up and down: active connections,
    # items currently in a queue, concurrent in-flight requests.
    class UpDownCounter < Base
      # Increments the counter by +n+ (default 1).
      # @param n [Numeric]
      # @param attrs [Hash] metric attributes
      def increment(amount = 1, attrs = {})
        @instrument.add(amount, attributes: attrs)
      end

      # Decrements the counter by +n+ (default 1).
      # @param n [Numeric]
      # @param attrs [Hash] metric attributes
      def decrement(amount = 1, attrs = {})
        @instrument.add(-amount, attributes: attrs)
      end

      # @api private
      def record_value(value, attrs = {})
        increment(value, attrs)
      end
    end
  end
end
