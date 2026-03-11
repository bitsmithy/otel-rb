# frozen_string_literal: true

require 'test_helper'
require 'logger'
require 'stringio'
require 'telemetry/log_bridge'

class LogBridgeTest < Minitest::Test
  def teardown
    Thread.current[:telemetry_skip_otel_bridge] = nil
  end

  # --- OTel emission ---

  def test_bridge_emits_otel_log_record
    logger, emissions = bridged_logger
    logger.info('hello')

    assert_equal 1, emissions.size
    assert_equal 9, emissions.first[:severity_number]
    assert_equal 'INFO', emissions.first[:severity_text]
    assert_equal 'hello', emissions.first[:body]
    assert_equal 'info', emissions.first[:attributes]['level']
  end

  def test_bridge_maps_all_severity_levels
    expected = { debug: 5, info: 9, warn: 13, error: 17, fatal: 21 }

    expected.each do |level, otel_num|
      logger, emissions = bridged_logger
      logger.public_send(level, "test #{level}")

      assert_equal 1, emissions.size, "Expected 1 emission for #{level}"
      assert_equal otel_num, emissions.first[:severity_number], "Wrong severity for #{level}"
    end
  end

  # --- Trace context ---

  def test_bridge_attaches_trace_context
    logger, emissions = bridged_logger

    Telemetry.tracer.in_span('test-span') do
      logger.info('traced')
    end

    assert_equal 1, emissions.size
    refute_nil emissions.first[:trace_id]
    refute_nil emissions.first[:span_id]
  end

  def test_bridge_omits_trace_context_without_span
    logger, emissions = bridged_logger
    logger.info('no trace')

    assert_equal 1, emissions.size
    assert_nil emissions.first[:trace_id]
    assert_nil emissions.first[:span_id]
  end

  # --- Block form ---

  def test_bridge_handles_block_form
    logger, emissions = bridged_logger
    eval_count = 0

    logger.info do
      eval_count += 1
      'from block'
    end

    assert_equal 1, eval_count
    assert_equal 1, emissions.size
    assert_equal 'from block', emissions.first[:body]
  end

  # --- Thread-local skip ---

  def test_bridge_skips_when_thread_local_set
    logger, emissions = bridged_logger

    Thread.current[:telemetry_skip_otel_bridge] = true
    logger.info('skipped')

    assert_empty emissions
  end

  # --- Request ID ---

  def test_bridge_includes_request_id_when_set
    logger, emissions = bridged_logger

    Thread.current[Telemetry::Middleware::THREAD_REQUEST_ID_KEY] = 'abc-123'
    logger.info('with request id')
    Thread.current[Telemetry::Middleware::THREAD_REQUEST_ID_KEY] = nil

    assert_equal 1, emissions.size
    assert_equal 'abc-123', emissions.first[:attributes]['request.id']
  end

  def test_bridge_omits_request_id_when_not_set
    logger, emissions = bridged_logger
    logger.info('no request id')

    assert_equal 1, emissions.size
    refute emissions.first[:attributes].key?('request.id')
  end

  # --- BroadcastLogger compatibility ---

  def test_bridge_emits_through_broadcast_logger
    require 'active_support'
    require 'active_support/broadcast_logger'

    emissions = []
    inner = ::Logger.new(StringIO.new)
    broadcast = ActiveSupport::BroadcastLogger.new(inner)

    Telemetry.send(:prepend_log_bridge, broadcast)
    inject_mock_otel_logger(inner, emissions)

    broadcast.info('broadcast hello')

    assert_equal 1, emissions.size
    assert_equal 9, emissions.first[:severity_number]
    assert_equal 'broadcast hello', emissions.first[:body]
  end

  # --- Original output preserved ---

  def test_bridge_preserves_original_logger_output
    io = StringIO.new
    logger = ::Logger.new(io)
    logger.singleton_class.prepend(Telemetry::LogBridge)
    inject_mock_otel_logger(logger)

    logger.info('hello')

    assert_match(/hello/, io.string)
  end

  private

  def bridged_logger
    emissions = []
    logger = ::Logger.new(StringIO.new)
    logger.singleton_class.prepend(Telemetry::LogBridge)
    inject_mock_otel_logger(logger, emissions)
    [logger, emissions]
  end

  def inject_mock_otel_logger(logger, emissions = [])
    mock = Object.new
    mock.define_singleton_method(:on_emit) { |**kwargs| emissions << kwargs }
    logger.instance_variable_set(:@telemetry_bridge_logger, mock)
  end
end
