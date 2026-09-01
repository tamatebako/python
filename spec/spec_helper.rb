# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../tools/lib", __dir__))
require "tfs"

SPEC_ROOT = __dir__
SPEC_FIXTURES = File.join(SPEC_ROOT, "fixtures")

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.order = :random
  Kernel.srand(config.seed)
end
