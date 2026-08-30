# frozen_string_literal: true

module Telemetry
  module LoggingAPI
    def log(level, message, **)
      logger.public_send(level, message, **)
    end

    def logger
      raise NotSetupError, :logger unless @logger

      @logger
    end
  end
end
