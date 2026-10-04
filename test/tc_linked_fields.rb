require "test/unit"
require "marc"

class TestFieldLink < Test::Unit::TestCase
  def test_parse_full_link
    link = MARC::FieldLink.parse("245-03/$1/r")
    assert_equal("245", link.tag)
    assert_equal(3, link.occurrence)
    assert_equal("$1", link.script)
    assert_equal("/r", link.direction)
    assert_equal("245-03/$1/r", link.to_s)
  end

  def test_parse_forms
    assert_equal("880-02", MARC::FieldLink.parse("880-02").to_s)
    assert_equal("245-01/(3/r/", MARC::FieldLink.parse("245-01/(3/r/").to_s)
  end

  def test_parse_rejects_bad_values
    assert_raise(MARC::LinkException) { MARC::FieldLink.parse("245-1") }
    assert_raise(MARC::LinkException) { MARC::FieldLink.parse("24-01") }
    assert_raise(MARC::LinkException) { MARC::FieldLink.parse("245-01/abc") }
    assert_raise(MARC::LinkException) { MARC::FieldLink.parse("245-01/x") }
    assert_raise(MARC::LinkException) { MARC::FieldLink.parse("245-00") }
    assert_raise(MARC::LinkException) { MARC::FieldLink.parse("245-01/") }
  end

  def test_with
    link = MARC::FieldLink.parse("245-01/$1")
    assert_equal("880-01/$1", link.with(tag: "880").to_s)
    assert_equal("245-02/$1", link.with(occurrence: 2).to_s)
    assert_equal("245-01", link.with(script: nil).to_s)
  end
end

class TestLinkedFields < Test::Unit::TestCase
  def two_title_record
    r = MARC::Record.new
    g1 = r.append_field_link(
      MARC::DataField.new("245", "1", "0", ["a", "First title"], ["c", "2024"]),
      MARC::DataField.new("880", "1", "0", ["a", "第一标题"], ["c", "2024"]),
      script: "$1"
    )
    g2 = r.append_field_link(
      MARC::DataField.new("245", "1", "0", ["a", "Second title"]),
      MARC::DataField.new("880", "1", "0", ["a", "第二标题"]),
      script: "$1"
    )
    [r, g1, g2]
  end

  def test_append_creates_distinct_groups_per_occurrence
    r, g1, g2 = two_title_record
    assert_equal(["245", 1], [g1.tag, g1.occurrence])
    assert_equal(["245", 2], [g2.tag, g2.occurrence])
    groups = r.field_link_groups
    assert_equal(2, groups.length)
    assert(groups.all?(&:paired?))
    # the two same-tag fields are not bound into one group
    assert_equal(1, groups.count { |g| g.tag == "245" && g.field["a"] == "First title" })
    assert_equal(1, groups.count { |g| g.tag == "245" && g.field["a"] == "Second title" })
  end

  def test_append_writes_matching_six_values
    r, = two_title_record
    tags = r.fields.map(&:tag)
    assert_equal(%w[245 880 245 880], tags)
    first_245 = r.fields("245").first
    first_880 = r.fields("880").first
    assert_equal("880-01/$1", first_245["6"])
    assert_equal("245-01/$1", first_880["6"])
    # $6 becomes the first subfield; others keep their order
    assert_equal(%w[6 a c], first_245.codes(false))
  end

  def test_lookup_by_tag_occurrence_and_by_field
    r, g1, _g2 = two_title_record
    found = r.field_link_group("245", 1)
    assert_same(g1.field, found.field)
    by_field = r.field_link_group(r.fields("880").last)
    assert_equal(["245", 2], by_field.key)
    assert_nil(r.field_link_group("245", 9))
  end

  def test_legal_unpaired_original
    r, = two_title_record
    r.append_field_link(MARC::DataField.new("246", "1", " ", ["a", "No alt yet"]))
    group = r.field_link_group("246", 1)
    assert(group.missing_alternate?)
    assert_not_predicate(group, :paired?)
    assert_equal(["246"], r.unpaired_link_fields.map(&:tag))
  end

  def test_legal_dangling_880
    r, = two_title_record
    dangling = MARC::DataField.new("880", "1", "0", ["6", "500-07"], ["a", "note alt"])
    r << dangling
    group = r.field_link_group("500", 7)
    assert_nil(group.field)
    assert_same(dangling, group.alternate)
    assert(group.missing_original?)
    assert_equal(3, r.field_link_groups.length)
  end

  def test_duplicate_occurrence_aborts_renumber_without_mutation
    r, = two_title_record
    # a good group with a gap, which renumbering would compact if it ran
    r << MARC::DataField.new("500", " ", " ", ["6", "880-05"], ["a", "note"])
    r << MARC::DataField.new("880", " ", " ", ["6", "500-05"], ["a", "alt note"])
    extra = MARC::DataField.new("245", "1", "0", ["6", "880-01"], ["a", "clone"])
    clone_880 = MARC::DataField.new("880", "1", "0", ["6", "245-01"], ["a", "alt clone"])
    r << extra
    r << clone_880
    assert_raise(MARC::DuplicateLinkException) { r.renumber_field_links() }
    # the untouched good group kept its gap and original $6 values
    assert_equal("880-05", r.fields("500").first["6"])
    alt_500 = r.fields("880").find { |f| f.link&.tag == "500" }
    assert_equal("500-05", alt_500["6"])
  end

  def test_one_to_many_880_raises
    r = MARC::Record.new
    r << MARC::DataField.new("245", "1", "0", ["6", "880-01"], ["a", "Title"])
    r << MARC::DataField.new("880", "1", "0", ["6", "245-01"], ["a", "alt one"])
    r << MARC::DataField.new("880", "1", "0", ["6", "245-01"], ["a", "alt two"])
    assert_raise(MARC::AmbiguousLinkException) { r.field_link_groups }
  end

  def test_malformed_six_raises
    r = MARC::Record.new
    r << MARC::DataField.new("245", "1", "0", ["6", "880-1"], ["a", "Title"])
    assert_raise(MARC::LinkException) { r.field_link_groups }
  end

  def test_append_checks_before_mutation
    r, = two_title_record
    r << MARC::DataField.new("500", " ", " ", ["6", "880-9"], ["a", "bad link"])
    field = MARC::DataField.new("246", "1", " ", ["a", "x"])
    assert_raise(MARC::LinkException) { r.append_field_link(field) }
    assert_not_include(r.tags, "246")
    # the would-be field is not mutated either
    assert_nil(field["6"])
  end

  def test_delete_group_and_insert_new_roundtrip
    r, g1, g2 = two_title_record
    removed = r.delete_field_link("245", 2)
    assert_same(g2.field, removed.field)
    assert_equal(%w[245 880], r.map(&:tag))

    new_group = r.append_field_link(
      MARC::DataField.new("245", "1", "0", ["a", "Replacement"]),
      MARC::DataField.new("880", "1", "0", ["a", "替换标题"]),
      script: "$1"
    )
    assert_equal(2, new_group.occurrence)

    reloaded = MARC::Record.new_from_marc(r.to_marc)
    groups = reloaded.field_link_groups.sort_by(&:occurrence)
    assert_equal([1, 2], groups.map(&:occurrence))
    # the surviving link still points at its original group's 880
    assert_equal("First title", groups.first.field["a"])
    assert_equal("第一标题", groups.first.alternate["a"])
    assert_equal("880-01/$1", groups.first.field["6"])
    assert_equal("245-01/$1", groups.first.alternate["6"])
    assert_equal("Replacement", groups.last.field["a"])
  end

  def test_delete_one_member_leaves_legal_unpaired
    r, = two_title_record
    r.delete_field_link("245", 1, member: :alternate)
    group = r.field_link_group("245", 1)
    assert_nil(group.alternate)
    assert_equal("880-01/$1", group.field["6"])
    assert_equal(1, r.unpaired_link_fields.length)
  end

  def test_renumber_compacts_per_tag_and_preserves_parts
    r = MARC::Record.new
    r << MARC::DataField.new("245", "1", "0", ["a", "kept"], ["6", "880-01/$1"])
    r << MARC::DataField.new("880", "1", "0", ["6", "245-01/$1/r"], ["a", "保留"])
    r << MARC::DataField.new("245", "1", "0", ["6", "880-03"], ["a", "later"])
    r << MARC::DataField.new("880", "1", "0", ["6", "245-03"], ["a", "后来"])

    mapping = r.renumber_field_links
    assert_equal({1 => 1, 3 => 2}, mapping["245"])
    first = r.fields("245").first
    # $6 keeps its subfield position (not first); script and direction survive
    assert_equal(%w[a 6], first.codes(false))
    assert_equal("880-01/$1", first["6"])
    assert_equal("245-01/$1/r", r.fields("880").first["6"])
    assert_equal("880-02", r.fields("245").last["6"])
    assert_equal("245-02", r.fields("880").last["6"])
    # field order untouched
    assert_equal(%w[245 880 245 880], r.map(&:tag))
  end
end
