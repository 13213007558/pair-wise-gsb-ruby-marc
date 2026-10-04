# frozen_string_literal: true

module MARC
  module FixedField
    # Built-in MARC21 bibliographic 008 layouts.
    module MARC21
      DATE_TYPE_CODES = {
        "b" => "公元前日期",
        "c" => "当前出版且持续",
        "d" => "已停止出版",
        "e" => "详细日期",
        "i" => "包含起讫日期",
        "k" => "集中出版的连续出版物",
        "m" => "多个日期",
        "n" => "日期未知",
        "p" => "发行日期和生产/版权日期",
        "q" => "可疑日期",
        "r" => "重印日期/原始日期",
        "s" => "单一已知日期/可能日期",
        "t" => "出版日期和版权日期",
        "u" => "出版状态未知"
      }.freeze

      BOOK_DATE_TYPE_CODES = DATE_TYPE_CODES.reject { |code, _| %w[c d k u].include?(code) }.freeze
      PUBLICATION_STATUS_CODES = {
        "c" => "当前出版的连续出版物",
        "d" => "已停止出版的连续出版物",
        "u" => "出版状态未知"
      }.freeze

      ILLUSTRATION_CODES = %w[a b c d e f g h i j k l m o q].freeze
      AUDIENCE_CODES = %w[a b c d e f g j].freeze
      FORM_CODES = %w[o q r s].freeze
      CONTENTS_CODES = %w[a b c d e f g h i j k l m o p q r s t u v z].freeze
      GOVERNMENT_CODES = %w[a c f g i l m o p s u z].freeze
      YES_NO_CODES = %w[0 1].freeze
      LITERARY_FORM_CODES = %w[0 1 c d e f h i j m p s].freeze
      BIOGRAPHY_CODES = %w[a b c d].freeze
      MODIFIED_RECORD_CODES = %w[# d s x].freeze
      CATALOGING_SOURCE_CODES = %w[ c u].freeze

      FREQUENCY_CODES = %w[a b c d e f g h i j k m q s t u z].freeze
      REGULARITY_CODES = %w[n r u x].freeze
      ORIGINAL_ALPHABET_CODES = %w[0 1].freeze
      ENTRY_CONVENTION_CODES = %w[0 1 2].freeze
      RELIEF_CODES = %w[a b c d e f g].freeze

      def self.declare
        declare_book
        declare_serial
        declare_map
      end

      def self.declare_book
        FixedField.declare(
          :book,
          label: "MARC21 图书",
          aliases: %i[books 图书],
          record_types: %w[a t],
          default_record_type: "a",
          default_bibliographic_level: "m"
        ) do
          common_fields
          field :illustrations, 18, 4, repeatable: true,
            label: "插图代码", aliases: ["插图"],
            codes: code_set(ILLUSTRATION_CODES)
          field :audience_level, 22, 1,
            label: "目标读者", aliases: ["读者对象"],
            codes: code_set(AUDIENCE_CODES)
          field :form_of_item, 23, 1,
            label: "载体形态", aliases: ["资料形态"],
            codes: code_set(FORM_CODES)
          field :contents_nature, 24, 4, repeatable: true,
            label: "内容性质", aliases: ["内容特征"],
            codes: code_set(CONTENTS_CODES)
          field :government_publication, 28, 1,
            label: "政府出版物", aliases: ["政府出版品"],
            codes: code_set(GOVERNMENT_CODES)
          field :conference_publication, 29, 1,
            label: "会议出版物",
            codes: code_set(YES_NO_CODES, "0" => "非会议出版物", "1" => "会议出版物")
          field :festschrift, 30, 1,
            label: "纪念文集",
            codes: code_set(YES_NO_CODES, "0" => "非纪念文集", "1" => "纪念文集")
          field :index, 31, 1,
            label: "索引",
            codes: code_set(YES_NO_CODES, "0" => "无索引", "1" => "有索引")
          gap :undefined_32, 32
          field :literary_form, 33, 1,
            label: "文学形式",
            codes: code_set(LITERARY_FORM_CODES)
          field :biography, 34, 1,
            label: "传记代码",
            codes: code_set(BIOGRAPHY_CODES)
          common_suffix
          book_date_links
        end
      end

      def self.declare_serial
        FixedField.declare(
          :serial,
          label: "MARC21 连续出版物",
          aliases: %i[serials continuing_resource continuing_resources 连续出版物],
          record_types: %w[a t],
          bibliographic_levels: %w[b s i],
          default_record_type: "a",
          default_bibliographic_level: "s"
        ) do
          field :date_entered, 0, 6,
            label: "录入日期", aliases: ["编目日期"],
            pattern: /\A[0-9| ]{6}\z/
          field :publication_status, 6, 1,
            label: "出版状态", aliases: ["日期类型"],
            codes: code_set(PUBLICATION_STATUS_CODES.keys)
          field :date1, 7, 4,
            label: "日期 1", aliases: ["开始日期"],
            pattern: /\A[0-9u| ]{4}\z/
          field :date2, 11, 4,
            label: "日期 2", aliases: ["结束日期"],
            pattern: /\A[0-9u| ]{4}\z/
          field :place, 15, 3,
            label: "出版地", aliases: ["出版、制作、执行地"],
            pattern: /\A[A-Za-z0-9| ]{3}\z/
          field :frequency, 18, 1,
            label: "出版频率", aliases: ["频率"],
            codes: code_set(FREQUENCY_CODES)
          field :regularity, 19, 1,
            label: "出版规律性", aliases: ["规律性"],
            codes: code_set(REGULARITY_CODES)
          field :issn_center, 20, 1,
            label: "ISSN 中心",
            pattern: /\A[A-Za-z0-9| ]\z/
          gap :undefined_21_22, 21, 2
          field :form_of_item, 23, 1,
            label: "载体形态", aliases: ["资料形态"],
            codes: code_set(FORM_CODES)
          field :nature_of_work, 24, 1,
            label: "作品性质",
            pattern: /\A[A-Za-z| ]\z/
          field :contents_nature, 25, 4, repeatable: true,
            label: "内容性质", aliases: ["内容特征"],
            codes: code_set(CONTENTS_CODES)
          field :government_publication, 29, 1,
            label: "政府出版物",
            codes: code_set(GOVERNMENT_CODES)
          field :conference_publication, 30, 1,
            label: "会议出版物",
            codes: code_set(YES_NO_CODES, "0" => "非会议出版物", "1" => "会议出版物")
          field :original_alphabet_title, 31, 1,
            label: "原题名/文字",
            codes: code_set(ORIGINAL_ALPHABET_CODES, "0" => "无原题名", "1" => "有原题名")
          field :entry_convention, 32, 1,
            label: "著录惯例",
            codes: code_set(ENTRY_CONVENTION_CODES)
          gap :undefined_33, 33
          gap :undefined_34, 34
          common_suffix
          serial_date_links
        end
      end

      def self.declare_map
        FixedField.declare(
          :map,
          label: "MARC21 地图",
          aliases: %i[maps 地图],
          record_types: %w[e f],
          default_record_type: "e",
          default_bibliographic_level: "m"
        ) do
          common_fields
          field :relief, 18, 4, repeatable: true,
            label: "地貌表示", aliases: ["地势"],
            codes: code_set(RELIEF_CODES)
          field :projection, 22, 2,
            label: "投影法", aliases: ["地图投影"],
            pattern: /\A[A-Za-z| ]{2}\z/
          field :type_of_cartographic_material, 25, 1,
            label: "地图资料类型", aliases: ["制图资料类型"],
            pattern: /\A[A-Za-z| ]\z/
          gap :undefined_24, 24
          gap :undefined_26_27, 26, 2
          field :government_publication, 28, 1,
            label: "政府出版物",
            codes: code_set(GOVERNMENT_CODES)
          field :form_of_item, 29, 1,
            label: "载体形态", aliases: ["资料形态"],
            codes: code_set(FORM_CODES)
          gap :undefined_30, 30
          field :undefined_31_34, 31, 4
          common_suffix
          map_date_links
        end
      end

      def self.common_fields(layout)
        layout.field :date_entered, 0, 6,
          label: "录入日期", aliases: ["编目日期"],
          pattern: /\A[0-9| ]{6}\z/
        layout.field :date_type, 6, 1,
          label: "日期类型",
          codes: code_set(BOOK_DATE_TYPE_CODES.keys)
        layout.field :date1, 7, 4,
          label: "日期 1", aliases: ["开始日期"],
          pattern: /\A[0-9u| ]{4}\z/
        layout.field :date2, 11, 4,
          label: "日期 2", aliases: ["结束日期"],
          pattern: /\A[0-9u| ]{4}\z/
        layout.field :place, 15, 3,
          label: "出版地", aliases: ["出版、制作、执行地"],
          pattern: /\A[A-Za-z0-9| ]{3}\z/
      end

      def self.common_suffix(layout)
        layout.field :language, 35, 3,
          label: "语言", aliases: ["语种"],
          pattern: /\A[A-Za-z| ]{3}\z/
        layout.field :modified_record, 38, 1,
          label: "修改记录", aliases: ["记录修改类型"],
          codes: code_set(MODIFIED_RECORD_CODES)
        layout.field :cataloging_source, 39, 1,
          label: "编目来源", aliases: ["目录来源"],
          codes: code_set(CATALOGING_SOURCE_CODES)
      end

      def self.book_date_links(layout)
        layout.linked_validator(:date_type, :date1, :date2) do |type, first, second|
          validate_dates(type, first, second,
            single: %w[s k],
            range: %w[e i m q r t],
            bc: %w[b],
            production: %w[p],
            unknown: %w[n u])
        end
      end

      def self.map_date_links(layout)
        layout.linked_validator(:date_type, :date1, :date2) do |type, first, second|
          validate_dates(type, first, second,
            single: %w[s k],
            range: %w[i m q r t],
            bc: %w[b],
            detailed: %w[e],
            production: %w[p],
            unknown: %w[n u])
        end
      end

      def self.serial_date_links(layout)
        layout.linked_validator(:publication_status, :date1, :date2) do |status, first, second|
          case status
          when "c"
            validate_year_pair(first, second)
          when "d"
            validate_closed_serial_dates(first, second)
          when "u"
            validate_unknown_dates(first, second)
          end
        end
      end

      def self.validate_dates(type, first, second, rules)
        return if type == " " || type == "|"

        if rules[:single].include?(type)
          validate_single_year(first, second)
        elsif rules[:range].include?(type)
          validate_year_pair(first, second)
        elsif rules[:production].include?(type)
          validate_year_pair(first, second)
        elsif rules[:bc] && rules[:bc].include?(type)
          validate_year_pair(first, second)
        elsif rules[:unknown].include?(type)
          validate_unknown_dates(first, second)
        end
      end

      def self.validate_single_year(first, second)
        errors = []
        errors << "日期 1 must be four digits for a single date" unless year?(first)
        errors << "日期 2 must be blanks for a single date" unless second == "    "
        errors
      end

      def self.validate_closed_serial_dates(first, second)
        errors = validate_year_pair(first, second)
        if year?(first) && second == "9999"
          errors << "日期 2 cannot be 9999 for a ceased serial"
        end
        errors
      end

      def self.validate_year_pair(first, second)
        errors = []
        errors << "日期 1 must be four digits" unless year?(first)
        errors << "日期 2 must be four digits" unless year?(second) || second == "    "
        if year?(first) && year?(second) && first.to_i > second.to_i && second != "9999"
          errors << "日期 1 cannot be later than 日期 2"
        end
        errors
      end

      def self.validate_unknown_dates(first, second)
        errors = []
        if /\A[0-9u| ]{4}\z/.match(first).nil? || /\A[0-9u| ]{4}\z/.match(second).nil?
          errors << "unknown date ranges must contain digits, u, blanks, or fill characters"
        end
        errors
      end

      def self.year?(value)
        !/\A\d{4}\z/.match(value).nil?
      end

      def self.code_set(codes, labels = {})
        Array(codes).each_with_object({}) do |code, result|
          result[code] = labels[code]
        end
      end
    end
  end
end
