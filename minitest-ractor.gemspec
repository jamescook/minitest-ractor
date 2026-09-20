# frozen_string_literal: true

require_relative "lib/minitest/ractor/version"

Gem::Specification.new do |spec|
  spec.name     = "minitest-ractor"
  spec.version  = Minitest::Ractor::VERSION
  spec.authors  = ["James Cook"]
  spec.email    = ["jcook.rubyist@gmail.com"]

  spec.summary  = "Runs Minitest suites in a pool of Ractors, proving the code under test is isolated"
  spec.description = <<~TEXT
    Replaces Minitest's thread-based parallel executor with one backed by Ractors. A Ractor
    may not touch mutable state another Ractor can see, so a suite that runs green under the
    pool is a standing proof that the code those tests reached holds no shared mutable state.
    The point is the isolation proof, not the wall-clock time. Ruby 4.x only.
  TEXT

  spec.homepage = "https://github.com/jamescook/minitest-ractor"
  spec.license  = "MIT"

  # Ruby 4.x only, deliberately. Ractor::Port and its one-reader rule are the whole design;
  # there is no 3.x fallback and there will not be one.
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["source_code_uri"]       = spec.homepage
  spec.metadata["changelog_uri"]         = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.match(%r{^(test|probes|docs|\.github)/}) || f.match(/^\./)
    end
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "minitest", "~> 6.0"
end
