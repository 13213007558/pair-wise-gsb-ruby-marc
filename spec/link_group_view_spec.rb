require "spec_helper"

RSpec.describe MARC::LinkGroupView do
  def linked_record
    record = MARC::Record.new
    record.append(MARC::DataField.new("760", "0", " ", ["8", "1-1\\p"], ["a", "A1"]))
    record.append(MARC::DataField.new("500", " ", " ", ["a", "unlinked"]))
    record.append(MARC::DataField.new("762", "0", " ", ["8", "1-2\\p"], ["a", "A2"]))
    record.append(MARC::DataField.new("830", "0", " ", ["8", "2.1"], ["a", "B1"]))
    record.append(
      MARC::DataField.new(
        "880", "0", " ",
        ["8", "1-3\\p"], ["a", "A3"],
        ["8", "2-2"], ["a", "B2"]
      )
    )
    record
  end

  it "parses link number, optional sequence, separator, and link type" do
    view = linked_record.link_groups

    expect(view.map(&:link_number)).to eq([1, 2])
    expect(view[1].field_positions).to eq([0, 2, 4])
    expect(view[1].sequence_numbers).to eq([1, 2, 3])
    expect(view[1].link_types).to eq(["p"])
    expect(view[2].field_positions).to eq([3, 4])
    expect(view[2].sequence_numbers).to eq([1, 2])
    expect(view.unlinked_fields.map(&:tag)).to eq(["500"])
  end

  it "reorders one group without moving fields or changing another group" do
    record = linked_record
    plan = record.link_groups.plan_reorder(1, [record.fields[0], record.fields[4], record.fields[2]])

    expect(plan).to be_valid
    expect(plan.changes.map(&:field_position)).to eq([4, 2])
    expect(plan.changes.map(&:to)).to eq(["1-2\\p", "1-3\\p"])

    modified = plan.apply
    expect(modified).not_to equal(record)
    expect(modified.fields.map(&:tag)).to eq(record.fields.map(&:tag))
    expect(record.fields[2]["8"]).to eq("1-2\\p")
    expect(record.fields[4].subfields.map(&:value)).to eq(["1-3\\p", "A3", "2-2", "B2"])
    expect(modified.fields[2]["8"]).to eq("1-3\\p")
    expect(modified.fields[4].subfields.map(&:value)).to eq(["1-2\\p", "A3", "2-2", "B2"])

    reparsed = MARC::Record.new_from_marc(modified.to_marc).link_groups
    expect(reparsed[1].field_positions).to eq([0, 2, 4])
    expect(reparsed[1].members.map(&:sequence_number)).to eq([1, 3, 2])
    expect(reparsed[2].field_positions).to eq([3, 4])
    expect(reparsed[2].sequence_numbers).to eq([1, 2])
  end

  it "reports missing, duplicate, and inconsistent link type issues" do
    record = MARC::Record.new
    record.append(MARC::DataField.new("500", " ", " ", ["8", "3-1\\p"], ["a", "one"]))
    record.append(MARC::DataField.new("500", " ", " ", ["8", "3-1\\p"], ["a", "two"]))
    record.append(MARC::DataField.new("500", " ", " ", ["8", "3-3\\p"], ["a", "three"]))
    record.append(MARC::DataField.new("500", " ", " ", ["8", "3-5\\r"], ["a", "four"]))
    record.append(MARC::DataField.new("500", " ", " ", ["8", "bad"], ["a", "invalid"]))

    codes = record.link_groups.issues.map(&:code)
    expect(codes).to include(
      :duplicate_sequence_number,
      :missing_sequence_number,
      :inconsistent_link_type,
      :invalid_link_value
    )
  end

  it "rejects orders that omit members or include fields outside the group" do
    record = linked_record
    view = record.link_groups

    plan = view.plan_reorder(1, [record.fields[0], record.fields[4]])
    expect(plan).not_to be_valid
    expect(plan.errors.map { |error| error[:message] }).to include(/all sequenced members/)

    plan = view.plan_reorder(1, [record.fields[0], record.fields[4], record.fields[1]])
    expect(plan).not_to be_valid
    expect(plan.errors.map { |error| error[:message] }).to include(/not in link group/)
  end

  it "renumbers links and preserves suffixes and shared-field membership" do
    record = linked_record
    plan = record.link_groups.plan_renumber(1 => 10, 2 => 20)

    expect(plan).to be_valid
    modified = plan.apply
    expect(modified.fields[4].subfields.map(&:value)).to eq(["10-3\\p", "A3", "20-2", "B2"])

    reparsed = MARC::Record.new_from_marc(modified.to_marc).link_groups
    expect(reparsed.map(&:link_number)).to eq([10, 20])
  end

  it "rejects duplicate renumber targets and duplicate group declarations" do
    expect(linked_record.link_groups.plan_renumber(1 => 2)).not_to be_valid

    record = MARC::Record.new
    record.append(
      MARC::DataField.new(
        "500", " ", " ",
        ["8", "4-1\\p"], ["a", "first"],
        ["8", "4-1\\p"], ["a", "duplicate"]
      )
    )
    plan = record.link_groups.plan_reorder(4, [0])

    expect(plan).not_to be_valid
    expect(plan.errors.map { |error| error[:message] }).to include(/declares link group/)
  end
end
