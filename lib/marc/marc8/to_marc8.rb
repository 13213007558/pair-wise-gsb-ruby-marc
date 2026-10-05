require "marc"
require "marc/marc8/map_to_unicode"

module MARC
  module Marc8
    # Class to convert UTF-8 to MARC-8, the reverse of
    # MARC::Marc8::ToUnicode. Requires ruby 1.9+.
    #
    # http://www.loc.gov/marc/specifications/speccharmarc8.html
    #
    # NOT thread-safe, it keeps character set designation state while
    # transcoding, do not share an instance between threads.
    #
    # State is reset at the beginning of every #transcode call, so every
    # transcoded string (eg. every MARC record, or every field) is
    # independent: it always starts out with the MARC-8 default character
    # sets (Basic Latin in G0, ANSEL in G1).
    #
    # The set of MARC-8 character sets the encoder is allowed to use can be
    # restricted by the caller:
    #
    #     # by code, one-character string, or symbolic name
    #     MARC::Marc8::ToMarc8.new(charsets: [0x42, "E", :eacc])
    #
    # Characters that can not be represented with the available character
    # sets raise an Encoding::UndefinedConversionError (reporting the
    # character offset in the input) by default. Pass :invalid => :replace
    # to instead substitute a replacement text -- by default a MARC-8
    # escaped unicode 'named character reference' like "&#x4E2D;", which
    # MARC::Marc8::ToUnicode expands back to the original character
    # (http://www.loc.gov/marc/specifications/speccharconversion.html#lossless).
    # A custom replacement can be supplied with :replace. Replaced
    # characters (with their offsets) are collected in #replacements.
    #
    # When a character can be represented in more than one character set,
    # the representation requiring the fewest escape sequences overall is
    # chosen; ties are broken deterministically, so output is stable.
    class ToMarc8
      BASIC_LATIN = 0x42
      ANSEL = 0x45
      EACC = 0x31

      CODESETS = MARC::Marc8::MapToUnicode::CODESETS

      CHARSET_NAMES = {
        extended_arabic: 0x34,
        ansel: 0x45,
        basic_arabic: 0x33,
        basic_hebrew: 0x32,
        eacc: 0x31,
        cjk: 0x31,
        superscripts: 0x70,
        extended_cyrillic: 0x51,
        basic_greek: 0x53,
        basic_latin: 0x42,
        subscripts: 0x62,
        greek_symbols: 0x67,
        basic_cyrillic: 0x4E
      }.freeze

      # Preference order when several representations need the same number
      # of escape sequences; keeps output deterministic and unsurprising.
      CHARSET_PREFERENCE = [BASIC_LATIN, ANSEL, EACC].freeze

      # Character set designations in effect at the start of a transcode;
      # reset to the MARC-8 defaults on every call.
      attr_reader :g0, :g1

      # List of [character_offset, character] pairs that were replaced
      # during the most recent #transcode call (only with :invalid => :replace).
      attr_reader :replacements

      def initialize(options = {})
        allowed = options[:charsets] || CODESETS.keys
        @charsets = allowed.map { |c| self.class.normalize_charset(c) }.freeze
        @default_options = {}
        @default_options[:invalid] = options[:invalid] if options.has_key?(:invalid)
        @default_options[:replace] = options[:replace] if options.has_key?(:replace)
        @g0 = BASIC_LATIN
        @g1 = ANSEL
        @replacements = []
      end

      # Returns a binary (ASCII-8BIT) encoded string of MARC-8 bytes
      # equivalent to the UTF-8 string passed in.
      #
      # Options (also settable as defaults in the constructor):
      #
      # * :invalid => :replace -- substitute unrepresentable characters
      #   instead of raising Encoding::UndefinedConversionError.
      # * :replace => "..." -- replacement text for unrepresentable
      #   characters; defaults to a per-character escaped unicode named
      #   character reference ("&#xXXXX;"). Must itself be representable.
      def transcode(utf8_string, options = {})
        return (+"").b if utf8_string.nil? || utf8_string.empty?

        options = @default_options.merge(options)
        invalid = options[:invalid]
        replacement = options[:replace]

        @g0 = BASIC_LATIN
        @g1 = ANSEL
        @replacements = []

        unless utf8_string.encoding == Encoding::UTF_8
          utf8_string = utf8_string.encode(Encoding::UTF_8)
        end

        # Each unit is a list of candidate representations; a representation
        # is an ordered list of steps, each step being
        # {slot:, charset:, bytes:} where slot is :g0, :g1 or nil (raw byte,
        # no character set designation needed).
        units = []
        each_cluster(utf8_string) do |pos, base, marks|
          units.concat(units_for(pos, base, marks, invalid, replacement))
        end

        out = (+"").b
        choose_representations(units).each do |rep|
          rep.each do |step|
            if step[:slot] == :g0 && @g0 != step[:charset]
              out << g0_escape(step[:charset])
              @g0 = step[:charset]
            elsif step[:slot] == :g1 && @g1 != step[:charset]
              out << g1_escape(step[:charset])
              @g1 = step[:charset]
            end
            out << step[:bytes]
          end
        end
        out
      end

      # Reverse lookup table: unicode codepoint =>
      # [[charset, marc8 codepoint, combining_flag], ...]. Entries the
      # ToUnicode decoder can never map back (bytes below 0x20 and between
      # 0x81-0x9F, which it treats as control characters) are excluded.
      def self.reverse_map
        @reverse_map ||= begin
          rev = Hash.new { |hash, key| hash[key] = [] }
          CODESETS.each do |charset, map|
            map.each do |marc8_cp, (uni_cp, cflag)|
              next if marc8_cp < 0x20 || (marc8_cp > 0x80 && marc8_cp < 0xA0)
              rev[uni_cp] << [charset, marc8_cp, cflag]
            end
          end
          rev
        end
      end

      def self.normalize_charset(charset)
        case charset
        when Integer
          charset
        when Symbol
          CHARSET_NAMES.fetch(charset) do
            raise ArgumentError, "unknown MARC-8 character set name: #{charset.inspect}"
          end
        when String
          if charset.length == 1
            charset.ord
          elsif CHARSET_NAMES.has_key?(charset.to_sym)
            CHARSET_NAMES[charset.to_sym]
          else
            raise ArgumentError, "unknown MARC-8 character set: #{charset.inspect}"
          end
        else
          raise ArgumentError, "unknown MARC-8 character set: #{charset.inspect}"
        end
      end

      private

      def multibyte?(charset)
        charset == EACC
      end

      def mark?(codepoint)
        /\p{M}/.match?([codepoint].pack("U"))
      end

      # Control characters the ToUnicode decoder passes through untouched,
      # so we emit them as raw bytes. 0x1B (ESCAPE) is excluded: emitting it
      # raw would corrupt the escape-sequence stream, so it is treated as
      # unrepresentable instead.
      def control_passthrough?(codepoint)
        (codepoint < 0x20 && codepoint != 0x1B) ||
          (codepoint > 0x80 && codepoint < 0xA0)
      end

      def lookup(uni_cp, combining)
        self.class.reverse_map[uni_cp].select do |charset, _marc8_cp, cflag|
          cflag == combining && @charsets.include?(charset)
        end
      end

      # Yields [character_offset, base_codepoint, [[mark_codepoint, offset], ...]]
      # for each base character and its trailing unicode combining marks.
      # Marks with no preceding base character are yielded with a nil base.
      def each_cluster(str)
        cps = str.codepoints
        i = 0
        while i < cps.length
          if mark?(cps[i])
            yield i, nil, [[cps[i], i]]
            i += 1
          else
            j = i + 1
            j += 1 while j < cps.length && mark?(cps[j])
            marks = (i...j).map { |k| [cps[k], k] }
            yield i, cps[i], marks[1..] || []
            i = j
          end
        end
      end

      def units_for(pos, base, marks, invalid, replacement)
        if base && marks.empty? && control_passthrough?(base)
          return [[[{slot: nil, charset: nil, bytes: base.chr}]]]
        end

        # original characters of the cluster, with their offsets, for
        # error reporting and replacement
        orig = (base ? [[base, pos]] : []) + marks

        base_options = base ? lookup(base, false) : []
        cluster_marks = marks

        if base_options.empty?
          # No direct mapping for the (possibly precomposed) base character:
          # decompose, eg. U+00E9 becomes "e" + U+0301, which is how MARC-8
          # represents such characters. Decomposed characters inherit the
          # offset of the character they came from.
          decomposed = orig.flat_map do |cp, cp_pos|
            [cp].pack("U*").unicode_normalize(:nfd).codepoints.map { |d| [d, cp_pos] }
          end
          base = decomposed[0][0]
          cluster_marks = decomposed[1..] || []
          base_options = lookup(base, false)
        end

        if base_options.empty?
          unrepresentable!(pos, orig[0][0], invalid)
          return orig.flat_map { |cp, cp_pos| replacement_units(cp_pos, cp, replacement) }
        end

        # Marks that have no mapping of their own may still decompose into
        # representable characters (eg. U+0340 -> U+0300).
        cluster_marks = cluster_marks.flat_map do |cp, cp_pos|
          if lookup(cp, true).empty? && lookup(cp, false).empty?
            [cp].pack("U*").unicode_normalize(:nfd).codepoints.map { |d| [d, cp_pos] }
          else
            [[cp, cp_pos]]
          end
        end

        # MARC-8 combining marks precede their base character. Unicode
        # marks that are ordinary spacing characters in MARC-8 (eg. U+0654
        # ARABIC HAMZA ABOVE) stay in their logical position after the
        # base. Marks with no representation at all are replaced (or raise).
        combinable = []
        regular = []
        bad = []
        cluster_marks.each do |cp, cp_pos|
          if !lookup(cp, true).empty?
            combinable << cp
          elsif !lookup(cp, false).empty?
            regular << [cp, cp_pos]
          else
            bad << [cp, cp_pos]
          end
        end

        units = [build_reps(base_options, combinable)]
        regular.each do |cp, _cp_pos|
          units << build_reps(lookup(cp, false), [])
        end
        bad.each do |cp, cp_pos|
          unrepresentable!(cp_pos, cp, invalid)
          units.concat(replacement_units(cp_pos, cp, replacement))
        end
        units
      end

      def unrepresentable!(pos, codepoint, invalid)
        return if invalid == :replace

        raise Encoding::UndefinedConversionError,
          format("U+%04X (%s) at character offset %d can not be represented in MARC-8 with the available character sets",
            codepoint, [codepoint].pack("U"), pos)
      end

      def replacement_units(pos, codepoint, replacement)
        @replacements << [pos, [codepoint].pack("U")]
        text = replacement || ("&#x%04X;" % codepoint)
        units = []
        each_cluster(text) do |_rpos, base, marks|
          if base && marks.empty? && control_passthrough?(base)
            units << [[{slot: nil, charset: nil, bytes: base.chr}]]
            next
          end
          options = base ? lookup(base, false) : []
          good_marks = marks.map(&:first).reject { |cp| lookup(cp, true).empty? }
          if options.empty? || good_marks.length != marks.length
            raise MARC::Exception,
              "MARC-8 replacement text #{text.inspect} can not be represented with the available character sets"
          end
          units << build_reps(options, good_marks)
        end
        units
      end

      # All candidate representations for one cluster: every base character
      # option combined with every way to express the combining marks.
      def build_reps(base_options, marks)
        mark_options = marks.map { |cp| lookup(cp, true) }

        variants = [[]]
        unless marks.empty?
          common = mark_options.map { |opts| opts.map(&:first) }.reduce(:&)
          variants = sort_charsets(common).map do |charset|
            mark_options.map { |opts| opts.find { |o| o[0] == charset } }
          end
          if variants.empty?
            # no single character set covers all marks; fall back to the
            # preferred character set for each mark independently
            variants = [mark_options.map { |opts| opts.min_by { |o| charset_rank(o[0]) } }]
          end
        end

        reps = []
        sort_options(base_options).each do |base_charset, base_cp, _|
          variants.each do |mark_choices|
            steps = mark_choices.map { |charset, marc8_cp, _| step_for(charset, marc8_cp) }
            steps << step_for(base_charset, base_cp)
            reps << steps
          end
        end
        reps.sort_by { |rep| rep_sort_key(rep) }
      end

      def step_for(charset, marc8_cp)
        if multibyte?(charset)
          {slot: :g0, charset: charset,
           bytes: [marc8_cp >> 16, (marc8_cp >> 8) & 0xFF, marc8_cp & 0xFF].pack("C3")}
        elsif marc8_cp > 0x80
          {slot: :g1, charset: charset, bytes: marc8_cp.chr}
        else
          {slot: :g0, charset: charset, bytes: marc8_cp.chr}
        end
      end

      def charset_rank(charset)
        CHARSET_PREFERENCE.index(charset) || (CHARSET_PREFERENCE.length + charset)
      end

      def sort_charsets(charsets)
        charsets.sort_by { |c| charset_rank(c) }
      end

      def sort_options(options)
        options.sort_by { |charset, marc8_cp, _| [charset_rank(charset), marc8_cp] }
      end

      def rep_sort_key(rep)
        rep.map do |step|
          [step[:slot] ? 0 : 1, charset_rank(step[:charset] || 0), step[:bytes]]
        end
      end

      # Picks one representation per unit, minimizing the total number of
      # escape sequences (character set designations) over the whole string.
      # Ties are broken by representation order, which is deterministic.
      def choose_representations(units)
        dp = {[BASIC_LATIN, ANSEL] => 0}
        parents = []

        units.each_with_index do |reps, i|
          next_dp = {}
          parent = {}
          dp.each do |state, cost|
            reps.each do |rep|
              new_state, escapes = simulate(state, rep)
              total = cost + escapes
              if !next_dp.has_key?(new_state) || total < next_dp[new_state]
                next_dp[new_state] = total
                parent[new_state] = [state, rep]
              end
            end
          end
          dp = next_dp
          parents << parent
        end

        state = dp.keys.min_by { |s| [dp[s], s] }
        chosen = []
        (units.length - 1).downto(0) do |i|
          prev_state, rep = parents[i][state]
          chosen.unshift(rep)
          state = prev_state
        end
        chosen
      end

      def simulate(state, rep)
        g0, g1 = state
        escapes = 0
        rep.each do |step|
          case step[:slot]
          when :g0
            if g0 != step[:charset]
              escapes += 1
              g0 = step[:charset]
            end
          when :g1
            if g1 != step[:charset]
              escapes += 1
              g1 = step[:charset]
            end
          end
        end
        [[g0, g1], escapes]
      end

      def g0_escape(charset)
        if multibyte?(charset)
          "\x1B$1".b
        else
          "\x1B(".b << charset
        end
      end

      def g1_escape(charset)
        "\x1B)".b << charset
      end
    end
  end
end
