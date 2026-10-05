# frozen_string_literal: true

require "marc"
require "marc/marc8/map_to_unicode"
require "set"

module MARC
  module Marc8
    # Convert UTF-8 strings to MARC-8.
    class FromUnicode
      BASIC_LATIN = 0x42
      ANSEL = 0x45
      EACC = 0x31
      ESCAPE = 0x1b
      G0_DESIGNATE = 0x28
      G1_DESIGNATE = 0x29
      MULTIBYTE_DESIGNATE = 0x24
      MAP_PATH = File.expand_path("map_to_unicode.rb", __dir__)

      CODESETS = MARC::Marc8::MapToUnicode::CODESETS

      def initialize(options = {})
        @allowed_charsets = extract_allowed_charsets(options)
        @replace_invalid = options[:invalid] == :replace
        @replacement = options.fetch(:replace, "?")
        @inverse = self.class.inverse_map(@allowed_charsets)
        reset_state
      end

      # Encode a string as MARC-8 bytes. With +invalid: :replace+ and
      # +replace+ the supplied replacement text is used for unrepresentable
      # characters. +allowed_charsets+ limits usable MARC-8 character sets.
      def transcode(utf8_string, options = {})
        return +"" if utf8_string.nil? || utf8_string.empty?

        string = prepare_string(utf8_string)
        replace_invalid = options.fetch(:invalid, @replace_invalid) == :replace
        replacement = options.fetch(:replace, @replacement)

        reset_state if options.fetch(:reset_state, true)
        output = String.new.force_encoding(Encoding::ASCII_8BIT)
        each_cluster(string) do |components|
          append_cluster(output, components, replace_invalid, replacement)
        end
        output
      end

      def reset_state
        @g0 = BASIC_LATIN
        @g1 = ANSEL
      end

      def self.inverse_map(allowed_charsets = nil)
        @inverse_maps ||= {}
        allowed = (allowed_charsets || CODESETS.keys).sort
        @inverse_maps[allowed] ||= build_inverse_map(allowed)
      end

      def self.build_inverse_map(allowed_charsets)
        inverse = Hash.new { |hash, key| hash[key] = [] }
        variant_codes = variant_marc8_codes

        CODESETS.each do |charset, mappings|
          next unless allowed_charsets.include?(charset)

          mappings.each do |marc8_code, (unicode_code, combining)|
            next if marc8_code < 0x20
            inverse[unicode_code] << {
              charset: charset,
              code: marc8_code,
              combining: combining,
              variant: variant_codes.include?([charset, marc8_code])
            }
          end
        end

        inverse.each_value do |candidates|
          candidates.sort_by! do |candidate|
            [candidate[:charset], candidate[:variant] ? 1 : 0, candidate[:code]]
          end
        end
        inverse
      end

      def self.variant_marc8_codes
        @variant_marc8_codes ||= begin
          charset = nil
          File.readlines(MAP_PATH, encoding: "UTF-8").each_with_object(Set.new) do |line, variants|
            match = line.match(/CHARSET_([0-9A-Fa-f]+)\s*=/)
            charset = match[1].to_i(16) if match

            mapping = line.match(/\b0x([0-9A-Fa-f]+)\s*=>\s*\[0x[0-9A-Fa-f]+,\s*(?:true|false)\]/)
            if charset && mapping && line =~ /variant/i
              variants << [charset, mapping[1].to_i(16)]
            end
          end
        end
      end

      private

      def extract_allowed_charsets(options)
        charsets = options[:allowed_charsets] || options[:charsets] || CODESETS.keys
        names = charset_names
        resolved = Array(charsets).map do |charset|
          if charset.is_a?(Integer)
            charset
          elsif names.key?(charset.to_s.upcase)
            names[charset.to_s.upcase]
          elsif charset.to_s =~ /\A[0-9A-Fa-f]+\z/
            charset.to_i(16)
          else
            charset.ord
          end
        end
        (resolved + [BASIC_LATIN]).uniq.sort
      end

      def charset_names
        {
          "BASIC_LATIN" => BASIC_LATIN,
          "BASIC LATIN" => BASIC_LATIN,
          "B" => BASIC_LATIN,
          "ANSEL" => ANSEL,
          "EXTENDED_LATIN" => ANSEL,
          "EXTENDED LATIN" => ANSEL,
          "E" => ANSEL,
          "EACC" => EACC,
          "CJK" => EACC,
          "1" => EACC
        }
      end

      def prepare_string(string)
        result = string.dup
        result.force_encoding(Encoding::UTF_8) unless result.encoding == Encoding::UTF_8
        unless result.valid_encoding?
          raise Encoding::InvalidByteSequenceError.new("invalid UTF-8 input for MARC-8 encoding")
        end
        result
      end

      def each_cluster(string)
        codepoints = string.each_codepoint.to_a
        index = 0

        while index < codepoints.length
          codepoint = codepoints[index]
          position = character_position(codepoints, index)
          components = starting_components(codepoint, position)
          index += 1

          while index < codepoints.length && combining_codepoint?(codepoints[index])
            components << [codepoints[index], character_position(codepoints, index)]
            index += 1
          end

          yield components
        end
      end

      def starting_components(codepoint, position)
        if combining_codepoint?(codepoint) || direct_candidates(codepoint, false).any?
          [[codepoint, position]]
        else
          unicode_char(codepoint).unicode_normalize(:nfd).each_codepoint.map do |part|
            [part, position]
          end
        end
      end

      def character_position(codepoints, codepoint_index)
        position = 0
        codepoints[0...codepoint_index].each { |codepoint| position += unicode_char(codepoint).length }
        position
      end

      def combining_codepoint?(codepoint)
        (0x300..0x36f).cover?(codepoint) ||
          (0x1ab0..0x1aff).cover?(codepoint) ||
          (0x1dc0..0x1dff).cover?(codepoint) ||
          (0x20d0..0x20ff).cover?(codepoint) ||
          (0xfe20..0xfe2f).cover?(codepoint)
      end

      def unicode_char(codepoint)
        codepoint.chr(Encoding::UTF_8)
      end

      def append_cluster(output, components, replace_invalid, replacement)
        before_marks_g0 = @g0
        before_marks_g1 = @g1
        marks = components.select { |codepoint, _position| combining_codepoint?(codepoint) }
        base = components.find { |codepoint, _position| !combining_codepoint?(codepoint) }

        append_components(output, marks.reverse, replace_invalid, replacement)
        after_marks_g0 = @g0
        after_marks_g1 = @g1
        @g0 = before_marks_g0
        @g1 = before_marks_g1
        output << ESCAPE.chr(Encoding::ASCII_8BIT) << G0_DESIGNATE.chr(Encoding::ASCII_8BIT) << before_marks_g0.chr(Encoding::ASCII_8BIT) if marks.any? && after_marks_g0 != before_marks_g0
        if marks.any? && after_marks_g1 != before_marks_g1
          output << ESCAPE.chr(Encoding::ASCII_8BIT) << G1_DESIGNATE.chr(Encoding::ASCII_8BIT) << before_marks_g1.chr(Encoding::ASCII_8BIT)
        end
        append_components(output, [base].compact, replace_invalid, replacement)
      end

      def append_components(output, components, replace_invalid, replacement)
        components.each do |codepoint, position|
          candidates = direct_candidates(codepoint, combining_codepoint?(codepoint))
          if candidates.empty?
            append_replacement(output, codepoint, position, replace_invalid, replacement)
          else
            append_candidate(output, choose_candidate(candidates))
          end
        end
      end

      def direct_candidates(codepoint, combining)
        @inverse.fetch(codepoint, []).select do |candidate|
          candidate[:combining] == combining
        end
      end

      def choose_candidate(candidates)
        candidates.min_by do |candidate|
          plane = candidate_plane(candidate)
          current_charset = plane == :g0 ? @g0 : @g1
          default_charset = plane == :g0 ? BASIC_LATIN : ANSEL
          [
            current_charset == candidate[:charset] ? 0 : 1,
            candidate[:charset] == default_charset ? 0 : 1,
            candidate[:charset],
            candidate[:code]
          ]
        end
      end

      def append_candidate(output, candidate)
        plane = candidate_plane(candidate)
        append_escape(output, candidate[:charset], plane)

        if candidate[:charset] == EACC
          code = candidate[:code]
          output << ((code >> 16) & 0xff).chr(Encoding::ASCII_8BIT)
          output << ((code >> 8) & 0xff).chr(Encoding::ASCII_8BIT)
          output << (code & 0xff).chr(Encoding::ASCII_8BIT)
        else
          output << candidate[:code].chr(Encoding::ASCII_8BIT)
        end
      end

      def candidate_plane(candidate)
        return :g0 if candidate[:charset] == EACC
        candidate[:code] < 0x80 ? :g0 : :g1
      end

      def append_escape(output, charset, plane)
        current_charset = plane == :g0 ? @g0 : @g1
        return if current_charset == charset

        output << ESCAPE.chr(Encoding::ASCII_8BIT)
        if plane == :g0
          output << MULTIBYTE_DESIGNATE.chr(Encoding::ASCII_8BIT) if charset == EACC
          output << (charset == EACC ? charset.chr(Encoding::ASCII_8BIT) : G0_DESIGNATE.chr(Encoding::ASCII_8BIT))
          output << charset.chr(Encoding::ASCII_8BIT) unless charset == EACC
          @g0 = charset
        else
          output << G1_DESIGNATE.chr(Encoding::ASCII_8BIT)
          output << charset.chr(Encoding::ASCII_8BIT)
          @g1 = charset
        end
      end


      def append_replacement(output, codepoint, position, replace_invalid, replacement)
        unless replace_invalid
          hex = codepoint.to_s(16).upcase.rjust(4, "0")
          raise Encoding::UndefinedConversionError.new(
            "MARC-8 cannot encode U+#{hex} at character position #{position}"
          )
        end

        replacement.to_s.each_codepoint do |replacement_codepoint|
          candidates = direct_candidates(
            replacement_codepoint,
            combining_codepoint?(replacement_codepoint)
          )
          if candidates.empty?
            hex = replacement_codepoint.to_s(16).upcase.rjust(4, "0")
            raise Encoding::UndefinedConversionError.new(
              "MARC-8 replacement contains U+#{hex}"
            )
          end
          append_candidate(output, choose_candidate(candidates))
        end
      end
    end
  end
end
