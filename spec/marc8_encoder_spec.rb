require "spec_helper"
require "stringio"

RSpec.describe MARC::Marc8::FromUnicode do
  it "encodes Latin combining characters before their base character" do
    encoder = described_class.new

    expect(encoder.transcode("é")).to eq("\xe2e".b)
    expect(encoder.transcode("ắ")).to eq("\xe2\xe6a".b)
  end

  it "keeps encoding state independent between strings" do
    encoder = described_class.new

    expect(encoder.transcode("α")).to eq("\x1b(Sα".b)
    expect(encoder.transcode("é")).to eq("\xe2e".b)
  end

  it "switches through G0 charsets and EACC with stable escape sequences" do
    encoder = described_class.new

    expect(encoder.transcode("aα汉字a!").bytes.map { |byte| format("%02X", byte) }).to eq(%w[
      61 1B 28 53 61 1B 24 31 27 48 57 21 3A 52 1B 28 42 61 21
    ])
  end

  it "round-trips precomposed and combining Unicode through the existing decoder" do
    encoder = described_class.new
    decoder = MARC::Marc8::ToUnicode.new
    samples = ["ắ", "ǻ", "ἀ", "A\u0328\u0301", "a\u0308\u0304", "αβ é!"]

    samples.each do |sample|
      marc8 = encoder.transcode(sample)
      expect(decoder.transcode(marc8).unicode_normalize(:nfc)).to eq(sample.unicode_normalize(:nfc))
    end
  end

  it "restricts output to the allowed charsets" do
    encoder = described_class.new(allowed_charsets: ["ANSEL", 0x42])

    expect(encoder.transcode("é")).to eq("\xe2e".b)
    expect { encoder.transcode("α") }.to raise_error(Encoding::UndefinedConversionError, /U+03B1.*position 0/)
  end

  it "reports the original character position for unrepresentable characters" do
    encoder = described_class.new
    error = begin
      encoder.transcode("ab😀z")
    rescue Encoding::UndefinedConversionError => e
      e
    end

    expect(error.message).to include("U+1F600", "character position 2")
  end

  it "supports caller supplied replacement text" do
    encoder = described_class.new

    expect(encoder.transcode("a😀", invalid: :replace, replace: "[?]")).to eq("a[?]".b)
  end

  it "prefers the canonical EACC code when duplicate Unicode mappings exist" do
    encoder = described_class.new

    expect(encoder.transcode("禺").bytes.map { |byte| format("%02X", byte) }).to eq(%w[1B 24 31 22 68 23])
  end
end

RSpec.describe MARC::Writer do
  it "writes UTF-8 records as MARC-8 and preserves byte-accurate directory entries" do
    record = MARC::Record.new
    record.append(MARC::ControlField.new("008", "260101t20262026enk     b    001 0 eng  "))
    record.append(MARC::DataField.new("100", "1", " ", ["a", "Ñoño"]))
    record.append(MARC::DataField.new(
      "245", "1", "0",
      ["a", "αβ é!"],
      ["b", "汉字"],
      ["c", "Œuvre"]
    ))

    marc = MARC::Writer.encode(record, external_encoding: "MARC-8")
    base_address = marc[12..16].to_i
    directory = marc[24...(base_address - 1)]

    expect(marc[9]).to eq(" ")
    expect(marc[0..4].to_i).to eq(marc.bytesize)

    directory.scan(/.{12}/).each do |entry|
      length = entry[3..6].to_i
      offset = entry[7..11].to_i
      expect(marc.byteslice(base_address + offset, length).bytesize).to eq(length)
    end

    read_back = MARC::Reader.decode(marc, external_encoding: "MARC-8")
    expect(read_back["100"]["a"]).to eq("Ñoño")
    expect(read_back["245"].subfields.map(&:value)).to eq(["αβ é!", "汉字", "Œuvre"])
  end

  it "writes MARC-8 through an IO-backed writer" do
    io = StringIO.new
    writer = MARC::Writer.new(io, external_encoding: "MARC-8", invalid: :replace, replace: "?")
    record = MARC::Record.new
    record.append(MARC::DataField.new("245", "0", " ", ["a", "café😀"]))

    writer.write(record)
    read_back = MARC::Reader.decode(io.string, external_encoding: "MARC-8")

    expect(read_back["245"]["a"]).to eq("café?")
  end
end
