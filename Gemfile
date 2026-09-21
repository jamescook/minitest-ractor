# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "benchmark-ips", "~> 2.15" # benchmark/

# The specimen for :unsafe_method. Fiddle is one of the few stdlib extensions that still refuses
# a worker, and it is a bundled gem, so `bundle exec` hides it unless it is named here. Not a
# dependency of the gem itself — nothing in lib/ requires it.
gem "fiddle"
gem "rake", "~> 13.0"
gem "rubocop", "~> 1.91" # 1.91 accepts TargetRubyVersion 4.0 and 4.1
gem "rubocop-minitest", "~> 0.38"
gem "rubocop-performance", "~> 1.26"
