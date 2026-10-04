require "spec_helper"

RSpec.describe MARC::FieldLinkGroupView do
  def build_record
    record = MARC::Record.new
    record.append MARC::DataField.new("500", " ", " ", ["8", "1"], ["a", "first"])
    record.append MARC::DataField.new("600", " ", " ", ["8", "2"], ["8", "1.2"], ["a", "shared"])
    record.append MARC::DataField.new("700", " ", " ", ["8", "1.3"], ["a", "third"])
    record.append MARC::DataField.new("800", " ", " ", ["8", "2.2"], ["a", "second group"])
    record.append MARC::ControlField.new("001", "untouched-control")
    record.append MARC::DataField.new("245", " ", " ", ["a", "unlinked"])
    record
  end

  it "parses link numbers, optional sequences, types, and multiple memberships" do
    record = build_record
    field = MARC::DataField.new("900", " ", " ", ["8", "3.1\\p"], ["8", "4\\r"], ["a", "linked twice"])
    record.append(field)

    view = described_class.new(record)
    typed_group = view.group(3)

    expect(view.groups.map(&:number)).to eq([1, 2, 3, 4])
    expect(view.group(1).sequences).to eq([nil, 2, 3])
    expect(view.linked_fields).to eq([0, 1, 2, 3, 6])
    expect(view.unlinked_fields).to eq([4, 5])
    expect(typed_group.type).to eq("p")
    expect(view.group(4).type).to eq("r")
    expect(view.group(3).members.first).to have_attributes(
      number: 3,
      sequence: 1,
      type: "p",
      field_position: 6,
      subfield_position: 0,
      raw: "3.1\\p"
    )
  end

  it "reports gaps, duplicate sequences, and inconsistent types separately" do
    record = MARC::Record.new
    record.append MARC::DataField.new("500", " ", " ", ["8", "1"], ["a", "unnumbered"])
    record.append MARC::DataField.new("600", " ", " ", ["8", "1.2\\p"], ["a", "skips one"])
    record.append MARC::DataField.new("700", " ", " ", ["8", "2.1\\p"], ["a", "duplicate"])
    record.append MARC::DataField.new("710", " ", " ", ["8", "2.1\\r"], ["a", "duplicate and different type"])
    record.append MARC::DataField.new("900", " ", " ", ["8", "bad"], ["a", "invalid"])

    view = described_class.new(record)

    expect(view.group(1).issues.map(&:code)).to eq([:gap_in_sequence])
    expect(view.group(2).issues.map(&:code)).to match_array([:duplicate_sequence, :type_mismatch])
    expect(view.issues.map(&:code)).to include(:invalid_link)
  end

  it "creates a plan without changing the source record" do
    record = build_record
    view = described_class.new(record)

    plan = view.reorder_group(1, [0, 2, 1])

    expect(plan.changes.map { |change| [change.field_position, change.old_value, change.new_value] }).to eq(
      [[0, "1", "1.1"], [2, "1.3", "1.2"], [1, "1.2", "1.3"]]
    )
    expect(record.fields[0]["8"]).to eq("1")
    expect(record.fields[1].subfields.map(&:value)).to eq(["2", "1.2", "shared"])
    expect(record.fields[2]["8"]).to eq("1.3")
  end

  it "applies a reordered group to a copy while preserving field positions" do
    record = build_record
    view = described_class.new(record)
    plan = view.reorder_group(1, [0, 2, 1])
    updated = plan.apply

    expect(updated).not_to equal(record)
    expect(updated.fields.map(&:tag)).to eq(%w[500 600 700 800 001 245])
    expect(updated.fields[0]["8"]).to eq("1.1")
    expect(updated.fields[1].subfields.map(&:value)).to eq(["2", "1.3", "shared"])
    expect(updated.fields[2]["8"]).to eq("1.2")
    expect(updated.fields[3]["8"]).to eq("2.2")
    expect(updated.fields[4].value).to eq("untouched-control")
    expect(updated.fields[5]["a"]).to eq("unlinked")
    expect(updated.fields[2].subfields[0]).not_to equal(record.fields[2].subfields[0])
  end

  it "keeps another group's meaning when a shared field moves within one group" do
    record = build_record
    view = described_class.new(record)
    plan = view.reorder_group(1, [0, 2, 1])
    updated = plan.apply
    reparsed = MARC::Record.new_from_marc(updated.to_marc)
    reparsed_view = described_class.new(reparsed)

    expect(plan.groups.map { |group| [group.number, group.fields, group.sequences] }).to eq(
      reparsed_view.groups.map { |group| [group.number, group.fields, group.sequences] }
    )
    expect(reparsed_view.group(1).fields).to eq([0, 2, 1])
    expect(reparsed_view.group(1).sequences).to eq([1, 2, 3])
    expect(reparsed_view.group(2).fields).to eq([1, 3])
    expect(reparsed_view.group(2).sequences).to eq([nil, 2])
    expect(reparsed_view.group(1).issues).to be_empty
    expect(reparsed.fields.map(&:tag)).to eq(%w[500 600 700 800 001 245])
  end

  it "does not absorb unlinked fields or allow partial group reorders" do
    record = build_record
    view = described_class.new(record)

    expect { view.reorder_group(1, [0, 2]) }.to raise_error(ArgumentError, /exactly the members/)
    expect { view.reorder_group(1, [0, 2, 5]) }.to raise_error(ArgumentError, /not a member/)
    expect { view.reorder_group(9, [0, 2, 1]) }.to raise_error(ArgumentError, /unknown link group/)
    expect(view.groups.map(&:fields)).to eq([[0, 1, 2], [1, 3]])
  end

  it "renumbers all memberships in every affected group without moving fields" do
    record = build_record
    view = described_class.new(record)
    plan = view.renumber_groups(1 => 7, 2 => 8)
    updated = plan.apply

    expect(updated.fields[0]["8"]).to eq("7")
    expect(updated.fields[1].subfields.select { |subfield| subfield.code == "8" }.map(&:value)).to eq(["8", "7.2"])
    expect(updated.fields[2]["8"]).to eq("7.3")
    expect(updated.fields[3]["8"]).to eq("8.2")
    expect(updated.fields.map(&:tag)).to eq(%w[500 600 700 800 001 245])
  end

  it "supports a compact renumbering plan and full-group swaps" do
    record = build_record
    view = described_class.new(record)

    expect(view.renumber_groups.groups.map(&:number)).to eq([1, 2])

    swapped = view.renumber_groups(1 => 2, 2 => 1).apply
    swapped_view = described_class.new(swapped)

    expect(swapped_view.groups.map(&:number)).to eq([1, 2])
    expect(swapped_view.group(1).fields).to eq([1, 3])
    expect(swapped_view.group(2).fields).to eq([0, 1, 2])
    expect { view.renumber_groups(1 => 2) }.to raise_error(ArgumentError, /already in use/)
  end
end
