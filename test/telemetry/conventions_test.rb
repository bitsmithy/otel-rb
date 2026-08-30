# frozen_string_literal: true

require 'digest'
require 'json'
require 'test_helper'

class ConventionsTest < Minitest::Test
  def test_pins_the_shared_contract
    fixture = File.expand_path('../fixtures/telemetry-conventions-v1.0.0.json', __dir__)
    manifest = JSON.parse(File.read(fixture))

    assert_equal ['1.0.0', manifest.fetch('contract_version'), Digest::SHA256.file(fixture).hexdigest],
                 [Telemetry::Conventions::VERSION, Telemetry::Conventions::VERSION, Telemetry::Conventions::SHA256]
  end
end
