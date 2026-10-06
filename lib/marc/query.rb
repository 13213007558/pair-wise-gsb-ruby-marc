module MARC
  # MARC::Query is a composable query interface for MARC::Record that
  # makes an explicit distinction between *same-field* constraints and
  # *cross-field* existential constraints.
  #
  # A classic bibliographic question is: "does this record have a 700
  # field with role editor and a specific author?" The two conditions
  # must hold for the *same* 700 occurrence. With naive iteration (or
  # with hashes keyed by tag) it is easy to accidentally answer "yes"
  # when one 700 has the author and a different 700 has the role.
  #
  # MARC::Query.field scopes every constraint built inside its block to
  # a single field occurrence:
  #
  #   query = MARC::Query.field("700") do |f|
  #     f.all(
  #       f.subfield("e").value(/editor/),
  #       f.subfield("a").value(/Twain, Mark/)
  #     )
  #   end
  #   query.matches?(record) # true only if ONE 700 satisfies both
  #
  # Constraints combined at the record level are existentially
  # quantified independently, so this is satisfied even by two
  # different 700 fields:
  #
  #   MARC::Query.all(
  #     MARC::Query.field("700") { |f| f.subfield("a").value(/Twain/) },
  #     MARC::Query.field("700") { |f| f.subfield("e").value("editor") }
  #   )
  #
  # Fields can be bound to names, and subfield values can be captured
  # and referenced from other fields (for example fields linked
  # through a shared subfield 8 value):
  #
  #   query = MARC::Query.all(
  #     MARC::Query.field("700", as: :main) { |f| f.subfield("8").bind(as: :link) },
  #     MARC::Query.field("880", as: :alt) { |f| f.subfield("8").value(MARC::Query.ref(:link)) }
  #   )
  #   result = query.run(record)
  #   result.success?        # boolean
  #   result.values[:link]   # the captured subfield 8 value
  #   result.bindings[:main] # FieldBinding: field, record index, subfield positions
  #
  # Queries operate directly on MARC::Record / MARC::DataField /
  # MARC::Subfield objects. Records are never converted to plain
  # hashes, so repeated tags and repeated subfield codes are fully
  # preserved.
  #
  # Combinators: Query.all (AND), Query.any (OR), Query.not /
  # Query.none (NOT), Query.count (quantity of matching occurrences).
  # The scope of NOT is determined by the binding layer it appears in:
  # inside a field block it negates a constraint on that one field
  # occurrence; at the record level it negates the existence of any
  # matching field.
  #
  # Evaluation produces witnesses: Result#bindings and
  # Result#witnesses expose the concrete fields (with their index in
  # the record) and subfield positions that made the query succeed.
  # On failure the result carries no witnesses at all.
  module Query
    # A reference to a value captured earlier in the query, resolved
    # at evaluation time. See Query.ref.
    class Reference
      attr_reader :name

      def initialize(name)
        @name = name.to_sym
      end
    end

    # Creates a reference to a value bound elsewhere in the query,
    # e.g. MARC::Query.ref(:link). References are resolved
    # left-to-right: the capturing field must be evaluated before the
    # field that references the value.
    def self.ref(name)
      Reference.new(name)
    end

    # A quantity condition used by Query.count and
    # SubfieldBuilder#count.
    class Quantity
      attr_reader :exactly, :at_least, :at_most

      def initialize(exactly: nil, at_least: nil, at_most: nil)
        @exactly = exactly
        @at_least = at_least
        @at_most = at_most
      end

      def matches?(count)
        return false if @exactly && count != @exactly
        return false if @at_least && count < @at_least
        return false if @at_most && count > @at_most
        true
      end
    end

    # Matches a subfield value against a String (exact), Regexp,
    # callable, nil (any value) or a Query::Reference.
    module Matcher
      def self.matches?(matcher, value, values)
        case matcher
        when nil
          true
        when Reference
          values.key?(matcher.name) && values[matcher.name] == value
        when Regexp
          !!(value =~ matcher)
        else
          if matcher.respond_to?(:call)
            !!matcher.call(value)
          else
            matcher == value
          end
        end
      end
    end

    # Matches a field tag against a String, Regexp, Array of tags or
    # nil (any tag).
    module TagMatcher
      def self.matches?(matcher, tag)
        case matcher
        when nil
          true
        when Regexp
          !!(tag =~ matcher)
        when Array
          matcher.include?(tag)
        else
          matcher == tag
        end
      end
    end

    # A concrete subfield occurrence that took part in a successful
    # match: the MARC::Subfield itself plus its index within the
    # field's subfield list.
    class SubfieldMatch
      attr_reader :subfield, :index

      def initialize(subfield, index)
        @subfield = subfield
        @index = index
      end

      def code
        @subfield.code
      end

      def value
        @subfield.value
      end
    end

    # A concrete field occurrence that took part in a successful
    # match: the field itself, its index within the record's field
    # list, and the subfield positions that satisfied the constraints.
    class FieldBinding
      attr_reader :field, :index, :subfield_matches

      def initialize(field, index, subfield_matches = [])
        @field = field
        @index = index
        @subfield_matches = subfield_matches
      end

      def tag
        @field.tag
      end
    end

    # The outcome of running a query against a record. A successful
    # result carries the bindings, captured values and witnesses that
    # made it succeed; a failed result carries none of these.
    class Result
      attr_reader :bindings, :values, :witnesses

      def initialize(success, bindings = {}, values = {}, witnesses = [])
        @success = success
        @bindings = bindings
        @values = values
        @witnesses = witnesses
      end

      # The empty successful result used to start evaluation.
      def self.empty
        new(true)
      end

      # The result of a query that found no solution. Never carries
      # fabricated witnesses.
      def self.failure
        new(false)
      end

      def success?
        @success
      end

      def merge(bindings: {}, values: {}, witnesses: [])
        Result.new(@success,
          @bindings.merge(bindings),
          @values.merge(values),
          @witnesses + witnesses)
      end
    end
    # Base class for record-level query nodes.
    class Node
      # Yields every Result that satisfies this node, extending +base+.
      def each_result(record, base = Result.empty)
        return enum_for(:each_result, record, base) unless block_given?
        raise NotImplementedError
      end

      # Enumerator of all solutions of this query against the record.
      def solutions(record)
        each_result(record)
      end

      # The first solution, or Result.failure when there is none.
      def run(record)
        each_result(record).first || Result.failure
      end

      def matches?(record)
        !each_result(record).first.nil?
      end
    end

    # Record-level AND: all children must succeed, with bindings and
    # captured values threaded left to right.
    class And < Node
      def initialize(children)
        @children = children
      end

      def each_result(record, base = Result.empty)
        return enum_for(:each_result, record, base) unless block_given?
        results = [base]
        @children.each do |child|
          next_results = []
          results.each do |result|
            child.each_result(record, result) do |extended|
              next_results << extended
            end
          end
          results = next_results
          break if results.empty?
        end
        results.each { |result| yield result }
      end
    end

    # Record-level OR: any child may succeed.
    class Or < Node
      def initialize(children)
        @children = children
      end

      def each_result(record, base = Result.empty)
        return enum_for(:each_result, record, base) unless block_given?
        @children.each do |child|
          child.each_result(record, base) { |result| yield result }
        end
      end
    end

    # Record-level NOT: succeeds (without adding witnesses) exactly
    # when the child has no solution in this scope.
    class Not < Node
      def initialize(child)
        @child = child
      end

      def each_result(record, base = Result.empty)
        return enum_for(:each_result, record, base) unless block_given?
        yield base if @child.each_result(record, base).first.nil?
      end
    end

    # Evaluation context for field-level constraints: the field under
    # consideration plus the values captured so far at the record
    # level (used to resolve Query::Reference matchers).
    class FieldContext
      attr_reader :field, :record_values

      def initialize(field, record_values = {})
        @field = field
        @record_values = record_values
      end
    end

    # Accumulates subfield witnesses and captured values while
    # field-level constraints are evaluated against one occurrence.
    class FieldMatch
      attr_reader :subfield_matches, :values

      def initialize(subfield_matches = [], values = {})
        @subfield_matches = subfield_matches
        @values = values
      end

      def merge(other)
        FieldMatch.new(
          @subfield_matches + other.subfield_matches,
          @values.merge(other.values)
        )
      end
    end

    # Base class for constraints evaluated against a single field
    # occurrence.
    class FieldConstraint
      def each_field_match(context, base = FieldMatch.new)
        return enum_for(:each_field_match, context, base) unless block_given?
        raise NotImplementedError
      end
    end

    # Field-level AND: all constraints must hold for this occurrence.
    class FieldAnd < FieldConstraint
      def initialize(children)
        @children = children
      end

      def each_field_match(context, base = FieldMatch.new)
        return enum_for(:each_field_match, context, base) unless block_given?
        matches = [base]
        @children.each do |child|
          next_matches = []
          matches.each do |match|
            child.each_field_match(context, match) do |extended|
              next_matches << extended
            end
          end
          matches = next_matches
          break if matches.empty?
        end
        matches.each { |match| yield match }
      end
    end

    # Field-level OR: any constraint may hold for this occurrence.
    class FieldOr < FieldConstraint
      def initialize(children)
        @children = children
      end

      def each_field_match(context, base = FieldMatch.new)
        return enum_for(:each_field_match, context, base) unless block_given?
        @children.each do |child|
          child.each_field_match(context, base) { |match| yield match }
        end
      end
    end

    # Field-level NOT: succeeds exactly when the inner constraint
    # cannot be satisfied by this field occurrence.
    class FieldNot < FieldConstraint
      def initialize(child)
        @child = child
      end

      def each_field_match(context, base = FieldMatch.new)
        return enum_for(:each_field_match, context, base) unless block_given?
        yield base if @child.each_field_match(context, base).first.nil?
      end
    end
    # Matches a subfield of the current field by code and (optionally)
    # value; can also capture the subfield value under a name so other
    # fields can reference it via Query.ref.
    class SubfieldPredicate < FieldConstraint
      def initialize(code, matcher, bind_as)
        @code = code
        @matcher = matcher
        @bind_as = bind_as
      end

      def each_field_match(context, base = FieldMatch.new)
        return enum_for(:each_field_match, context, base) unless block_given?
        return unless context.field.respond_to?(:subfields)
        values = context.record_values.merge(base.values)
        context.field.subfields.each_with_index do |subfield, index|
          next unless code_matches?(subfield)
          next unless Matcher.matches?(@matcher, subfield.value, values)
          captured = @bind_as ? {@bind_as => subfield.value} : {}
          witness = FieldMatch.new([SubfieldMatch.new(subfield, index)], captured)
          yield base.merge(witness)
        end
      end

      private

      def code_matches?(subfield)
        case @code
        when nil
          true
        when Regexp
          !!(subfield.code =~ @code)
        else
          @code == subfield.code
        end
      end
    end

    # A quantity condition over the number of subfields with a given
    # code within the current field occurrence.
    class SubfieldCount < FieldConstraint
      def initialize(code, quantity)
        @code = code
        @quantity = quantity
      end

      def each_field_match(context, base = FieldMatch.new)
        return enum_for(:each_field_match, context, base) unless block_given?
        return unless context.field.respond_to?(:subfields)
        count = 0
        context.field.subfields.each do |subfield|
          count += 1 if code_matches?(subfield)
        end
        yield base if @quantity.matches?(count)
      end

      private

      def code_matches?(subfield)
        case @code
        when nil
          true
        when Regexp
          !!(subfield.code =~ @code)
        else
          @code == subfield.code
        end
      end
    end

    # Matches an indicator of the current data field against a String
    # or Regexp.
    class IndicatorPredicate < FieldConstraint
      def initialize(position, matcher)
        @position = position
        @matcher = matcher
      end

      def each_field_match(context, base = FieldMatch.new)
        return enum_for(:each_field_match, context, base) unless block_given?
        field = context.field
        return unless field.is_a?(MARC::DataField)
        value = (@position == 1) ? field.indicator1 : field.indicator2
        ok = case @matcher
        when Regexp
          !!(value =~ @matcher)
        else
          @matcher == value
        end
        yield base if ok
      end
    end

    # Matches the tag of the current field against a String, Regexp or
    # Array of tags.
    class TagPredicate < FieldConstraint
      def initialize(matcher)
        @matcher = matcher
      end

      def each_field_match(context, base = FieldMatch.new)
        return enum_for(:each_field_match, context, base) unless block_given?
        yield base if TagMatcher.matches?(@matcher, context.field.tag)
      end
    end

    # Wraps a user-supplied predicate called with the current
    # MARC::DataField (or MARC::ControlField).
    class CustomPredicate < FieldConstraint
      def initialize(callable)
        @callable = callable
      end

      def each_field_match(context, base = FieldMatch.new)
        return enum_for(:each_field_match, context, base) unless block_given?
        yield base if @callable.call(context.field)
      end
    end
    # Record-level node that binds one field occurrence. Every
    # constraint built in the Query.field block must hold for the
    # *same* occurrence; different occurrences never jointly satisfy
    # the constraints of one FieldNode.
    class FieldNode < Node
      def initialize(tag, name, indicator1, indicator2, constraint)
        @tag = tag
        @name = name
        @indicator1 = indicator1
        @indicator2 = indicator2
        @constraint = constraint || FieldAnd.new([])
      end

      def each_result(record, base = Result.empty)
        return enum_for(:each_result, record, base) unless block_given?
        record.fields.each_with_index do |field, index|
          next unless TagMatcher.matches?(@tag, field.tag)
          next unless indicators_match?(field)
          context = FieldContext.new(field, base.values)
          @constraint.each_field_match(context) do |match|
            binding = FieldBinding.new(field, index, match.subfield_matches)
            named = @name ? {@name => binding} : {}
            yield base.merge(bindings: named, values: match.values, witnesses: [binding])
          end
        end
      end

      private

      def indicators_match?(field)
        return true unless @indicator1 || @indicator2
        return false unless field.is_a?(MARC::DataField)
        indicator_matches?(@indicator1, field.indicator1) &&
          indicator_matches?(@indicator2, field.indicator2)
      end

      def indicator_matches?(matcher, value)
        case matcher
        when nil
          true
        when Regexp
          !!(value =~ matcher)
        else
          matcher == value
        end
      end
    end

    # Record-level quantity condition: succeeds when the number of
    # field occurrences satisfying the (optional) inner constraint
    # matches the requested quantity. All matching occurrences are
    # reported as witnesses.
    class CountNode < Node
      def initialize(tag, quantity, constraint)
        @tag = tag
        @quantity = quantity
        @constraint = constraint || FieldAnd.new([])
      end

      def each_result(record, base = Result.empty)
        return enum_for(:each_result, record, base) unless block_given?
        witnesses = []
        record.fields.each_with_index do |field, index|
          next unless TagMatcher.matches?(@tag, field.tag)
          context = FieldContext.new(field, base.values)
          match = @constraint.each_field_match(context).first
          next unless match
          witnesses << FieldBinding.new(field, index, match.subfield_matches)
        end
        yield base.merge(witnesses: witnesses) if @quantity.matches?(witnesses.size)
      end
    end

    # Builds field-level constraints inside a Query.field or
    # Query.count block. All methods return constraint objects; the
    # block must return the constraint(s) to apply, either directly or
    # combined with #all / #any / #not.
    class FieldBuilder
      # Constraint on the field tag: String, Regexp or Array of tags.
      def tag(matcher)
        TagPredicate.new(matcher)
      end

      # Constraint on indicator 1: String or Regexp.
      def indicator1(matcher)
        IndicatorPredicate.new(1, matcher)
      end

      # Constraint on indicator 2: String or Regexp.
      def indicator2(matcher)
        IndicatorPredicate.new(2, matcher)
      end

      # Starts a subfield constraint for the given code (String or
      # Regexp). See SubfieldBuilder.
      def subfield(code)
        SubfieldBuilder.new(code)
      end

      # Field-level AND: all constraints must hold for this occurrence.
      def all(*constraints)
        FieldAnd.new(constraints)
      end

      # Field-level OR: any constraint may hold for this occurrence.
      def any(*constraints)
        FieldOr.new(constraints)
      end

      # Field-level NOT: the inner constraint must not hold for this
      # occurrence.
      def not(constraint)
        FieldNot.new(constraint)
      end

      # Custom predicate called with the current field object.
      def satisfy(&block)
        CustomPredicate.new(block)
      end
    end

    # Builds constraints on the subfields of one field occurrence.
    class SubfieldBuilder
      def initialize(code)
        @code = code
      end

      # The field must have a subfield with this code whose value
      # matches: String (exact), Regexp, callable, or Query.ref(name)
      # for a value captured by another field. With :as, the matching
      # value is captured under that name.
      def value(matcher, as: nil)
        SubfieldPredicate.new(@code, matcher, as)
      end

      # The field must have at least one subfield with this code.
      def exists
        SubfieldPredicate.new(@code, nil, nil)
      end

      # Captures the value of a subfield with this code under a name,
      # so later fields can reference it via Query.ref(name).
      def bind(as:)
        SubfieldPredicate.new(@code, nil, as)
      end

      # Quantity condition on the number of subfields with this code,
      # e.g. f.subfield("e").count(at_least: 2).
      def count(exactly: nil, at_least: nil, at_most: nil)
        SubfieldCount.new(@code,
          Quantity.new(exactly: exactly, at_least: at_least, at_most: at_most))
      end
    end
    # Builds a record-level node that binds one field occurrence.
    # +tag+ may be a String, Regexp, Array of tags or nil (any field).
    # Indicators may be constrained with Strings or Regexps. The block
    # receives a FieldBuilder and must return the constraint(s) to
    # apply to the same occurrence; without a block the node only
    # checks tag and indicators.
    def self.field(tag = nil, as: nil, indicator1: nil, indicator2: nil, &block)
      constraint = block ? constraint_from(block) : nil
      FieldNode.new(tag, as, indicator1, indicator2, constraint)
    end

    # Record-level AND: all nodes must succeed. Bindings and captured
    # values are threaded left to right, so a field on the left can
    # capture a value that a field on the right references.
    def self.all(*nodes)
      And.new(nodes)
    end

    # Record-level OR: any node may succeed.
    def self.any(*nodes)
      Or.new(nodes)
    end

    # Record-level NOT: succeeds when the node has no solution.
    def self.not(node)
      Not.new(node)
    end

    class << self
      alias_method :none, :not
    end

    # Record-level quantity condition over field occurrences, e.g.
    # MARC::Query.count("700", at_least: 2) { |f| ... }.
    def self.count(tag = nil, exactly: nil, at_least: nil, at_most: nil, &block)
      constraint = block ? constraint_from(block) : nil
      CountNode.new(tag,
        Quantity.new(exactly: exactly, at_least: at_least, at_most: at_most),
        constraint)
    end

    # Builds a field-level constraint from a Query.field / Query.count
    # block. The block receives a FieldBuilder; its return value may
    # be a single constraint, an array of constraints (ANDed), or nil
    # (no constraint).
    def self.constraint_from(block)
      built = block.call(FieldBuilder.new)
      case built
      when nil
        FieldAnd.new([])
      when Array
        built.each do |constraint|
          unless constraint.is_a?(FieldConstraint)
            raise ArgumentError, "field block must return field constraints"
          end
        end
        FieldAnd.new(built)
      when FieldConstraint
        built
      else
        raise ArgumentError, "field block must return field constraints"
      end
    end
  end
end
