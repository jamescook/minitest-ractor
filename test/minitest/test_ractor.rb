# frozen_string_literal: true

require "test_helper"

class TestRactor < Minitest::Test
  def test_it_has_a_version
    assert_match(/\A\d+\.\d+\.\d+\z/, Minitest::Ractor::VERSION)
  end

  def test_ruby_is_new_enough_to_have_ports
    # Ractor::Port and its one-reader rule are the whole design. Nothing here works without it.
    assert defined?(::Ractor::Port), "this gem needs Ruby 4.x; Ractor::Port is missing"
  end

  def test_a_bare_ractor_inside_the_namespace_is_this_module_not_rubys
    # Pinning the trap documented atop lib/minitest/ractor.rb. If this ever stops being true,
    # the `::Ractor` discipline throughout the gem is no longer needed — and until then, a
    # forgotten `::` fails loudly rather than silently, which is what makes it survivable.
    require "fixtures/lexical_scope_probe"
    probe = Minitest::Ractor::LexicalScopeProbe

    assert_same Minitest::Ractor, probe::BARE_RACTOR
    assert_same ::Ractor, probe::QUALIFIED_RACTOR
  end
end
