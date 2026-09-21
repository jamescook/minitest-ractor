# frozen_string_literal: true

require "test_helper"
require "minitest/ractor/provenance"
require "open3"

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

  MINE = [+"mutable"].freeze

  # WHERE THE THING IS DEFINED, which is not where the refusal was raised. A worker reading
  # RbConfig::CONFIG from your own file is refused AT YOUR LINE, so the frame says the project's
  # and the constant is the standard library's. Advice that goes by the frame tells you to freeze
  # RbConfig's strings on behalf of every other gem in the process.
  def test_it_finds_who_defined_a_named_constant
    assert_equal :project, Provenance.of_constant("TestProvenance::MINE")
    assert_equal :ruby, Provenance.of_constant("RbConfig::CONFIG")
    assert_equal :gem, Provenance.of_constant("Minitest::Runnable")
  end

  # The two answers a frame can never give.
  def test_a_constant_defined_in_c_has_no_file_to_open
    assert_equal :native, Provenance.of_constant("Float::INFINITY")
  end

  def test_a_constant_it_cannot_resolve_is_unknown_and_does_not_raise
    assert_equal :unknown, Provenance.of_constant("No::Such::Thing")
    assert_equal :unknown, Provenance.of_constant("not a constant name")
    assert_equal :unknown, Provenance.of_constant(nil)
  end

  # Globals have no owner to ask about, so this is a measured list. It matters: $LOAD_PATH was
  # the largest single cause in one real suite, and it is not anybody's to delete.
  def test_it_tells_rubys_own_globals_from_the_projects
    assert_equal :ruby, Provenance.of_global("$LOAD_PATH")
    assert_equal :ruby, Provenance.of_global("$stdout")
    assert_equal :project, Provenance.of_global("$my_applications_cache")
  end

  # A hardcoded list of anything rots, and this one would rot silently: a global Ruby added
  # would start being reported as the project's, with advice to delete it. So the list is
  # checked against the thing it was copied from, in a bare process, where every global present
  # is one Ruby itself defined.
  #
  # Also catches the escaping, which is easy to get wrong: "$\" written plainly inside %w[]
  # swallows the following space and produces "$ $_".
  # RUBYOPT has to be cleared as well as gems disabled. Under `bundle exec` it carries
  # -rbundler/setup, and the subprocess then reports $thor_runner and $1 among Ruby's own — which
  # is what this test caught the first time it ran.
  def test_the_list_of_rubys_globals_still_matches_a_bare_ruby
    bare = { "RUBYOPT" => nil, "RUBYLIB" => nil }
    out, status = Open3.capture2 bare, RbConfig.ruby, "--disable-gems", "-e",
                                 "puts global_variables"

    assert_predicate status, :success?
    assert_equal out.split.sort, Provenance::RUBY_GLOBALS.sort
  end
end
