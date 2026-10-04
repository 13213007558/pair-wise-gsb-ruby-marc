module MARC
  # A view over the field-link groups encoded in subfield $8.
  #
  # A $8 value contains a linking number, an optional sequence number,
  # and an optional one-character type/identification code:
  #
  #   "3"      # linking number 3; unnumbered first member
  #   "3.1"    # second member in group 3
  #   "3.1\p"  # second member, with type p
  #
  # A field may contain several $8 subfields and therefore belong to more
  # than one group. Reordering changes only the sequence in the selected
  # $8 occurrences; record field order is intentionally preserved.
  class FieldLinkGroupView
    LINK_PATTERN = /\A([1-9]\d?)(?:\.([1-9]))?(?:\\([A-Za-z0-9]))?\z/

    Link = Struct.new(
      :number, :sequence, :type, :raw, :field_position, :subfield_position
    ) do
      def ordered?
        !sequence.nil?
      end

      def position
        field_position
      end

      alias field_index field_position
      alias subfield_index subfield_position
    end

    Issue = Struct.new(
      :code, :message, :number, :type, :field_position, :subfield_position, :value
    )
    Change = Struct.new(:field_position, :subfield_position, :old_value, :new_value)

    class Group
      attr_reader :record
      attr_reader :number, :members, :issues

      def initialize(record, number, members, issues = [])
        @record = record
        @number = number
        @members = members.sort_by do |link|
          [link.sequence.nil? ? 0 : 1, link.sequence || 0, link.field_position, link.subfield_position]
        end
        @issues = issues
      end

      def type
        types = members.map(&:type).uniq
        types.length == 1 ? types.first : nil
      end

      def fields
        members.map(&:field_position).uniq
      end

      def field_objects
        fields.map { |position| record.fields[position] }
      end

      alias field_records field_objects

      def sequences
        members.map(&:sequence)
      end

      def ordered?
        members.any?(&:ordered?)
      end
    end

    class Plan
      attr_reader :source_view, :changes

      def initialize(source_view, changes)
        @source_view = source_view
        @changes = changes
        @projected_record = source_view.record.deep_dup
        apply_to_record(@projected_record)
        @projected_view = FieldLinkGroupView.new(@projected_record)
      end

      def groups
        @projected_view.groups
      end

      def group(number)
        @projected_view.group(number)
      end

      def issues
        @projected_view.issues
      end

      def valid?
        issues.none?
      end

      alias valid_for_apply? valid?

      def apply
        apply_to_record(source_view.record.deep_dup)
      end

      def apply_to(record)
        unless compatible?(record)
          raise ArgumentError, "record does not match the record used to build this plan"
        end

        apply_to_record(record)
      end

      private

      def compatible?(record)
        source = source_view.record
        record.fields.length == source.fields.length &&
          record.fields.each_with_index.all? do |field, index|
            original = source.fields[index]
            field.class == original.class &&
              field.tag == original.tag &&
              field.respond_to?(:subfields) == original.respond_to?(:subfields)
          end
      end

      def apply_to_record(record)
        changes.each do |change|
          field = record.fields[change.field_position]
          field.subfields[change.subfield_position].value = change.new_value
        end
        record
      end
    end

    attr_reader :record, :links, :issues

    def initialize(record)
      @record = record
      @links = []
      @issues = []
      parse
    end

    def groups
      grouped = @links.group_by(&:number)
      grouped.keys.sort.map do |number|
        members = grouped[number]
        Group.new(@record, number, members, issues_for(number, members))
      end
    end

    def group(number)
      groups.find { |group| group.number == normalized_number(number) }
    end

    def plan
      Plan.new(self, [])
    end

    def linked_fields
      @links.map(&:field_position).uniq
    end

    alias linked_field_positions linked_fields

    def unlinked_fields
      linked = linked_fields
      @record.fields.each_index.reject { |index| linked.include?(index) }
    end

    alias unlinked_field_positions unlinked_fields

    def reorder_group(number, ordered_fields)
      target = group(number)
      raise ArgumentError, "unknown link group #{number.inspect}" unless target

      requested_positions = normalize_requested_fields(ordered_fields, target)
      requested_members = requested_positions.map { |position| link_for_field(position, target) }
      expected = target.members.map { |link| [link.field_position, link.subfield_position] }.sort
      actual = requested_members.map { |link| [link.field_position, link.subfield_position] }.sort
      if requested_members.length != requested_positions.uniq.length || expected != actual
        raise ArgumentError, "reordering must include exactly the members of link group #{target.number}"
      end

      explicit = target.ordered?
      changes = requested_members.each_with_index.flat_map do |link, index|
        sequence = index.zero? && !explicit ? nil : index + (explicit ? 1 : 0)
        new_value = render(link.number, sequence, link.type)
        next [] if link.raw == new_value
        [Change.new(link.field_position, link.subfield_position, link.raw, new_value)]
      end

      Plan.new(self, changes)
    end

    alias reorder reorder_group

    def renumber_groups(mapping = nil)
      normalized = {}
      mapping ||= default_renumbering
      mapping.each do |old_number, new_number|
        old = normalized_number(old_number)
        new = normalized_number(new_number)
        unless @links.any? { |link| link.number == old }
          raise ArgumentError, "unknown link group #{old_number.inspect}"
        end
        normalized[old] = new
      end

      current_numbers = @links.map(&:number).uniq
      targets = normalized.values
      if targets.uniq.length != targets.length ||
          targets.any? { |target| current_numbers.include?(target) && !normalized.key?(target) }
        raise ArgumentError, "renumbering target is already in use"
      end

      changes = @links.select { |link| normalized.key?(link.number) }.map do |link|
        new_value = render(normalized[link.number], link.sequence, link.type)
        next nil if link.raw == new_value
        Change.new(link.field_position, link.subfield_position, link.raw, new_value)
      end.compact

      Plan.new(self, changes)
    end

    alias renumber renumber_groups

    private

    def parse
      @record.fields.each_with_index do |field, field_index|
        next unless field.is_a?(MARC::DataField)

        field.subfields.each_with_index do |subfield, subfield_index|
          next unless subfield.code == "8"

          match = LINK_PATTERN.match(subfield.value)
          unless match
            @issues << Issue.new(
              :invalid_link,
              "invalid $8 link #{subfield.value.inspect}",
              nil, nil, field_index, subfield_index, subfield.value
            )
            next
          end

          @links << Link.new(
            match[1].to_i,
            match[2] && match[2].to_i,
            match[3],
            subfield.value,
            field_index,
            subfield_index
          )
        end
      end
    end

    def issues_for(number, members)
      issues = []
      types = members.map(&:type)
      unique_types = types.uniq
      if unique_types.length > 1
        issues << Issue.new(:type_mismatch, "link group #{number} has inconsistent types", number, nil, nil, nil, nil)
      end

      members.map(&:field_position).group_by(&:itself).each do |field_position, occurrences|
        next unless occurrences.length > 1
          issues << Issue.new(
            :duplicate_link,
            "field #{field_position} joins link group #{number} more than once",
            number, nil, field_position, nil, nil
          )
      end

      if members.any?(&:ordered?)
        sequences = members.select(&:ordered?).map(&:sequence)
        sequences.group_by(&:itself).each do |sequence, occurrences|
          next unless occurrences.length > 1
          issues << Issue.new(
            :duplicate_sequence,
            "link group #{number} repeats sequence #{sequence}",
            number, unique_types.length == 1 ? unique_types.first : nil, nil, nil, nil
          )
        end

        unnumbered = members.select { |link| link.sequence.nil? }
        if unnumbered.length > 1
          unnumbered[1..-1].each do |link|
            issues << Issue.new(
              :missing_sequence,
              "link group #{number} has more than one unnumbered member",
              number, unique_types.length == 1 ? unique_types.first : link.type,
              link.field_position, link.subfield_position, link.raw
            )
          end
        end

        (1..sequences.max.to_i).each do |sequence|
          unless sequences.include?(sequence)
            issues << Issue.new(
              :gap_in_sequence,
              "link group #{number} is missing sequence #{sequence}",
              number, unique_types.length == 1 ? unique_types.first : nil, nil, nil, nil
            )
          end
        end
      end

      issues
    end

    def default_renumbering
      @links.group_by(&:number).keys.sort.each_with_index.each_with_object({}) do |(old_number, index), mapping|
        mapping[old_number] = index + 1
      end
    end

    def normalize_requested_fields(ordered_fields, group)
      field_positions = group.fields
      ordered_fields.map do |field|
        if field.is_a?(MARC::DataField)
          position = @record.fields.index(field)
          unless position && field_positions.include?(position)
            raise ArgumentError, "field is not a member of link group #{group.number}"
          end
          position
        elsif field.is_a?(Integer)
          unless field_positions.include?(field)
            raise ArgumentError, "field position #{field} is not a member of link group #{group.number}"
          end
          field
        else
          raise ArgumentError, "fields must be MARC::DataField objects or field positions"
        end
      end
    end

    def link_for_field(field_position, group)
      links = group.members.select { |link| link.field_position == field_position }
      if links.length > 1
        raise ArgumentError, "field #{field_position} joins link group #{group.number} more than once"
      end
      links.first
    end

    def normalized_number(number)
      Integer(number)
    rescue ArgumentError, TypeError
      raise ArgumentError, "link group number must be an integer"
    end

    def render(number, sequence, type)
      value = number.to_s
      value += ".#{sequence}" if sequence
      value += "\\#{type}" if type
      value
    end
  end

  LinkedFieldGroupView = FieldLinkGroupView

  FieldLinkGroup = FieldLinkGroupView
  LinkedFieldGroup = FieldLinkGroupView
end
