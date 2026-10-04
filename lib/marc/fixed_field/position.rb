# frozen_string_literal: true

module MARC
  module FixedField
    class Position
      attr_reader :name, :label, :offset, :width, :codes, :pattern, :aliases, :repeatable

      def initialize(name, offset, width, options = {})
        @name = name.to_sym
        @label = options[:label] || name.to_s
        @offset = Integer(offset)
        @width = Integer(width)
        @codes = options[:codes] || {}
        @pattern = options[:pattern]
        @aliases = Array(options[:aliases]).map(&:to_s)
        @repeatable = !!options[:repeatable]
      end

      def range
        offset...(offset + width)
      end

      def include?(character_offset)
        range.include?(Integer(character_offset))
      end

      def lookup_names
        [name.to_s, label, *aliases]
      end

      def code_label(value)
        codes[value]
      end
    end
  end
end
