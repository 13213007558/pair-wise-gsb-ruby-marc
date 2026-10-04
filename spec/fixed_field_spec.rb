# frozen_string_literal: true

require "spec_helper"

RSpec.describe MARC::FixedField do
  let(:raw_008) { "000107s2000    nyua          001 0 eng  " }

  def record(leader, value = raw_008)
    record = MARC::Record.new
    record.leader = leader
    record << MARC::ControlField.new("008", value)
    record
  end

  it "selects a book layout and exposes semantic names and raw offsets" do
    view = described_class.view(record("00000nam a22002414a 4500"))

    expect(view.layout.id).to eq(:marc21_book)
    expect(view[:date_type].raw).to eq("s")
    expect(view[:literary_form].raw).to eq("0")
    expect(view.offset_of(:literary_form)).to eq(33)
    expect(view.name_at(33)).to eq(:literary_form)
    expect(view[:date_type].label).to eq("Single known date")
  end

  it "uses a continuing-resource layout for the same 008 bytes" do
    view = described_class.view(record("00000nas a22002414a 4500"))

    expect(view.layout.id).to eq(:marc21_continuing_resource)
    expect(view[:date_type].raw).to eq("s")
    expect(view[:title_page].raw).to eq("0")
    expect(view.offset_of(:title_page)).to eq(33)
    expect(view.name_at(33)).to eq(:title_page)
    expect(view.offset_of(:date_type)).to eq(6)
  end

  it "selects a map layout from the cartographic record type" do
    map_record = record("00000nem a22002414a 4500", "880715q19701979th ab  aae          chi  ")
    view = described_class.view(map_record)

    expect(view.layout.id).to eq(:marc21_map)
    expect(view[:date_type].raw).to eq("q")
    expect(view[:relief].raw).to eq("ab  ")
    expect(view[:type_of_cartographic_material].raw).to eq("e")
    expect(view.offset_of(:relief)).to eq(18)
    expect(view.offset_of(:type_of_cartographic_material)).to eq(24)
    expect(view.name_at(24)).to eq(:type_of_cartographic_material)
  end

  it "validates enum codes and segment widths on edit" do
    view = described_class.view(record("00000nam a22002414a 4500"))

    expect { view[:date_type] = "Z" }.to raise_error(
      described_class::View::ValidationError,
      /unknown code "Z"/
    )
    expect { view[:date1] = "200" }.to raise_error(
      described_class::View::ValidationError,
      /must be 4 characters/
    )
  end

  it "checks linked date type and date ranges" do
    view = described_class.view(record("00000nas a22002414a 4500"))
    view.update(date_type: "i", date1: "1999", date2: "2000")
    expect { view.update(date_type: "i", date1: "1999", date2: "1998") }.to raise_error(
      described_class::View::ValidationError,
      /date range is inconsistent/
    )

    view[:date2] = "2000"
    expect(view.errors.grep(/date/)).to be_empty
    expect(view.fetch(:date2)).to eq("2000")
  end

  it "allows a blank second date for a single date" do
    view = described_class.view(record("00000nam a22002414a 4500"))
    view[:date1] = "2000"
    view[:date2] = "    "

    expect(view.errors.grep(/date/)).to be_empty
  end

  it "preserves unknown bytes when unrelated segments are edited" do
    value = raw_008.dup
    value[22] = "Z"
    view = described_class.view(record("00000nam a22002414a 4500", value))

    expect(view[:target_audience].state).to eq(:unknown)
    expect(view[:target_audience].raw).to eq("Z")
    view.update(date_type: "q", date1: "1970", date2: "1979")

    expect(view.field.value[22]).to eq("Z")
    expect(view.field.value[6]).to eq("q")
    expect(view.errors.join("\n")).to include("unknown code \"Z\"")
  end

  it "keeps leader-based layout selection for an unknown 008 date code" do
    value = raw_008.dup
    value[6] = "Z"
    view = described_class.view(record("00000nam a22002414a 4500", value))

    expect(view.layout.id).to eq(:marc21_book)
    expect(view[:date_type].state).to eq(:unknown)
    expect(view.errors.join("\n")).to include("unknown code \"Z\"")
  end

  it "keeps spaces, fill characters, and unknown codes semantically distinct" do
    view = described_class.view(record("00000nam a22002414a 4500"))
    value = raw_008.dup
    value[22] = " "
    value[23] = "|"
    value[33] = "Z"
    view.field.value = value

    expect(view[:target_audience].state).to eq(:blank)
    expect(view[:form_of_item].state).to eq(:fill)
    expect(view[:literary_form].state).to eq(:unknown)
    expect(view[:form_of_item].fill?).to be(true)
    expect(view[:literary_form].unknown?).to be(true)
  end

  it "requires an explicit migration rule before changing record type" do
    map_record = record("00000nam a22002414a 4500")

    expect { described_class.migrate(map_record, layout: :marc21_map) }.to raise_error(
      ArgumentError,
      /explicit migration rule/
    )
    expect(map_record.leader[6]).to eq("a")
  end

  it "migrates with an explicit rule and avoids old-layout writes afterward" do
    map_record = record("00000nam a22002414a 4500")
    migrated = described_class.migrate(map_record, layout: :marc21_map, rule: :preserve_common)

    expect(map_record.leader[6]).to eq("e")
    expect(migrated.layout.id).to eq(:marc21_map)
    expect(migrated[:date_type].raw).to eq("s")
    expect { described_class.view(map_record, layout: described_class.layout(:marc21_book)) }.to raise_error(
      described_class::LayoutMismatch,
      /migration rule/
    )
  end

  it "selects a 006 layout from the first type byte" do
    fixed_record = MARC::Record.new
    fixed_record.leader = "00000nam a22002414a 4500"
    fixed_record << MARC::ControlField.new("006", "s     b       0   ")
    view = fixed_record.fixed_field("006")

    expect(view.layout.id).to eq(:marc21_continuing_resource_006)
    expect(view[:type_byte].raw).to eq("s")
    expect(view[:form_of_item].raw).to eq("b")
    expect(view.offset_of(:form_of_item)).to eq(6)
    expect(view.name_at(6)).to eq(:form_of_item)
  end

  it "registers a declarative custom layout" do
    layout = MARC::FixedField::Layout.new(
      id: :custom_book,
      label: "Custom book 008",
      record_types: [{record_type: "a", bibliographic_level: "m"}]
    ) do |declared|
      declared.segment(:date_type, 6, 1, "Date type", MARC::FixedField::DATE_TYPES)
    end

    described_class.register_layout(layout)

    expect(described_class.layout(:custom_book)).to eq(layout)
    described_class.unregister_layout(:custom_book)
  end

  it "reports a short field and pads it when edited" do
    short_record = record("00000nam a22002414a 4500", "880715s2000")
    view = described_class.view(short_record)

    expect(view.errors.join("\n")).to include("must be at least 40 characters")
    view[:date_type] = "s"

    expect(short_record["008"].value.length).to eq(40)
  end
end
