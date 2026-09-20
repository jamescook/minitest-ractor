# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  # Fixtures are test classes that deliberately hold shared mutable state. They are INPUT to
  # the suite, not part of it — collecting them would make the suite fail at itself.
  t.test_files = FileList["test/**/test_*.rb"].exclude("test/fixtures/**/*")
  t.warning = false # Ractors still print an experimental warning on use
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError
  # rubocop is a development dependency; the suite must still run without it
end

namespace :hooks do
  desc "Point git at .githooks (core.hooksPath is local config, so a fresh clone needs this)"
  task :install do
    sh "git config core.hooksPath .githooks"
    puts "git hooks wired. They reject references to docs/adr/ and to bead ids, neither of"
    puts "which is checked in, so a reference to either dangles for every other reader."
  end
end

task default: :test
