module MARC
  # basic exception class for exceptions that
  # can occur during MARC processing.

  class Exception < RuntimeError
  end

  class RecordException < MARC::Exception
    attr_reader :record

    def initialize(record)
      @record = record
      id = @record["001"] || "<record with no 001>"
      super("Record #{id}: #{@record.errors.join("\n....")}")
    end
  end

  # Raised for problems with field-link ($6 / 880) relationships:
  # malformed $6 values, duplicate occurrence numbers or one-to-many
  # groupings.
  class LinkException < MARC::Exception
  end

  # Two non-880 fields of the same tag carry $6 links with the same
  # occurrence number, so the number no longer identifies a unique
  # relationship ("duplicate number").
  class DuplicateLinkException < LinkException
  end

  # More than one 880 field claims to be the alternate representation
  # of the same original field, or a group otherwise fans out into a
  # one-to-many relationship.
  class AmbiguousLinkException < LinkException
  end
end
