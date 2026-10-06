require "test/unit"
require "marc"

class TestQuery < Test::Unit::TestCase
  def build_record(fields)
    record = MARC::Record.new
    fields.each { |field| record.append(field) }
    record
  end

  # Two 700 fields, each satisfying only half of the condition:
  # the first has the author, the second has the editor role.
  def split_record
    build_record([
      MARC::DataField.new("700", "1", " ", ["a", "Twain, Mark"], ["e", "author"]),
      MARC::DataField.new("700", "1", " ", ["a", "Smith, John"], ["e", "editor"])
    ])
  end

  def test_same_field_constraints_are_not_split_across_occurrences
    query = MARC::Query.field("700") do |f|
      f.all(
        f.subfield("a").value(/Twain/),
        f.subfield("e").value("editor")
      )
    end
    result = query.run(split_record)
    assert_false(result.success?)
    assert_false(query.matches?(split_record))
  end

  def test_failed_result_carries_no_witnesses
    query = MARC::Query.field("700", as: :ed) do |f|
      f.all(
        f.subfield("a").value(/Twain/),
        f.subfield("e").value("editor")
      )
    end
    result = query.run(split_record)
    assert_false(result.success?)
    assert_empty(result.witnesses)
    assert_empty(result.bindings)
    assert_empty(result.values)
  end

  def test_same_field_constraints_match_a_single_occurrence
    query = MARC::Query.field("700", as: :ed) do |f|
      f.all(
        f.subfield("a").value(/Smith/),
        f.subfield("e").value("editor")
      )
    end
    result = query.run(split_record)
    assert(result.success?)
    binding = result.bindings[:ed]
    assert_equal("700", binding.tag)
    assert_equal(1, binding.index)
    assert_equal("Smith, John", binding.field["a"])
  end

  def test_cross_field_existential_constraints_may_use_two_occurrences
    query = MARC::Query.all(
      MARC::Query.field("700") { |f| f.subfield("a").value(/Twain/) },
      MARC::Query.field("700") { |f| f.subfield("e").value("editor") }
    )
    assert(query.matches?(split_record))
  end

  def test_or_at_record_level
    query = MARC::Query.any(
      MARC::Query.field("700") { |f| f.subfield("e").value("translator") },
      MARC::Query.field("700") { |f| f.subfield("e").value("editor") }
    )
    assert(query.matches?(split_record))
  end

  def test_or_inside_field_scope
    query = MARC::Query.field("700") do |f|
      f.any(
        f.subfield("e").value("translator"),
        f.subfield("e").value("editor")
      )
    end
    assert(query.matches?(split_record))
  end
  def test_not_inside_field_scope_applies_to_that_occurrence
    # an occurrence that has a role subfield which is not "editor"
    query = MARC::Query.field("700", as: :f) do |f|
      f.all(
        f.subfield("e").exists,
        f.not(f.subfield("e").value("editor"))
      )
    end
    result = query.run(split_record)
    assert(result.success?)
    assert_equal("Twain, Mark", result.bindings[:f].field["a"])
  end

  def test_not_at_record_level_negates_existence
    query = MARC::Query.not(
      MARC::Query.field("700") { |f| f.subfield("e").value("editor") }
    )
    assert_false(query.matches?(split_record))
    without_editor = build_record([
      MARC::DataField.new("700", "1", " ", ["a", "Twain, Mark"], ["e", "author"])
    ])
    assert(query.matches?(without_editor))
  end

  def test_record_level_none_alias
    query = MARC::Query.none(MARC::Query.field("041"))
    assert(query.matches?(split_record))
  end

  def test_field_occurrence_count
    assert(MARC::Query.count("700", exactly: 2).matches?(split_record))
    assert_false(MARC::Query.count("700", exactly: 3).matches?(split_record))
    assert(MARC::Query.count("700", at_least: 1, at_most: 2).matches?(split_record))
    assert_false(MARC::Query.count("700", at_least: 3).matches?(split_record))
  end

  def test_count_with_constraint_reports_matching_witnesses
    query = MARC::Query.count("700", exactly: 1) do |f|
      f.subfield("e").value("editor")
    end
    result = query.run(split_record)
    assert(result.success?)
    assert_equal(1, result.witnesses.length)
    assert_equal("Smith, John", result.witnesses.first.field["a"])
  end

  def test_repeated_subfield_count_within_one_field
    record = build_record([
      MARC::DataField.new("700", "1", " ",
        ["a", "Twain, Mark"], ["e", "author"], ["e", "editor"])
    ])
    query = MARC::Query.field("700") { |f| f.subfield("e").count(exactly: 2) }
    assert(query.matches?(record))
    assert_false(MARC::Query.field("700") { |f|
      f.subfield("e").count(exactly: 3)
    }.matches?(record))
  end

  def test_indicator_constraints
    record = build_record([
      MARC::DataField.new("700", "0", " ", ["a", "Twain, Mark"]),
      MARC::DataField.new("700", "1", " ", ["a", "Smith, John"])
    ])
    query = MARC::Query.field("700", indicator1: "1", as: :f)
    result = query.run(record)
    assert(result.success?)
    assert_equal("Smith, John", result.bindings[:f].field["a"])

    scoped = MARC::Query.field("700") do |f|
      f.all(f.indicator1("0"), f.indicator2(" "), f.subfield("a").exists)
    end
    assert(scoped.matches?(record))
  end

  def test_tag_as_regexp_and_control_fields_are_skipped_for_subfields
    record = build_record([
      MARC::ControlField.new("008", "860210s1985    xxu           000 0 eng d"),
      MARC::DataField.new("700", "1", " ", ["a", "Twain, Mark"])
    ])
    query = MARC::Query.field(/7../) { |f| f.subfield("a").value(/Twain/) }
    assert(query.matches?(record))
    any_tag = MARC::Query.field { |f| f.subfield("a").value(/Twain/) }
    assert(any_tag.matches?(record))
  end
  # Field groups linked through a shared subfield 8 value: the value
  # captured from one field constrains the other field.
  def linked_record
    build_record([
      MARC::DataField.new("700", "1", " ", ["8", "1"], ["a", "Twain, Mark"]),
      MARC::DataField.new("880", "1", " ", ["8", "1"], ["a", "马克·吐温"])
    ])
  end

  def linkage_query
    MARC::Query.all(
      MARC::Query.field("700", as: :main) { |f| f.subfield("8").bind(as: :link) },
      MARC::Query.field("880", as: :alt) do |f|
        f.subfield("8").value(MARC::Query.ref(:link))
      end
    )
  end

  def test_fields_linked_through_subfield_8
    result = linkage_query.run(linked_record)
    assert(result.success?)
    assert_equal("1", result.values[:link])
    assert_equal("700", result.bindings[:main].tag)
    assert_equal("880", result.bindings[:alt].tag)
    assert_equal("马克·吐温", result.bindings[:alt].field["a"])
  end

  def test_linkage_fails_when_subfield_8_values_differ
    record = build_record([
      MARC::DataField.new("700", "1", " ", ["8", "1"], ["a", "Twain, Mark"]),
      MARC::DataField.new("880", "1", " ", ["8", "2"], ["a", "马克·吐温"])
    ])
    result = linkage_query.run(record)
    assert_false(result.success?)
    assert_empty(result.witnesses)
  end

  def test_linkage_backtracks_to_a_matching_occurrence
    # the first 700 has no linked 880, the second one does
    record = build_record([
      MARC::DataField.new("700", "1", " ", ["8", "1"], ["a", "Smith, John"]),
      MARC::DataField.new("700", "1", " ", ["8", "2"], ["a", "Twain, Mark"]),
      MARC::DataField.new("880", "1", " ", ["8", "2"], ["a", "马克·吐温"])
    ])
    result = linkage_query.run(record)
    assert(result.success?)
    assert_equal("2", result.values[:link])
    assert_equal("Twain, Mark", result.bindings[:main].field["a"])
  end

  def test_witnesses_expose_field_and_subfield_positions
    record = build_record([
      MARC::DataField.new("100", "1", " ", ["a", "Header"]),
      MARC::DataField.new("700", "1", " ",
        ["a", "Twain, Mark"], ["e", "author"], ["e", "editor"])
    ])
    query = MARC::Query.field("700", as: :f) do |f|
      f.subfield("e").value("editor")
    end
    result = query.run(record)
    assert(result.success?)
    binding = result.bindings[:f]
    assert_equal(1, binding.index)
    assert_equal(1, binding.subfield_matches.length)
    match = binding.subfield_matches.first
    assert_equal("e", match.code)
    assert_equal(2, match.index)
    assert_equal("editor", match.value)
    assert_same(record.fields[1], binding.field)
  end

  def test_solutions_enumerates_every_occurrence
    query = MARC::Query.field("700")
    assert_equal(2, query.solutions(split_record).count)
  end

  def test_repeated_subfields_are_not_collapsed
    record = build_record([
      MARC::DataField.new("700", "1", " ",
        ["a", "Twain, Mark"], ["e", "author"], ["e", "editor"])
    ])
    query = MARC::Query.field("700") { |f| f.subfield("e").exists }
    solutions = query.solutions(record).to_a
    assert_equal(2, solutions.length)
    values = solutions.map { |s| s.witnesses.first.subfield_matches.first.value }
    assert_equal(["author", "editor"], values)
  end

  def test_custom_predicate
    query = MARC::Query.field("700") do |f|
      f.satisfy { |field| field.subfields.length > 2 }
    end
    record = build_record([
      MARC::DataField.new("700", "1", " ",
        ["a", "Twain, Mark"], ["e", "author"], ["e", "editor"])
    ])
    assert(query.matches?(record))
    assert_false(query.matches?(split_record))
  end
end
