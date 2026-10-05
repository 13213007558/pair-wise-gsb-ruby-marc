module MARC
  # A class for writing MARC records as binary MARC (ISO 2709)
  #
  # == Too-long records
  #
  # The MARC binary format only allows records that are total 99999 bytes long,
  # due to size of a length field in the record.
  #
  # By default, the Writer will raise a MARC::Exception when encountering
  # in-memory records that are too long to be legally written out as ISO 2709
  # binary.

  # However, if you set `allow_oversized` to true, then the Writer will
  # write these records out anyway, filling in any binary length/offset slots
  # with all 0's, if they are not wide enough to hold the true value.
  # While these records are illegal, they can still be read back in using
  # the MARC::ForgivingReader, as well as other platform MARC readers
  # in tolerant mode.
  #
  # If you set `allow_oversized` to false on the Writer, a MARC::Exception
  # will be raised instead, if you try to write an oversized record.
  #
  #    writer = Writer.new(some_path)
  #    writer.allow_oversized = true
  #
  # == MARC-8 output
  #
  # By default records are written out with their string bytes as-is
  # (normally UTF-8). To instead transcode records to the legacy MARC-8
  # character encoding on write, pass the :encoding option:
  #
  #    writer = MARC::Writer.new(some_path, :encoding => "MARC-8")
  #
  # The leader's character coding scheme flag (byte 9) will be set to
  # MARC-8, and field byte lengths and directory offsets are computed
  # from the transcoded MARC-8 bytes. Character set designation state is
  # reset for every record written. Options for the transcoder
  # (MARC::Marc8::ToMarc8), such as :charsets, :invalid or :replace, can
  # be passed along with :marc8_options:
  #
  #    writer = MARC::Writer.new(some_path, :encoding => "MARC-8",
  #      :marc8_options => {:invalid => :replace})
  class Writer
    attr_accessor :allow_oversized

    # the constructor which you must pass a file path
    # or an object that responds to a write message.
    #
    # Options:
    #  * encoding: output character encoding. Only "MARC-8" is treated
    #    specially, transcoding records to MARC-8 on write. Anything else
    #    (or nothing) leaves record bytes as-is.
    #  * marc8_options: options hash for MARC::Marc8::ToMarc8, used only
    #    with encoding "MARC-8".

    def initialize(file, options = {}, &blk)
      if file.instance_of?(String)
        @fh = File.new(file, "w")
      elsif file.respond_to?(:write)
        @fh = file
      else
        raise ArgumentError, "must pass in file name or handle"
      end
      self.allow_oversized = false
      @encoding = options[:encoding]
      @marc8_options = options[:marc8_options] || {}

      if block_given?
        blk.call(self)
        self.close
      end
    end

    # write a record to the file or handle

    def write(record)
      @fh.write(MARC::Writer.encode(record, allow_oversized, encoding: @encoding, marc8_options: @marc8_options))
    end

    # close underlying filehandle

    def close
      @fh.close
    end

    # a static method that accepts a MARC::Record object
    # and returns the record encoded as MARC21 in transmission format
    #
    # Second arg allow_oversized, default false, set to true
    # to raise on MARC record that can't fit into ISO 2709.
    #
    # With keyword arg encoding set to "MARC-8", field values are first
    # transcoded from UTF-8 to MARC-8 (see MARC::Marc8::ToMarc8), and the
    # leader's character coding scheme flag is set to MARC-8.
    def self.encode(record, allow_oversized = false, encoding: nil, marc8_options: {})
      if encoding == "MARC-8"
        require "marc/marc8/to_marc8" unless defined?(MARC::Marc8::ToMarc8)
        marc8_record = transcode_record_to_marc8(record, marc8_options)
        encoded = encode(marc8_record, allow_oversized)
        # keep the passed-in record's leader in sync, as we do ordinarily
        record.leader = marc8_record.leader
        return encoded
      end

      directory = +""
      fields = +""
      offset = 0
      record.each do |field|
        # encode the field
        field_data = +""
        if field.instance_of?(MARC::DataField)
          warn("Warn:  Missing indicator") unless field.indicator1 && field.indicator2
          field_data = (field.indicator1 || " ") + (field.indicator2 || " ")
          field.subfields.each do |s|
            field_data += SUBFIELD_INDICATOR + s.code + s.value
          end
        elsif field.instance_of?(MARC::ControlField)
          field_data = field.value
        end
        field_data += END_OF_FIELD

        # calculate directory entry for the field
        field_length = (field_data.respond_to?(:bytesize) ?
                          field_data.bytesize :
                          field_data.length)
        directory += sprintf("%03s", field.tag) + format_byte_count(field_length, allow_oversized, 4) + format_byte_count(offset, allow_oversized)

        # add field to data for other fields
        fields += field_data

        # update offset for next field
        offset += field_length
      end

      # determine the base (leader + directory)
      base = record.leader + directory + END_OF_FIELD

      # determine complete record
      marc = base + fields + END_OF_RECORD

      # update leader with the byte offest to the end of the directory
      bytesize = base.respond_to?(:bytesize) ? base.bytesize() : base.length
      marc[12..16] = format_byte_count(bytesize, allow_oversized)

      # update the record length
      bytesize = marc.respond_to?(:bytesize) ? marc.bytesize() : marc.length
      marc[0..4] = format_byte_count(bytesize, allow_oversized)

      # store updated leader in the record that was passed in
      record.leader = marc[0..LEADER_LENGTH - 1]

      # return encoded marc
      marc
    end

    # Returns a new MARC::Record with all field values transcoded from
    # UTF-8 to MARC-8 (binary-tagged strings), and the leader's character
    # coding scheme flag (byte 9) set to MARC-8. A fresh transcoder is
    # used for every record, so character set designation state never
    # leaks between records.
    def self.transcode_record_to_marc8(record, marc8_options = {})
      transcoder = MARC::Marc8::ToMarc8.new(marc8_options)
      transcoded = MARC::Record.new
      leader = record.leader.dup
      leader[9] = " " # MARC-8 character coding scheme
      transcoded.leader = leader
      record.each do |field|
        if field.instance_of?(MARC::DataField)
          new_field = MARC::DataField.new(field.tag, field.indicator1, field.indicator2)
          field.subfields.each do |subfield|
            new_field.append(MARC::Subfield.new(subfield.code, transcoder.transcode(subfield.value)))
          end
          transcoded.append(new_field)
        elsif field.instance_of?(MARC::ControlField)
          transcoded.append(MARC::ControlField.new(field.tag, transcoder.transcode(field.value)))
        end
      end
      transcoded
    end

    # Formats numbers for insertion into marc binary slots.
    # These slots only allow so many digits (and need to be left-padded
    # with spaces to that number of digits). If the number
    # is too big, either an exception will be raised, or
    # we'll return all 0's to proper number of digits.
    #
    # first arg is number, second is boolean whether to allow oversized,
    # third is max digits (default 5)
    def self.format_byte_count(number, allow_oversized, num_digits = 5)
      formatted = sprintf("%0#{num_digits}i", number)
      if formatted.length > num_digits
        # uh, oh, we've exceeded our max. Either zero out
        # or raise, depending on settings.
        if allow_oversized
          formatted = sprintf("%0#{num_digits}i", 0)
        else
          raise MARC::Exception.new("Can't write MARC record in binary format, as a length/offset value of #{number} is too long for a #{num_digits}-byte slot.")
        end
      end
      formatted
    end
  end
end
