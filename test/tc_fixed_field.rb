# frozen_string_literal: true

require "test/unit"
require "marc"

class TestFixedField < Test::Unit::TestCase
  RAW_008 = "000107s2000    nyua          001 0 eng  "

  def fixed_record(leader, value = RAW_008)
    record = MARC::Record.new
    record.leader = leader
    record << MARC::ControlField.new("008", value)
    record
  end

  def test_book_layout_and_bidirectional_locations
    view = MARC::FixedField.view(fixed_record("00000nam a22002414a 4500"))

    assert_equal(:marc21_book, view.layout.id)
    assert_equal("s", view[:date_type].raw)
    assert_equal("0", view[:literary_form].raw)
    assert_equal(33, view.offset_of(:literary_form))
    assert_equal(:literary_form, view.name_at(33))
    assert_equal("Single known date", view[:date_type].label)
  end

  def test_same_008_uses_continuing_resource_layout
    view = MARC::FixedField.view(fixed_record("00000nas a22002414a 4500"))

    assert_equal(:marc21_continuing_resource, view.layout.id)
    assert_equal("s", view[:date_type].raw)
    assert_equal("0", view[:title_page].raw)
    assert_equal(33, view.offset_of(:title_page))
    assert_equal(:title_page, view.name_at(33))
  end

  def test_map_layout
    map_record = fixed_record("00000nem a22002414a 4500", "880715q19701979th ab  aae          chi  ")
    view = MARC::FixedField.view(map_record)

    assert_equal(:marc21_map, view.layout.id)
    assert_equal("q", view[:date_type].raw)
    assert_equal("ab  ", view[:relief].raw)
    assert_equal("e", view[:type_of_cartographic_material].raw)
    assert_equal(18, view.offset_of(:relief))
    assert_equal(24, view.offset_of(:type_of_cartographic_material))
    assert_equal(:type_of_cartographic_material, view.name_at(24))
  end

  def test_enum_and_width_validation
    view = MARC::FixedField.view(fixed_record("00000nam a22002414a 4500"))

    assert_raise(MARC::FixedField::View::ValidationError) { view[:date_type] = "Z" }
    assert_raise(MARC::FixedField::View::ValidationError) { view[:date1] = "200" }
  end

  def test_date_type_and_date_range_link_validation
    view = MARC::FixedField.view(fixed_record("00000nas a22002414a 4500"))
    view.update(date_type: "i", date1: "1999", date2: "2000")

    assert_raise(MARC::FixedField::View::ValidationError) do
      view.update(date_type: "i", date1: "1999", date2: "1998")
    end
    view[:date2] = "2000"
    assert_empty(view.errors.grep(/date/))
  end

  def test_single_date_allows_blank_second_date
    view = MARC::FixedField.view(fixed_record("00000nam a22002414a 4500"))
    view[:date1] = "2000"
    view[:date2] = "    "

    assert_empty(view.errors.grep(/date/))
  end

  def test_unknown_bytes_remain_when_unrelated_segment_edited
    value = RAW_008.dup
    value[22] = "Z"
    view = MARC::FixedField.view(fixed_record("00000nam a22002414a 4500", value))

    assert_equal(:unknown, view[:target_audience].state)
    view.update(date_type: "q", date1: "1970", date2: "1979")

    assert_equal("Z", view.field.value[22])
    assert_equal("q", view.field.value[6])
    assert_match(/unknown code "Z"/, view.errors.join("\n"))
  end

  def test_unknown_008_date_code_does_not_change_layout_selection
    value = RAW_008.dup
    value[6] = "Z"
    view = MARC::FixedField.view(fixed_record("00000nam a22002414a 4500", value))

    assert_equal(:marc21_book, view.layout.id)
    assert_equal("Z", view[:date_type].raw)
    assert_equal(:unknown, view[:date_type].state)
    assert_match(/unknown code "Z"/, view.errors.join("\n"))
  end

  def test_spaces_fill_characters_and_unknown_codes_remain_distinct
    view = MARC::FixedField.view(fixed_record("00000nam a22002414a 4500"))
    value = RAW_008.dup
    value[22] = " "
    value[23] = "|"
    value[33] = "Z"
    view.field.value = value

    assert_equal(:blank, view[:target_audience].state)
    assert_equal(:fill, view[:form_of_item].state)
    assert_equal(:unknown, view[:literary_form].state)
    assert(view[:form_of_item].fill?)
    assert(view[:literary_form].unknown?)
  end

  def test_record_type_change_requires_migration_rule
    map_record = fixed_record("00000nam a22002414a 4500")

    assert_raise(ArgumentError) { MARC::FixedField.migrate(map_record, layout: :marc21_map) }
    assert_equal("a", map_record.leader[6])
  end

  def test_explicit_migration_changes_layout_and_rejects_old_layout
    map_record = fixed_record("00000nam a22002414a 4500")
    migrated = MARC::FixedField.migrate(map_record, layout: :marc21_map, rule: :preserve_common)

    assert_equal("e", map_record.leader[6])
    assert_equal(:marc21_map, migrated.layout.id)
    assert_equal("s", migrated[:date_type].raw)
    assert_raise(MARC::FixedField::LayoutMismatch) do
      MARC::FixedField.view(map_record, layout: MARC::FixedField.layout(:marc21_book))
    end
  end

  def test_006_layout_uses_first_type_byte
    fixed_record = MARC::Record.new
    fixed_record.leader = "00000nam a22002414a 4500"
    fixed_record << MARC::ControlField.new("006", "s     b       0   ")
    view = fixed_record.fixed_field("006")

    assert_equal(:marc21_continuing_resource_006, view.layout.id)
    assert_equal("s", view[:type_byte].raw)
    assert_equal("b", view[:form_of_item].raw)
    assert_equal(6, view.offset_of(:form_of_item))
    assert_equal(:form_of_item, view.name_at(6))
  end

  def test_declarative_custom_layout_can_be_registered
    layout = MARC::FixedField::Layout.new(
      id: :custom_book,
      label: "Custom book 008",
      record_types: [{record_type: "a", bibliographic_level: "m"}]
    ) do |declared|
      declared.segment(:date_type, 6, 1, "Date type", MARC::FixedField::DATE_TYPES)
    end
    MARC::FixedField.register_layout(layout)
    begin
      selected = MARC::FixedField.layout(:custom_book)
      view = MARC::FixedField::View.new(MARC::ControlField.new("008", " " * 40), layout: selected)

      assert_equal(layout, selected)
      assert_equal(6, view.offset_of(:date_type))
    ensure
      MARC::FixedField.unregister_layout(:custom_book)
    end
  end

  def test_short_fixed_field_reports_width_and_pads_on_edit
    short_record = fixed_record("00000nam a22002414a 4500", "880715s2000")
    view = MARC::FixedField.view(short_record)

    assert_match(/must be at least 40 characters/, view.errors.join("\n"))
    view[:date_type] = "s"

    assert_equal(40, short_record["008"].value.length)
  end
end
