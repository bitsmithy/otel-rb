# frozen_string_literal: true

module Telemetry
  class ConfigurationError < StandardError; end

  class NotSetupError < StandardError
    def initialize(method_name)
      super("Telemetry.#{method_name} called before Telemetry.setup — call Telemetry.setup first")
    end
  end
end
