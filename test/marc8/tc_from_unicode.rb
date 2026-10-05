require "test-unit"
require "marc"
require "marc/marc8/from_unicode"
require "marc/marc8/to_unicode"
require "stringio"

class Marc8FromUnicodeTest < Test::Unit::TestCase
  def test_latin_combining_marks_are_written_before_base
    encoder = MARC::Marc8::FromUnicode.new

    assert_equal("\xe2e".b, encoder.transcode("é"))
    assert_equal("\xe2\xe6a".b, encoder.transcode("ắ"))
  end

  def test_encoding_state_is_independent_between_strings
    encoder = MARC::Marc8::FromUnicode.new

    assert_equal([0x1b, 0x28, 0x53, 0x61].pack("C*"), encoder.transcode("\u03B1"))
    assert_equal("\xe2e".b, encoder.transcode("é"))
  end

  def test_g0_and_eacc_switching
    encoder = MARC::Marc8::FromUnicode.new
    marc8 = encoder.transcode("aα汉字a!")

    assert_equal(%w[61 1B 28 53 61 1B 24 31 27 48 57 21 3A 52 1B 28 42 61 21],
                 marc8.bytes.map { |byte| format("%02X", byte) })
  end

  def test_combining_roundtrip
    encoder = MARC::Marc8::FromUnicode.new
    samples = ["ắ", "ǻ", "ἀ", "A\u0328\u0301", "a\u0308\u0304", "αβ é!"]

    samples.each do |sample|
      decoder = MARC::Marc8::ToUnicode.new
      decoded = decoder.transcode(encoder.transcode(sample)).unicode_normalize(:nfc)
      assert_equal(sample.unicode_normalize(:nfc), decoded)
    end
  end

  def test_allowed_charsets_limit_representation
    encoder = MARC::Marc8::FromUnicode.new(allowed_charsets: ["ANSEL", 0x42])

    assert_equal("\xe2e".b, encoder.transcode("é"))
    error = assert_raise(Encoding::UndefinedConversionError) { encoder.transcode("α") }
    assert_match(/U\+03B1.*position 0/, error.message)
  end

  def test_unrepresentable_character_reports_position
    encoder = MARC::Marc8::FromUnicode.new
    error = assert_raise(Encoding::UndefinedConversionError) { encoder.transcode("ab😀z") }

    assert_match(/U\+1F600/, error.message)
    assert_match(/character position 2/, error.message)
  end

  def test_replacement_text
    encoder = MARC::Marc8::FromUnicode.new

    assert_equal("a[?]".b, encoder.transcode("a😀", invalid: :replace, replace: "[?]"))
  end

  def test_canonical_eacc_variant_is_preferred
    encoder = MARC::Marc8::FromUnicode.new

    assert_equal(%w[1B 24 31 22 68 23],
                 encoder.transcode("禺").bytes.map { |byte| format("%02X", byte) })
  end

  def test_writer_marc8_leader_and_byte_directory
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

    assert_equal(" ", marc[9])
    assert_equal(marc.bytesize, marc[0..4].to_i)

    directory.scan(/.{12}/).each do |entry|
      length = entry[3..6].to_i
      offset = entry[7..11].to_i
      assert_equal(length, marc.byteslice(base_address + offset, length).bytesize)
    end

    read_back = MARC::Reader.decode(marc, external_encoding: "MARC-8")
    assert_equal("Ñoño", read_back["100"]["a"])
    assert_equal(["αβ é!", "汉字", "Œuvre"], read_back["245"].subfields.map(&:value))
  end

  def test_writer_replacement_options
    io = StringIO.new
    writer = MARC::Writer.new(io, external_encoding: "MARC-8", invalid: :replace, replace: "?")
    record = MARC::Record.new
    record.append(MARC::DataField.new("245", "0", " ", ["a", "café😀"])  )

    writer.write(record)
    read_back = MARC::Reader.decode(io.string, external_encoding: "MARC-8")

    assert_equal("café?", read_back["245"]["a"])
  end
end
