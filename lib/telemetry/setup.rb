# frozen_string_literal: true

require 'opentelemetry-sdk'
require 'opentelemetry-exporter-otlp'
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'

module Telemetry
  module Setup
    def self.call(config)
      resource = build_resource(config)

      # --- Traces ---
      tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(resource: resource)
      unless exporter_none?('OTEL_TRACES_EXPORTER')
        trace_exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(**endpoint_opts(config))
        tracer_provider.add_span_processor(
          OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(trace_exporter)
        )
      end

      # --- Metrics ---
      meter_provider = setup_metrics(config, resource)

      # --- Logs ---
      setup_logs(config, resource)

      # --- Globals ---
      OpenTelemetry.tracer_provider = tracer_provider
      OpenTelemetry.meter_provider  = meter_provider
      OpenTelemetry.propagation     = composite_propagator

      tracer = tracer_provider.tracer(config.service_name, config.service_version)
      meter  = meter_provider.meter(config.service_name, version: config.service_version)

      { shutdown: build_shutdown(tracer_provider, meter_provider), tracer: tracer, meter: meter }
    end

    private_class_method def self.build_resource(config)
      OpenTelemetry::SDK::Resources::Resource.create(
        'service.name' => config.service_name,
        'service.namespace' => config.service_namespace,
        'service.version' => config.service_version
      )
    end

    private_class_method def self.endpoint_opts(config)
      config.endpoint ? { endpoint: config.endpoint } : {}
    end

    private_class_method def self.setup_metrics(config, resource)
      require 'opentelemetry-metrics-sdk'
      require 'opentelemetry/metrics'

      OpenTelemetry::SDK::Metrics::MeterProvider.new(resource: resource).tap do |mp|
        unless exporter_none?('OTEL_METRICS_EXPORTER')
          require 'opentelemetry-exporter-otlp-metrics'
          require 'opentelemetry/exporter/otlp_metrics'
          metric_exporter = OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter.new(**endpoint_opts(config))
          mp.add_metric_reader(
            OpenTelemetry::SDK::Metrics::Export::PeriodicMetricReader.new(exporter: metric_exporter)
          )
        end
      end
    end

    private_class_method def self.setup_logs(config, resource)
      require 'opentelemetry-logs-sdk'
      require 'opentelemetry/logs'

      logger_provider = OpenTelemetry::SDK::Logs::LoggerProvider.new(resource: resource)
      unless exporter_none?('OTEL_LOGS_EXPORTER')
        require 'opentelemetry-exporter-otlp-logs'
        require 'opentelemetry/exporter/otlp_logs'
        log_exporter = OpenTelemetry::Exporter::OTLP::Logs::LogsExporter.new(**endpoint_opts(config))
        logger_provider.add_log_record_processor(
          OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(log_exporter)
        )
      end
      OpenTelemetry.logger_provider = logger_provider
    end

    private_class_method def self.exporter_none?(env_var)
      ENV.fetch(env_var, '').strip.downcase == 'none'
    end

    private_class_method def self.composite_propagator
      OpenTelemetry::Context::Propagation::CompositeTextMapPropagator.compose_propagators(
        [
          OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator,
          OpenTelemetry::Baggage::Propagation::TextMapPropagator.new
        ]
      )
    end

    private_class_method def self.build_shutdown(tracer_provider, meter_provider)
      lambda do
        tracer_provider.shutdown
        meter_provider.shutdown
        OpenTelemetry.logger_provider.shutdown
      end
    end
  end
end
