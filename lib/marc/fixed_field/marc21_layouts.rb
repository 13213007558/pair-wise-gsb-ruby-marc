# frozen_string_literal: true

module MARC
  class FixedField
    FIELD_TYPE_CODES = {
      "a" => "Language material",
      "t" => "Manuscript language material",
      "s" => "Serial/Integrated resource",
      "e" => "Cartographic material",
      "f" => "Manuscript cartographic material"
    }.freeze

    BOOK_RECORD_TYPES = [{record_type: "a"}, {record_type: "t"}].freeze
    MAP_RECORD_TYPES = [{record_type: "e"}, {record_type: "f"}].freeze
    CONTINUING_RESOURCE_RECORD_TYPES = %w[b i s].flat_map do |level|
      [{record_type: "a", bibliographic_level: level}, {record_type: "s", bibliographic_level: level}]
    end.freeze

    DATE_TYPES = {
      " " => "No dates given",
      "|" => "No attempt to code",
      "b" => "No dates given",
      "c" => "Continuing resource currently published",
      "d" => "Continuing resource ceased publication",
      "e" => "Detailed date",
      "i" => "Inclusive dates",
      "k" => "Range of years",
      "m" => "Multiple dates",
      "n" => "Dates unknown",
      "p" => "Date of distribution/release",
      "q" => "Questionable date",
      "r" => "Reprint date",
      "s" => "Single known date",
      "t" => "Publication and copyright dates",
      "u" => "Continuing resource status unknown"
    }.freeze

    BOOK_ILLUSTRATIONS = {
      " " => "No illustrations",
      "|" => "No attempt to code",
      "a" => "Illustrations",
      "b" => "Maps",
      "c" => "Portraits",
      "d" => "Charts",
      "e" => "Plans",
      "f" => "Plates",
      "g" => "Music",
      "h" => "Facsimiles",
      "i" => "Coats of arms",
      "j" => "Genealogical tables",
      "k" => "Forms",
      "l" => "Samples",
      "m" => "Phonodisc, phonowire, or phonotape",
      "o" => "Photographs",
      "p" => "Illuminations"
    }.freeze

    AUDIENCE = {
      " " => "Unknown or not applicable",
      "|" => "No attempt to code",
      "a" => "Preschool",
      "b" => "Primary",
      "c" => "Pre-adolescent",
      "d" => "Adolescent",
      "e" => "Adult",
      "f" => "Specialized",
      "g" => "General",
      "j" => "Juvenile"
    }.freeze

    FORM_OF_ITEM = {
      " " => "None of the following",
      "|" => "No attempt to code",
      "o" => "Online",
      "q" => "Direct electronic",
      "r" => "Regular print reproduction",
      "s" => "Electronic"
    }.freeze

    NATURE_OF_CONTENTS = {
      " " => "None of the following",
      "|" => "No attempt to code",
      "0" => "Tables",
      "1" => "Indexes",
      "2" => "Dictionaries",
      "3" => "Encyclopedias",
      "4" => "Concordances",
      "5" => "Abstracts or summaries",
      "6" => "Bibliographies",
      "8" => "Bibliography",
      "a" => "Abstracts",
      "b" => "Bibliographies",
      "c" => "Catalogs",
      "d" => "Dictionaries",
      "e" => "Encyclopedias",
      "f" => "Handbooks",
      "g" => "Legal articles",
      "i" => "Indexes",
      "k" => "Discographies",
      "l" => "Legislation",
      "m" => "Theses",
      "n" => "Surveys of literature",
      "o" => "Reviews",
      "p" => "Programmed texts",
      "q" => "Filmographies",
      "r" => "Directories",
      "s" => "Statistics",
      "t" => "Technical reports",
      "u" => "Standards/specifications",
      "v" => "Legal cases and notes",
      "w" => "Law reports and digests",
      "z" => "Treaties"
    }.freeze

    GOVERNMENT_PUBLICATION = {
      " " => "Not a government publication",
      "|" => "No attempt to code",
      "a" => "Autonomous or semi-autonomous component",
      "c" => "Multilocal",
      "f" => "Federal/national",
      "i" => "International intergovernmental",
      "l" => "Local",
      "m" => "Multistate",
      "o" => "Government publication, level undetermined",
      "s" => "State, provincial, territorial, dependent",
      "u" => "Unknown"
    }.freeze

    CONFERENCE_PUBLICATION = {
      " " => "Not a conference publication",
      "|" => "No attempt to code",
      "0" => "Not a conference publication",
      "1" => "Conference publication"
    }.freeze

    FESTSCHRIFT = {
      " " => "Not a festschrift",
      "|" => "No attempt to code",
      "0" => "Not a festschrift",
      "1" => "Festschrift"
    }.freeze

    INDEX = {
      " " => "No index",
      "|" => "No attempt to code",
      "0" => "No index",
      "1" => "Index present"
    }.freeze

    LITERARY_FORM = {
      " " => "Non-fiction",
      "|" => "No attempt to code",
      "0" => "Non-fiction",
      "1" => "Fiction",
      "c" => "Comic strips",
      "d" => "Dramas",
      "e" => "Essays",
      "f" => "Novels",
      "h" => "Humor, satires, etc.",
      "i" => "Letters",
      "j" => "Short stories",
      "m" => "Mixed forms",
      "p" => "Poetry",
      "s" => "Speeches"
    }.freeze

    BIOGRAPHY = {
      " " => "No biographical material",
      "|" => "No attempt to code",
      "a" => "Autobiography",
      "b" => "Individual biography",
      "c" => "Collective biography",
      "d" => "Contains biographical information"
    }.freeze

    FREQUENCY = {
      " " => "No determinable frequency",
      "|" => "No attempt to code",
      "a" => "Annual",
      "b" => "Bimonthly",
      "c" => "Semiweekly",
      "d" => "Daily",
      "e" => "Biweekly",
      "f" => "Semiannual",
      "g" => "Biennial",
      "h" => "Triennial",
      "i" => "Three times a week",
      "j" => "Three times a month",
      "k" => "Continuously updated",
      "m" => "Monthly",
      "q" => "Quarterly",
      "u" => "Unknown",
      "z" => "Other"
    }.freeze

    REGULARITY = {
      " " => "Regularity undetermined",
      "|" => "No attempt to code",
      "n" => "Normalized irregular",
      "r" => "Regular",
      "u" => "Unknown",
      "x" => "Completely irregular"
    }.freeze

    SERIAL_TYPE = {
      " " => "Not one of the following",
      "|" => "No attempt to code",
      "d" => "Updating database",
      "l" => "Updating loose-leaf",
      "m" => "Monographic series",
      "n" => "Newspaper",
      "p" => "Periodical",
      "w" => "Updating web site"
    }.freeze

    ORIGINAL_ALPHABET_OR_SCRIPT = {
      " " => "No non-roman alphabet/script",
      "|" => "No attempt to code",
      "a" => "Basic roman",
      "b" => "Extended roman",
      "c" => "Cyrillic",
      "d" => "Japanese",
      "e" => "Chinese",
      "f" => "Arabic",
      "g" => "Greek",
      "h" => "Hebrew",
      "i" => "Thai",
      "j" => "Devanagari",
      "k" => "Korean",
      "l" => "Tamil",
      "u" => "Unknown",
      "z" => "Other"
    }.freeze

    ENTRY_CONVENTION = {
      " " => "Successive entry",
      "|" => "No attempt to code",
      "0" => "Successive entry",
      "1" => "Latest entry",
      "2" => "Integrated entry"
    }.freeze

    MAP_SPECIAL_FORMAT = {
      " " => "No special format",
      "|" => "No attempt to code",
      "e" => "Manuscript",
      "j" => "Picture card, post card",
      "k" => "Calendar",
      "l" => "Puzzle",
      "n" => "Game",
      "o" => "Wall map",
      "p" => "Playing cards",
      "r" => "Loose-leaf",
      "z" => "Other"
    }.freeze

    RELIEF = {
      " " => "No relief shown",
      "|" => "No attempt to code",
      "a" => "Contours",
      "b" => "Shading",
      "c" => "Gradient and bathymetric tints",
      "d" => "Hachures",
      "e" => "Bathymetry, soundings",
      "f" => "Form lines",
      "g" => "Spot heights",
      "i" => "Pictorially",
      "j" => "Land forms",
      "k" => "Bathymetry, isolines",
      "m" => "Rock drawings",
      "z" => "Other"
    }.freeze

    CARTOGRAPHIC_MATERIAL_TYPE = {
      " " => "Not applicable",
      "|" => "No attempt to code",
      "d" => "Atlas",
      "e" => "Single map",
      "g" => "Diagram",
      "j" => "Map series",
      "k" => "Profile",
      "l" => "Volume in a series",
      "n" => "Chart",
      "o" => "Globe",
      "p" => "Printed or hand-drawn textile",
      "q" => "Model",
      "r" => "3-D puzzle",
      "s" => "Space or celestial chart",
      "u" => "Unspecified",
      "v" => "View",
      "w" => "Treatise",
      "y" => "Postcard",
      "z" => "Other"
    }.freeze

    MODIFIED_RECORD = {
      " " => "Not modified",
      "|" => "No attempt to code",
      "d" => "Dashed-on information omitted",
      "o" => "Completely romanized",
      "r" => "Shortened",
      "x" => "Missing characters"
    }.freeze

    CATALOGING_SOURCE = {
      " " => "National bibliographic agency",
      "|" => "No attempt to code",
      "c" => "Cooperative cataloging program",
      "d" => "Other",
      "u" => "Unknown"
    }.freeze

    def self.add_common_book_and_serial_segments(layout)
      layout.segment(:date_entered, 0, 6, "Date entered")
      layout.segment(:date_type, 6, 1, "Date type/Publication status", DATE_TYPES)
      layout.segment(:date1, 7, 4, "Date 1")
      layout.segment(:date2, 11, 4, "Date 2")
      layout.segment(:place_of_publication, 15, 3, "Place of publication, production, or execution")
      layout.segment(:language, 35, 3, "Language code")
      layout.segment(:modified_record, 38, 1, "Modified record", MODIFIED_RECORD)
      layout.segment(:cataloging_source, 39, 1, "Cataloging source", CATALOGING_SOURCE)
    end

    def self.book_layout
      Layout.new(id: :marc21_book, label: "MARC21 Books", record_types: BOOK_RECORD_TYPES) do |layout|
        add_common_book_and_serial_segments(layout)
        layout.segment(:illustrations, 18, 4, "Illustrations", BOOK_ILLUSTRATIONS, repeatable: true)
        layout.segment(:target_audience, 22, 1, "Target audience", AUDIENCE)
        layout.segment(:form_of_item, 23, 1, "Form of item", FORM_OF_ITEM)
        layout.segment(:nature_of_contents, 24, 4, "Nature of contents", NATURE_OF_CONTENTS, repeatable: true)
        layout.segment(:government_publication, 28, 1, "Government publication", GOVERNMENT_PUBLICATION)
        layout.segment(:conference_publication, 29, 1, "Conference publication", CONFERENCE_PUBLICATION)
        layout.segment(:festschrift, 30, 1, "Festschrift", FESTSCHRIFT)
        layout.segment(:index, 31, 1, "Index", INDEX)
        layout.reserved(32, 1, "Undefined character position")
        layout.segment(:literary_form, 33, 1, "Literary form", LITERARY_FORM)
        layout.segment(:biography, 34, 1, "Biography", BIOGRAPHY)
      end
    end

    def self.continuing_resource_layout
      options = {id: :marc21_continuing_resource, label: "MARC21 Continuing Resources", record_types: CONTINUING_RESOURCE_RECORD_TYPES}
      Layout.new(options) do |layout|
        add_common_book_and_serial_segments(layout)
        layout.segment(:frequency, 18, 1, "Frequency", FREQUENCY)
        layout.segment(:regularity, 19, 1, "Regularity", REGULARITY)
        layout.reserved(20, 1, "ISDS center code")
        layout.segment(:serials_type, 21, 1, "Type of continuing resource", SERIAL_TYPE)
        layout.segment(:form_of_original_item, 22, 1, "Form of original item", FORM_OF_ITEM)
        layout.segment(:form_of_item, 23, 1, "Form of item", FORM_OF_ITEM)
        layout.segment(:nature_of_contents, 24, 4, "Nature of entire contents", NATURE_OF_CONTENTS, repeatable: true)
        layout.segment(:government_publication, 28, 1, "Government publication", GOVERNMENT_PUBLICATION)
        layout.segment(:conference_publication, 29, 1, "Conference publication", CONFERENCE_PUBLICATION)
        layout.reserved(30, 1, "Undefined character position")
        layout.segment(
          :original_alphabet_or_script,
          31,
          1,
          "Original alphabet or script of title",
          ORIGINAL_ALPHABET_OR_SCRIPT
        )
        layout.reserved(32, 1, "Undefined character position")
        title_page_values = {
          " " => "No title page",
          "0" => "No title page",
          "1" => "Title page",
          "|" => "No attempt to code"
        }
        layout.segment(:title_page, 33, 1, "Title page", title_page_values)
        layout.segment(:entry_convention, 34, 1, "Entry convention", ENTRY_CONVENTION)
      end
    end

    def self.map_layout
      Layout.new(id: :marc21_map, label: "MARC21 Maps", record_types: MAP_RECORD_TYPES) do |layout|
        layout.segment(:date_entered, 0, 6, "Date entered")
        layout.segment(:date_type, 6, 1, "Date type/Publication status", DATE_TYPES)
        layout.segment(:date1, 7, 4, "Date 1")
        layout.segment(:date2, 11, 4, "Date 2")
        layout.segment(:place_of_publication, 15, 3, "Place of publication, production, or execution")
        layout.segment(:relief, 18, 4, "Relief", RELIEF, repeatable: true)
        layout.segment(:projection, 22, 2, "Projection")
        layout.segment(
          :type_of_cartographic_material,
          24,
          1,
          "Type of cartographic material",
          CARTOGRAPHIC_MATERIAL_TYPE
        )
        layout.segment(:special_format_characteristics, 25, 1, "Special format characteristics", MAP_SPECIAL_FORMAT)
        layout.reserved(26, 2, "Undefined character positions")
        layout.segment(:government_publication, 28, 1, "Government publication", GOVERNMENT_PUBLICATION)
        layout.segment(:form_of_item, 29, 1, "Form of item", FORM_OF_ITEM)
        layout.reserved(30, 1, "Undefined character position")
        layout.segment(:index, 31, 1, "Index", INDEX)
        layout.reserved(32, 3, "Undefined character positions")
        layout.segment(:language, 35, 3, "Language code")
        layout.segment(:modified_record, 38, 1, "Modified record", MODIFIED_RECORD)
        layout.segment(:cataloging_source, 39, 1, "Cataloging source", CATALOGING_SOURCE)
      end
    end

    def self.book_006_layout
      Layout.new(id: :marc21_book_006, label: "MARC21 Books - 006", tag: "006", field_length: 18, record_types: [{type_byte: "a"}, {type_byte: "t"}]) do |layout|
        layout.segment(:type_byte, 0, 1, "Type of material", FIELD_TYPE_CODES)
        layout.reserved(1, 4, "Undefined character positions")
        layout.segment(:target_audience, 5, 1, "Target audience", AUDIENCE)
        layout.segment(:form_of_item, 6, 1, "Form of item", FORM_OF_ITEM)
        layout.segment(:nature_of_contents, 7, 4, "Nature of contents", NATURE_OF_CONTENTS, repeatable: true)
        layout.segment(:government_publication, 11, 1, "Government publication", GOVERNMENT_PUBLICATION)
        layout.segment(:conference_publication, 12, 1, "Conference publication", CONFERENCE_PUBLICATION)
        layout.segment(:festschrift, 13, 1, "Festschrift", FESTSCHRIFT)
        layout.segment(:index, 14, 1, "Index", INDEX)
        layout.reserved(15, 1, "Undefined character position")
        layout.segment(:literary_form, 16, 1, "Literary form", LITERARY_FORM)
        layout.segment(:biography, 17, 1, "Biography", BIOGRAPHY)
      end
    end

    def self.continuing_resource_006_layout
      Layout.new(id: :marc21_continuing_resource_006, label: "MARC21 Continuing Resources - 006", tag: "006", field_length: 18, record_types: [{type_byte: "s"}]) do |layout|
        layout.segment(:type_byte, 0, 1, "Type of material", FIELD_TYPE_CODES)
        layout.segment(:frequency, 1, 1, "Frequency", FREQUENCY)
        layout.segment(:regularity, 2, 1, "Regularity", REGULARITY)
        layout.reserved(3, 1, "ISDS center code")
        layout.segment(:serials_type, 4, 1, "Type of continuing resource", SERIAL_TYPE)
        layout.segment(:form_of_original_item, 5, 1, "Form of original item", FORM_OF_ITEM)
        layout.segment(:form_of_item, 6, 1, "Form of item", FORM_OF_ITEM)
        layout.segment(:nature_of_contents, 7, 4, "Nature of entire contents", NATURE_OF_CONTENTS, repeatable: true)
        layout.segment(:government_publication, 11, 1, "Government publication", GOVERNMENT_PUBLICATION)
        layout.segment(:conference_publication, 12, 1, "Conference publication", CONFERENCE_PUBLICATION)
        layout.reserved(13, 1, "Undefined character position")
        layout.segment(:original_alphabet_or_script, 14, 1, "Original alphabet or script of title", ORIGINAL_ALPHABET_OR_SCRIPT)
        layout.reserved(15, 1, "Undefined character position")
        layout.segment(:entry_convention, 16, 1, "Entry convention", ENTRY_CONVENTION)
        layout.reserved(17, 1, "Undefined character position")
      end
    end

    def self.map_006_layout
      Layout.new(id: :marc21_map_006, label: "MARC21 Maps - 006", tag: "006", field_length: 18, record_types: [{type_byte: "e"}, {type_byte: "f"}]) do |layout|
        layout.segment(:type_byte, 0, 1, "Type of material", FIELD_TYPE_CODES)
        layout.reserved(1, 5, "Undefined character positions")
        layout.segment(:relief, 6, 4, "Relief", RELIEF, repeatable: true)
        layout.segment(:projection, 10, 2, "Projection")
        layout.segment(
          :type_of_cartographic_material,
          12,
          1,
          "Type of cartographic material",
          CARTOGRAPHIC_MATERIAL_TYPE
        )
        layout.reserved(13, 2, "Undefined character positions")
        layout.segment(:government_publication, 15, 1, "Government publication", GOVERNMENT_PUBLICATION)
        layout.segment(:form_of_item, 16, 1, "Form of item", FORM_OF_ITEM)
        layout.segment(:special_format_characteristics, 17, 1, "Special format characteristics", MAP_SPECIAL_FORMAT)
      end
    end

  end
end
