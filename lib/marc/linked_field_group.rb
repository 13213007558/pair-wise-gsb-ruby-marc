module MARC
  # One original field and the alternate-script fields linked to it through
  # subfield $6. A regular MARC record normally has one 880 field per group.
  # Unpaired groups are valid when exactly one side is absent from a record.
  class LinkedFieldGroup
    attr_reader :tag, :occurrence, :original_fields, :alternate_fields

    def initialize(tag, occurrence, original_fields = [], alternate_fields = [], fields = nil)
      @tag = tag.to_s
      @occurrence = FieldLink.format_occurrence(occurrence)
      @original_fields = Array(original_fields).dup
      @alternate_fields = Array(alternate_fields).dup
      @fields = fields ? Array(fields).dup : @original_fields + @alternate_fields
    end

    def original
      @original_fields.first
    end

    def alternate
      @alternate_fields.first
    end

    def paired?
      !@original_fields.empty? && !@alternate_fields.empty?
    end

    def unpaired?
      !paired?
    end

    def key
      [@tag, @occurrence]
    end

    def fields
      @fields
    end

    def add_original(field)
      @original_fields << field
      @fields << field
    end

    def add_alternate(field)
      @alternate_fields << field
      @fields << field
    end

    def ==(other)
      other.is_a?(self.class) &&
        tag == other.tag &&
        occurrence == other.occurrence &&
        original_fields == other.original_fields &&
        alternate_fields == other.alternate_fields
    end
  end

  class LinkedFieldGroupCollection
    include Enumerable

    attr_reader :groups, :errors

    def initialize(groups, errors)
      @groups = groups
      @errors = errors
    end

    def each(&block)
      @groups.each(&block)
    end

    def [](tag_or_key, occurrence = nil)
      if tag_or_key.is_a?(Integer)
        @groups[tag_or_key]
      else
        key = occurrence ? [tag_or_key.to_s, FieldLink.format_occurrence(occurrence)] : tag_or_key
        @groups.find { |group| group.key == key }
      end
    end

    def valid?
      @errors.empty?
    end

    def empty?
      @groups.empty?
    end
  end
end
