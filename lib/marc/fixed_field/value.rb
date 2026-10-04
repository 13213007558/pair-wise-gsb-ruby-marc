# frozen_string_literal: true

module MARC
  class FixedField
    class Value
      attr_reader :segment, :raw

      def initialize(segment, raw)
        @segment = segment
        @raw = raw
      end

      def state
        return :invalid_width unless raw.length == segment.length
        return :blank if raw.strip.empty?
        return :fill if raw.include?("|") && valid?
        return :unknown if segment.coded? && !valid?

        :known
      end

      def known?
        state == :known
      end

      def blank?
        state == :blank
      end

      def fill?
        state == :fill
      end

      def unknown?
        state == :unknown
      end

      def valid?
        segment.valid_value?(raw)
      end

      def label
        labels = raw_labels
        return labels.first if !segment.repeatable && labels.length == 1

        labels
      end

      private

      def raw_labels
        return [raw] unless segment.coded?

        characters = segment.repeatable ? raw.chars : [raw]
        characters.map { |character| segment.values[character] || "Unknown code #{character.inspect}" }
      end
    end
  end
end
