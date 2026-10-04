# frozen_string_literal: true

module MARC
  # One relationship between an original field and its 880 alternate
  # representation, matched up through their $6 subfields.
  #
  # A group is identified by the original field's tag plus a two-digit
  # occurrence number. Two 245 fields in one record therefore form two
  # separate groups (245-01 and 245-02), each with its own 880; fields
  # sharing a tag are never collapsed into one group.
  #
  # Either side may be missing: MARC permits an original field whose
  # alternate has not (yet) been supplied, and vice versa. Use #paired?
  # to tell.
  class FieldLinkGroup
    # Original tag named by the relationship, e.g. "245".
    attr_reader :tag

    # Occurrence number (Integer) shared by the two $6 values.
    attr_reader :occurrence

    # The original (non-880) field, or nil if only the 880 exists.
    attr_reader :field

    # The 880 alternate-script field, or nil if only the original exists.
    attr_reader :alternate

    def initialize(tag, occurrence, field: nil, alternate: nil)
      @tag = tag
      @occurrence = occurrence
      @field = field
      @alternate = alternate
      freeze
    end

    # Both members of the relationship are present in the record.
    def paired?
      !@field.nil? && !@alternate.nil?
    end

    # The 880 is missing from the record (legal, unpaired original).
    def missing_alternate?
      !@field.nil? && @alternate.nil?
    end

    # The original is missing from the record (legal, dangling 880).
    def missing_original?
      @field.nil? && !@alternate.nil?
    end

    # Members in the fixed order [original, 880], with the missing side
    # omitted.
    def fields
      [@field, @alternate].compact
    end

    # Script identification code carried by the original's $6, falling
    # back to the 880's $6.
    def script
      members_in_order.map(&:link).compact.map(&:script).compact.first
    end

    # Direction information (/r or /r/) from the original's $6, falling
    # back to the 880's $6.
    def direction
      members_in_order.map(&:link).compact.map(&:direction).compact.first
    end

    def key
      [@tag, @occurrence]
    end

    private

    def members_in_order
      [@field, @alternate].compact
    end
  end

  class Record
    ALTERNATE_TAG = "880"

    # Yield each MARC::FieldLinkGroup in the record, in the order the
    # relationship first appears. Returns an Enumerator when no block
    # is given.
    #
    # Legal unpaired fields (an original with no 880, or an 880 whose
    # original is absent) are included; use FieldLinkGroup#paired? to
    # distinguish them.
    #
    # Raises MARC::LinkException for a malformed $6,
    # MARC::DuplicateLinkException when two fields of the same tag reuse
    # an occurrence number, and MARC::AmbiguousLinkException when more
    # than one 880 claims the same original.
    def each_field_link_group
      return enum_for(:each_field_link_group) unless block_given?

      field_link_groups.each { |group| yield group }
    end

    # All FieldLinkGroups; see #each_field_link_group.
    def field_link_groups
      groups = {}
      order = []
      each do |f|
        link = linkable_link(f) or next
        key = group_key(f, link)
        group = groups[key]
        if group.nil?
          order << key
          group = MARC::FieldLinkGroup.new(key[0], key[1])
          groups[key] = group
        end
        if f.tag == ALTERNATE_TAG
          if group.alternate
            raise MARC::AmbiguousLinkException.new(
              "multiple 880 fields link to #{key[0]}-#{'%02d' % key[1]}"
            )
          end
          groups[key] = MARC::FieldLinkGroup.new(
            key[0], key[1], field: group.field, alternate: f
          )
        else
          if group.field
            raise MARC::DuplicateLinkException.new(
              "duplicate occurrence #{'%02d' % key[1]} on linked #{key[0]} fields"
            )
          end
          groups[key] = MARC::FieldLinkGroup.new(
            key[0], key[1], field: f, alternate: group.alternate
          )
        end
      end
      order.map { |key| groups[key] }
    end

    # Find one group. Pass the original tag plus occurrence number:
    #
    #   record.field_link_group("245", 1)
    #
    # or a field that carries a $6 (either side):
    #
    #   record.field_link_group(record["880"])
    #
    # Returns nil when no such group exists.
    def field_link_group(tag_or_field, occurrence = nil)
      if tag_or_field.is_a?(MARC::DataField)
        link = tag_or_field.link
        return nil unless link
        key = group_key(tag_or_field, link)
      else
        raise ArgumentError, "occurrence number required" if occurrence.nil?
        key = [tag_or_field.to_s, Integer(occurrence)]
      end
      field_link_groups.find { |group| group.key == key }
    end

    # Fields carrying a well-formed $6 to an 880 whose partner is
    # missing. Returns DataFields, in record order.
    def unpaired_link_fields
      field_link_groups.reject(&:paired?).flat_map(&:fields)
    end

    # Append a new linked relationship to the record.
    #
    # +field+ is the original field; +alternate+ is an optional 880
    # DataField (its tag is set to 880 if needed). The $6 subfields are
    # generated for both sides, so callers never assemble them by hand.
    #
    # The occurrence number is the lowest unused one for the tag unless
    # given explicitly with +occurrence+.
    #
    # Ordering rules:
    # * the original is appended to the end of the record, and the 880
    #   immediately after it;
    # * a newly created $6 becomes the first subfield, while all other
    #   subfields keep their relative order.
    #
    # Nothing is modified until the whole record has been checked; a
    # malformed $6, duplicate occurrence or one-to-many grouping raises
    # before any field changes.
    def append_field_link(field, alternate = nil, script: nil, direction: nil,
      occurrence: nil)
      raise ArgumentError, "field must be a MARC::DataField" unless field.is_a?(MARC::DataField)
      raise MARC::LinkException, "cannot link an 880 as the original field" if field.tag == ALTERNATE_TAG
      if field.link?
        raise MARC::LinkException, "field already carries a $6 link"
      end
      if fields.include?(field)
        raise MARC::LinkException, "field is already attached to a record"
      end
      if alternate
        raise ArgumentError, "alternate must be a MARC::DataField" unless alternate.is_a?(MARC::DataField)
        if fields.include?(alternate)
          raise MARC::LinkException, "alternate is already attached to a record"
        end
      end

      groups = field_link_groups
      used = groups.select { |g| g.tag == field.tag }.map(&:occurrence)
      number = occurrence ? Integer(occurrence) : (1..Float::INFINITY).find { |n| !used.include?(n) }
      if used.include?(number)
        raise MARC::DuplicateLinkException.new(
          "occurrence #{'%02d' % number} is already used by a #{field.tag} field"
        )
      end

      original_value = link_value(ALTERNATE_TAG, number, script, direction)
      alternate_value = link_value(field.tag, number, script, direction)
      validate_link_value!(original_value)
      validate_link_value!(alternate_value)

      field.set_link(original_value, move_to_front: true)
      if alternate
        alternate.tag = ALTERNATE_TAG
        alternate.remove_link!
        alternate.set_link(alternate_value, move_to_front: true)
      end

      append(field)
      append(alternate) if alternate
      @fields.clean = false

      field_link_group(field.tag, number)
    end

    # Remove a linked relationship identified by tag and occurrence (or
    # by a member field).
    #
    #   record.delete_field_link("245", 1)              # remove both sides
    #   record.delete_field_link("245", 1, member: :alternate) # keep the original
    #
    # With +member: :original+ or +member: :alternate+ only that side is
    # removed; the survivor keeps its $6 and becomes a legal unpaired
    # field. Returns the FieldLinkGroup as it was before deletion.
    def delete_field_link(tag_or_field, occurrence = nil, member: :both)
      unless %i[both original alternate].include?(member)
        raise ArgumentError, "member must be :both, :original or :alternate"
      end
      group = field_link_group(tag_or_field, occurrence)
      raise MARC::LinkException, "no such linked field group" unless group

      doomed = case member
      when :both then group.fields
      when :original then [group.field].compact
      when :alternate then [group.alternate].compact
      end
      @fields.reject! { |f| doomed.include?(f) }
      @fields.clean = false
      group
    end

    # Renumber every relationship's occurrence, per original tag, to
    # 01, 02, ... in the order the groups first appear in the record.
    #
    # Each field's script and direction information is preserved and
    # its $6 subfield keeps its position among the subfields; the field
    # order in the record is untouched.
    #
    # Returns a Hash mapping original tag to an old-occurrence =>
    # new-occurrence Hash.
    def renumber_field_links
      groups = field_link_groups
      seen = Hash.new(0)
      plan = []
      groups.each do |group|
        new_number = (seen[group.tag] += 1)
        next if new_number == group.occurrence
        plan << [group, new_number]
      end

      plan.each do |group, new_number|
        rewrite_occurrence(group.field, new_number) if group.field
        rewrite_occurrence(group.alternate, new_number) if group.alternate
      end
      @fields.clean = false

      groups.each_with_object({}) do |group, mapping|
        (mapping[group.tag] ||= {})[group.occurrence] = renumbered_occurrence(group, plan)
      end
    end

    private

    def linkable_link(field)
      return nil unless field.is_a?(MARC::DataField)
      link = field.link
      return nil if link.nil?
      # Only original <-> 880 relationships are managed here.
      if field.tag == ALTERNATE_TAG || link.tag == ALTERNATE_TAG
        if field.tag == ALTERNATE_TAG && link.tag == ALTERNATE_TAG
          raise MARC::LinkException, "880 field's $6 must name the original tag, not 880"
        end
        link
      end
    end

    def group_key(field, link)
      field.tag == ALTERNATE_TAG ? [link.tag, link.occurrence] : [field.tag, link.occurrence]
    end

    def link_value(tag, occurrence, script, direction)
      value = format("%s-%02d", tag, occurrence)
      value += "/#{script}" if script
      value + direction.to_s
    end

    def validate_link_value!(value)
      MARC::FieldLink.parse(value)
    end

    def rewrite_occurrence(field, new_number)
      link = field.link
      updated = link.with(occurrence: new_number)
      field.set_link(updated.to_s)
    end

    def renumbered_occurrence(group, plan)
      change = plan.find { |g, _| g.key == group.key }
      change ? change[1] : group.occurrence
    end
  end
end
