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
end

module MARC
  class LinkedFieldException < MARC::Exception
  end

  class InvalidLinkedFieldException < LinkedFieldException
  end

  class DuplicateOccurrenceNumberException < LinkedFieldException
  end

  class OneToManyLinkedFieldException < LinkedFieldException
  end

  LinkedFieldError = LinkedFieldException
  InvalidLinkedFieldError = InvalidLinkedFieldException
  DuplicateOccurrenceNumberError = DuplicateOccurrenceNumberException
  OneToManyLinkedFieldError = OneToManyLinkedFieldException
end
