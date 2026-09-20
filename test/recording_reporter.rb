# frozen_string_literal: true

require "minitest"

# Stands in for the reporter Minitest hands to the executor with every job. It is the whole
# observation point for the executor's tests: everything the executor is supposed to do is
# visible here, and nothing about how it does it is.
#
# It also records WHERE each call happened. The executor's central promise is that the reporter
# never crosses into a worker, and a reporter that notices which Ractor it was called from is
# the only way to see that promise kept rather than assume it.
class RecordingReporter < Minitest::AbstractReporter
  Call = Struct.new :klass, :name, :result, :ractor

  attr_reader :prerecorded, :recorded

  def initialize
    super
    @prerecorded = []
    @recorded    = []
  end

  def prerecord(klass, name)
    @prerecorded << Call.new(klass, name, nil, ::Ractor.current)
  end

  def record(result)
    @recorded << Call.new(result.klass, result.name, result, ::Ractor.current)
  end

  def names
    @recorded.map(&:name)
  end

  def workers
    @recorded.map { |call| call.result.metadata[:minitest_ractor_worker] }
  end
end
