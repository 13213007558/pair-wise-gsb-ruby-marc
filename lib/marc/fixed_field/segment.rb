# frozen_string_literal: true

module MARC
  class FixedField
    class Segment
      attr_reader :name, :offset, :length, :label, :values, :repeatable

      def initialize(name, offset, length, label, values = nil, repeatable = false)
        @name = name
        @offset = offset
        @length = length
        @label = label
        @values = values
        @repeatable = repeatable
      end

      def cover?(position)
        position >= offset && position < offset + length
      end

      def coded?
        !values.nil?
      end

      def valid_value?(value)
        return false unless value.is_a?(String) && value.length == length
        return true unless coded?

        characters = repeatable ? value.chars : [value]
        characters.all? { |character| values.key?(character) }
      end
    end
  end
end
