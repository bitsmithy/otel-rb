# frozen_string_literal: true

require 'test_helper'

class InstrumentTest < Minitest::Test
  # --- Telemetry.meter (raw OTel meter) ---

  def test_meter_returns_otel_meter_after_setup
    refute_nil Telemetry.meter
  end

  def test_meter_responds_to_create_counter
    assert_respond_to Telemetry.meter, :create_counter
  end

  # --- Handle (no value) returns cached wrapper ---

  def test_counter_handle
    h = Telemetry.counter('test.counter')
    assert_instance_of Telemetry::Instruments::Counter, h
  end

  def test_histogram_handle
    h = Telemetry.histogram('test.histogram')
    assert_instance_of Telemetry::Instruments::Histogram, h
  end

  def test_gauge_handle
    h = Telemetry.gauge('test.gauge')
    assert_instance_of Telemetry::Instruments::Gauge, h
  end

  def test_up_down_counter_handle
    h = Telemetry.up_down_counter('test.updown')
    assert_instance_of Telemetry::Instruments::UpDownCounter, h
  end

  def test_handle_with_unit_and_description
    h = Telemetry.counter('test.counter.opts', unit: '{order}', description: 'Orders placed')
    assert_instance_of Telemetry::Instruments::Counter, h
  end

  def test_handles_are_cached
    a = Telemetry.counter('cache.test')
    b = Telemetry.counter('cache.test')
    assert_same a, b
  end

  # --- Counter handle methods ---

  def test_counter_handle_add
    orders = Telemetry.counter('h.counter.add', unit: '{order}')
    assert_silent { orders.add(1) }
  end

  def test_counter_handle_add_with_attrs
    orders = Telemetry.counter('h.counter.add.attrs', unit: '{order}')
    assert_silent { orders.add(1, 'payment.method' => 'card') }
  end

  def test_counter_handle_add_multiple
    orders = Telemetry.counter('h.counter.add.multi', unit: '{order}')
    assert_silent { orders.add(3, 'payment.method' => 'card') }
  end

  # --- Fire-and-forget (value given) ---

  def test_counter_with_value
    assert_silent { Telemetry.counter('rec.counter', 1) }
  end

  def test_counter_with_value_and_attrs
    assert_silent { Telemetry.counter('rec.counter.attrs', 1, 'env' => 'test') }
  end

  def test_counter_with_value_unit_and_description
    assert_silent { Telemetry.counter('rec.counter.full', 1, unit: '{order}', description: 'Orders placed') }
  end

  def test_counter_with_value_attrs_unit_and_description
    assert_silent do
      Telemetry.counter('rec.counter.full.attrs', 1, 'payment.method' => 'card', unit: '{order}',
                                                     description: 'Orders placed')
    end
  end

  def test_histogram_with_value
    assert_silent { Telemetry.histogram('rec.histogram', 0.5) }
  end

  def test_histogram_with_value_unit_and_description
    assert_silent { Telemetry.histogram('rec.histogram.full', 0.42, unit: 's', description: 'Order processing time') }
  end

  def test_histogram_with_value_attrs_unit_and_description
    assert_silent do
      Telemetry.histogram('rec.histogram.full.attrs', 0.42, 'queue' => 'default', unit: 's',
                                                            description: 'Order processing time')
    end
  end

  def test_gauge_with_value
    assert_silent { Telemetry.gauge('rec.gauge', 42) }
  end

  def test_gauge_with_value_unit_and_description
    assert_silent { Telemetry.gauge('rec.gauge.full', 17, unit: '{job}', description: 'Jobs waiting in queue') }
  end

  def test_gauge_with_value_attrs_unit_and_description
    assert_silent do
      Telemetry.gauge('rec.gauge.full.attrs', 17, 'queue' => 'default', unit: '{job}',
                                                  description: 'Jobs waiting in queue')
    end
  end

  def test_up_down_counter_with_value
    assert_silent { Telemetry.up_down_counter('rec.updown', -1) }
  end

  def test_up_down_counter_with_positive_value_unit_and_description
    assert_silent do
      Telemetry.up_down_counter('rec.updown.full.pos', 1, unit: '{connection}', description: 'Active DB connections')
    end
  end

  def test_up_down_counter_with_negative_value_unit_and_description
    assert_silent do
      Telemetry.up_down_counter('rec.updown.full.neg', -1, unit: '{connection}', description: 'Active DB connections')
    end
  end

  def test_up_down_counter_with_value_attrs_unit_and_description
    assert_silent do
      Telemetry.up_down_counter('rec.updown.full.attrs', 1, 'pool' => 'primary', unit: '{connection}',
                                                            description: 'Active DB connections')
    end
  end

  # --- Histogram handle methods ---

  def test_histogram_handle_record
    durations = Telemetry.histogram('h.histogram.record', unit: 's')
    assert_silent { durations.record(0.42) }
  end

  def test_histogram_handle_record_with_attrs
    durations = Telemetry.histogram('h.histogram.record.attrs', unit: 's')
    assert_silent { durations.record(0.42, 'queue' => 'default') }
  end

  # --- Histogram block timing ---

  def test_histogram_times_block
    assert_silent { Telemetry.histogram('test.duration') { 'work' } }
  end

  def test_histogram_block_returns_block_value
    result = Telemetry.histogram('test.duration2') { 42 }
    assert_equal 42, result
  end

  def test_histogram_block_with_attrs
    assert_silent { Telemetry.histogram('test.duration3', 'queue' => 'default') { 'work' } }
  end

  def test_histogram_numeric_with_block_raises
    assert_raises(ArgumentError) { Telemetry.histogram('test.duration4', 1) { 'work' } }
  end

  def test_histogram_block_with_explicit_unit
    assert_silent { Telemetry.histogram('test.duration5', unit: 's') { 'work' } }
  end

  def test_histogram_block_with_attrs_and_unit
    assert_silent { Telemetry.histogram('test.duration6', 'queue' => 'default', unit: 's') { 'work' } }
  end

  # --- Gauge handle methods ---

  def test_gauge_handle_record
    depth = Telemetry.gauge('h.gauge.record', unit: '{job}')
    assert_silent { depth.record(17) }
  end

  def test_gauge_handle_record_with_attrs
    depth = Telemetry.gauge('h.gauge.record.attrs', unit: '{job}')
    assert_silent { depth.record(17, 'queue' => 'default') }
  end

  # --- Telemetry.time shorthand ---

  def test_time_does_not_raise
    assert_silent { Telemetry.time('test.op_duration') { 'work' } }
  end

  def test_time_returns_block_value
    result = Telemetry.time('test.op_duration2') { :done }
    assert_equal :done, result
  end

  def test_time_with_attrs
    assert_silent { Telemetry.time('test.op_duration3', 'queue' => 'default') { 'work' } }
  end

  # --- UpDownCounter handle methods ---

  def test_up_down_counter_increment
    assert_silent { Telemetry.up_down_counter('test.conns').increment }
  end

  def test_up_down_counter_increment_with_amount
    assert_silent { Telemetry.up_down_counter('test.conns2').increment(5) }
  end

  def test_up_down_counter_increment_with_attrs
    assert_silent { Telemetry.up_down_counter('test.conns5').increment(1, 'pool' => 'primary') }
  end

  def test_up_down_counter_decrement
    assert_silent { Telemetry.up_down_counter('test.conns3').decrement }
  end

  def test_up_down_counter_decrement_with_amount
    assert_silent { Telemetry.up_down_counter('test.conns4').decrement(3) }
  end

  def test_up_down_counter_decrement_with_attrs
    assert_silent { Telemetry.up_down_counter('test.conns6').decrement(1, 'pool' => 'primary') }
  end

  # --- Histogram#time unit conversion ---

  def test_histogram_time_defaults_to_ms
    recorded = histogram_time_recorded(unit: nil)
    assert_in_delta 100, recorded, 50
  end

  def test_histogram_time_converts_to_hours
    recorded = histogram_time_recorded(unit: 'h')
    assert_in_delta 0.1 / 3600, recorded, 0.001
  end

  def test_histogram_time_converts_to_minutes
    recorded = histogram_time_recorded(unit: 'min')
    assert_in_delta 0.1 / 60, recorded, 0.001
  end

  def test_histogram_time_converts_to_seconds
    recorded = histogram_time_recorded(unit: 's')
    assert_in_delta 0.1, recorded, 0.05
  end

  def test_histogram_time_converts_to_milliseconds
    recorded = histogram_time_recorded(unit: 'ms')
    assert_in_delta 100, recorded, 50
  end

  def test_histogram_time_converts_to_microseconds
    recorded = histogram_time_recorded(unit: 'us')
    assert_in_delta 100_000, recorded, 50_000
  end

  def test_histogram_time_converts_to_nanoseconds
    recorded = histogram_time_recorded(unit: 'ns')
    assert_in_delta 100_000_000, recorded, 50_000_000
  end

  def test_histogram_time_raises_for_non_time_unit
    h = Telemetry.histogram('time.bad_unit', unit: 'By')
    error = assert_raises(ArgumentError) { h.time { 'work' } }
    assert_match(/cannot time with unit/, error.message)
  end

  # --- NotSetupError ---

  def test_not_setup_error
    Telemetry.reset!
    assert_raises(Telemetry::NotSetupError) { Telemetry.counter('x') }
  end

  SpyInstrument = Struct.new(:last_value) do
    def record(value, **)
      self.last_value = value
    end
  end

  private

  # Creates a histogram with the given unit, times a ~100ms sleep, and returns
  # the recorded value by spying on the underlying OTel instrument.
  def histogram_time_recorded(unit:)
    spy = SpyInstrument.new
    h = Telemetry::Instruments::Histogram.new(spy, unit: unit)
    h.time { sleep 0.1 }
    spy.last_value
  end
end
