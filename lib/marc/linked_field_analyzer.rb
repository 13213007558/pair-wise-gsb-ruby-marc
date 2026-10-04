module MARC
  class LinkedFieldAnalyzer
    def self.analyze(record, allow_duplicate_occurrences: false)
      new(record, allow_duplicate_occurrences).analyze
    end

    def initialize(record, allow_duplicate_occurrences)
      @record = record
      @allow_duplicate_occurrences = allow_duplicate_occurrences
      @groups = Hash.new { |hash, key| hash[key] = LinkedFieldGroup.new(key[0], key[1]) }
      @errors = []
      @occurrence_keys = Hash.new { |hash, occurrence| hash[occurrence] = [] }
      @original_counts = Hash.new(0)
      @alternate_counts = Hash.new(0)
    end

    def analyze
      @record.fields.each do |field|
        next unless field.is_a?(MARC::DataField)

        links = field.subfields.select { |subfield| subfield.code == "6" }
        if links.empty?
          add_invalid(field, "880 fields must include a $6 link") if field.tag == "880"
          next
        end

        if links.length > 1
          add_invalid(field, "has multiple $6 link subfields")
          next
        end

        link = MARC::FieldLink.parse(links.first.value)
        unless link
          add_invalid(field, "has an invalid $6 link: #{links.first.value.inspect}")
          next
        end

        if field.tag == "880"
          analyze_alternate(field, link)
        else
          analyze_original(field, link)
        end
      end

      add_duplicate_occurrence_errors unless @allow_duplicate_occurrences
      add_one_to_many_errors

      groups = @groups.values.sort_by { |group| group.fields.map { |field| @record.fields.index(field) }.min }
      LinkedFieldGroupCollection.new(groups, @errors)
    end

    private

    def analyze_original(field, link)
      if link.tag != "880"
        add_invalid(field, "must link to an 880 field")
        return
      end
      if link.script || link.right_to_left?
        add_invalid(field, "must not include script or orientation information in $6")
        return
      end

      key = [field.tag, link.occurrence]
      @groups[key].add_original(field)
      @occurrence_keys[link.occurrence] << key
      @original_counts[key] += 1
    end

    def analyze_alternate(field, link)
      if link.tag == "880"
        add_invalid(field, "cannot link another 880 field")
        return
      end

      key = [link.tag, link.occurrence]
      @groups[key].add_alternate(field)
      @occurrence_keys[link.occurrence] << key
      @alternate_counts[key] += 1
    end

    def add_invalid(field, message)
      @errors << MARC::InvalidLinkedFieldException.new("#{field.tag} field #{message}")
    end

    def add_duplicate_occurrence_errors
      [@original_counts, @alternate_counts].each do |counts|
        counts.each do |key, count|
          next unless count > 1

          message = "duplicate occurrence number #{key[1]} for #{key[0]}"
          @errors << MARC::DuplicateOccurrenceNumberException.new(message)
        end
      end

      @occurrence_keys.each do |occurrence, keys|
        next unless keys.uniq.length > 1

        message = "occurrence number #{occurrence} is used by more than one field tag"
        @errors << MARC::DuplicateOccurrenceNumberException.new(message)
      end
    end

    def add_one_to_many_errors
      @groups.each do |key, group|
        original_count = group.original_fields.length
        alternate_count = group.alternate_fields.length

        next if original_count.zero? || alternate_count.zero?
        next unless (original_count == 1 && alternate_count > 1) ||
          (original_count > 1 && alternate_count == 1)

        message = "#{key[0]} occurrence #{key[1]} links one field to #{[original_count, alternate_count].max} fields"
        @errors << MARC::OneToManyLinkedFieldException.new(message)
      end
    end
  end
end
