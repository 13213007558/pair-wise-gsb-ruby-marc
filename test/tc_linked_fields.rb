require "test/unit"
require "marc"

class TestLinkedFields < Test::Unit::TestCase
  def field(tag, link, *subfields)
    MARC::DataField.new(tag, "0", "0", ["6", link], *subfields)
  end

  def plain(tag, *subfields)
    MARC::DataField.new(tag, "0", "0", *subfields)
  end

  def test_field_link_parses_tag_occurrence_script_and_orientation
    original_link = MARC::FieldLink.parse("880-01")
    alternate_link = MARC::FieldLink.parse("245-01/(3/r")

    assert_equal("880", original_link.tag)
    assert_equal("01", original_link.occurrence)
    assert_nil(original_link.script)
    assert_equal(false, original_link.right_to_left?)

    assert_equal("245", alternate_link.tag)
    assert_equal("(3", alternate_link.script)
    assert_equal(true, alternate_link.right_to_left?)
    assert_equal("245-01/(3/r", alternate_link.to_s)
    assert_nil(MARC::FieldLink.parse("245-00"))
    rtl_without_script = MARC::FieldLink.parse("245-01//r")
    assert_nil(rtl_without_script.script)
    assert_equal(true, rtl_without_script.right_to_left?)
    assert_raise(MARC::Exception) { MARC::FieldLink.new("245", 1, "a/b") }
  end

  def test_same_tag_fields_with_different_occurrences_remain_separate_groups
    record = MARC::Record.new
    record.append(field("245", "880-01", ["a", "First title"]))
    record.append(field("880", "245-01/Arab/r", ["a", "العنوان الأول"]))
    record.append(field("245", "880-02", ["a", "Second title"]))
    record.append(field("880", "245-02/Arab/r", ["a", "العنوان الثاني"]))

    groups = record.linked_field_groups
    assert_equal([["245", "01"], ["245", "02"]], groups.map(&:key))
    assert_equal(["First title", "Second title"], groups.map { |group| group.original["a"] })
    alternate_titles = groups.map { |group| group.alternate["a"] }
    assert_equal(["العنوان الأول", "العنوان الثاني"], alternate_titles)
  end

  def test_unpaired_groups_are_valid
    record = MARC::Record.new
    record.append(field("245", "880-01", ["a", "Only original"]))
    record.append(field("880", "250-02", ["a", "Only alternate"]))

    groups = record.linked_field_groups
    assert_predicate(groups, :valid?)
    assert(groups.all?(&:unpaired?))
    assert_nil(groups[0].alternate)
    assert_nil(groups[1].original)
  end

  def test_duplicate_occurrence_is_distinct_from_one_to_many
    duplicate = MARC::Record.new
    duplicate.append(field("245", "880-01", ["a", "Title"]))
    duplicate.append(field("246", "880-01", ["a", "Variant"]))
    duplicate_groups = duplicate.linked_field_groups
    assert_not_predicate(duplicate_groups, :valid?)
    assert(duplicate_groups.errors.any? { |error| error.is_a?(MARC::DuplicateOccurrenceNumberException) })
    assert(duplicate_groups.errors.none? { |error| error.is_a?(MARC::OneToManyLinkedFieldException) })

    one_to_many = MARC::Record.new
    one_to_many.append(field("245", "880-01", ["a", "Title"]))
    one_to_many.append(field("880", "245-01", ["a", "First alternate"]))
    one_to_many.append(field("880", "245-01", ["a", "Second alternate"]))
    one_to_many_groups = one_to_many.linked_field_groups
    assert(one_to_many_groups.errors.any? { |error| error.is_a?(MARC::OneToManyLinkedFieldException) })
  end

  def test_880_without_link_is_invalid
    record = MARC::Record.new
    record.append(plain("880", ["a", "Missing link"]))

    groups = record.linked_field_groups
    assert_empty(groups)
    assert_kind_of(MARC::InvalidLinkedFieldException, groups.errors.first)
  end

  def test_append_delete_reuse_and_marc_roundtrip
    record = MARC::Record.new
    first = record.append_linked_field_group(
      plain("245", ["a", "First title"], ["b", "First statement"]),
      plain("880", ["a", "العنوان الأول"], ["b", "بيان المسؤولية الأول"]),
      script: "(3", right_to_left: true
    )
    second = record.append_linked_field_group(
      plain("245", ["a", "Second title"], ["b", "Second statement"]),
      plain("880", ["a", "العنوان الثاني"], ["b", "بيان المسؤولية الثاني"]),
      script: "(3", right_to_left: true
    )

    assert_equal(["245", "01"], first.key)
    assert_equal(["245", "02"], second.key)
    assert_equal(["880-01", "245-01/(3/r", "880-02", "245-02/(3/r"], record.fields.map { |f| f["6"] })

    record.delete_linked_field_group!(first)
    replacement = record.append_linked_field_group(
      plain("245", ["a", "Third title"]),
      plain("880", ["a", "العنوان الثالث"]),
      script: "(3", right_to_left: true
    )

    assert_equal(["245", "01"], replacement.key)
    assert_equal(["245", "02"], second.key)
    assert_equal(["880-02", "245-02/(3/r", "880-01", "245-01/(3/r"], record.fields.map { |f| f["6"] })

    read_back = MARC::Record.new_from_marc(record.to_marc)
    assert_equal("Second title", read_back.linked_field_groups["245", "02"].original["a"])
    assert_equal("Third title", read_back.linked_field_groups["245", "01"].original["a"])
  end

  def test_append_can_use_an_explicit_occurrence
    record = MARC::Record.new
    group = record.append_linked_field_group(
      plain("245", ["a", "Title"]),
      plain("880", ["a", "العنوان"]),
      occurrence: 42,
      script: "(3", right_to_left: true
    )

    assert_equal("42", group.occurrence)
    assert_equal("880-42", record.fields[0]["6"])
    assert_equal("245-42/(3/r", record.fields[1]["6"])

    assert_raise(MARC::DuplicateOccurrenceNumberException) do
      record.append_linked_field_group(
        plain("246", ["a", "Variant"]),
        plain("880", ["a", "البديل"]),
        occurrence: 42
      )
    end
    assert_equal(2, record.fields.length)
  end

  def test_failed_append_does_not_modify_record_or_supplied_fields
    record = MARC::Record.new
    record.append(plain("880", ["a", "Missing link"]))
    original = plain("245", ["a", "Title"])
    alternate = plain("880", ["a", "Alternate"])

    assert_raise(MARC::InvalidLinkedFieldException) do
      record.append_linked_field_group(original, alternate)
    end
    assert_equal(["880"], record.fields.map(&:tag))
    assert_nil(original.link_subfield)
    assert_nil(alternate.link_subfield)
  end

  def test_renumber_densifies_groups_and_preserves_orders
    record = MARC::Record.new
    record.append(field("245", "880-03", ["a", "Late title"], ["b", "Late statement"]))
    record.append(field("880", "245-03/Arab/r", ["a", "عنوان متأخر"]))
    record.append(field("250", "880-01", ["a", "Edition"]))
    record.append(field("880", "250-01/Arab/r", ["a", "طبعة"]))

    groups = record.renumber_linked_field_groups!
    assert_equal([["245", "01"], ["250", "02"]], groups.map(&:key))
    assert_equal(["245", "880", "250", "880"], record.fields.map(&:tag))
    assert_equal(["880-01", "245-01/Arab/r", "880-02", "250-02/Arab/r"], record.fields.map { |f| f["6"] })
    assert_equal(["6", "a", "b"], record.fields.first.subfields.map(&:code))
  end

  def test_ambiguous_group_is_not_renumbered
    record = MARC::Record.new
    record.append(plain("245", ["6", "880-01"], ["a", "Title"]))
    record.append(field("880", "245-01", ["a", "First"]))
    record.append(field("880", "245-01", ["a", "Second"]))

    assert_raise(MARC::OneToManyLinkedFieldException) do
      record.renumber_linked_field_groups!
    end
    assert_equal("245-01", record.fields[1]["6"])
    assert_equal("245-01", record.fields[2]["6"])
  end
end
