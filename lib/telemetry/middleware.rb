# frozen_string_literal: true

require 'rack'
require 'opentelemetry'

module Telemetry
  class Middleware
    HTTP_SERVER_REQUEST_COUNT    = 'http.server.request.count'
    HTTP_SERVER_REQUEST_DURATION = 'http.server.request.duration'
    HTTP_SERVER_ACTIVE_REQUESTS  = 'http.server.active_requests'

    # Set by Rails router after routing (Rails 7.1+)
    ROUTE_PATTERN_KEY = 'action_dispatch.route_uri_pattern'

    def initialize(app)
      @app = app
      @instruments_initialized = false
    end

    def call(env)
      init_instruments unless @instruments_initialized

      request = Rack::Request.new(env)
      context = OpenTelemetry.propagation.extract(env, getter: rack_getter)

      OpenTelemetry::Context.with_current(context) do
        Telemetry.tracer.in_span("#{request.request_method} #{request.path}", kind: :server) do |span|
          active_requests&.add(1, attributes: { 'http.request.method' => request.request_method })
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          status, headers, body = @app.call(env)

          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          route    = env[ROUTE_PATTERN_KEY] || request.path

          span.name = "#{request.request_method} #{route}"

          span.status = OpenTelemetry::Trace::Status.error("HTTP #{status}") if status >= 500

          span.set_attribute('http.request.method',           request.request_method)
          span.set_attribute('http.route',                    route)
          span.set_attribute('http.response.status_code',     status)
          span.set_attribute('server.address',                request.host)
          span.set_attribute('server.port',                   request.port)

          metric_attrs = {
            'http.request.method' => request.request_method,
            'http.route' => route,
            'http.response.status_code' => status.to_s
          }

          request_count&.add(1, attributes: metric_attrs)
          request_duration&.record(duration, attributes: metric_attrs)
          active_requests&.add(-1, attributes: { 'http.request.method' => request.request_method })

          [status, headers, body]
        end
      end
    end

    private

    def init_instruments
      meter = Telemetry.meter
      if meter
        @request_count    = meter.create_counter(HTTP_SERVER_REQUEST_COUNT,
                                                 unit: '{request}', description: 'Total HTTP server requests')
        @request_duration = meter.create_histogram(HTTP_SERVER_REQUEST_DURATION,
                                                   unit: 's', description: 'HTTP server request duration')
        @active_requests  = meter.create_up_down_counter(HTTP_SERVER_ACTIVE_REQUESTS,
                                                         unit: '{request}', description: 'Active HTTP server requests')
      end
      @instruments_initialized = true
    end

    attr_reader :request_count, :request_duration, :active_requests

    def rack_getter
      OpenTelemetry::Context::Propagation::RackEnvGetter.new
    end
  end
end
