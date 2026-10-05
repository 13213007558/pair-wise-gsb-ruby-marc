require "test/unit"
require "marc"

require "marc/marc8/to_unicode"
require "marc/marc8/to_marc8"

if "".respond_to?(:encoding)

  class TestMarc8ToMarc8 < Test::Unit::TestCase
    def decode(marc8)
      MARC::Marc8::ToUnicode.new.transcode(marc8)
    end

    def test_empty_string
      value = MARC::Marc8::ToMarc8.new.transcode("")
      assert_equal "ASCII-8BIT", value.encoding.name
      assert_equal "", value

      value = MARC::Marc8::ToMarc8.new.transcode(nil)
      assert_equal "ASCII-8BIT", value.encoding.name
      assert_equal "", value
    end

    def test_plain_ascii
      value = MARC::Marc8::ToMarc8.new.transcode("Hello, world!")
      assert_equal "ASCII-8BIT", value.encoding.name
      assert_equal "Hello, world!".b, value
    end

    def test_ansel_combining_marks
      converter = MARC::Marc8::ToMarc8.new

      # precomposed (NFC) input
      assert_equal "Conversa\xF0c\xE4ao".b, converter.transcode("Conversa\u00E7\u00E3o")
      # canonically decomposed (NFD) input produces the same bytes
      assert_equal "Conversa\xF0c\xE4ao".b,
        converter.transcode("Conversa\u00E7\u00E3o".unicode_normalize(:nfd))
      # combining mark precedes its base character in MARC-8
      assert_equal "caf\xE2e".b, converter.transcode("caf\u00E9")
    end

    def test_ansel_direct_mapping_needs_no_escape
      # U+2113 (script small l) maps directly into ANSEL, which is the
      # default G1 set, so no escape sequences are needed at all.
      converter = MARC::Marc8::ToMarc8.new
      assert_equal "caf\xE2e \xC1".b, converter.transcode("caf\u00E9 \u2113")
    end

    def test_eacc_multibyte
      converter = MARC::Marc8::ToMarc8.new
      assert_equal "\x1B$1!04K7o".b, converter.transcode("\u4E2D\u56FD")
    end

    def test_consecutive_different_charsets
      converter = MARC::Marc8::ToMarc8.new
      assert_equal "ab\x1B$1!04K7o\x1B(Bcd".b,
        converter.transcode("ab\u4E2D\u56FDcd")
    end

    def test_greek_g0_designation
      converter = MARC::Marc8::ToMarc8.new
      assert_equal "\x1B(Sabd".b, converter.transcode("\u03B1\u03B2\u03B3")
    end

    def test_superscripts
      converter = MARC::Marc8::ToMarc8.new
      assert_equal "\x1B(p2".b, converter.transcode("\u00B2")
    end

    def test_prefers_fewer_escape_sequences
      converter = MARC::Marc8::ToMarc8.new

      # The exclamation mark is available in Basic Latin, Basic Hebrew and
      # others. Switching to Basic Hebrew just for it and back again would
      # cost extra escapes; reusing the already-designated Hebrew set is
      # cheaper, so only one escape sequence is emitted for the string.
      value = converter.transcode("\u05D0!\u05D1")
      assert_equal 1, value.count("\x1B")
      assert_equal "\x1B(2\x60!a".b, value

      # sanity check the general case too: latin -> cjk -> latin
      value = converter.transcode("ab\u4E2D\u56FDcd")
      assert_equal 2, value.count("\x1B")
    end

    def test_stable_output
      input = "Conversac\u00E7\u00E3o \u4E2D\u56FD \u03B1\u03B2 !"
      first = MARC::Marc8::ToMarc8.new.transcode(input)
      5.times do
        assert_equal first, MARC::Marc8::ToMarc8.new.transcode(input)
      end
      # and repeated calls on one instance are independent
      converter = MARC::Marc8::ToMarc8.new
      assert_equal converter.transcode(input), converter.transcode(input)
    end

    def test_state_reset_between_calls
      converter = MARC::Marc8::ToMarc8.new
      converter.transcode("\u4E2D\u56FD")
      # a following call starts again with default character sets,
      # no escape sequences needed for plain latin
      assert_equal "plain".b, converter.transcode("plain")
    end

    def test_unrepresentable_raises_with_position
      converter = MARC::Marc8::ToMarc8.new
      error = assert_raise(Encoding::UndefinedConversionError) do
        converter.transcode("ab\u{1F600}cd")
      end
      assert_match(/U\+1F600/, error.message)
      assert_match(/offset 2/, error.message)
    end

    def test_unrepresentable_replace_default_ncr
      converter = MARC::Marc8::ToMarc8.new
      value = converter.transcode("a\u{1F600}b", invalid: :replace)
      assert_equal "a&#x1F600;b".b, value
      assert_equal [[1, "\u{1F600}"]], converter.replacements

      # the default replacement is a lossless escaped character reference:
      # the decoder expands it back to the original character
      assert_equal "a\u{1F600}b", decode(value)
    end

    def test_unrepresentable_replace_custom_text
      converter = MARC::Marc8::ToMarc8.new
      value = converter.transcode("a\u{1F600}b", invalid: :replace, replace: "?")
      assert_equal "a?b".b, value
      assert_equal [[1, "\u{1F600}"]], converter.replacements
    end

    def test_unrepresentable_combining_mark_replaced_after_base
      # only Basic Latin allowed: the base letter can be encoded, the
      # combining mark can not, it is replaced after the base character
      converter = MARC::Marc8::ToMarc8.new(charsets: [:basic_latin])
      value = converter.transcode("e\u0301", invalid: :replace)
      assert_equal "e&#x0301;".b, value
      assert_equal [[1, "\u0301"]], converter.replacements
      assert_equal "e\u0301", decode(value).unicode_normalize(:nfd)
    end

    def test_baseless_combining_mark
      converter = MARC::Marc8::ToMarc8.new
      # a combining mark with no base character to attach to can not be
      # represented in MARC-8
      assert_raise(Encoding::UndefinedConversionError) do
        converter.transcode("\u0301abc")
      end
      value = converter.transcode("\u0301abc", invalid: :replace)
      assert_equal "&#x0301;abc".b, value
      assert_equal [[0, "\u0301"]], converter.replacements
    end

    def test_charset_restriction
      converter = MARC::Marc8::ToMarc8.new(charsets: [:basic_latin, :ansel])
      assert_raise(Encoding::UndefinedConversionError) do
        converter.transcode("\u4E2D")
      end
      # allowed charsets still work
      assert_equal "caf\xE2e".b, converter.transcode("caf\u00E9")

      # same thing, expressed with codes and strings
      converter = MARC::Marc8::ToMarc8.new(charsets: [0x42, "E"])
      assert_equal "caf\xE2e".b, converter.transcode("caf\u00E9")

      # with replacement instead of raising
      converter = MARC::Marc8::ToMarc8.new(charsets: [:basic_latin], invalid: :replace)
      assert_equal "&#x4E2D;".b, converter.transcode("\u4E2D")
    end

    def test_unknown_charset_name
      assert_raise(ArgumentError) do
        MARC::Marc8::ToMarc8.new(charsets: [:no_such_charset])
      end
    end

    def test_constructor_default_options
      converter = MARC::Marc8::ToMarc8.new(invalid: :replace, replace: "?")
      assert_equal "a?b".b, converter.transcode("a\u{1F600}b")
      # per-call options override constructor defaults
      assert_raise(Encoding::UndefinedConversionError) do
        converter.transcode("a\u{1F600}b", invalid: nil)
      end
    end

    def test_round_trip_examples
      examples = [
        "Hello, world!",
        "Conversac\u00E7\u00E3o",
        "M\u00FCller, L\u00E9o",
        "\u4E2D\u56FD\u7C73\u306E",
        "ab\u4E2D\u56FDcd \u03B1\u03B2\u03B3!",
        "\u05D0\u05DC\u05E3 \u05D1\u05D9\u05EA",
        "caf\u00E9 \u2113 \u00B2"
      ]
      converter = MARC::Marc8::ToMarc8.new
      examples.each do |example|
        assert_equal example.unicode_normalize(:nfc), decode(converter.transcode(example)),
          "round trip failed for #{example.inspect}"
      end
    end

    def test_lots_of_utf8_test_cases
      # Encode every line of the pymarc-derived UTF-8 test data to MARC-8,
      # decode it back with the existing decoder, and expect the same
      # normalized unicode back.
      utf8_file = File.open(File.expand_path("../data/test_utf8.txt", __FILE__), "r:UTF-8")

      i = 0
      converter = MARC::Marc8::ToMarc8.new

      begin
        loop do
          i += 1
          utf8 = utf8_file.readline.chomp

          marc8 = converter.transcode(utf8)
          assert_equal "ASCII-8BIT", marc8.encoding.name, "Encoded data line #{i} is tagged binary"

          converted = decode(marc8)
          assert_equal utf8.unicode_normalize(:nfc), converted, "Round trip of test data line #{i}"
        end
      rescue EOFError
        assert i > 1500, "Read as many lines as we expected to, at least 1500"
      rescue => e
        warn "Error at test data line #{i}"
        raise e
      end
    end
  end
else
  require "pathname"
  warn "\nTests not being run in ruby 1.9.x, skipping #{Pathname.new(__FILE__).basename}\n\n"
end
