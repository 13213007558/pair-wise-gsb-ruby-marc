# frozen_string_literal: true

module MARC
  class FixedField
    class Layout
      attr_reader :id, :label, :tag, :field_length, :record_types, :segments

      def initialize(options = nil, id: nil, label: nil, tag: "008", field_length: 40, record_types: nil)
        options ||= {id: id, label: label, tag: tag, field_length: field_length, record_types: record_types || []}
        @id = options.fetch(:id)
        @label = options.fetch(:label)
        @tag = options.fetch(:tag, "008")
        @field_length = options.fetch(:field_length, 40)
        @record_types = options.fetch(:record_types, [])
        @segments = []
        yield self if block_given?
      end

      def segment(name, offset, length, label, values = nil, repeatable: false)
        if @segments.any? { |existing| offset < existing.offset + existing.length && existing.offset < offset + length }
          raise ArgumentError, "segment #{name.inspect} overlaps an existing segment"
        end

        @segments << Segment.new(name, offset, length, label, values, repeatable)
      end

      def reserved(offset, length = 1, label = "Unknown")
        segment("reserved_#{offset}".to_sym, offset, length, label, nil)
      end

      def [](name_or_offset)
        if name_or_offset.is_a?(Symbol)
          return @segments.find { |segment| segment.name == name_or_offset }
        end

        @segments.find { |segment| segment.cover?(name_or_offset.to_i) }
      end


      def segment_for(name_or_offset)
        segment = self[name_or_offset]
        return segment if segment

        raise KeyError, "#{name_or_offset.inspect} is not defined in layout #{id}"
      end

      def offset_of(name)
        segment_for(name).offset
      end

      def matches_record?(record_or_leader, type_byte = nil)
        leader = record_or_leader.is_a?(MARC::Record) ? record_or_leader.leader : record_or_leader
        return false unless leader && leader.length > 7

        record_types.any? do |record_type|
          record_type.all? { |key, value| type_value_for(key, leader, type_byte) == value }
        end
      end

      private

      def type_value_for(key, leader, type_byte)
        case key
        when :record_type then leader[6]
        when :bibliographic_level then leader[7]
        when :type_byte then type_byte
        end
      end
    end
  end
end
