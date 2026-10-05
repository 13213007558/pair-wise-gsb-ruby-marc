require "test/unit"
require "marc"

require "stringio"

class WriterTest < Test::Unit::TestCase
  def test_writer
    writer = MARC::Writer.new("test/writer.dat")
    record = MARC::Record.new
    record.append(MARC::DataField.new("245", "0", "1", ["a", "foo"]))
    writer.write(record)
    writer.close

    # read it back to make sure
    reader = MARC::Reader.new("test/writer.dat")
    records = reader.entries
    assert_equal(records.length, 1)
    assert_equal(records[0], record)

    # cleanup
    File.unlink("test/writer.dat")
  end

  # Only in ruby 1.9
  if "".respond_to?(:encoding)
    def test_writer_bad_encoding
      writer = MARC::Writer.new("test/writer.dat")

      # MARC::Writer should just happily write out whatever bytes you give it, even
      # mixing encodings that can't be mixed. We ran into an actual example mixing
      # MARC8 (tagged ruby binary) and UTF8, we want it to be written out.

      record = MARC::Record.new

      record.append MARC::DataField.new("700", "0", " ", ["a", +"Nhouy Abhay,".dup.force_encoding("BINARY")], ["c", +"Th\xE5ao,".dup.force_encoding("BINARY")], ["d", "1909-"])
      record.append MARC::DataField.new("700", "0", " ", ["a", +"Somchin P\xF8\xE5o. Ngin,".dup.force_encoding("BINARY")])

      record.append MARC::DataField.new("100", "0", "0", ["a", +"\xE5angkham. ".dup.force_encoding("BINARY")])
      record.append MARC::DataField.new("245", "1", "0", ["b", +"chef-d'oeuvre de la litt\xE2erature lao".dup.force_encoding("BINARY")])

      # One in UTF8 and marked
      record.append MARC::DataField.new("999", "0", "1", ["a", +"chef-d'ocuvre de la littU+FFC3\U+FFA9rature".dup.force_encoding("UTF-8")])

      writer.write(record)
      writer.close
    ensure
      File.unlink("test/writer.dat")
    end
  end

  def test_write_too_long_iso2709
    too_long_record = MARC::Record.new
    1.upto(1001) do
      too_long_record.append MARC::DataField.new("500", " ", " ", ["a", "A really long record.1234567890123456789012345678901234567890123456789012345678901234567890123456789"])
    end

    wbuffer = StringIO.new(+"", "w")
    writer = MARC::Writer.new(wbuffer)
    writer.allow_oversized = true

    writer.write(too_long_record)
    writer.close

    assert_equal "00000", wbuffer.string.slice(0, 5), "zero'd out length bytes when too long"

    rbuffer = StringIO.new(wbuffer.string.dup)

    # Regular reader won't read our illegal record.
    # assert_raise(NoMethodError) do
    #  reader = MARC::Reader.new(rbuffer)
    #  reader.first
    # end

    # Forgiving reader will, round trippable
    new_record = MARC::Reader.decode(rbuffer.string, forgiving: true)
    assert_equal too_long_record, new_record, "Too long record round-trippable with forgiving mode"

    # Test in the middle of a MARC file
    good_record = MARC::Record.new
    good_record.append MARC::DataField.new("500", " ", " ", ["a", "A short record"])
    wbuffer = StringIO.new(+"", "w")
    writer = MARC::Writer.new(wbuffer)
    writer.allow_oversized = true

    writer.write(good_record)
    writer.write(too_long_record)
    writer.write(good_record)

    rbuffer = StringIO.new(wbuffer.string.dup)
    reader = MARC::ForgivingReader.new(rbuffer)
    records = reader.to_a

    assert_equal 3, records.length
    assert_equal good_record, records[0]
    assert_equal good_record, records[2]
    assert_equal too_long_record, records[1]
  end

  def test_raises_on_too_long_if_configured
    too_long_record = MARC::Record.new
    1.upto(1001) do
      too_long_record.append MARC::DataField.new("500", " ", " ", ["a", "A really long record.1234567890123456789012345678901234567890123456789012345678901234567890123456789"])
    end

    wbuffer = StringIO.new(+"", "w")
    writer = MARC::Writer.new(wbuffer)

    assert_raise(MARC::Exception) do
      writer.write too_long_record
    end
  end

  def test_forgiving_writer
    marc = "00305cam a2200133 a 4500001000700000003000900007005001700016008004100033008004100074035002500115245001700140909001000157909000400167\036635145\036UK-BiLMS\03620060329173705.0\036s1982iieng6                  000 0 eng||\036060116|||||||||xxk                 eng||\036  \037a(UK-BiLMS)M0017366ZW\03600\037aTest record.\036  \037aa\037b\037c\036\037b0\036\035\000"
    rec = MARC::Record.new_from_marc(marc)
    assert_nothing_raised do
      rec.to_marc
    end
  end

  def test_unicode_roundtrip
    record = MARC::Reader.new("test/utf8.marc", external_encoding: "UTF-8").first

    writer = MARC::Writer.new("test/writer.dat")
    writer.write(record)
    writer.close

    read_back_record = MARC::Reader.new("test/writer.dat", external_encoding: "UTF-8").first

    # Make sure the one we wrote out then read in again
    # is the same as the one we read the first time
    # Looks like "==" is over-ridden to do that. Don't ever change, #==
    assert_equal record, read_back_record, "Round-tripped record must equal original record"
  end

  if "".respond_to?(:encoding)
    # Builds a short record exercising latin combining marks, CJK (EACC)
    # and several different character sets in a row.
    def marc8_test_record
      record = MARC::Record.new
      record.append MARC::ControlField.new("001", "   000000001 ")
      record.append MARC::DataField.new("100", "1", " ", ["a", "M\u00FCller, Li \u674E"])
      record.append MARC::DataField.new("245", "1", "0",
        ["a", "Conversa\u00E7\u00E3o \u4E2D\u56FD :"],
        ["b", "\u03B1\u03B2\u03B3 \u05D0\u05D1\u05D2 ab"])
      record
    end

    def test_writer_marc8_round_trip
      record = marc8_test_record

      buffer = StringIO.new("".b)
      writer = MARC::Writer.new(buffer, encoding: "MARC-8")
      writer.write(record)

      raw = buffer.string

      # leader: MARC-8 character coding scheme flag, correct lengths
      assert_equal " ", raw[9]
      assert_equal raw.bytesize, raw[0..4].to_i
      base_address = raw[12..16].to_i
      assert_equal MARC::LEADER_LENGTH + (MARC::DIRECTORY_ENTRY_LENGTH * 3) + 1, base_address

      # directory: byte lengths and offsets must add up, field
      # data must be terminated at exactly those byte offsets
      directory = raw[MARC::LEADER_LENGTH...base_address - 1]
      offset = 0
      tags = []
      3.times do |field_num|
        entry = directory[(field_num * MARC::DIRECTORY_ENTRY_LENGTH), MARC::DIRECTORY_ENTRY_LENGTH]
        tags << entry[0..2]
        length = entry[3..6].to_i
        entry_offset = entry[7..11].to_i
        assert_equal offset, entry_offset, "directory entry #{field_num} offset"
        field_data = raw[(base_address + offset), length]
        assert_equal length, field_data.bytesize, "directory entry #{field_num} byte length"
        assert_equal MARC::END_OF_FIELD, field_data[-1], "field #{field_num} terminated"
        offset += length
      end
      assert_equal %w[001 100 245], tags
      assert_equal base_address + offset + 1, raw.bytesize
      assert_equal MARC::END_OF_RECORD, raw[-1]

      # read it back with the existing decoder: normalized unicode
      # content must be identical
      read_back = MARC::Reader.new(StringIO.new(raw), external_encoding: "MARC-8").entries.first
      assert_equal " ", read_back.leader[9]
      record.fields.each_with_index do |field, i|
        read_field = read_back.fields[i]
        assert_equal field.tag, read_field.tag
        if field.instance_of?(MARC::DataField)
          field.subfields.each_with_index do |subfield, j|
            assert_equal subfield.value.unicode_normalize(:nfc),
              read_field.subfields[j].value,
              "field #{field.tag} subfield $#{subfield.code}"
          end
        else
          assert_equal field.value.unicode_normalize(:nfc), read_field.value
        end
      end
    end

    def test_writer_marc8_record_state_independence
      buffer = StringIO.new("".b)
      writer = MARC::Writer.new(buffer, encoding: "MARC-8")

      first = MARC::Record.new
      first.append MARC::DataField.new("245", "1", "0", ["a", "\u4E2D\u56FD"])
      second = MARC::Record.new
      second.append MARC::DataField.new("245", "1", "0", ["a", "plain latin"])
      writer.write(first)
      writer.write(second)

      raw = buffer.string
      first_length = raw[0..4].to_i
      second_raw = raw[first_length..]

      # the second record starts with default character sets again:
      # plain latin needs no escape sequences at all
      assert !second_raw.include?("\x1B".b), "no escape sequences in second record"

      records = MARC::Reader.new(StringIO.new(raw), external_encoding: "MARC-8").entries
      assert_equal 2, records.length
      assert_equal "\u4E2D\u56FD", records[0]["245"]["a"]
      assert_equal "plain latin", records[1]["245"]["a"]
    end

    def test_writer_marc8_encode_class_method
      record = marc8_test_record
      marc = MARC::Writer.encode(record, encoding: "MARC-8")
      assert_equal "ASCII-8BIT", marc.encoding.name
      assert_equal " ", marc[9]
      # leader of the passed-in record is updated, as usual
      assert_equal " ", record.leader[9]
      assert_equal marc[0, MARC::LEADER_LENGTH], record.leader

      read_back = MARC::Reader.new(StringIO.new(marc), external_encoding: "MARC-8").entries.first
      assert_equal "Conversa\u00E7\u00E3o \u4E2D\u56FD :", read_back["245"]["a"]
    end

    def test_writer_marc8_unrepresentable_raises
      record = MARC::Record.new
      record.append MARC::DataField.new("245", "1", "0", ["a", "emoji \u{1F600} here"])
      assert_raise(Encoding::UndefinedConversionError) do
        MARC::Writer.encode(record, encoding: "MARC-8")
      end
    end

    def test_writer_marc8_unrepresentable_replaced
      record = MARC::Record.new
      record.append MARC::DataField.new("245", "1", "0", ["a", "emoji \u{1F600} here"])

      buffer = StringIO.new("".b)
      writer = MARC::Writer.new(buffer, encoding: "MARC-8", marc8_options: {invalid: :replace})
      writer.write(record)

      # replaced with an escaped character reference, which the
      # decoder expands back to the original character
      read_back = MARC::Reader.new(StringIO.new(buffer.string), external_encoding: "MARC-8").entries.first
      assert_equal "emoji \u{1F600} here", read_back["245"]["a"]
    end
  end
end
