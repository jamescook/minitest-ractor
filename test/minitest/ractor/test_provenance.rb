# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/provenance"

class TestProvenance < Minitest::Test
  Provenance = Minitest::Ractor::Provenance

  GEM_DIR  = "#{Gem.default_dir}/gems/minitest-6.0.6/lib/minitest/test.rb".freeze
  RUBY_DIR = "#{RbConfig::CONFIG['rubylibdir']}/erb.rb".freeze

  def test_a_file_under_the_project_is_the_projects
    assert_equal :project, Provenance.of("#{Dir.pwd}/lib/thing.rb")
    assert_equal :project, Provenance.of(__FILE__)
  end

  def test_a_file_under_a_gem_directory_belongs_to_a_gem
    assert_equal :gem, Provenance.of(GEM_DIR)
  end

  def test_a_file_under_rubys_own_library_belongs_to_ruby
    assert_equal :ruby, Provenance.of(RUBY_DIR)
  end

  # Frames arrive as "path:12:in 'Thing#method'", never as bare paths, so trimming is the
  # first thing this has to get right.
  def test_it_reads_a_backtrace_frame_and_not_only_a_path
    assert_equal :gem, Provenance.of("#{GEM_DIR}:91:in 'block (2 levels) in Minitest::Test#run'")
    assert_equal :project, Provenance.of("#{Dir.pwd}/test/x.rb:3:in 'block in <main>'")
  end

  # A relative frame is what you get from a file loaded by a relative path, which is normal
  # when somebody runs `ruby test/thing_test.rb`.
  def test_a_relative_frame_is_the_projects
    assert_equal :project, Provenance.of("test/thing_test.rb:12:in 'x'")
  end

  def test_it_does_not_fall_over_on_nothing
    assert_equal :unknown, Provenance.of(nil)
    assert_equal :unknown, Provenance.of("")
  end

  # The question the two callers actually ask.
  def test_it_answers_whether_somebody_can_edit_the_file
    assert Provenance.editable?("#{Dir.pwd}/lib/thing.rb")
    refute Provenance.editable?(GEM_DIR)
    refute Provenance.editable?(RUBY_DIR)
  end
end
