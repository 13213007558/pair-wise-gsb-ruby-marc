require "test/unit"
require "marc"

class QueryTest < Test::Unit::TestCase
  def test_same_field_predicates_do_not_match_across_occurrences
    record = split_editor_author_record
    result = editor_author_query.match(record)

    assert_false(result.match?)
    assert_equal([], result.witnesses)
    assert_equal([], result.positions)
    assert_equal({match: false, bindings: {}, witnesses: []}, result.to_h)
  end

  def test_record_helpers_run_queries_without_hash_conversion
    record = split_editor_author_record

    assert_false(record.query? do
      field("700") { subfield("a", "Author"); subfield("e", "editor") }
    end)
    result = record.query { field("700") { subfield("a", "Author") } }

    assert_true(result.match?)
    assert_equal(0, result.field_witnesses.first.field_index)
  end

  def test_same_field_predicates_bind_one_occurrence_and_positions
    record = MARC::Record.new
    record.append(MARC::DataField.new("700", "1", "2",
      ["a", "Author"], ["e", "editor"], ["a", "Other"]))

    result = editor_author_query.match(record)

    assert_true(result.match?)
    assert_equal([0], result.field_witnesses.map(&:field_index))
    assert_equal("700", result.field_witnesses.first.tag)
    assert_equal("1", result.field_witnesses.first.indicator1)
    assert_equal("2", result.field_witnesses.first.indicator2)
    assert_equal([[0, "a"], [1, "e"]],
      result.subfield_witnesses.map { |witness| [witness.subfield_index, witness.code] })
    assert_equal([
      {type: :field, field_index: 0, tag: "700"},
      {type: :subfield, field_index: 0, subfield_index: 0, code: "a", value: "Author"},
      {type: :subfield, field_index: 0, subfield_index: 1, code: "e", value: "editor"}
    ], result.positions)
  end

  def test_linked_fields_match_by_shared_field_link_group
    result = linked_group_query.match(linked_group_record)

    assert_true(result.match?)
    assert_equal([0, 1], result.field_witnesses.map(&:field_index))
    assert_equal("1", result.value(:group))
    assert_equal([[0, "8"], [0, "a"], [1, "8"], [1, "e"]],
      result.subfield_witnesses.map { |witness| [witness.field_index, witness.code] })
  end

  def test_linked_fields_do_not_match_another_group
    record = linked_group_record
    record.fields("880").first.subfields.first.value = "2"

    assert_false(linked_group_query.match?(record))
  end

  def test_or_not_and_quantifiers_respect_their_binding_layer
    record = split_editor_author_record
    record.append(MARC::DataField.new("880", "0", " ", ["a", "alternative"]))

    query = MARC::Query.build do
      count_fields("700", 2)
      any do
        field("700") { subfield("e", "editor") }
        field("880") { indicator1("0") }
      end
      not_ { field("999") }
    end

    result = query.match(record)
    assert_true(result.match?)
    count = result.witnesses.grep(MARC::Query::CountWitness).first
    assert_equal(2, count.count)
    assert_equal([0, 1], count.witnesses.map(&:field_index))
  end

  def test_field_local_not_stays_inside_its_field
    record = MARC::Record.new
    record.append(MARC::DataField.new("700", " ", " ", ["a", "Author"], ["e", "editor"]))
    record.append(MARC::DataField.new("700", " ", " ", ["x", "unrelated"]))

    result = MARC::Query.match?(record) do
      field("700") do
        subfield("a", "Author")
        subfield("e", "editor")
        not_ { subfield("x") }
      end
    end

    assert_true(result)
  end

  def test_repeated_subfields_are_counted_by_position
    record = MARC::Record.new
    record.append(MARC::DataField.new("500", " ", " ",
      ["a", "first"], ["a", "second"]))

    result = MARC::Query.match(record) do
      field("500") { count_subfields("a", 2) }
    end

    assert_true(result.match?)
    count = result.witnesses.grep(MARC::Query::CountWitness).first
    assert_equal([0, 1], count.witnesses.map(&:subfield_index))
  end

  def test_values_can_bind_one_field_and_relate_another
    record = MARC::Record.new
    record.append(MARC::DataField.new("700", " ", " ",
      ["8", "10"], ["a", "Author"]))
    record.append(MARC::DataField.new("880", " ", " ",
      ["8", "10"], ["e", "editor"]))

    query = MARC::Query.build do
      field("700", as: :main) do
        subfield("8", true, as: :link_value)
        subfield("a", "Author")
      end
      field("880", different_from: :main) do
        subfield("8", bind(:link_value))
        subfield("e", "editor")
      end
    end

    result = query.match(record)
    assert_true(result.match?)
    assert_equal("10", result.value(:link_value))
    assert_equal(0, result.field_index(:main))
  end

  def test_bindings_from_an_or_branch_are_available_later
    record = MARC::Record.new
    record.append(MARC::DataField.new("700", " ", " ", ["a", "Author"], ["e", "editor"]))

    query = MARC::Query.build do
      any do
        field("700", as: :person) { subfield("e", "editor") }
      end
      field("700", different_from: :person) do
        subfield("a", "Other Author")
      end
    end

    assert_false(query.match?(record))
    record.append(MARC::DataField.new("700", " ", " ", ["a", "Other Author"]))
    result = query.match(record)
    assert_true(result.match?)
    assert_equal([0, 1], result.field_witnesses.map(&:field_index))
  end

  def test_query_does_not_convert_record_to_hash
    record = Object.new
    def record.fields
      [MARC::DataField.new("700", " ", " ", ["a", "Author"], ["e", "editor"]), 0]
    end

    def record.to_hash
      raise "queries must not flatten MARC records to hashes"
    end

    assert_true(editor_author_query.match?(record))
  end

  private

  def split_editor_author_record
    record = MARC::Record.new
    record.append(MARC::DataField.new("700", " ", " ", ["a", "Author"]))
    record.append(MARC::DataField.new("700", " ", " ", ["e", "editor"]))
    record
  end

  def linked_group_record
    record = MARC::Record.new
    record.append(MARC::DataField.new("700", " ", " ",
      ["8", "1"], ["a", "Author"]))
    record.append(MARC::DataField.new("880", " ", " ",
      ["8", "1"], ["e", "editor"]))
    record.append(MARC::DataField.new("880", " ", " ",
      ["8", "2"], ["e", "editor"]))
    record
  end

  def editor_author_query
    MARC::Query.build do
      field("700") do
        subfield("e", "editor")
        subfield("a", "Author")
      end
    end
  end

  def linked_group_query
    MARC::Query.build do
      field("700", as: :main, link: :group) do
        subfield("a", "Author")
      end
      field("880", link: :group) do
        linked_to(:main)
        subfield("e", "editor")
      end
    end
  end
end
