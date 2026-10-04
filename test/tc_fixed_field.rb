require "test/unit"
require "marc"

class TestFixedField < Test::Unit::TestCase
  BOOK_LEADER = "00000cam a2200000 a 4500".freeze
  SERIAL_LEADER = "00000cas a2200000 a 4500".freeze
  MAP_LEADER = "00000cem a2200000 a 4500".freeze

  def make_record(leader, value)
    record = MARC::Record.new
    record.leader = leader
    record << MARC::ControlField.new("008", value)
    record
  end

  def fixed_value
    value = " " * 40
    value[0..5] = "000107"
    yield value
    value
  end

  def test_same_position_has_different_semantics_by_record_type
    value = fixed_value do |field|
      field[6] = "s"
      field[7..14] = "2000    "
      field[15..17] = "nyu"
      field[35..37] = "eng"
    end
    book = make_record(BOOK_LEADER, value).fixed_field
    serial = make_record(SERIAL_LEADER, value).fixed_field

    assert_equal(:book, book.layout.key)
    assert_equal(:serial, serial.layout.key)
    assert_equal("s", book[:date_type])
    assert_equal("日期类型", book.fetch("日期类型")[:label])
    assert_equal("s", serial[:publication_status])
    assert_equal("s", serial.fetch("出版状态")[:value])
    assert_equal(:unknown_encoding, serial.fetch(:publication_status)[:state])
  end

  def test_position_18_is_type_specific
    value = fixed_value do |field|
      field[6] = "s"
      field[7..14] = "2000    "
      field[15..17] = "nyu"
      field[18] = "q"
      field[35..37] = "eng"
    end
    book = make_record(BOOK_LEADER, value).fixed_field
    serial = make_record(SERIAL_LEADER, value).fixed_field

    assert_equal(:illustrations, book.name_at(18))
    assert_equal("q   ", book[:illustrations])
    assert_equal(:frequency, serial.name_at(18))
    assert_equal("q", serial[:frequency])
    assert_equal(18, book.offset_of(:illustrations))
    assert_equal(18, serial.offset_of(:frequency))
    assert_equal(18...22, book.range_for(:illustrations))
    assert_equal(18...19, serial.range_for(:frequency))
  end

  def test_bidirectional_offset_and_name_lookup
    value = " " * 40
    value[0..5] = "820107"
    value[6] = "q"
    value[7..14] = "19821980"
    value[15..17] = "dca"
    value[22..23] = "aa"
    value[35..37] = "eng"
    view = make_record(MAP_LEADER, value).fixed_field

    assert_equal(6, view.offset_of("日期类型"))
    assert_equal(:projection, view.name_at(22))
    assert_equal(22...24, view.range_for("投影法"))
  end

  def test_editing_validates_enum_width_and_linked_dates
    value = fixed_value do |field|
      field[6] = "i"
      field[7..14] = "20001999"
      field[15..17] = "nyu"
      field[35..37] = "eng"
    end
    view = make_record(BOOK_LEADER, value).fixed_field

    assert_raise_kind_of(MARC::FixedField::ValidationError) do
      view.set(:date_type, "z")
    end
    assert_raise_kind_of(MARC::FixedField::ValidationError) do
      view.set(:language, "xx")
    end
    assert_raise_kind_of(MARC::FixedField::ValidationError) do
      view.update(date_type: "i", date1: "2000", date2: "1999")
    end
  end

  def test_serial_publication_status_date_range_consistency
    value = fixed_value do |field|
      field[6] = "d"
      field[7..14] = "20001999"
      field[15..17] = "nyu"
      field[35..37] = "eng"
    end
    view = make_record(SERIAL_LEADER, value).fixed_field

    assert_equal("d", view[:publication_status])
    error = assert_raise_kind_of(MARC::FixedField::ValidationError) do
      view.update(publication_status: "d", date1: "2000", date2: "1999")
    end
    assert_match(/日期 1 cannot be later than 日期 2/, error.message)
  end

  def test_spaces_fill_characters_and_untouched_unknown_bytes_are_preserved
    value = fixed_value do |field|
      field[6] = "z"
      field[7..14] = "2000    "
      field[15..17] = "nyu"
      field[23] = "|"
      field[35..37] = "eng"
    end
    record = make_record(BOOK_LEADER, value)
    view = record.fixed_field

    assert_equal(:unknown_encoding, view.fetch(:date_type)[:state])
    assert_equal(:fill_character, view.fetch(:form_of_item)[:state])
    assert_equal(:blank, view.fetch(:audience_level)[:state])
    assert(view.errors.any? { |message| message.include?('日期类型 has unknown encoding "z"') })

    view.set(:language, "fre")

    assert_equal("fre", record["008"].value[35..37])
    assert_equal("z", record["008"].value[6])
    assert_equal("|", record["008"].value[23])
  end

  def test_record_type_change_requires_explicit_migration_rule
    value = fixed_value do |field|
      field[6] = "s"
      field[7..14] = "2000    "
      field[15..17] = "nyu"
      field[35..37] = "eng"
    end
    record = make_record(BOOK_LEADER, value)

    record.leader = SERIAL_LEADER
    assert(record.pending_fixed_field_migration?)
    assert_raise_kind_of(MARC::FixedField::PendingMigration) { record.fixed_field }

    migrated = record.migrate_fixed_field(to: :serial, rule: :preserve_common)

    assert_equal(false, record.pending_fixed_field_migration?)
    assert_equal(:serial, migrated.layout.key)
    assert_equal("000107", migrated[:date_entered])
    assert_equal(" ", migrated[:publication_status])
    assert_equal("2000", migrated[:date1])
    assert_equal("    ", migrated[:date2])
    assert_equal("nyu", migrated[:place])
    assert_equal("eng", migrated[:language])
    assert_equal(" ", migrated[:frequency])
  end

  def test_existing_view_rejects_writes_after_direct_leader_byte_change
    value = fixed_value do |field|
      field[6] = "s"
      field[7..14] = "2000    "
      field[15..17] = "nyu"
      field[35..37] = "eng"
    end
    record = make_record(BOOK_LEADER, value)
    view = record.fixed_field

    changed_leader = record.leader.dup
    changed_leader[6] = "e"
    record.leader = changed_leader

    assert_raise_kind_of(MARC::FixedField::PendingMigration) do
      view.set(:language, "fre")
    end
    assert_equal("eng", record["008"].value[35..37])
  end

  def test_custom_declared_layout_validates_declared_fields
    layout = MARC::FixedField::Layout.define(
      :custom_book,
      label: "自定义图书",
      record_types: ["a"],
      default_record_type: "a",
      default_bibliographic_level: "m"
    ) do
      field :entry, 0, 1, label: "类型",
        codes: { "a" => "图书", "t" => "手稿" }
      field :code, 1, 1, label: "代码",
        codes: { "x" => "有效" }
      field :rest, 2, 38
      linked_validator(:entry, :code) do |entry, code|
        "自定义联动字段无效" if entry == "t" && code == "x"
      end
    end
    current = make_record(BOOK_LEADER, "ax" + (" " * 38))
    view = current.fixed_field("008", layout: layout)

    assert_equal("ax" + (" " * 38), view.raw)
    assert_equal(:entry, view.name_at(0))
    assert_equal(0, view.offset_of("类型"))
    assert_raise_kind_of(MARC::FixedField::ValidationError) { view.set(:code, "z") }
    assert_raise_kind_of(MARC::FixedField::ValidationError) do
      view.update(entry: "t", code: "x")
    end
  end

  def test_blank_and_callable_migration_rules
    value = fixed_value do |field|
      field[6] = "s"
      field[7..14] = "2000    "
      field[15..17] = "nyu"
      field[35..37] = "eng"
    end
    record = make_record(BOOK_LEADER, value)
    record.leader = SERIAL_LEADER

    migrated = record.migrate_fixed_field(to: :serial, rule: :blank)
    assert_equal(" " * 40, migrated.raw)

    record.leader = MAP_LEADER
    mapped = record.migrate_fixed_field(to: :map) do |_source, _target, _record|
      value = " " * 40
      value[0..5] = "000203"
      value[6] = "e"
      value[7..14] = "20012001"
      value[35..37] = "eng"
      value
    end

    assert_equal(:map, mapped.layout.key)
    assert_equal("e", mapped[:date_type])
    assert_equal("2001", mapped[:date1])
    assert_equal("2001", mapped[:date2])
  end
end
