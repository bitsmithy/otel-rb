# frozen_string_literal: true

module Telemetry
  # Instrument wrappers returned by Telemetry.instrument.
  # These are not part of the public API — do not instantiate directly.
  # @api private
  module Instruments
    # Monotonically increasing cumulative count.
    # Use for things that only ever go up: requests served, errors thrown, bytes sent.
    class Counter
      def initialize(instrument)
        @instrument = instrument
      end

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
    class Histogram
      def initialize(instrument)
        @instrument = instrument
      end

      # @param value [Numeric] observed value
      # @param attrs [Hash] metric attributes
      def record(value, attrs = {})
        @instrument.record(value, attributes: attrs)
      end

      alias record_value record

      # Times the given block and records its wall-clock duration in seconds.
      # Returns the block's own return value.
      #
      # @param attrs [Hash] metric attributes
      # @yieldreturn the block's return value (passed through unchanged)
      def time(attrs = {})
        start  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        record(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, attrs)
        result
      end
    end

    # Current value at a point in time (non-additive snapshot).
    # Use when you only care about the latest reading: memory usage, temperature,
    # CPU %, file descriptor count.
    class Gauge
      def initialize(instrument)
        @instrument = instrument
      end

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
    class UpDownCounter
      def initialize(instrument)
        @instrument = instrument
      end

      # Increments the counter by +n+ (default 1).
      # @param n [Numeric]
      # @param attrs [Hash] metric attributes
      def increment(n = 1, attrs = {})
        @instrument.add(n, attributes: attrs)
      end

      # Decrements the counter by +n+ (default 1).
      # @param n [Numeric]
      # @param attrs [Hash] metric attributes
      def decrement(n = 1, attrs = {})
        @instrument.add(-n, attributes: attrs)
      end

      # @api private
      def record_value(value, attrs = {})
        increment(value, attrs)
      end
    end
  end
end
