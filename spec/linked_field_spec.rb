require "spec_helper"

RSpec.describe "MARC linked fields" do
  def linked_field(tag, link, *subfields)
    MARC::DataField.new(tag, "0", "0", ["6", link], *subfields)
  end

  def plain_field(tag, *subfields)
    MARC::DataField.new(tag, "0", "0", *subfields)
  end

  describe MARC::FieldLink do
    it "parses an original-field link" do
      link = MARC::FieldLink.parse("880-01")
      expect(link.tag).to eq("880")
      expect(link.occurrence).to eq("01")
      expect(link.script).to be_nil
      expect(link.right_to_left?).to eq(false)
      expect(link.to_s).to eq("880-01")
    end

    it "can append an explicitly numbered group" do
      record = MARC::Record.new
      group = record.append_linked_field_group(
        plain_field("245", ["a", "Title"]),
        plain_field("880", ["a", "العنوان"]),
        occurrence: 42,
        script: "(3",
        right_to_left: true
      )

      expect(group.occurrence).to eq("42")
      expect(record.fields[0]["6"]).to eq("880-42")
      expect(record.fields[1]["6"]).to eq("245-42/(3/r")
    end

    it "parses an alternate-field link with script and orientation" do
      link = MARC::FieldLink.parse("245-01/(3/r")
      expect(link.tag).to eq("245")
      expect(link.occurrence).to eq("01")
      expect(link.script).to eq("(3")
      expect(link.right_to_left?).to eq(true)
      expect(link.to_s).to eq("245-01/(3/r")
    end

    it "parses right-to-left orientation without a script code" do
      link = MARC::FieldLink.parse("245-01//r")
      expect(link.script).to be_nil
      expect(link.right_to_left?).to eq(true)
      expect(link.to_s).to eq("245-01//r")
    end

    it "rejects malformed links and occurrence zero" do
      expect(MARC::FieldLink.parse("245-1")).to be_nil
      expect(MARC::FieldLink.parse("245-00")).to be_nil
      expect(MARC::FieldLink.parse("88-01")).to be_nil
      expect(MARC::FieldLink.parse("245-01/" )).to be_nil
      expect(MARC::FieldLink.parse("245-01/x/")).to be_nil
    end
  end

  describe MARC::Record do
    it "groups fields by tag and occurrence without grouping all equal tags" do
      record = MARC::Record.new
      record.append(linked_field("245", "880-01", ["a", "First title"]))
      record.append(linked_field("880", "245-01/Arab/r", ["a", "العنوان الأول"]))
      record.append(linked_field("245", "880-02", ["a", "Second title"]))
      record.append(linked_field("880", "245-02/Arab/r", ["a", "العنوان الثاني"]))

      groups = record.linked_field_groups
      expect(groups.map(&:key)).to eq([["245", "01"], ["245", "02"]])
      expect(groups.map { |group| group.original["a"] })
        .to eq(["First title", "Second title"])
      expect(groups.map { |group| group.alternate["a"] })
        .to eq(["العنوان الأول", "العنوان الثاني"])
    end

    it "treats missing counterparts as valid unpaired groups" do
      record = MARC::Record.new
      record.append(linked_field("245", "880-01", ["a", "Only original"]))
      record.append(linked_field("880", "250-02", ["a", "Only alternate"]))

      groups = record.linked_field_groups
      expect(groups).to be_valid
      expect(groups.map(&:unpaired?)).to eq([true, true])
      expect(groups[0].original["a"]).to eq("Only original")
      expect(groups[0].alternate).to be_nil
      expect(groups[1].original).to be_nil
      expect(groups[1].alternate["a"]).to eq("Only alternate")
    end

    it "reports duplicate occurrence numbers" do
      record = MARC::Record.new
      record.append(linked_field("245", "880-01", ["a", "Title"]))
      record.append(linked_field("246", "880-01", ["a", "Variant"]))

      groups = record.linked_field_groups
      expect(groups).not_to be_valid
      expect(groups.errors).to include(an_instance_of(MARC::DuplicateOccurrenceNumberException))
      expect(groups.errors).not_to include(an_instance_of(MARC::OneToManyLinkedFieldException))
      expect { record.linked_field_groups(strict: true) }
        .to raise_error(MARC::DuplicateOccurrenceNumberException)
    end

    it "reports a one-to-many link distinctly from duplicate numbers" do
      record = MARC::Record.new
      record.append(linked_field("245", "880-01", ["a", "Title"]))
      record.append(linked_field("880", "245-01/Arab", ["a", "First alternate"]))
      record.append(linked_field("880", "245-01/Arab", ["a", "Second alternate"]))

      groups = record.linked_field_groups
      expect(groups.errors.map(&:class).uniq)
        .to contain_exactly(MARC::OneToManyLinkedFieldException, MARC::DuplicateOccurrenceNumberException)
    end

    it "flags an 880 field with no $6 as invalid" do
      record = MARC::Record.new
      record.append(plain_field("880", ["a", "Missing link"]))

      groups = record.linked_field_groups
      expect(groups).to be_empty
      expect(groups).not_to be_valid
      expect(groups.errors.first).to be_a(MARC::InvalidLinkedFieldException)
    end

    it "appends and deletes linked groups and round-trips remaining links" do
      record = MARC::Record.new
      first = record.append_linked_field_group(
        plain_field("245", ["a", "First title"], ["b", "First statement"]),
        plain_field("880", ["a", "العنوان الأول"], ["b", "بيان المسؤولية الأول"]),
        script: "(3",
        right_to_left: true
      )
      second = record.append_linked_field_group(
        plain_field("245", ["a", "Second title"], ["b", "Second statement"]),
        plain_field("880", ["a", "العنوان الثاني"], ["b", "بيان المسؤولية الثاني"]),
        script: "(3",
        right_to_left: true
      )

      expect(first.key).to eq(["245", "01"])
      expect(second.key).to eq(["245", "02"])
      expect(record.fields.map { |field| field.subfields.map(&:code) })
        .to all(eq(["6", "a", "b"]))
      expect(record.fields.map { |field| field["6"] })
        .to eq(["880-01", "245-01/(3/r", "880-02", "245-02/(3/r"])

      record.delete_linked_field_group!(first)
      replacement = record.append_linked_field_group(
        plain_field("245", ["a", "Third title"]),
        plain_field("880", ["a", "العنوان الثالث"]),
        script: "(3",
        right_to_left: true
      )

      expect(replacement.key).to eq(["245", "01"])
      expect(second.key).to eq(["245", "02"])
      expect(record.fields.map(&:tag)).to eq(["245", "880", "245", "880"])
      expect(record.fields.map { |field| field["6"] })
        .to eq(["880-02", "245-02/(3/r", "880-01", "245-01/(3/r"])

      read_back = MARC::Record.new_from_marc(record.to_marc)
      groups = read_back.linked_field_groups
      expect(groups.map { |group| [group.tag, group.occurrence] })
        .to contain_exactly(["245", "01"], ["245", "02"])
      expect(groups["245", "02"].original["a"]).to eq("Second title")
      expect(groups["245", "02"].alternate["a"]).to eq("العنوان الثاني")
      expect(groups["245", "01"].original["a"]).to eq("Third title")
    end

    it "does not modify the record or supplied fields when append validation fails" do
      record = MARC::Record.new
      record.append(plain_field("880", ["a", "Missing link"]))
      original = plain_field("245", ["a", "Title"])
      alternate = plain_field("880", ["a", "Alternate"])

      expect { record.append_linked_field_group(original, alternate) }
        .to raise_error(MARC::InvalidLinkedFieldException)
      expect(record.fields.map(&:tag)).to eq(["880"])
      expect(original.link_subfield).to be_nil
      expect(alternate.link_subfield).to be_nil
    end

    it "renumbers groups densely and preserves field and subfield order" do
      record = MARC::Record.new
      record.append(linked_field("245", "880-03", ["a", "Late title"], ["b", "Late statement"]))
      record.append(linked_field("880", "245-03/Arab/r", ["a", "عنوان متأخر"]))
      record.append(linked_field("250", "880-01", ["a", "Edition"]))
      record.append(linked_field("880", "250-01/Arab/r", ["a", "طبعة"]))

      groups = record.renumber_linked_field_groups!

      expect(groups.map(&:key)).to eq([["245", "01"], ["250", "02"]])
      expect(record.fields.map(&:tag)).to eq(["245", "880", "250", "880"])
      expect(record.fields.map { |field| field["6"] })
        .to eq(["880-01", "245-01/Arab/r", "880-02", "250-02/Arab/r"])
      expect(record.fields.first.subfields[1].code).to eq("a")
      expect(record.fields.first.subfields[2].code).to eq("b")
    end

    it "does not renumber an ambiguous one-to-many group" do
      record = MARC::Record.new
      original = plain_field("245", ["6", "880-01"], ["a", "Title"])
      first_alternate = linked_field("880", "245-01", ["a", "First"])
      second_alternate = linked_field("880", "245-01", ["a", "Second"])
      record.append(original)
      record.append(first_alternate)
      record.append(second_alternate)

      expect { record.renumber_linked_field_groups! }
        .to raise_error(MARC::OneToManyLinkedFieldException)
      expect(original.subfields.map(&:code)).to eq(["6", "a"])
      expect(first_alternate["6"]).to eq("245-01")
      expect(second_alternate["6"]).to eq("245-01")
    end
  end
end
