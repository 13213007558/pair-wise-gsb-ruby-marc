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
  class Writer
    attr_accessor :allow_oversized
    attr_reader :encoding_options

    # the constructor which you must pass a file path
    # or an object that responds to a write message

    def initialize(file, **options, &blk)
      if file.instance_of?(String)
        @fh = File.new(file, self.class.marc8?(options) ? "w:binary" : "w")
      elsif file.respond_to?(:write)
        @fh = file
      else
        raise ArgumentError, "must pass in file name or handle"
      end
      self.allow_oversized = false
      @encoding_options = {}
      options.each { |key, value| @encoding_options[key.to_sym] = value }

      if block_given?
        blk.call(self)
        self.close
      end
    end

    # write a record to the file or handle

    def write(record)
      @fh.write(MARC::Writer.encode(record, allow_oversized, **encoding_options))
    end

    # close underlying filehandle

    def close
      @fh.close
    end

    # Encode a record as MARC 21 transmission bytes. Pass
    # +external_encoding: "MARC-8"+ to transcode UTF-8 field values to MARC-8.
    #
    # Second arg allow_oversized, default false, set to true
    # to raise on MARC record that can't fit into ISO 2709.
    def self.encode(record, allow_oversized = false, **options)
      options = options.each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
      marc8_output = marc8?(options)
      original_leader = record.leader.dup if marc8_output
      directory = +""
      fields = +""
      offset = 0
      record.each do |field|
        transcode_options = marc8_transcode_options(options)
        # encode the field
        field_data = String.new.force_encoding(Encoding::ASCII_8BIT)
        if field.instance_of?(MARC::DataField)
          warn("Warn:  Missing indicator") unless field.indicator1 && field.indicator2
          field_data << encode_text(field.indicator1 || " ", new_marc8_encoder(options), transcode_options)
          field_data << encode_text(field.indicator2 || " ", new_marc8_encoder(options), transcode_options)
          field.subfields.each do |s|
            field_data << SUBFIELD_INDICATOR
            field_data << encode_text(s.code, new_marc8_encoder(options), transcode_options)
            field_data << encode_text(s.value, new_marc8_encoder(options), transcode_options)
          end
        elsif field.instance_of?(MARC::ControlField)
          field_data << encode_text(field.value, new_marc8_encoder(options), transcode_options)
        end
        field_data << END_OF_FIELD

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
      leader = record.leader.dup
      leader[9] = " " if marc8_output && leader[9] != " "
      base = encode_text(leader, nil).force_encoding(Encoding::ASCII_8BIT)
      base += directory + END_OF_FIELD

      # determine complete record
      marc = base + fields + END_OF_RECORD

      # update leader with the byte offest to the end of the directory
      bytesize = base.respond_to?(:bytesize) ? base.bytesize() : base.length
      marc[12..16] = format_byte_count(bytesize, allow_oversized)

      # update the record length
      bytesize = marc.respond_to?(:bytesize) ? marc.bytesize() : marc.length
      marc[0..4] = format_byte_count(bytesize, allow_oversized)

      if marc8_output
        generated_leader = marc[0..LEADER_LENGTH - 1]
        generated_leader[9] = original_leader[9]
        record.leader = generated_leader
      else
        record.leader = marc[0..LEADER_LENGTH - 1]
      end

      # return encoded marc
      marc
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

    def self.marc8?(options)
      options[:external_encoding].to_s.upcase == "MARC-8"
    end

    def self.new_marc8_encoder(options)
      return unless marc8?(options)

      require "marc/marc8/from_unicode" unless defined? MARC::Marc8::FromUnicode
      encoder_options = {}
      [:allowed_charsets, :charsets, :invalid, :replace].each do |key|
        encoder_options[key] = options[key] if options.key?(key)
      end
      MARC::Marc8::FromUnicode.new(encoder_options)
    end

    def self.marc8_transcode_options(options)
      transcode_options = {}
      [:invalid, :replace].each do |key|
        transcode_options[key] = options[key] if options.key?(key)
      end
      transcode_options
    end

    def self.encode_text(value, encoder, options = nil)
      if encoder
        text = encoder.transcode(value, options || {})
      else
        text = value.to_s
        text = text.dup
        text.force_encoding(Encoding::BINARY)
      end
    end
  end
end
